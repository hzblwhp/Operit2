package app.pengsong

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class RuntimeCoreLinkChannel(private val runtimeHost: AndroidRuntimeHost) {
    /** Connects Dart FFI to the runtime already owned by the Android host. */
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method != "connectCoreFfi") return false
        runtimeHost.runRuntime(result) {
            OperitRuntimeNative.connectCoreFfi(runtimeHost.ensureRuntimeHandle())
        }
        return true
    }
}
