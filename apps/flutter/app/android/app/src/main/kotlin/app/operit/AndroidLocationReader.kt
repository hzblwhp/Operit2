package app.operit

import android.Manifest
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import androidx.core.os.CancellationSignal
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

        // 目的：优先 provider 之外再并发请求备选 provider，谁先给出定位就用谁。
        //
        // 起因：调用方通常传 highAccuracy=false，于是只走 NETWORK_PROVIDER。
        // 但 Android 的网络定位在国内依赖 Google NLP 后端，实测必然 10s 左右
        // DEADLINE_EXCEEDED（Name resolution delay 0 / remote_addr=null），
        // 与调用方传的 timeout 无关；而 GPS_PROVIDER 是纯卫星、不需要网络。
        // 之前只请求单个 provider，所以 non-high-accuracy 场景在这类环境下永远拿不到定位。
        val preferred = if (highAccuracy) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER
        val fallback = if (highAccuracy) LocationManager.NETWORK_PROVIDER else LocationManager.GPS_PROVIDER
        val providers = listOf(preferred, fallback)
            .filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
            .distinct()
        check(providers.isNotEmpty()) {
            "No location provider is enabled. preferred=$preferred fallback=$fallback"
        }
        val completed = CountDownLatch(1)
        var fix: Location? = null
        var fixProvider: String = preferred
        val signals = ArrayList<Pair<String, CancellationSignal>>()
        try {
            for (candidate in providers) {
                val signal = CancellationSignal()
                signals.add(candidate to signal)
                runCatching {
                    LocationManagerCompat.getCurrentLocation(
                        manager, candidate, signal, ContextCompat.getMainExecutor(activity),
                    ) { location ->
                        if (location != null && fix == null) {
                            fix = location
                            fixProvider = candidate
                            completed.countDown()
                        }
                    }
                }
            }
            check(completed.await(timeout.toLong(), TimeUnit.SECONDS)) {
                "Current location request timed out after ${timeout}s (providers=${providers.joinToString()})"
            }
            val location = fix ?: error("The location provider did not return a current position")
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
                "provider" to fixProvider,
                "timestamp" to location.time,
                "rawData" to JSONObject(mapOf("altitude" to location.altitude,
                    "speed" to location.speed, "bearing" to location.bearing)).toString(),
                "address" to if (address == null) "" else requireNotNull(address.getAddressLine(0)) { "Reverse geocoder omitted the address" },
                "city" to if (address == null) "" else requireNotNull(address.locality) { "Reverse geocoder omitted the city" },
                "province" to if (address == null) "" else requireNotNull(address.adminArea) { "Reverse geocoder omitted the province" },
                "country" to if (address == null) "" else requireNotNull(address.countryName) { "Reverse geocoder omitted the country" },
            )
        } finally {
            for ((_, signal) in signals) {
                runCatching { signal.cancel() }
            }
        }
    }
}
