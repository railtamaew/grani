package com.granivpn.mobile

import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import java.util.Locale

object NativeVpnRuntimeState {
    private const val TAG = "NativeVpnRuntimeState"
    private const val PREFS_NAME = "grani_vpn_prefs"
    private const val KEY_LAST_PROTOCOL = "last_vpn_protocol"
    private const val KEY_AWG_EXPECTED_UP = "amneziawg_expected_up"
    private const val KEY_AWG_EXPECTED_UP_AT = "amneziawg_expected_up_at"
    private const val KEY_NATIVE_EXPECTED_UP = "native_vpn_expected_up"
    private const val KEY_NATIVE_EXPECTED_UP_AT = "native_vpn_expected_up_at"
    private const val KEY_NATIVE_EXPECTED_PROTOCOL = "native_vpn_expected_protocol"
    private const val KEY_RUNTIME_STATUS = "grani_runtime_status"
    private const val KEY_RUNTIME_OWNER = "grani_runtime_owner"
    private const val KEY_RUNTIME_BACKEND = "grani_runtime_backend"
    private const val KEY_RUNTIME_PROTOCOL = "grani_runtime_protocol"
    private const val KEY_RUNTIME_SESSION_ID = "grani_runtime_session_id"
    private const val KEY_RUNTIME_SOURCE = "grani_runtime_source"
    private const val KEY_RUNTIME_ERROR = "grani_runtime_error"
    private const val KEY_RUNTIME_UPDATED_AT = "grani_runtime_updated_at"
    private const val KEY_RUNTIME_SEQUENCE = "grani_runtime_sequence"
    private const val EXPECTED_UP_GRACE_MS = 90_000L
    private const val STARTUP_WATCHDOG_GRACE_MS = 15_000L
    private const val TRANSIENT_STATUS_MAX_AGE_MS = 120_000L
    private const val ERROR_STATUS_MAX_AGE_MS = 300_000L
    private const val OWNER_GRANI = "grani"
    private const val OWNER_NONE = "none"
    private const val OWNER_UNKNOWN = "third_party_or_unknown"

    enum class RuntimeStatus {
        OFF,
        CONNECTING,
        LOCAL_UP,
        VERIFIED,
        CONNECTED,
        DISCONNECTING,
        ERROR,
    }

    data class RuntimeSnapshot(
        val status: RuntimeStatus,
        val owner: String,
        val backend: String?,
        val protocol: String?,
        val sessionId: String?,
        val source: String?,
        val error: String?,
        val updatedAtMs: Long,
        val sequence: Long,
        val systemVpnActive: Boolean,
        val graniLikelyActive: Boolean,
        val awgLikelyActive: Boolean,
        val nativeLikelyActive: Boolean,
    )

    fun markAwgExpectedUp(context: Context, expected: Boolean) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val previousExpected = prefs.getBoolean(KEY_AWG_EXPECTED_UP, false)
        prefs.edit()
            .putBoolean(KEY_AWG_EXPECTED_UP, expected)
            .putLong(KEY_AWG_EXPECTED_UP_AT, if (expected) System.currentTimeMillis() else 0L)
            .apply()
        if (previousExpected != expected) {
            Log.i(TAG, "awg_expected_up=$expected")
        }
    }

    fun markNativeVpnExpectedUp(context: Context, expected: Boolean, protocol: String? = null) {
        val normalizedProtocol = protocol?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val previousExpected = prefs.getBoolean(KEY_NATIVE_EXPECTED_UP, false)
        val previousProtocol = prefs.getString(KEY_NATIVE_EXPECTED_PROTOCOL, null)
            ?.trim()
            ?.lowercase()
            ?.takeIf { it.isNotEmpty() }
        prefs.edit()
            .putBoolean(KEY_NATIVE_EXPECTED_UP, expected)
            .putLong(KEY_NATIVE_EXPECTED_UP_AT, if (expected) System.currentTimeMillis() else 0L)
            .apply {
                if (!normalizedProtocol.isNullOrBlank()) {
                    putString(KEY_NATIVE_EXPECTED_PROTOCOL, normalizedProtocol)
                } else if (!expected) {
                    remove(KEY_NATIVE_EXPECTED_PROTOCOL)
                }
            }
            .apply()
        if (previousExpected != expected || previousProtocol != normalizedProtocol) {
            Log.i(TAG, "native_expected_up=$expected protocol=${normalizedProtocol ?: "unknown"}")
        }
    }

    fun markRuntimeConnecting(
        context: Context,
        backend: String,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        writeRuntimeState(
            context,
            RuntimeStatus.CONNECTING,
            backend = backend,
            protocol = protocol,
            sessionId = sessionId,
            source = source,
            error = null,
        )
    }

    fun markRuntimeConnected(
        context: Context,
        backend: String,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        writeRuntimeState(
            context,
            RuntimeStatus.CONNECTED,
            backend = backend,
            protocol = protocol,
            sessionId = sessionId,
            source = source,
            error = null,
        )
    }

    fun markRuntimeLocalUp(
        context: Context,
        backend: String,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        writeRuntimeState(
            context,
            RuntimeStatus.LOCAL_UP,
            backend = backend,
            protocol = protocol,
            sessionId = sessionId,
            source = source,
            error = null,
        )
    }

    fun markRuntimeVerified(
        context: Context,
        backend: String,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        writeRuntimeState(
            context,
            RuntimeStatus.VERIFIED,
            backend = backend,
            protocol = protocol,
            sessionId = sessionId,
            source = source,
            error = null,
        )
    }

    fun markRuntimeDisconnecting(
        context: Context,
        backend: String?,
        protocol: String?,
        sessionId: String?,
        source: String,
    ) {
        writeRuntimeState(
            context,
            RuntimeStatus.DISCONNECTING,
            backend = backend,
            protocol = protocol,
            sessionId = sessionId,
            source = source,
            error = null,
        )
    }

    fun markRuntimeError(
        context: Context,
        backend: String?,
        protocol: String?,
        sessionId: String?,
        source: String,
        error: String?,
    ) {
        writeRuntimeState(
            context,
            RuntimeStatus.ERROR,
            backend = backend,
            protocol = protocol,
            sessionId = sessionId,
            source = source,
            error = error,
        )
    }

    fun markRuntimeOff(
        context: Context,
        source: String,
        reason: String? = null,
        sessionId: String? = null,
    ) {
        val app = context.applicationContext
        val normalizedSessionId = sessionId.normalizeRuntimeValue()
        if (shouldIgnoreStaleSession(app, normalizedSessionId, RuntimeStatus.OFF, source)) {
            return
        }
        val sequence = nextRuntimeSequence(app)
        app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_RUNTIME_STATUS, statusName(RuntimeStatus.OFF))
            .putString(KEY_RUNTIME_OWNER, OWNER_NONE)
            .remove(KEY_RUNTIME_BACKEND)
            .remove(KEY_RUNTIME_PROTOCOL)
            .remove(KEY_RUNTIME_SESSION_ID)
            .putString(KEY_RUNTIME_SOURCE, source)
            .apply {
                if (reason.isNullOrBlank()) {
                    remove(KEY_RUNTIME_ERROR)
                } else {
                    putString(KEY_RUNTIME_ERROR, reason)
                }
            }
            .putLong(KEY_RUNTIME_UPDATED_AT, System.currentTimeMillis())
            .putLong(KEY_RUNTIME_SEQUENCE, sequence)
            .apply()
        Log.i(
            TAG,
            "[VPN_RUNTIME] owner=$OWNER_NONE status=off source=$source " +
                "session=${normalizedSessionId ?: "none"} reason=${reason ?: "none"}",
        )
        notifyQuickTile(app)
        VpnNativeStateEmitter.emitRuntimeSnapshot(app)
    }

    private fun writeRuntimeState(
        context: Context,
        status: RuntimeStatus,
        backend: String?,
        protocol: String?,
        sessionId: String?,
        source: String,
        error: String?,
    ) {
        val app = context.applicationContext
        val normalizedBackend = backend.normalizeLowerRuntimeValue()
        val normalizedProtocol = protocol.normalizeLowerRuntimeValue()
        val normalizedSessionId = sessionId.normalizeRuntimeValue()
        if (
            status != RuntimeStatus.CONNECTING &&
            (shouldIgnoreStaleSession(app, normalizedSessionId, status, source) ||
                shouldIgnoreStaleBackend(app, normalizedBackend, status, source))
        ) {
            return
        }
        val sequence = nextRuntimeSequence(app)
        app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_RUNTIME_STATUS, statusName(status))
            .putString(KEY_RUNTIME_OWNER, OWNER_GRANI)
            .putString(KEY_RUNTIME_SOURCE, source)
            .putLong(KEY_RUNTIME_UPDATED_AT, System.currentTimeMillis())
            .putLong(KEY_RUNTIME_SEQUENCE, sequence)
            .apply {
                if (normalizedBackend == null) remove(KEY_RUNTIME_BACKEND) else putString(KEY_RUNTIME_BACKEND, normalizedBackend)
                if (normalizedProtocol == null) remove(KEY_RUNTIME_PROTOCOL) else putString(KEY_RUNTIME_PROTOCOL, normalizedProtocol)
                if (normalizedSessionId == null) remove(KEY_RUNTIME_SESSION_ID) else putString(KEY_RUNTIME_SESSION_ID, normalizedSessionId)
                if (error.isNullOrBlank()) remove(KEY_RUNTIME_ERROR) else putString(KEY_RUNTIME_ERROR, error)
            }
            .apply()
        Log.i(
            TAG,
            "[VPN_RUNTIME] owner=$OWNER_GRANI status=${statusName(status)} " +
                "backend=${normalizedBackend ?: "unknown"} protocol=${normalizedProtocol ?: "unknown"} " +
                "session=${normalizedSessionId ?: "none"} source=$source error=${error ?: "none"}",
        )
        notifyQuickTile(app)
        VpnNativeStateEmitter.emitRuntimeSnapshot(app)
    }

    private fun shouldIgnoreStaleSession(
        context: Context,
        incomingSessionId: String?,
        status: RuntimeStatus,
        source: String,
    ): Boolean {
        val incoming = incomingSessionId.normalizeRuntimeValue() ?: return false
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val current = prefs.getString(KEY_RUNTIME_SESSION_ID, null).normalizeRuntimeValue() ?: return false
        if (current == incoming) return false
        val currentStatus = prefs.getString(KEY_RUNTIME_STATUS, null) ?: "unknown"
        Log.i(
            TAG,
            "[VPN_RUNTIME] stale_session_ignored status=${statusName(status)} " +
                "source=$source incoming_session=$incoming current_session=$current " +
                "current_status=$currentStatus",
        )
        return true
    }

    /**
     * Protocol engines finish asynchronously. After a handover an old engine
     * can still report LOCAL_UP/ERROR on its worker thread. Session ids are the
     * primary ownership key, but older/reused ids are possible during recovery;
     * the currently connecting/connected backend is therefore a second guard.
     */
    private fun shouldIgnoreStaleBackend(
        context: Context,
        incomingBackend: String?,
        status: RuntimeStatus,
        source: String,
    ): Boolean {
        val incoming = incomingBackend.normalizeLowerRuntimeValue() ?: return false
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val current = prefs.getString(KEY_RUNTIME_BACKEND, null).normalizeLowerRuntimeValue() ?: return false
        if (current == incoming) return false
        val currentStatus = parseStatus(prefs.getString(KEY_RUNTIME_STATUS, null))
        val currentOwnsRuntime = currentStatus == RuntimeStatus.CONNECTING ||
            currentStatus == RuntimeStatus.LOCAL_UP ||
            currentStatus == RuntimeStatus.VERIFIED ||
            currentStatus == RuntimeStatus.CONNECTED
        if (!currentOwnsRuntime) return false
        Log.i(
            TAG,
            "[VPN_RUNTIME] stale_backend_ignored status=${statusName(status)} " +
                "source=$source incoming_backend=$incoming current_backend=$current " +
                "current_status=${statusName(currentStatus)}",
        )
        return true
    }

    fun isAwgExpectedUp(context: Context): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_AWG_EXPECTED_UP, false)) return false
        if (!isExpectedFresh(prefs.getLong(KEY_AWG_EXPECTED_UP_AT, 0L))) return false
        return prefs.getString(KEY_LAST_PROTOCOL, null)?.equals("graniwg", ignoreCase = true) == true
    }

    private fun isAwgProtocol(protocol: String?): Boolean {
        val p = protocol?.trim()?.lowercase() ?: return false
        return p == "graniwg" || p == "amneziawg" || p == "awg"
    }

    fun isAwgStartupInProgress(context: Context): Boolean {
        val snapshot = getRuntimeSnapshot(context.applicationContext)
        return snapshot.status == RuntimeStatus.CONNECTING &&
            snapshot.backend?.equals("amneziawg", ignoreCase = true) == true &&
            isAwgProtocol(snapshot.protocol)
    }

    fun isNativeVpnExpectedUp(context: Context): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_NATIVE_EXPECTED_UP, false)) return false
        val expectedAt = prefs.getLong(KEY_NATIVE_EXPECTED_UP_AT, 0L)
        if (!isExpectedFresh(expectedAt)) return false
        val expectedProtocol = prefs.getString(KEY_NATIVE_EXPECTED_PROTOCOL, null)
        val lastProtocol = prefs.getString(KEY_LAST_PROTOCOL, null)
        val protocol = expectedProtocol ?: lastProtocol
        return !isAwgProtocol(protocol)
    }

    private fun isExpectedFresh(expectedAt: Long): Boolean {
        if (expectedAt <= 0L) return false
        return System.currentTimeMillis() - expectedAt <= EXPECTED_UP_GRACE_MS
    }

    fun isSystemVpnActive(context: Context): Boolean {
        val connectivityManager =
            context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return false
        return connectivityManager.allNetworks.any { network ->
            val capabilities = connectivityManager.getNetworkCapabilities(network)
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
    }

    fun isAwgLikelyActive(context: Context): Boolean {
        if (SimpleAmneziaWgRunner.isUp()) return true
        return isAwgExpectedUp(context) && isSystemVpnActive(context)
    }

    fun isNativeVpnLikelyActive(context: Context): Boolean {
        return GraniVpnService.isVpnRunning()
    }

    fun isNativeVpnActiveOrClosing(context: Context): Boolean {
        return GraniVpnService.isNativeTunnelActiveOrClosing()
    }

    fun isAnyGraniVpnLikelyActive(context: Context): Boolean {
        return isNativeVpnLikelyActive(context) || isAwgLikelyActive(context)
    }

    fun isAnyGraniVpnActiveOrClosing(context: Context): Boolean {
        return isNativeVpnActiveOrClosing(context) || isAwgLikelyActive(context)
    }

    fun getRuntimeSnapshot(context: Context): RuntimeSnapshot {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val storedStatus = parseStatus(prefs.getString(KEY_RUNTIME_STATUS, null))
        val updatedAt = prefs.getLong(KEY_RUNTIME_UPDATED_AT, 0L)
        val sequence = prefs.getLong(KEY_RUNTIME_SEQUENCE, 0L)
        val systemVpnActive = isSystemVpnActive(app)
        val awgActive = isAwgLikelyActive(app)
        val nativeActive = isNativeVpnLikelyActive(app)
        val nativeActiveOrClosing = isNativeVpnActiveOrClosing(app)
        val graniActive = awgActive || nativeActiveOrClosing
        val status = reconcileStoredStatus(storedStatus, updatedAt, graniActive)
        val owner = when {
            status != RuntimeStatus.OFF -> OWNER_GRANI
            systemVpnActive -> OWNER_UNKNOWN
            else -> OWNER_NONE
        }
        return RuntimeSnapshot(
            status = status,
            owner = owner,
            backend = prefs.getString(KEY_RUNTIME_BACKEND, null),
            protocol = prefs.getString(KEY_RUNTIME_PROTOCOL, null),
            sessionId = prefs.getString(KEY_RUNTIME_SESSION_ID, null),
            source = prefs.getString(KEY_RUNTIME_SOURCE, null),
            error = prefs.getString(KEY_RUNTIME_ERROR, null),
            updatedAtMs = updatedAt,
            sequence = sequence,
            systemVpnActive = systemVpnActive,
            graniLikelyActive = graniActive,
            awgLikelyActive = awgActive,
            nativeLikelyActive = nativeActive,
        )
    }

    fun getDiagnosticDump(context: Context): Map<String, Any?> {
        val app = context.applicationContext
        val snapshot = getRuntimeSnapshot(app)
        val service = GraniVpnService.peekStateForFlutter()
        val powerManager = app.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val activityManager = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val notificationManager = app.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        return linkedMapOf(
            "device_manufacturer" to Build.MANUFACTURER,
            "device_brand" to Build.BRAND,
            "device_model" to Build.MODEL,
            "android_sdk" to Build.VERSION.SDK_INT,
            "process_uptime_ms" to SystemClock.elapsedRealtime(),
            "battery_optimization_ignored" to
                (powerManager?.isIgnoringBatteryOptimizations(app.packageName) == true),
            "background_restricted" to
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    activityManager?.isBackgroundRestricted == true
                } else {
                    false
                }),
            "notifications_enabled" to
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    notificationManager?.areNotificationsEnabled() == true
                } else {
                    true
                }),
            "runtime_owner" to snapshot.owner,
            "runtime_status" to statusName(snapshot.status),
            "runtime_backend" to snapshot.backend,
            "runtime_protocol" to snapshot.protocol,
            "runtime_session_id" to snapshot.sessionId,
            "runtime_source" to snapshot.source,
            "runtime_error" to snapshot.error,
            "runtime_updated_at_ms" to snapshot.updatedAtMs,
            "runtime_sequence" to snapshot.sequence,
            "runtime_age_ms" to if (snapshot.updatedAtMs <= 0L) null else
                (System.currentTimeMillis() - snapshot.updatedAtMs).coerceAtLeast(0L),
            "android_system_vpn_active" to snapshot.systemVpnActive,
            "grani_likely_active" to snapshot.graniLikelyActive,
            "awg_likely_active" to snapshot.awgLikelyActive,
            "native_likely_active" to snapshot.nativeLikelyActive,
            "native_active_or_closing" to isNativeVpnActiveOrClosing(app),
            "native_expected_up" to isNativeVpnExpectedUp(app),
            "quick_tile_state" to statusName(snapshot.status),
            "notification_expected" to (snapshot.status != RuntimeStatus.OFF && snapshot.graniLikelyActive),
            "service_committed" to service.first,
            "service_state" to service.second,
            "awg_runner_up" to SimpleAmneziaWgRunner.isUp(),
        )
    }

    fun reconcileRuntimeWatchdog(context: Context, source: String) {
        val app = context.applicationContext
        val snapshot = getRuntimeSnapshot(app)
        Log.i(
            TAG,
            "[VPN_RUNTIME] watchdog source=$source owner=${snapshot.owner} status=${statusName(snapshot.status)} " +
                "backend=${snapshot.backend ?: "unknown"} protocol=${snapshot.protocol ?: "unknown"} " +
                "system_vpn=${snapshot.systemVpnActive} grani=${snapshot.graniLikelyActive}",
        )
        if (snapshot.status == RuntimeStatus.OFF) return
        if (!snapshot.graniLikelyActive) {
            if (
                snapshot.status == RuntimeStatus.CONNECTING &&
                isFresh(snapshot.updatedAtMs, STARTUP_WATCHDOG_GRACE_MS)
            ) {
                Log.i(
                    TAG,
                    "[VPN_RUNTIME] watchdog source=$source startup_grace=1 " +
                        "status=${statusName(snapshot.status)} backend=${snapshot.backend ?: "unknown"} " +
                        "protocol=${snapshot.protocol ?: "unknown"}",
                )
                return
            }
            if (
                snapshot.status == RuntimeStatus.CONNECTING ||
                snapshot.status == RuntimeStatus.LOCAL_UP ||
                snapshot.status == RuntimeStatus.VERIFIED ||
                snapshot.status == RuntimeStatus.CONNECTED ||
                snapshot.status == RuntimeStatus.DISCONNECTING
            ) {
                markRuntimeOff(app, source = "${source}_watchdog", reason = "runtime_not_alive")
            }
            return
        }
        if (snapshot.awgLikelyActive) {
            reconcileAwgNotification(app, "${source}_watchdog")
        }
        if (snapshot.nativeLikelyActive) {
            GraniVpnService.reconcileForegroundNotification(app, "${source}_watchdog")
        }
    }

    fun reconcileAwgNotification(context: Context, source: String) {
        val app = context.applicationContext
        if (!isAwgLikelyActive(app)) return
        try {
            Log.i(TAG, "reconcile_awg_notification source=$source")
            GraniAwgNotificationService.start(app)
        } catch (e: Exception) {
            Log.w(TAG, "reconcile_awg_notification_failed source=$source", e)
        }
    }

    fun notifyQuickTile(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            QuickTileService.notifyVpnStateChanged(context.applicationContext)
        }
    }

    private fun reconcileStoredStatus(
        stored: RuntimeStatus,
        updatedAt: Long,
        graniActive: Boolean,
    ): RuntimeStatus {
        if (graniActive) {
            return when (stored) {
                RuntimeStatus.CONNECTING ->
                    if (isFresh(updatedAt, TRANSIENT_STATUS_MAX_AGE_MS)) stored else RuntimeStatus.CONNECTED
                RuntimeStatus.LOCAL_UP ->
                    if (isFresh(updatedAt, TRANSIENT_STATUS_MAX_AGE_MS)) stored else RuntimeStatus.CONNECTED
                RuntimeStatus.VERIFIED ->
                    if (isFresh(updatedAt, TRANSIENT_STATUS_MAX_AGE_MS)) stored else RuntimeStatus.CONNECTED
                RuntimeStatus.DISCONNECTING ->
                    if (isFresh(updatedAt, TRANSIENT_STATUS_MAX_AGE_MS)) stored else RuntimeStatus.CONNECTED
                RuntimeStatus.ERROR ->
                    if (isFresh(updatedAt, ERROR_STATUS_MAX_AGE_MS)) stored else RuntimeStatus.CONNECTED
                RuntimeStatus.OFF -> RuntimeStatus.CONNECTED
                RuntimeStatus.CONNECTED -> RuntimeStatus.CONNECTED
            }
        }

        return when (stored) {
            RuntimeStatus.CONNECTING,
            RuntimeStatus.LOCAL_UP,
            RuntimeStatus.VERIFIED,
            RuntimeStatus.DISCONNECTING ->
                if (isFresh(updatedAt, TRANSIENT_STATUS_MAX_AGE_MS)) stored else RuntimeStatus.OFF
            RuntimeStatus.ERROR ->
                if (isFresh(updatedAt, ERROR_STATUS_MAX_AGE_MS)) RuntimeStatus.ERROR else RuntimeStatus.OFF
            RuntimeStatus.CONNECTED, RuntimeStatus.OFF -> RuntimeStatus.OFF
        }
    }

    private fun parseStatus(value: String?): RuntimeStatus {
        val normalized = value?.trim()?.uppercase(Locale.US) ?: return RuntimeStatus.OFF
        return RuntimeStatus.values().firstOrNull { it.name == normalized } ?: RuntimeStatus.OFF
    }

    private fun statusName(status: RuntimeStatus): String {
        return status.name.lowercase(Locale.US)
    }

    private fun isFresh(updatedAt: Long, maxAgeMs: Long): Boolean {
        if (updatedAt <= 0L) return false
        return System.currentTimeMillis() - updatedAt <= maxAgeMs
    }

    private fun nextRuntimeSequence(context: Context): Long {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return synchronized(this) {
            val next = prefs.getLong(KEY_RUNTIME_SEQUENCE, 0L) + 1L
            // Commit keeps sequence monotonic even when state writers run on
            // different service/plugin threads.
            prefs.edit().putLong(KEY_RUNTIME_SEQUENCE, next).commit()
            next
        }
    }

    private fun String?.normalizeLowerRuntimeValue(): String? {
        return this?.trim()?.lowercase(Locale.US)?.takeIf { it.isNotEmpty() }
    }

    private fun String?.normalizeRuntimeValue(): String? {
        return this?.trim()?.takeIf { it.isNotEmpty() }
    }
}
