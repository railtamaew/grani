package com.granivpn.mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * После остановки VPN по FCM из [EntitlementFcmReceiver]: дергает Dart `/auth/me`
 * ([EntitlementPushHandler]) или ставит флаг, чтобы [takePendingAndClear] на следующем resume.
 */
object EntitlementAuthSyncBridge {
    private const val TAG = "EntitlementAuthSync"
    const val CHANNEL = "com.granivpn.mobile/entitlement_sync"
    const val ENGINE_CACHE_ID = "grani_main"

    private const val PREFS = "grani_entitlement_auth_sync"
    private const val KEY_PENDING = "pending_auth_sync"
    private const val KEY_SOURCE = "pending_source"

    fun notifyAuthRefreshAfterEntitlementStop(context: Context, traceSource: String) {
        val app = context.applicationContext
        val engine = try {
            FlutterEngineCache.getInstance().get(ENGINE_CACHE_ID)
        } catch (_: Exception) {
            null
        }
        val messenger = engine?.dartExecutor?.binaryMessenger
        if (messenger != null) {
            Handler(Looper.getMainLooper()).post {
                try {
                    MethodChannel(messenger, CHANNEL).invokeMethod(
                        "refreshAuthAfterEntitlement",
                        mapOf("source" to traceSource),
                        object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                Log.i(TAG, "Dart auth sync ok ($traceSource)")
                            }

                            override fun error(
                                errorCode: String,
                                errorMessage: String?,
                                errorDetails: Any?,
                            ) {
                                Log.w(TAG, "Dart auth sync error: $errorCode $errorMessage")
                                setPending(app, traceSource)
                            }

                            override fun notImplemented() {
                                Log.w(TAG, "Dart auth sync notImplemented")
                                setPending(app, traceSource)
                            }
                        },
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "invokeMethod failed: ${e.message}")
                    setPending(app, traceSource)
                }
            }
        } else {
            Log.i(TAG, "No cached engine, pending prefs ($traceSource)")
            setPending(app, traceSource)
        }
    }

    private fun setPending(ctx: Context, source: String) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_PENDING, true)
            .putString(KEY_SOURCE, source)
            .apply()
    }

    fun takePendingAndClear(ctx: Context): Pair<Boolean, String> {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pending = p.getBoolean(KEY_PENDING, false)
        val src = p.getString(KEY_SOURCE, "") ?: ""
        if (pending) {
            p.edit().remove(KEY_PENDING).remove(KEY_SOURCE).apply()
        }
        return Pair(pending, src)
    }
}
