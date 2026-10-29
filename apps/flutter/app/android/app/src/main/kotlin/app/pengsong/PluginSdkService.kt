package app.pengsong

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor

/** Keeps the activated Core process bound while third-party SDK clients are connected. */
class PluginSdkService : Service() {
    private val endpoint = object : Binder() {
        /** Creates a bidirectional data session using two Binder-transferred pipe handles. */
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != IBinder.FIRST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags)
            data.enforceInterface("app.pengsong.PluginSdk")
            checkNotNull(reply) { "Plugin SDK Open requires a synchronous Binder transaction" }
            val incoming = ParcelFileDescriptor.createPipe()
            try {
                val outgoing = ParcelFileDescriptor.createPipe()
                try {
                    OperitRuntimeNative.acceptPluginSdkPipes(incoming[0].fd, outgoing[1].fd)
                    reply.writeNoException()
                    outgoing[0].writeToParcel(reply, 0)
                    incoming[1].writeToParcel(reply, 0)
                } finally {
                    outgoing.forEach { it.close() }
                }
            } finally {
                incoming.forEach { it.close() }
            }
            return true
        }
    }

    /** Returns the Binder endpoint; Core readiness is established by the activation Activity. */
    override fun onBind(intent: Intent): IBinder = endpoint
}
