package com.granivpn.mobile

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.Log
import org.amnezia.awg.backend.Tunnel

object VpnRuntimeCoordinator {
    private const val TAG = "VpnRuntimeCoordinator"
    private const val PREFS_RECONNECT = "grani_vpn_reconnect"
    private const val KEY_INTENTIONALLY_STOPPED = "vpn_intentionally_stopped"
    private const val DEFAULT_WAIT_DOWN_MS = 3200L

    data class ConnectResult(
        val started: Boolean,
        val backend: String,
    )

    fun connect(
        context: Context,
        config: String,
        protocol: String?,
        mtu: Int = 0,
        source: String = "unknown",
        connectionSessionId: String? = null,
    ): ConnectResult {
        val app = context.applicationContext
        val normalizedProtocol = protocol?.trim()?.lowercase()
        Log.i(
            TAG,
            "connect requested source=$source protocol=${normalizedProtocol ?: "unknown"} session=${connectionSessionId ?: "null"}",
        )

        clearIntentionallyStopped(app)
        cleanupBeforeStart(app, source)

        return if (isAwgProtocol(normalizedProtocol)) {
            val state = SimpleAmneziaWgRunner.connect(app, config)
            val started = state == Tunnel.State.UP
            if (!started) {
                NativeVpnRuntimeState.markAwgExpectedUp(app, false)
            }
            scheduleStateRefresh(app)
            ConnectResult(started, "amneziawg")
        } else {
            GraniVpnService.startService(
                app,
                config,
                protocol,
                mtu,
                source = source,
                connectionSessionId = connectionSessionId,
            )
            scheduleStateRefresh(app)
            ConnectResult(started = true, backend = "native")
        }
    }

    fun disconnect(
        context: Context,
        source: String = "unknown",
        reason: String = "unspecified",
        connectionSessionId: String? = null,
        waitForDown: Boolean = true,
    ): Boolean {
        val app = context.applicationContext
        val awgActive = NativeVpnRuntimeState.isAwgLikelyActive(app)
        val nativeActive = NativeVpnRuntimeState.isNativeVpnLikelyActive(app)
        Log.i(
            TAG,
            "disconnect requested source=$source reason=$reason session=${connectionSessionId ?: "null"} " +
                "awg=$awgActive native=$nativeActive",
        )

        setIntentionallyStopped(app, true)

        if (awgActive) {
            SimpleAmneziaWgRunner.disconnect(app)
        } else {
            NativeVpnRuntimeState.markAwgExpectedUp(app, false)
            GraniAwgNotificationService.stop(app)
        }

        if (nativeActive) {
            GraniVpnService.stopService(
                app,
                source = source,
                reason = reason,
                connectionSessionId = connectionSessionId,
            )
            NativeVpnRuntimeState.markNativeVpnExpectedUp(app, false)
        } else {
            NativeVpnRuntimeState.markNativeVpnExpectedUp(app, false)
        }

        if (waitForDown) {
            waitUntilDown(app, DEFAULT_WAIT_DOWN_MS)
        }
        scheduleStateRefresh(app)
        return !NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(app)
    }

    fun cleanupBeforeStart(context: Context, source: String) {
        val app = context.applicationContext
        if (!NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(app)) {
            NativeVpnRuntimeState.markAwgExpectedUp(app, false)
            NativeVpnRuntimeState.markNativeVpnExpectedUp(app, false)
            return
        }
        disconnect(
            app,
            source = "${source}_pre_start",
            reason = "cleanup_before_start",
            waitForDown = true,
        )
        clearIntentionallyStopped(app)
    }

    fun waitUntilDown(context: Context, timeoutMs: Long = DEFAULT_WAIT_DOWN_MS): Boolean {
        val app = context.applicationContext
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (
            NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(app) &&
            SystemClock.elapsedRealtime() < deadline
        ) {
            Thread.sleep(100L)
        }
        val down = !NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(app)
        Log.i(TAG, "wait_until_down result=$down timeout_ms=$timeoutMs")
        return down
    }

    fun scheduleStateRefresh(context: Context) {
        val app = context.applicationContext
        NativeVpnRuntimeState.notifyQuickTile(app)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                NativeVpnRuntimeState.notifyQuickTile(app)
            }, 700L)
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                NativeVpnRuntimeState.notifyQuickTile(app)
            }, 2200L)
        }
    }

    private fun isAwgProtocol(protocol: String?): Boolean {
        val p = protocol?.trim()?.lowercase() ?: return false
        return p == "graniwg" || p == "amneziawg" || p == "awg"
    }

    private fun clearIntentionallyStopped(context: Context) {
        setIntentionallyStopped(context, false)
    }

    private fun setIntentionallyStopped(context: Context, stopped: Boolean) {
        try {
            context.applicationContext.getSharedPreferences(PREFS_RECONNECT, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_INTENTIONALLY_STOPPED, stopped)
                .apply()
        } catch (e: Exception) {
            Log.w(TAG, "set_intentionally_stopped_failed stopped=$stopped", e)
        }
    }
}
