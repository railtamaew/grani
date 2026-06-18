package com.granivpn.mobile

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.atomic.AtomicLong

/**
 * Доставка состояния VPN и (при подключении) тиков статистики трафика во Flutter без Dart-polling [getStatus]/[getTrafficStats].
 * [emit_type]: `state` — смена состояния; `traffic` — периодический снимок rx/tx только пока туннель поднят.
 * Интервал трафика: 1 с на переднем плане, 4 с в фоне ([setTrafficTelemetryBackgroundMode]).
 */
object VpnNativeStateEmitter {
    private const val TAG = "VpnNativeStateEmitter"
    private const val TRAFFIC_INTERVAL_FOREGROUND_MS = 1000L
    private const val TRAFFIC_INTERVAL_BACKGROUND_MS = 4000L
    private val mainHandler = Handler(Looper.getMainLooper())

    private val trafficTickIntervalMs = AtomicLong(TRAFFIC_INTERVAL_FOREGROUND_MS)

    @Volatile
    private var sink: EventChannel.EventSink? = null

    private val trafficRunnable = object : Runnable {
        override fun run() {
            if (sink == null) return
            val (connected, state) = GraniVpnService.peekStateForFlutter()
            val telemetryAllowed =
                connected || state == "local_up" || state == "dataplane_verified"
            if (!telemetryAllowed) {
                Log.d(TAG, "trafficRunnable: vpn not connected, stop ticks")
                return
            }
            val stats = GraniVpnService.getTrafficStatsSnapshot()
            deliverPayload(connected, state, "traffic", stats)
            val interval = trafficTickIntervalMs.get().coerceIn(500L, 30_000L)
            mainHandler.postDelayed(this, interval)
        }
    }

    fun attach(events: EventChannel.EventSink) {
        mainHandler.post {
            sink = events
            val (connected, state) = GraniVpnService.peekStateForFlutter()
            deliverPayload(connected, state, "state", null)
            if (connected) {
                maybeStartTrafficTicks()
            }
        }
    }

    fun detach() {
        mainHandler.post {
            stopTrafficTicks()
            sink = null
        }
    }

    fun emit(connected: Boolean, serviceState: String) {
        mainHandler.post {
            deliverPayload(connected, serviceState, "state", null)
        }
    }

    /**
     * Post-connect HTTP probe results for Flutter [ConnectionLogger] → POST /vpn/logs/send.
     * [payload] keys are snake_case (English). Safe if [sink] is null (logcat only on native side).
     */
    fun emitConnectivityProbe(payload: Map<String, Any>) {
        mainHandler.post {
            val s = sink ?: return@post
            val (connected, state) = GraniVpnService.peekStateForFlutter()
            val full = mutableMapOf<String, Any>(
                "connected" to connected,
                "service_state" to state,
                "ts" to System.currentTimeMillis(),
                "emit_type" to "connectivity_probe",
            )
            full.putAll(payload)
            try {
                s.success(full)
            } catch (e: Exception) {
                Log.w(TAG, "emitConnectivityProbe failed: ${e.message}")
            }
        }
    }

    /**
     * Runtime diagnostics from native VPN stack (cleanup/kill/fail reasons).
     */
    fun emitRuntimeDiag(eventName: String, payload: Map<String, Any>) {
        mainHandler.post {
            val s = sink ?: return@post
            val (connected, state) = GraniVpnService.peekStateForFlutter()
            val full = mutableMapOf<String, Any>(
                "connected" to connected,
                "service_state" to state,
                "ts" to System.currentTimeMillis(),
                "emit_type" to "runtime_diag",
                "event_name" to eventName,
            )
            full.putAll(payload)
            try {
                s.success(full)
            } catch (e: Exception) {
                Log.w(TAG, "emitRuntimeDiag failed: ${e.message}")
            }
        }
    }

    fun stopTrafficTicks() {
        mainHandler.removeCallbacks(trafficRunnable)
    }

    fun maybeStartTrafficTicks() {
        mainHandler.removeCallbacks(trafficRunnable)
        if (sink == null) return
        val (connected, _) = GraniVpnService.peekStateForFlutter()
        if (!connected) return
        val interval = trafficTickIntervalMs.get().coerceIn(500L, 30_000L)
        mainHandler.postDelayed(trafficRunnable, interval)
    }

    /**
     * Вызывается из Flutter при смене lifecycle: в фоне реже шлём traffic-тики (экономия батареи / main thread).
     */
    fun setTrafficTelemetryBackgroundMode(background: Boolean) {
        val ms = if (background) TRAFFIC_INTERVAL_BACKGROUND_MS else TRAFFIC_INTERVAL_FOREGROUND_MS
        trafficTickIntervalMs.set(ms)
        Log.d(TAG, "trafficTickIntervalMs=$ms background=$background")
        mainHandler.post {
            if (sink == null) return@post
            val (connected, _) = GraniVpnService.peekStateForFlutter()
            if (connected) {
                maybeStartTrafficTicks()
            }
        }
    }

    private fun deliverPayload(
        connected: Boolean,
        serviceState: String,
        emitType: String,
        stats: Map<String, Long>?,
    ) {
        val s = sink ?: return
        val payload = mutableMapOf<String, Any>(
            "connected" to connected,
            "service_state" to serviceState,
            "ts" to System.currentTimeMillis(),
            "emit_type" to emitType,
        )
        if (stats != null) {
            payload["rx_bytes"] = stats["rx_bytes"] ?: 0L
            payload["tx_bytes"] = stats["tx_bytes"] ?: 0L
        }
        try {
            s.success(payload)
        } catch (e: Exception) {
            Log.w(TAG, "deliverPayload failed: ${e.message}")
        }
    }
}
