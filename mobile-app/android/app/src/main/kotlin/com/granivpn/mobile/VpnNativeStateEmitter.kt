package com.granivpn.mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.Locale
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
    private val sinkGeneration = AtomicLong(0L)
    @Volatile
    private var appContext: Context? = null

    fun setAppContext(context: Context) {
        appContext = context.applicationContext
    }

    private val trafficRunnable = object : Runnable {
        override fun run() {
            if (sink == null) return
            val current = currentState()
            val telemetryAllowed =
                current.nativeLikelyActive &&
                    (current.connected ||
                        current.serviceState == "local_up" ||
                        current.serviceState == "dataplane_verified")
            if (!telemetryAllowed) {
                Log.d(TAG, "trafficRunnable: vpn not connected, stop ticks")
                return
            }
            val stats = GraniVpnService.getTrafficStatsSnapshot()
            deliverPayload(current, "traffic", stats)
            val interval = trafficTickIntervalMs.get().coerceIn(500L, 30_000L)
            mainHandler.postDelayed(this, interval)
        }
    }

    fun attach(events: EventChannel.EventSink) {
        mainHandler.post {
            sinkGeneration.incrementAndGet()
            sink = events
            val current = currentState()
            deliverPayload(current, "state", null)
            if (current.connected && current.nativeLikelyActive) {
                maybeStartTrafficTicks()
            }
        }
    }

    fun detach() {
        mainHandler.post {
            sinkGeneration.incrementAndGet()
            stopTrafficTicks()
            sink = null
        }
    }

    fun emit(connected: Boolean, serviceState: String) {
        if (sink == null) return
        val generation = sinkGeneration.get()
        mainHandler.post {
            if (generation != sinkGeneration.get()) return@post
            deliverPayload(currentState(connected, serviceState), "state", null)
        }
    }

    fun emitRuntimeSnapshot(context: Context, emitType: String = "state") {
        setAppContext(context)
        if (sink == null) return
        val generation = sinkGeneration.get()
        mainHandler.post {
            if (generation != sinkGeneration.get()) return@post
            deliverPayload(currentState(), emitType, null)
            val current = currentState()
            if (current.connected && current.nativeLikelyActive) {
                maybeStartTrafficTicks()
            } else {
                stopTrafficTicks()
            }
        }
    }

    /**
     * Post-connect HTTP probe results for Flutter [ConnectionLogger] → POST /vpn/logs/send.
     * [payload] keys are snake_case (English). Safe if [sink] is null (logcat only on native side).
     */
    fun emitConnectivityProbe(payload: Map<String, Any>) {
        if (sink == null) return
        val generation = sinkGeneration.get()
        mainHandler.post {
            if (generation != sinkGeneration.get()) return@post
            val s = sink ?: return@post
            val current = currentState()
            val full = mutableMapOf<String, Any>(
                "connected" to current.connected,
                "service_state" to current.serviceState,
                "runtime_status" to current.runtimeStatus,
                "runtime_backend" to current.runtimeBackend,
                "runtime_protocol" to current.runtimeProtocol,
                "runtime_owner" to current.runtimeOwner,
                "runtime_session_id" to (current.runtimeSessionId ?: ""),
                "runtime_error" to (current.runtimeError ?: ""),
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
        if (sink == null) return
        val generation = sinkGeneration.get()
        mainHandler.post {
            if (generation != sinkGeneration.get()) return@post
            val s = sink ?: return@post
            val current = currentState()
            val full = mutableMapOf<String, Any>(
                "connected" to current.connected,
                "service_state" to current.serviceState,
                "runtime_status" to current.runtimeStatus,
                "runtime_backend" to current.runtimeBackend,
                "runtime_protocol" to current.runtimeProtocol,
                "runtime_owner" to current.runtimeOwner,
                "runtime_session_id" to (current.runtimeSessionId ?: ""),
                "runtime_error" to (current.runtimeError ?: ""),
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
        val current = currentState()
        if (!current.connected || !current.nativeLikelyActive) return
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
            val current = currentState()
            if (current.connected && current.nativeLikelyActive) {
                maybeStartTrafficTicks()
            }
        }
    }

    private data class CurrentVpnState(
        val connected: Boolean,
        val serviceState: String,
        val runtimeStatus: String,
        val runtimeBackend: String,
        val runtimeProtocol: String,
        val runtimeOwner: String,
        val runtimeSessionId: String?,
        val runtimeError: String?,
        val nativeLikelyActive: Boolean,
        val awgLikelyActive: Boolean,
        val systemVpnActive: Boolean,
    )

    private fun currentState(
        connectedFallback: Boolean? = null,
        serviceStateFallback: String? = null,
    ): CurrentVpnState {
        val ctx = appContext ?: GraniVpnService.getAppContext()
        if (ctx == null) {
            val (connected, state) = GraniVpnService.peekStateForFlutter()
            return CurrentVpnState(
                connected = connectedFallback ?: connected,
                serviceState = serviceStateFallback ?: state,
                runtimeStatus = serviceStateFallback ?: state,
                runtimeBackend = "unknown",
                runtimeProtocol = "unknown",
                runtimeOwner = "unknown",
                runtimeSessionId = null,
                runtimeError = null,
                nativeLikelyActive = connected,
                awgLikelyActive = false,
                systemVpnActive = connected,
            )
        }

        val snapshot = NativeVpnRuntimeState.getRuntimeSnapshot(ctx)
        val status = snapshot.status.name.lowercase(Locale.US)
        val connected = when (snapshot.status) {
            NativeVpnRuntimeState.RuntimeStatus.LOCAL_UP,
            NativeVpnRuntimeState.RuntimeStatus.VERIFIED,
            NativeVpnRuntimeState.RuntimeStatus.CONNECTED -> snapshot.graniLikelyActive
            NativeVpnRuntimeState.RuntimeStatus.CONNECTING,
            NativeVpnRuntimeState.RuntimeStatus.DISCONNECTING,
            NativeVpnRuntimeState.RuntimeStatus.ERROR,
            NativeVpnRuntimeState.RuntimeStatus.OFF -> false
        }
        return CurrentVpnState(
            connected = connectedFallback ?: connected,
            serviceState = serviceStateFallback ?: status,
            runtimeStatus = status,
            runtimeBackend = snapshot.backend ?: "unknown",
            runtimeProtocol = snapshot.protocol ?: "unknown",
            runtimeOwner = snapshot.owner,
            runtimeSessionId = snapshot.sessionId,
            runtimeError = snapshot.error,
            nativeLikelyActive = snapshot.nativeLikelyActive,
            awgLikelyActive = snapshot.awgLikelyActive,
            systemVpnActive = snapshot.systemVpnActive,
        )
    }

    private fun deliverPayload(
        current: CurrentVpnState,
        emitType: String,
        stats: Map<String, Long>?,
    ) {
        val s = sink ?: return
        val payload = mutableMapOf<String, Any>(
            "connected" to current.connected,
            "service_state" to current.serviceState,
            "runtime_status" to current.runtimeStatus,
            "runtime_backend" to current.runtimeBackend,
            "runtime_protocol" to current.runtimeProtocol,
            "runtime_owner" to current.runtimeOwner,
            "runtime_session_id" to (current.runtimeSessionId ?: ""),
            "runtime_error" to (current.runtimeError ?: ""),
            "native_likely_active" to current.nativeLikelyActive,
            "awg_likely_active" to current.awgLikelyActive,
            "system_vpn_active" to current.systemVpnActive,
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
            sinkGeneration.incrementAndGet()
            sink = null
            stopTrafficTicks()
        }
    }
}
