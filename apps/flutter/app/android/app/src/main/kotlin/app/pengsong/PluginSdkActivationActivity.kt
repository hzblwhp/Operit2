package app.pengsong

import android.app.Activity
import android.os.Bundle
import android.os.ResultReceiver
import java.io.File
import org.json.JSONObject

/** Boots the configured Core runtime without creating a Flutter activity. */
class PluginSdkActivationActivity : Activity() {
    /** Initializes the selected local identity and reports readiness to the caller. */
    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val receiver = intent.getParcelableExtra<ResultReceiver>("result")
        if (receiver == null) { finish(); return }
        val host = AndroidCoreRuntime.get(this)
        host.runBackground {
            try {
                val response = JSONObject(OperitRuntimeNative.runtimeBootstrapRead(host.defaultRuntimeRootPath()))
                check(response.getBoolean("ok")) { response.getString("error") }
                check(!response.isNull("value")) { "Open Operit and configure local storage before using the Plugin SDK" }
                val config = JSONObject(response.getString("value"))
                check(config.getBoolean("confirmed")) { "Operit local storage has not been confirmed" }
                check(File(config.getString("runtimeRoot")).isAbsolute && File(config.getString("workspaceRoot")).isAbsolute) { "Operit storage roots must be absolute" }
                val identity = config.getString("activeIdentityId")
                check(Regex("^identity-[a-z0-9-]+$").matches(identity)) { "Invalid runtime identity" }
                val identities = config.getJSONArray("identities")
                check((0 until identities.length()).count { identities.getJSONObject(it).getString("id") == identity } == 1) { "Active identity is not configured" }
                host.setStorageRoots(
                    File(config.getString("runtimeRoot"), "identities/$identity").absolutePath,
                    File(config.getString("workspaceRoot"), "identities/$identity").absolutePath,
                )
                host.ensureRuntimeHandle()
                receiver.send(0, Bundle())
            } catch (error: Exception) {
                receiver.send(1, Bundle().apply { putString("error", error.toString()) })
            } finally {
                runOnUiThread { finish() }
            }
        }
    }
}
