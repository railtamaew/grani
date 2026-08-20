package com.granivpn.mobile

import android.content.Context
import android.util.Log
import java.util.Locale

/**
 * Single observable runtime contract for every VPN engine.
 *
 * Low-level engines are still different:
 * - VLESS WS: Xray + tun2socks.
 * - Hysteria 2: hysteria process + local SOCKS + tun2socks.
 * - WireGuard obf: AmneziaWG runner.
 *
 * UI, quick tile, notification, watchdog and client logs should see the same
 * state model regardless of the concrete engine.
 */
object ProtocolRuntimeContract {
    private const val TAG = "ProtocolRuntimeContract"
    private const val EVENT_NAME = "runtime_contract_state"
    private const val OUTCOME_EVENT_NAME = "runtime_contract_outcome"

    fun markConnecting(
        context: Context,
        backend: String,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        NativeVpnRuntimeState.markRuntimeConnecting(context, backend, protocol, sessionId, source)
        emit(context, "connecting", backend, protocol, sessionId, source, null)
    }

    fun markConnected(
        context: Context,
        backend: String,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        NativeVpnRuntimeState.markRuntimeConnected(context, backend, protocol, sessionId, source)
        emit(context, "connected", backend, protocol, sessionId, source, null)
    }

    fun markLocalUp(
        context: Context,
        backend: String,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        NativeVpnRuntimeState.markRuntimeLocalUp(context, backend, protocol, sessionId, source)
        emit(context, "local_up", backend, protocol, sessionId, source, null)
    }

    fun markVerified(
        context: Context,
        backend: String,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        NativeVpnRuntimeState.markRuntimeVerified(context, backend, protocol, sessionId, source)
        emit(context, "verified", backend, protocol, sessionId, source, null)
    }

    fun markDisconnecting(
        context: Context,
        backend: String?,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        NativeVpnRuntimeState.markRuntimeDisconnecting(context, backend, protocol, sessionId, source)
        emit(context, "disconnecting", backend, protocol, sessionId, source, null)
    }

    fun markError(
        context: Context,
        backend: String?,
        protocol: String?,
        sessionId: String?,
        source: String,
        error: String?,
    ) {
        NativeVpnRuntimeState.markRuntimeError(context, backend, protocol, sessionId, source, error)
        emit(context, "error", backend, protocol, sessionId, source, error)
    }

    fun markOff(
        context: Context,
        source: String,
        reason: String?,
        sessionId: String? = null,
    ) {
        NativeVpnRuntimeState.markRuntimeOff(context, source, reason, sessionId)
        emit(context, "off", null, null, sessionId, source, reason)
    }

    fun emitServiceState(
        context: Context,
        serviceState: String,
        backend: String?,
        protocol: String?,
        sessionId: String?,
        source: String,
        error: String? = null,
        details: Map<String, Any?> = emptyMap(),
    ) {
        emit(context, serviceState, backend, protocol, sessionId, source, error, details)
    }

    fun emitOutcome(
        context: Context,
        action: String,
        success: Boolean,
        backend: String?,
        protocol: String?,
        sessionId: String?,
        source: String,
        error: String? = null,
        details: Map<String, Any?> = emptyMap(),
    ) {
        val app = context.applicationContext
        val snapshot = NativeVpnRuntimeState.getRuntimeSnapshot(app)
        val outcomeDetails = linkedMapOf<String, Any?>(
            "runtime_action" to action,
            "runtime_success" to success,
            "snapshot_status" to snapshot.status.name.lowercase(Locale.US),
            "snapshot_owner" to snapshot.owner,
            "snapshot_backend" to snapshot.backend,
            "snapshot_protocol" to snapshot.protocol,
            "snapshot_session_id" to snapshot.sessionId,
            "system_vpn_active" to snapshot.systemVpnActive,
            "grani_likely_active" to snapshot.graniLikelyActive,
            "awg_likely_active" to snapshot.awgLikelyActive,
            "native_likely_active" to snapshot.nativeLikelyActive,
        )
        outcomeDetails.putAll(details)
        emit(
            app,
            status = "outcome_${action.normalizeRuntimeValue() ?: "unknown"}",
            backend = backend ?: snapshot.backend,
            protocol = protocol ?: snapshot.protocol,
            sessionId = sessionId ?: snapshot.sessionId,
            source = source,
            error = error,
            details = outcomeDetails,
            eventName = OUTCOME_EVENT_NAME,
        )
    }

    private fun emit(
        context: Context,
        status: String,
        backend: String?,
        protocol: String?,
        sessionId: String?,
        source: String,
        error: String?,
        details: Map<String, Any?> = emptyMap(),
        eventName: String = EVENT_NAME,
    ) {
        val normalizedStatus = status.normalizeRuntimeValue() ?: "unknown"
        val normalizedBackend = backend.normalizeRuntimeValue()
        val normalizedProtocol = protocol.normalizeRuntimeValue()
        val normalizedSession = sessionId?.trim()?.takeIf { it.isNotEmpty() }
        val normalizedError = error?.trim()?.takeIf { it.isNotEmpty() }
        val payload = linkedMapOf<String, Any>(
            "runtime_owner" to "grani",
            "runtime_status" to normalizedStatus,
            "runtime_backend" to (normalizedBackend ?: "unknown"),
            "runtime_protocol" to (normalizedProtocol ?: "unknown"),
            "runtime_session_id" to (normalizedSession ?: ""),
            "runtime_source" to source,
            "runtime_error" to (normalizedError ?: ""),
        )
        details.forEach { (key, value) ->
            if (value != null) payload[key] = value
        }
        Log.i(
            TAG,
            "[VPN_CONTRACT] status=$normalizedStatus backend=${normalizedBackend ?: "unknown"} " +
                "protocol=${normalizedProtocol ?: "unknown"} session=${normalizedSession ?: "none"} " +
                "source=$source error=${normalizedError ?: "none"}",
        )
        VpnNativeStateEmitter.emitRuntimeDiag(eventName, payload)
    }

    private fun String?.normalizeRuntimeValue(): String? {
        return this?.trim()?.lowercase(Locale.US)?.takeIf { it.isNotEmpty() }
    }
}
