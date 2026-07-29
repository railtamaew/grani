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
    private const val DEFAULT_WAIT_DOWN_MS = 7000L
    private const val HARD_CLEANUP_WAIT_MS = 4500L
    private const val STALE_SYSTEM_VPN_GRACE_MS = 1800L
    private const val STALE_SYSTEM_VPN_WAIT_MS = 3500L
    private const val AWG_PRE_START_STABLE_MS = 1500L
    private const val AWG_PRE_START_TIMEOUT_MS = 4000L
    private const val DEFAULT_WAIT_READY_MS = 6500L
    private const val WAIT_READY_POLL_MS = 150L
    private const val WAIT_READY_TERMINAL_GRACE_MS = 1200L

    data class ConnectResult(
        val started: Boolean,
        val backend: String,
        val status: NativeVpnRuntimeState.RuntimeStatus? = null,
        val error: String? = null,
    )

    private data class ReadyWaitResult(
        val ready: Boolean,
        val snapshot: NativeVpnRuntimeState.RuntimeSnapshot,
        val error: String? = null,
    )

    fun connect(
        context: Context,
        config: String,
        protocol: String?,
        mtu: Int = 0,
        source: String = "unknown",
        connectionSessionId: String? = null,
        awaitReady: Boolean = false,
        readyTimeoutMs: Long = DEFAULT_WAIT_READY_MS,
    ): ConnectResult {
        val app = context.applicationContext
        val normalizedProtocol = protocol?.trim()?.lowercase()
        Log.i(
            TAG,
            "connect requested source=$source protocol=${normalizedProtocol ?: "unknown"} session=${connectionSessionId ?: "null"}",
        )

        val backend = if (isAwgProtocol(normalizedProtocol)) "amneziawg" else "native"
        clearIntentionallyStopped(app)
        cleanupBeforeStart(app, source)
        if (backend == "amneziawg") {
            waitForAwgPreStartStability(app, source)
        }

        ProtocolRuntimeContract.markConnecting(
            app,
            backend = backend,
            protocol = normalizedProtocol ?: protocol,
            sessionId = connectionSessionId,
            source = source,
        )

        return if (backend == "amneziawg") {
            val state = SimpleAmneziaWgRunner.connect(app, config)
            val started = state == Tunnel.State.UP
            if (started) {
                ProtocolRuntimeContract.markConnected(
                    app,
                    backend = "amneziawg",
                    protocol = normalizedProtocol ?: protocol,
                    sessionId = connectionSessionId,
                    source = source,
                )
            } else {
                NativeVpnRuntimeState.markAwgExpectedUp(app, false)
                ProtocolRuntimeContract.markError(
                    app,
                    backend = "amneziawg",
                    protocol = normalizedProtocol ?: protocol,
                    sessionId = connectionSessionId,
                    source = source,
                    error = "amneziawg_start_failed",
                )
            }
            scheduleStateRefresh(app)
            ProtocolRuntimeContract.emitOutcome(
                app,
                action = "connect",
                success = started,
                backend = "amneziawg",
                protocol = normalizedProtocol ?: protocol,
                sessionId = connectionSessionId,
                source = source,
                error = if (started) null else "amneziawg_start_failed",
                details = mapOf(
                    "connect_result_semantics" to "tunnel_state",
                    "tunnel_state" to state.name.lowercase(),
                ),
            )
            ConnectResult(
                started = started,
                backend = "amneziawg",
                status = if (started) {
                    NativeVpnRuntimeState.RuntimeStatus.CONNECTED
                } else {
                    NativeVpnRuntimeState.RuntimeStatus.ERROR
                },
                error = if (started) null else "amneziawg_start_failed",
            )
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
            val readyResult = if (awaitReady) {
                waitForNativeReadyOrTerminal(app, connectionSessionId, readyTimeoutMs)
            } else {
                null
            }
            val success = readyResult?.ready ?: true
            val waitError = readyResult?.error
            ProtocolRuntimeContract.emitOutcome(
                app,
                action = "connect",
                success = success,
                backend = "native",
                protocol = normalizedProtocol ?: protocol,
                sessionId = connectionSessionId,
                source = source,
                error = waitError,
                details = mapOf(
                    "connect_result_semantics" to if (awaitReady) {
                        "runtime_ready_wait"
                    } else {
                        "service_start_requested"
                    },
                    "native_start_requested" to true,
                    "runtime_status" to (readyResult?.snapshot?.status?.name?.lowercase() ?: "unknown"),
                    "await_ready" to awaitReady,
                ),
            )
            ConnectResult(
                started = success,
                backend = "native",
                status = readyResult?.snapshot?.status,
                error = waitError,
            )
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
        val snapshot = NativeVpnRuntimeState.getRuntimeSnapshot(app)
        Log.i(
            TAG,
            "disconnect requested source=$source reason=$reason session=${connectionSessionId ?: "null"} " +
                "awg=$awgActive native=$nativeActive status=${snapshot.status}",
        )

        if (
            !awgActive &&
            !nativeActive &&
            snapshot.status == NativeVpnRuntimeState.RuntimeStatus.OFF
        ) {
            Log.i(
                TAG,
                "disconnect noop source=$source reason=$reason session=${connectionSessionId ?: "null"} " +
                    "system_vpn=${snapshot.systemVpnActive}",
            )
            ProtocolRuntimeContract.emitOutcome(
                app,
                action = "disconnect",
                success = true,
                backend = snapshot.backend,
                protocol = snapshot.protocol,
                sessionId = connectionSessionId ?: snapshot.sessionId,
                source = source,
                details = mapOf(
                    "disconnect_reason" to reason,
                    "disconnect_noop" to true,
                    "system_vpn_active" to snapshot.systemVpnActive,
                ),
            )
            scheduleStateRefresh(app)
            return true
        }

        setIntentionallyStopped(app, true)
        ProtocolRuntimeContract.markDisconnecting(
            app,
            backend = snapshot.backend ?: when {
                awgActive && nativeActive -> "mixed"
                awgActive -> "amneziawg"
                nativeActive -> "native"
                else -> null
            },
            protocol = snapshot.protocol,
            sessionId = connectionSessionId ?: snapshot.sessionId,
            source = source,
        )

        if (awgActive) {
            SimpleAmneziaWgRunner.disconnect(app)
            NativeVpnRuntimeState.markAwgExpectedUp(app, false)
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

        var down = if (waitForDown) {
            waitUntilDown(app, DEFAULT_WAIT_DOWN_MS)
        } else {
            !NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(app)
        }
        if (!down) {
            val systemVpnStillActive = NativeVpnRuntimeState.isSystemVpnActive(app)
            if (nativeActive || snapshot.backend == "native" || systemVpnStillActive) {
                hardCleanupNative(
                    app,
                    source = "${source}_hard_cleanup",
                    reason = "${reason}_disconnect_timeout",
                    connectionSessionId = connectionSessionId ?: snapshot.sessionId,
                )
                val hardCleanupDown = waitUntilDown(app, HARD_CLEANUP_WAIT_MS)
                Log.i(
                    TAG,
                    "disconnect hard_cleanup result=$hardCleanupDown " +
                        "source=$source system_vpn_before=$systemVpnStillActive",
                )
                val graniRuntimeDown = !NativeVpnRuntimeState.isAnyGraniVpnActiveOrClosing(app)
                if (!hardCleanupDown && graniRuntimeDown) {
                    val staleSystemVpn = NativeVpnRuntimeState.isSystemVpnActive(app)
                    Log.w(
                        TAG,
                        "disconnect hard_cleanup: GRANI runtime is down but Android still reports system VPN; " +
                            "treating disconnect as successful source=$source system_vpn=$staleSystemVpn",
                    )
                    if (staleSystemVpn) {
                        ProtocolRuntimeContract.emitServiceState(
                            app,
                            serviceState = "stale_system_vpn_icon_after_hard_cleanup",
                            backend = snapshot.backend,
                            protocol = snapshot.protocol,
                            sessionId = connectionSessionId ?: snapshot.sessionId,
                            source = source,
                            details = mapOf("system_vpn_active" to true),
                        )
                    }
                }
                down = hardCleanupDown || graniRuntimeDown
            }
        }
        val effectiveSessionId = connectionSessionId ?: snapshot.sessionId
        if (down) {
            NativeVpnRuntimeState.markAwgExpectedUp(app, false)
            NativeVpnRuntimeState.markNativeVpnExpectedUp(app, false)
            GraniAwgNotificationService.stop(app)
            ProtocolRuntimeContract.markOff(
                app,
                source = source,
                reason = reason,
                sessionId = effectiveSessionId,
            )
            ProtocolRuntimeContract.emitOutcome(
                app,
                action = "disconnect",
                success = true,
                backend = snapshot.backend,
                protocol = snapshot.protocol,
                sessionId = effectiveSessionId,
                source = source,
                details = mapOf(
                    "disconnect_reason" to reason,
                    "wait_for_down" to waitForDown,
                ),
            )
        } else {
            ProtocolRuntimeContract.markError(
                app,
                backend = snapshot.backend,
                protocol = snapshot.protocol,
                sessionId = effectiveSessionId,
                source = source,
                error = "disconnect_timeout",
            )
            ProtocolRuntimeContract.emitOutcome(
                app,
                action = "disconnect",
                success = false,
                backend = snapshot.backend,
                protocol = snapshot.protocol,
                sessionId = effectiveSessionId,
                source = source,
                error = "disconnect_timeout",
                details = mapOf(
                    "disconnect_reason" to reason,
                    "wait_for_down" to waitForDown,
                ),
            )
        }
        scheduleStateRefresh(app)
        return down
    }

    fun cleanupBeforeStart(context: Context, source: String) {
        val app = context.applicationContext
        val snapshot = NativeVpnRuntimeState.getRuntimeSnapshot(app)
        if (!NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(app)) {
            NativeVpnRuntimeState.markAwgExpectedUp(app, false)
            NativeVpnRuntimeState.markNativeVpnExpectedUp(app, false)
            if (snapshot.systemVpnActive) {
                Log.w(
                    TAG,
                    "cleanupBeforeStart: system VPN is active while GRANI runtime is not; " +
                    "attempt stale native cleanup before source=$source",
                )
                ProtocolRuntimeContract.markDisconnecting(
                    app,
                    backend = snapshot.backend ?: "native",
                    protocol = snapshot.protocol,
                    sessionId = snapshot.sessionId,
                    source = "${source}_stale_system_vpn",
                )
                hardCleanupNative(
                    app,
                    source = "${source}_stale_system_vpn",
                    reason = "cleanup_before_start_stale_system_vpn",
                    connectionSessionId = snapshot.sessionId,
                )
                val down = waitUntilDown(app, STALE_SYSTEM_VPN_WAIT_MS)
                Log.i(
                    TAG,
                    "cleanup_before_start_stale_system_vpn result=$down source=$source",
                )
            }
            ProtocolRuntimeContract.markOff(app, source = source, reason = "cleanup_before_start_no_active")
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
        var graniDownSince = 0L
        while (SystemClock.elapsedRealtime() < deadline) {
            val activeOrClosing = NativeVpnRuntimeState.isAnyGraniVpnActiveOrClosing(app)
            val systemVpnActive = NativeVpnRuntimeState.isSystemVpnActive(app)
            if (!activeOrClosing && !systemVpnActive) {
                Log.i(
                    TAG,
                    "wait_until_down result=true timeout_ms=$timeoutMs " +
                        "active_or_closing=false system_vpn=false",
                )
                return true
            }
            if (!activeOrClosing && systemVpnActive) {
                if (graniDownSince == 0L) {
                    graniDownSince = SystemClock.elapsedRealtime()
                }
                if (SystemClock.elapsedRealtime() - graniDownSince >= STALE_SYSTEM_VPN_GRACE_MS) {
                    Log.w(
                        TAG,
                        "wait_until_down stale_system_vpn_after_grani_down " +
                            "timeout_ms=$timeoutMs grace_ms=$STALE_SYSTEM_VPN_GRACE_MS",
                    )
                    return false
                }
            } else {
                graniDownSince = 0L
            }
            try {
                Thread.sleep(100L)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                Log.w(TAG, "wait_until_down interrupted timeout_ms=$timeoutMs")
                break
            }
        }
        val activeOrClosing = NativeVpnRuntimeState.isAnyGraniVpnActiveOrClosing(app)
        val systemVpnActive = NativeVpnRuntimeState.isSystemVpnActive(app)
        val down = !activeOrClosing && !systemVpnActive
        Log.i(
            TAG,
            "wait_until_down result=$down timeout_ms=$timeoutMs " +
                "active_or_closing=$activeOrClosing system_vpn=$systemVpnActive",
        )
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

    private fun waitForNativeReadyOrTerminal(
        context: Context,
        connectionSessionId: String?,
        timeoutMs: Long,
    ): ReadyWaitResult {
        val app = context.applicationContext
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        val startedAt = SystemClock.elapsedRealtime()
        var lastSnapshot = NativeVpnRuntimeState.getRuntimeSnapshot(app)

        while (SystemClock.elapsedRealtime() < deadline) {
            val lastError = GraniVpnService.getLastStartError(connectionSessionId)
            if (!lastError.isNullOrBlank()) {
                val snapshot = NativeVpnRuntimeState.getRuntimeSnapshot(app)
                Log.w(
                    TAG,
                    "wait_ready native failed by service_error session=${connectionSessionId ?: "null"} " +
                        "error=$lastError status=${snapshot.status}",
                )
                return ReadyWaitResult(
                    ready = false,
                    snapshot = snapshot,
                    error = lastError,
                )
            }

            val snapshot = NativeVpnRuntimeState.getRuntimeSnapshot(app)
            if (!matchesRequestedSession(snapshot, connectionSessionId)) {
                sleepReadyPoll()
                continue
            }
            lastSnapshot = snapshot

            if (isNativeReady(snapshot)) {
                Log.i(
                    TAG,
                    "wait_ready native ready status=${snapshot.status} " +
                        "session=${connectionSessionId ?: "null"} timeout_ms=$timeoutMs",
                )
                return ReadyWaitResult(ready = true, snapshot = snapshot)
            }

            val graceExpired =
                SystemClock.elapsedRealtime() - startedAt >= WAIT_READY_TERMINAL_GRACE_MS
            if (
                graceExpired &&
                (snapshot.status == NativeVpnRuntimeState.RuntimeStatus.ERROR ||
                    snapshot.status == NativeVpnRuntimeState.RuntimeStatus.OFF ||
                    snapshot.status == NativeVpnRuntimeState.RuntimeStatus.DISCONNECTING)
            ) {
                val error = snapshot.error ?: "native_runtime_${snapshot.status.name.lowercase()}"
                Log.w(
                    TAG,
                    "wait_ready native terminal status=${snapshot.status} " +
                        "session=${connectionSessionId ?: "null"} error=$error",
                )
                return ReadyWaitResult(
                    ready = false,
                    snapshot = snapshot,
                    error = error,
                )
            }

            sleepReadyPoll()
        }

        val error = "native_start_timeout_${lastSnapshot.status.name.lowercase()}"
        Log.w(
            TAG,
            "wait_ready native timeout session=${connectionSessionId ?: "null"} " +
                "status=${lastSnapshot.status} native=${lastSnapshot.nativeLikelyActive}",
        )
        return ReadyWaitResult(
            ready = false,
            snapshot = lastSnapshot,
            error = error,
        )
    }

    private fun matchesRequestedSession(
        snapshot: NativeVpnRuntimeState.RuntimeSnapshot,
        connectionSessionId: String?,
    ): Boolean {
        val requested = connectionSessionId?.trim()?.takeIf { it.isNotEmpty() } ?: return true
        val snapshotSession = snapshot.sessionId?.trim()?.takeIf { it.isNotEmpty() } ?: return true
        return snapshotSession == requested
    }

    private fun isNativeReady(snapshot: NativeVpnRuntimeState.RuntimeSnapshot): Boolean {
        return snapshot.status == NativeVpnRuntimeState.RuntimeStatus.VERIFIED ||
            snapshot.status == NativeVpnRuntimeState.RuntimeStatus.CONNECTED ||
            (
                snapshot.status == NativeVpnRuntimeState.RuntimeStatus.LOCAL_UP &&
                    snapshot.nativeLikelyActive
                )
    }

    private fun sleepReadyPoll() {
        try {
            Thread.sleep(WAIT_READY_POLL_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun waitForAwgPreStartStability(context: Context, source: String): Boolean {
        val app = context.applicationContext
        try {
            Tun2SocksProcessService.requestForceStop(
                app,
                source = "${source}_awg_pre_start",
                reason = "awg_pre_start_native_tail_cleanup",
            )
        } catch (e: Exception) {
            Log.w(TAG, "awg_pre_start: tun2socks cleanup failed source=$source: ${e.message}")
        }

        val deadline = SystemClock.elapsedRealtime() + AWG_PRE_START_TIMEOUT_MS
        var stableSince = 0L
        var lastNativeActive = false
        var lastSystemVpnActive = false
        while (SystemClock.elapsedRealtime() < deadline) {
            val nativeActive = NativeVpnRuntimeState.isNativeVpnActiveOrClosing(app)
            val systemVpnActive = NativeVpnRuntimeState.isSystemVpnActive(app)
            lastNativeActive = nativeActive
            lastSystemVpnActive = systemVpnActive
            if (!nativeActive && !systemVpnActive) {
                if (stableSince == 0L) {
                    stableSince = SystemClock.elapsedRealtime()
                }
                if (SystemClock.elapsedRealtime() - stableSince >= AWG_PRE_START_STABLE_MS) {
                    Log.i(
                        TAG,
                        "awg_pre_start stable=true source=$source stable_ms=$AWG_PRE_START_STABLE_MS",
                    )
                    return true
                }
            } else {
                stableSince = 0L
            }
            try {
                Thread.sleep(100L)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                Log.w(TAG, "awg_pre_start interrupted source=$source")
                return false
            }
        }
        Log.w(
            TAG,
            "awg_pre_start stable=false source=$source timeout_ms=$AWG_PRE_START_TIMEOUT_MS " +
                "native_active_or_closing=$lastNativeActive system_vpn=$lastSystemVpnActive",
        )
        return false
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

    private fun hardCleanupNative(
        context: Context,
        source: String,
        reason: String,
        connectionSessionId: String?,
    ) {
        val app = context.applicationContext
        val nativeActiveOrClosing = NativeVpnRuntimeState.isNativeVpnActiveOrClosing(app)
        val systemVpnActive = NativeVpnRuntimeState.isSystemVpnActive(app)
        Log.w(
            TAG,
            "hard_cleanup_native source=$source reason=$reason " +
                "session=${connectionSessionId ?: "null"} " +
                "active_or_closing=$nativeActiveOrClosing " +
                "system_vpn=$systemVpnActive",
        )
        NativeVpnRuntimeState.markNativeVpnExpectedUp(app, false)
        if (nativeActiveOrClosing) {
            try {
                GraniVpnService.stopService(
                    app,
                    source = source,
                    reason = reason,
                    connectionSessionId = connectionSessionId,
                )
            } catch (e: Exception) {
                Log.w(TAG, "hard_cleanup_native stopService failed source=$source: ${e.message}")
            }
            try {
                GraniVpnService.forceStopIfRunning(app, source = source, reason = reason)
            } catch (e: Exception) {
                Log.w(TAG, "hard_cleanup_native forceStopIfRunning failed source=$source: ${e.message}")
            }
        } else {
            Log.w(
                TAG,
                "hard_cleanup_native: skip GraniVpnService STOP because native runtime is already idle; " +
                    "force-stop only :tun2socks to avoid notification blink",
            )
        }
        try {
            Tun2SocksProcessService.requestForceStop(
                app,
                source = source,
                reason = reason,
            )
        } catch (e: Exception) {
            Log.w(TAG, "hard_cleanup_native tun2socks force stop failed source=$source: ${e.message}")
        }
        try {
            Thread.sleep(450L)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }
}
