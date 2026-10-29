package app.pengsong

import android.app.ActivityManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import android.text.format.Formatter
import org.json.JSONObject

/** Collects Android device metadata for the Flutter owner system-operation channel. */
object AndroidHostDeviceInfo {
    /** Reads the complete host DeviceInfoData contract from Android system services. */
    fun read(context: Context): String {
        val activityManager = checkNotNull(context.getSystemService(ActivityManager::class.java)) {
            "Android activity service is unavailable"
        }
        val memory = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memory)
        val storage = StatFs(context.filesDir.absolutePath)
        val metrics = context.resources.displayMetrics
        val battery = checkNotNull(context.getSystemService(BatteryManager::class.java)) {
            "Android battery service is unavailable"
        }
        val batteryLevel = battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        check(batteryLevel in 0..100) { "Android battery capacity is unavailable: $batteryLevel" }
        val deviceId = checkNotNull(
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID),
        ) { "Android device ID is unavailable" }
        check(deviceId.isNotBlank()) { "Android device ID is empty" }
        return JSONObject()
            .put("deviceId", deviceId)
            .put("model", Build.MODEL)
            .put("manufacturer", Build.MANUFACTURER)
            .put("androidVersion", Build.VERSION.RELEASE)
            .put("sdkVersion", Build.VERSION.SDK_INT)
            .put("screenResolution", "${metrics.widthPixels}x${metrics.heightPixels}")
            .put("screenDensity", metrics.density.toDouble())
            .put("totalMemory", Formatter.formatFileSize(context, memory.totalMem))
            .put("availableMemory", Formatter.formatFileSize(context, memory.availMem))
            .put("totalStorage", Formatter.formatFileSize(context, storage.totalBytes))
            .put("availableStorage", Formatter.formatFileSize(context, storage.availableBytes))
            .put("batteryLevel", batteryLevel)
            .put("batteryCharging", battery.isCharging)
            .put("cpuInfo", "${Build.HARDWARE}; ${Build.SUPPORTED_ABIS.joinToString(", ")}; " +
                "${Runtime.getRuntime().availableProcessors()} cores")
            .put("networkType", networkType(context))
            .put("additionalInfo", JSONObject()
                .put("brand", Build.BRAND)
                .put("device", Build.DEVICE)
                .put("product", Build.PRODUCT)
                .put("fingerprint", Build.FINGERPRINT))
            .toString()
    }

    /** Reports the active network transports and the explicit disconnected state. */
    private fun networkType(context: Context): String {
        val connectivity = checkNotNull(context.getSystemService(ConnectivityManager::class.java)) {
            "Android connectivity service is unavailable"
        }
        val network = connectivity.activeNetwork
        if (network == null) {
            return "none"
        }
        val capabilities = checkNotNull(connectivity.getNetworkCapabilities(network)) {
            "Android active network capabilities are unavailable"
        }
        val transports = listOf(
            NetworkCapabilities.TRANSPORT_WIFI to "wifi",
            NetworkCapabilities.TRANSPORT_CELLULAR to "cellular",
            NetworkCapabilities.TRANSPORT_ETHERNET to "ethernet",
            NetworkCapabilities.TRANSPORT_BLUETOOTH to "bluetooth",
            NetworkCapabilities.TRANSPORT_VPN to "vpn",
            NetworkCapabilities.TRANSPORT_WIFI_AWARE to "wifi-aware",
            NetworkCapabilities.TRANSPORT_LOWPAN to "lowpan",
            NetworkCapabilities.TRANSPORT_USB to "usb",
            NetworkCapabilities.TRANSPORT_THREAD to "thread",
            NetworkCapabilities.TRANSPORT_SATELLITE to "satellite",
        ).filter { (transport, _) -> capabilities.hasTransport(transport) }
        check(transports.isNotEmpty()) { "Android active network has no supported transport" }
        return transports.joinToString(",") { (_, name) -> name }
    }
}
