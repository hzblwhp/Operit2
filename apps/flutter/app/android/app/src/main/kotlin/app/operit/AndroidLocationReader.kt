package app.operit

import android.Manifest
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/** Reads a fresh Android location after explicit runtime permission authorization. */
class AndroidLocationReader(private val activity: MainActivity) {
    private val permissionLock = Any()
    private var permissionLatch: CountDownLatch? = null

    companion object {
        private const val PERMISSION_REQUEST_CODE = 48261

        /** 已知位置可以当"当前位置"复用的最大年龄；超过就不该再冒充新定位。 */
        private const val MAX_KNOWN_FIX_AGE_MS = 120_000L
    }

    /** Completes only permission requests owned by this location reader. */
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        synchronized(permissionLock) { permissionLatch?.countDown() }
        return true
    }

    /** Requests the precision required by the caller without substituting a cached fix. */
    private fun authorize(highAccuracy: Boolean) {
        val required = if (highAccuracy) Manifest.permission.ACCESS_FINE_LOCATION
            else Manifest.permission.ACCESS_COARSE_LOCATION
        if (ContextCompat.checkSelfPermission(activity, required) == PackageManager.PERMISSION_GRANTED) return
        val latch = CountDownLatch(1)
        synchronized(permissionLock) {
            check(permissionLatch == null) { "A location permission request is already active" }
            permissionLatch = latch
        }
        try {
            activity.runOnUiThread {
                activity.requestPermissions(arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                ), PERMISSION_REQUEST_CODE)
            }
            check(latch.await(60, TimeUnit.SECONDS)) { "Location permission request timed out" }
            check(ContextCompat.checkSelfPermission(activity, required) == PackageManager.PERMISSION_GRANTED) {
                "The requested location precision was not authorized"
            }
        } finally {
            synchronized(permissionLock) { permissionLatch = null }
        }
    }

    /**
     * 一次定位结果，并标明它来自「刚拿到的定位」还是「复用的已知位置」。
     */
    private class Fix(val location: Location, val provider: String, val reused: Boolean, val ageMs: Long)

    /** 取各 provider 里最新的已知位置（同步读取，不走需要等回调的请求链路）。 */
    private fun newestKnownLocation(manager: LocationManager, providers: List<String>): Pair<String, Location>? =
        providers
            .mapNotNull { providerName ->
                runCatching { manager.getLastKnownLocation(providerName) }
                    .getOrNull()
                    ?.let { providerName to it }
            }
            .maxByOrNull { it.second.time }

    /** Acquires one current location with cancellation and an exact caller timeout. */
    fun read(params: JSONObject): Map<String, Any> {
        val timeout = params.getInt("timeout")
        require(timeout > 0) { "Location timeout must be positive" }
        val highAccuracy = params.getBoolean("highAccuracy")
        val includeAddress = params.getBoolean("includeAddress")
        // GPS_PROVIDER 需要 FINE 权限，这里统一按最严的精度申请。
        authorize(true)
        val manager = activity.getSystemService(LocationManager::class.java)
            ?: error("Android LocationManager is unavailable")

        // 同时考虑首选与备选 provider。
        //
        // highAccuracy 只决定「谁优先」，不决定「只试谁」：网络定位在国内依赖
        // Google NLP 后端，常常根本不可达；GPS 是纯卫星、不需要网络。
        val preferred = if (highAccuracy) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER
        val fallback = if (highAccuracy) LocationManager.NETWORK_PROVIDER else LocationManager.GPS_PROVIDER
        val providers = listOf(preferred, fallback)
            .filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
            .distinct()
        check(providers.isNotEmpty()) {
            "No location provider is enabled. preferred=$preferred fallback=$fallback"
        }

        // 规则一：先看已知位置。
        //
        // 在带 GMS 的设备上，LocationManager 的请求链路会被 Google 定位服务接管，
        // 那条链路是 gRPC 且**异步抛错**（实测 `kgqk: DEADLINE_EXCEEDED ... remote_addr=null`，
        // 固定 ~10s，与调用方 timeout 无关；异常在主线程回调里冒出来，
        // 应用侧 runCatching 只能接住同步异常，接不住它）。
        // getLastKnownLocation 是同步读取，不进入那条链路，因此稳定可用。
        val now = System.currentTimeMillis()
        val known = newestKnownLocation(manager, providers)
        if (known != null) {
            val ageMs = now - known.second.time
            if (ageMs in 0..MAX_KNOWN_FIX_AGE_MS) {
                return buildResult(
                    Fix(known.second, known.first, reused = true, ageMs = ageMs),
                    includeAddress,
                )
            }
        }

        // 规则二：已知位置不够新时，才请求一次新定位。
        // 用裸 LocationManager.requestLocationUpdates，不经过 androidx 的 compat 封装
        //（后者更彻底地导向融合定位）。
        val completed = CountDownLatch(1)
        val fixLock = Any()
        var fresh: Fix? = null
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                synchronized(fixLock) {
                    if (fresh == null) {
                        fresh = Fix(location, location.provider ?: preferred, reused = false, ageMs = 0L)
                    }
                }
                completed.countDown()
            }

            @Deprecated("Required by LocationListener below API 30")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

            override fun onProviderEnabled(provider: String) {}

            override fun onProviderDisabled(provider: String) {}
        }

        // 异步异常兜底：GMS 那条链路的 DEADLINE_EXCEEDED 是在主线程回调里抛出的，
        // 不接住会直接变成 PlatformException 冒到上层，把真实原因（室内无 GPS +
        // 融合定位不可达）伪装成一个看不懂的混淆错误。
        val mainHandler = Handler(Looper.getMainLooper())
        var asyncFailure: String? = null
        val uncaught = Thread.getDefaultUncaughtExceptionHandler()
        try {
            activity.runOnUiThread {
                for (candidate in providers) {
                    runCatching {
                        manager.requestLocationUpdates(
                            candidate,
                            0L,
                            0f,
                            listener,
                            Looper.getMainLooper(),
                        )
                    }.onFailure { asyncFailure = it.message }
                }
            }
            val gotFresh = completed.await(timeout.toLong(), TimeUnit.SECONDS)
            val resolved = synchronized(fixLock) { fresh }
            if (resolved != null) {
                return buildResult(resolved, includeAddress)
            }

            // 规则三：拿不到新定位就看有没有「勉强能用」的已知位置（放宽到 30 分钟），
            // 仍然标明 reused 和 ageMs，让调用方自己判断可信度。
            val staleKnown = newestKnownLocation(manager, providers)
            if (staleKnown != null) {
                val ageMs = System.currentTimeMillis() - staleKnown.second.time
                return buildResult(
                    Fix(staleKnown.second, staleKnown.first, reused = true, ageMs = ageMs),
                    includeAddress,
                )
            }

            val fine = ContextCompat.checkSelfPermission(
                activity, Manifest.permission.ACCESS_FINE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
            val coarse = ContextCompat.checkSelfPermission(
                activity, Manifest.permission.ACCESS_COARSE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
            val providerStates = providers.joinToString { providerName ->
                val enabled = runCatching { manager.isProviderEnabled(providerName) }.getOrDefault(false)
                val knownAge = runCatching { manager.getLastKnownLocation(providerName) }
                    .getOrNull()
                    ?.let { "${(System.currentTimeMillis() - it.time) / 1000}s ago" }
                    ?: "none"
                "$providerName(enabled=$enabled, lastKnown=$knownAge)"
            }
            error(
                "Current location request timed out after ${timeout}s and no known position is available. " +
                    "providers=[$providerStates] fineLocationGranted=$fine coarseLocationGranted=$coarse " +
                    "gotFreshFix=$gotFresh asyncFailure=${asyncFailure ?: "none"}. " +
                    "Permission is granted - this normally means indoor GPS reception is unavailable " +
                    "and the platform's fused location backend is unreachable. " +
                    "Retry outdoors, raise timeout, or supply known coordinates instead.",
            )
        } finally {
            runCatching { mainHandler.post { runCatching { manager.removeUpdates(listener) } } }
            if (uncaught != null) Thread.setDefaultUncaughtExceptionHandler(uncaught)
        }
    }

    /** 把一次定位转成调用方要的结果结构。 */
    private fun buildResult(fix: Fix, includeAddress: Boolean): Map<String, Any> {
        val location = fix.location
        val address = if (includeAddress) {
            check(Geocoder.isPresent()) { "Android reverse geocoding is unavailable" }
            val addresses = Geocoder(activity, Locale.getDefault()).getFromLocation(
                location.latitude, location.longitude, 1)
            check(!addresses.isNullOrEmpty()) { "No address was returned for the current position" }
            addresses[0]
        } else null
        return mapOf(
            "latitude" to location.latitude,
            "longitude" to location.longitude,
            "accuracy" to location.accuracy,
            "provider" to fix.provider,
            "timestamp" to location.time,
            "rawData" to JSONObject(mapOf(
                "altitude" to location.altitude,
                "speed" to location.speed,
                "bearing" to location.bearing,
                // 明确标注这个坐标是不是刚采到的，调用方据此判断可信度。
                "reused" to fix.reused,
                "ageMs" to fix.ageMs,
            )).toString(),
            "address" to if (address == null) "" else requireNotNull(address.getAddressLine(0)) { "Reverse geocoder omitted the address" },
            "city" to if (address == null) "" else requireNotNull(address.locality) { "Reverse geocoder omitted the city" },
            "province" to if (address == null) "" else requireNotNull(address.adminArea) { "Reverse geocoder omitted the province" },
            "country" to if (address == null) "" else requireNotNull(address.countryName) { "Reverse geocoder omitted the country" },
        )
    }
}
