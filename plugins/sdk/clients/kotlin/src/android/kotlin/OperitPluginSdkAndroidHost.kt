package operit.plugin.sdk

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.ResultReceiver
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Supplies Binder activation and owned pipe descriptors to AndroidPluginSdkIpcHost. */
internal class OperitPluginSdkAndroidHost(private val context: Context) : AutoCloseable {
    private var endpoint: IBinder? = null
    private var connection: ServiceConnection? = null
    private var activeSessions = 0

    /** Activates Operit from a visible client, waits for Core, and binds its SDK service. */
    @Synchronized
    fun activate() {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Plugin SDK activation must run off the main thread" }
        if (endpoint != null) {
            check(endpoint!!.isBinderAlive) { "Operit Binder connection has died; close this client" }
            return
        }
        val ready = CompletableFuture<Unit>()
        val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
            /** Completes activation with the exact Core startup result. */
            override fun onReceiveResult(code: Int, data: Bundle?) {
                if (code == 0) ready.complete(Unit)
                else ready.completeExceptionally(IllegalStateException(data?.getString("error")))
            }
        }
        context.startActivity(Intent().setComponent(ComponentName("app.pengsong", "app.pengsong.PluginSdkActivationActivity"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("result", receiver))
        ready.get(60, TimeUnit.SECONDS)
        val bound = CompletableFuture<IBinder>()
        val service = object : ServiceConnection {
            /** Records the authenticated service Binder delivered by Android. */
            override fun onServiceConnected(name: ComponentName, binder: IBinder) { bound.complete(binder) }
            /** Rejects a connection lost while activation is in progress. */
            override fun onServiceDisconnected(name: ComponentName) { bound.completeExceptionally(IllegalStateException("Operit service disconnected")) }
            /** Rejects a service that does not publish its Binder. */
            override fun onNullBinding(name: ComponentName) { bound.completeExceptionally(IllegalStateException("Operit returned a null Binder")) }
            /** Reports package replacement or permanent binding loss. */
            override fun onBindingDied(name: ComponentName) { bound.completeExceptionally(IllegalStateException("Operit service binding died")) }
        }
        check(context.bindService(Intent().setComponent(ComponentName("app.pengsong", "app.pengsong.PluginSdkService")), service, Context.BIND_AUTO_CREATE)) { "Cannot bind Operit Plugin SDK service" }
        try {
            endpoint = bound.get(30, TimeUnit.SECONDS)
            connection = service
        } catch (error: Exception) {
            context.unbindService(service)
            throw error
        }
    }

    /** Returns owned read/write descriptors that the Rust SDK takes responsibility for closing. */
    @Synchronized
    fun open(): IntArray {
        activate()
        val request = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            request.writeInterfaceToken("app.pengsong.PluginSdk")
            check(endpoint!!.transact(IBinder.FIRST_CALL_TRANSACTION, request, reply, 0)) { "Operit rejected Plugin SDK Open" }
            reply.readException()
            val reader = ParcelFileDescriptor.CREATOR.createFromParcel(reply)
            reader.use {
                val writer = ParcelFileDescriptor.CREATOR.createFromParcel(reply)
                writer.use {
                    val result = intArrayOf(reader.detachFd(), writer.detachFd())
                    activeSessions += 1
                    return result
                }
            }
        } catch (error: Exception) {
            if (activeSessions == 0) close()
            throw error
        } finally {
            reply.recycle()
            request.recycle()
        }
    }

    /** Releases one native session's ownership of the process binding. */
    @Synchronized
    fun release() {
        check(activeSessions > 0) { "Plugin SDK binding has no active session" }
        activeSessions -= 1
        if (activeSessions == 0) close()
    }

    /** Releases the process binding after the native SDK sessions have been closed. */
    @Synchronized
    override fun close() {
        connection?.let { context.unbindService(it) }
        connection = null
        endpoint = null
    }
}
