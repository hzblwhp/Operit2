package app.operit

import android.Manifest
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
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
     * 收集一次定位结果，记录它是否来自「刚拿到的卫星/网络定位」还是「复用的已知位置」。
     */
    private class Fix(val location: Location, val provider: String, val reused: Boolean, val ageMs: Long)

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

        // 同时请求首选与备选 provider，谁先给出定位就用谁。
        //
        // highAccuracy 只决定「谁优先」，不决定「只试谁」：网络定位在国内依赖
        // Google NLP 后端，常常根本不可达；而 GPS 是纯卫星、不需要网络。
        // 只请求单个 provider 会让某一种环境下永远拿不到定位。
        val preferred = if (highAccuracy) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER
        val fallback = if (highAccuracy) LocationManager.NETWORK_PROVIDER else LocationManager.GPS_PROVIDER
        val providers = listOf(preferred, fallback)
            .filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
            .distinct()
        check(providers.isNotEmpty()) {
            "No location provider is enabled. preferred=$preferred fallback=$fallback"
        }

        // 刻意不用 androidx 的 LocationManagerCompat.getCurrentLocation。
        //
        // 在带 GMS 的设备上它会被导向 Google 融合定位，而那条链路是 gRPC：
        // 实测报 `DEADLINE_EXCEEDED ... remote_addr=null`，**调用方传的 timeout 被无视**，
        // 固定 ~10s 就抛错，即使 GPS 明明能给出坐标。直接调系统
        // LocationManager.requestLocationUpdates 可以完全绕开这层。
        val completed = CountDownLatch(1)
        val fixLock = Any()
        var fresh: Fix? = null
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                synchronized(fixLock) {
                    if (fresh == null) {
                        fresh = Fix(
                            location = location,
                            provider = location.provider ?: preferred,
                            reused = false,
                            ageMs = 0L,
                        )
                    }
                }
                completed.countDown()
            }

            @Deprecated("Required by LocationListener below API 30")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

            override fun onProviderEnabled(provider: String) {}

            override fun onProviderDisabled(provider: String) {}
        }

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
                    }
                }
            }
            val gotFreshFix = completed.await(timeout.toLong(), TimeUnit.SECONDS)
            val resolved = synchronized(fixLock) { fresh } ?: run {
                // 超时没拿到新定位。只有在存在「足够新的已知位置」时才回退，
                // 并且把它标成 reused —— 不能让调用方把一小时前的坐标当成当前位置。
                val now = System.currentTimeMillis()
                val known = providers
                    .mapNotNull { providerName ->
                        runCatching { manager.getLastKnownLocation(providerName) }.getOrNull()
                            ?.let { providerName to it }
                    }
                    .maxByOrNull { it.second.time }
                val reusable = known?.takeIf { (_, location) ->
                    now - location.time in 0..MAX_KNOWN_FIX_AGE_MS
                }
                if (reusable == null) {
                    val fine = ContextCompat.checkSelfPermission(
                        activity, Manifest.permission.ACCESS_FINE_LOCATION,
                    ) == PackageManager.PERMISSION_GRANTED
                    val coarse = ContextCompat.checkSelfPermission(
                        activity, Manifest.permission.ACCESS_COARSE_LOCATION,
                    ) == PackageManager.PERMISSION_GRANTED
                    val providerStates = providers.joinToString { providerName ->
                        val enabled = runCatching { manager.isProviderEnabled(providerName) }
                            .getOrDefault(false)
                        val knownAge = runCatching { manager.getLastKnownLocation(providerName) }
                            .getOrNull()
                            ?.let { "${(now - it.time) / 1000}s ago" }
                            ?: "none"
                        "$providerName(enabled=$enabled, lastKnown=$knownAge)"
                    }
                    error(
                        "Current location request timed out after ${timeout}s. " +
                            "providers=[$providerStates] " +
                            "fineLocationGranted=$fine coarseLocationGranted=$coarse " +
                            "gotFreshFix=$gotFreshFix. " +
                            "Permission is granted and no provider produced a fix within the timeout - " +
                            "this normally means indoor GPS reception is unavailable and the network " +
                            "provider cannot reach its backend. Retry outdoors, raise timeout, " +
                            "or supply known coordinates instead.",
                    )
                }
                Fix(
                    location = reusable.second,
                    provider = reusable.first,
                    reused = true,
                    ageMs = now - reusable.second.time,
                )
            }

            val location = resolved.location
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
                "provider" to resolved.provider,
                "timestamp" to location.time,
                "rawData" to JSONObject(mapOf(
                    "altitude" to location.altitude,
                    "speed" to location.speed,
                    "bearing" to location.bearing,
                    // 明确标注这个坐标是不是刚采到的，调用方据此判断可信度。
                    "reused" to resolved.reused,
                    "ageMs" to resolved.ageMs,
                )).toString(),
                "address" to if (address == null) "" else requireNotNull(address.getAddressLine(0)) { "Reverse geocoder omitted the address" },
                "city" to if (address == null) "" else requireNotNull(address.locality) { "Reverse geocoder omitted the city" },
                "province" to if (address == null) "" else requireNotNull(address.adminArea) { "Reverse geocoder omitted the province" },
                "country" to if (address == null) "" else requireNotNull(address.countryName) { "Reverse geocoder omitted the country" },
            )
        } finally {
            runCatching { manager.removeUpdates(listener) }
        }
    }
}
