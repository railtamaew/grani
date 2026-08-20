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
    private const val AWG_CLEAN_PRE_START_SETTLE_MS = 350L
    private const val AWG_PRE_START_STABLE_MS = 1500L
    private const val AWG_PRE_START_TIMEOUT_MS = 4000L
    private const val DEFAULT_WAIT_READY_MS = 6500L
    private const val WAIT_READY_POLL_MS = 150L
    private const val WAIT_READY_TERMINAL_GRACE_MS = 1200L
    private val operationGate = VpnRuntimeOperationGate()

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
    ): ConnectResult = operationGate.withConnect { operationToken ->
        try {
            connectLocked(
                context = context,
                config = config,
                protocol = protocol,
                mtu = mtu,
                source = source,
                connectionSessionId = connectionSessionId,
                awaitReady = awaitReady,
                readyTimeoutMs = readyTimeoutMs,
                operationToken = operationToken,
            )
        } catch (error: Exception) {
            val backend = if (isAwgProtocol(protocol)) "amneziawg" else "native"
            ProtocolRuntimeContract.markError(
                context.applicationContext,
                backend = backend,
                protocol = protocol,
                sessionId = connectionSessionId,
                source = source,
                error = error.message ?: error.javaClass.simpleName,
            )
            teardownAfterFailedStartLocked(
                context = context.applicationContext,
                backend = backend,
                source = source,
                reason = error.message ?: error.javaClass.simpleName,
                connectionSessionId = connectionSessionId,
            )
            throw error
        }
    }

    private fun connectLocked(
        context: Context,
        config: String,
        protocol: String?,
        mtu: Int,
        source: String,
        connectionSessionId: String?,
        awaitReady: Boolean,
        readyTimeoutMs: Long,
        operationToken: VpnRuntimeOperationGate.ConnectToken,
    ): ConnectResult {
        val app = context.applicationContext
        val normalizedProtocol = protocol?.trim()?.lowercase()
        Log.i(
            TAG,
            "connect requested source=$source protocol=${normalizedProtocol ?: "unknown"} session=${connectionSessionId ?: "null"}",
        )

        val backend = if (isAwgProtocol(normalizedProtocol)) "amneziawg" else "native"
        if (operationToken.isCancellationRequested()) {
            Log.i(
                TAG,
                "connect superseded before start source=$source protocol=${normalizedProtocol ?: "unknown"} " +
                    "session=${connectionSessionId ?: "null"}",
            )
            return ConnectResult(
                started = false,
                backend = backend,
                status = NativeVpnRuntimeState.getRuntimeSnapshot(app).status,
                error = "connect_superseded_by_disconnect",
            )
        }
        val existing = NativeVpnRuntimeState.getRuntimeSnapshot(app)
        if (canReuseVerifiedRuntime(existing, normalizedProtocol)) {
            clearIntentionallyStopped(app)
            Log.i(
                TAG,
                "connect reused source=$source requested_protocol=${normalizedProtocol ?: "unknown"} " +
                    "runtime_protocol=${existing.protocol ?: "unknown"} status=${existing.status}",
            )
            ProtocolRuntimeContract.emitOutcome(
                app,
                action = "connect",
                success = true,
                backend = existing.backend ?: backend,
                protocol = existing.protocol ?: normalizedProtocol ?: protocol,
                sessionId = existing.sessionId ?: connectionSessionId,
                source = source,
                details = mapOf(
                    "connect_result_semantics" to "verified_runtime_reused",
                    "runtime_status" to existing.status.name.lowercase(),
                    "runtime_reused" to true,
                    "system_vpn_active" to existing.systemVpnActive,
                ),
            )
            scheduleStateRefresh(app)
            return ConnectResult(
                started = true,
                backend = existing.backend ?: backend,
                status = existing.status,
            )
        }
        clearIntentionallyStopped(app)
        // A clean OFF runtime needs no destructive cleanup or duplicate OFF
        // persistence. Avoiding those synchronous state writes removes a
        // visible delay from every normal connection attempt.
        if (
            existing.status != NativeVpnRuntimeState.RuntimeStatus.OFF ||
            existing.systemVpnActive ||
            NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(app)
        ) {
            cleanupBeforeStartLocked(app, source)
        } else {
            Log.i(TAG, "connect clean_runtime_fast_path=true source=$source")
        }
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
            val localUp = state == Tunnel.State.UP
            val generation = SimpleAmneziaWgRunner.currentGeneration()
            if (localUp) {
                ProtocolRuntimeContract.markLocalUp(
                    app,
                    backend = "amneziawg",
                    protocol = normalizedProtocol ?: protocol,
                    sessionId = connectionSessionId,
                    source = source,
                )
            }
            val verification = if (localUp) {
                SimpleAmneziaWgRunner.awaitVerifiedTraffic(
                    generation = generation,
                    shouldCancel = operationToken::isCancellationRequested,
                )
            } else {
                SimpleAmneziaWgRunner.VerificationResult(
                    verified = false,
                    generation = generation,
                    rxBytes = 0L,
                    txBytes = 0L,
                    latestHandshakeEpochMillis = 0L,
                    elapsedMs = 0L,
                    reason = "amneziawg_start_failed",
                )
            }
            val started = localUp && verification.verified
            if (started) {
                ProtocolRuntimeContract.markVerified(
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
                    error = verification.reason,
                )
                teardownAfterFailedStartLocked(
                    app,
                    backend = "amneziawg",
                    source = source,
                    reason = verification.reason,
                    connectionSessionId = connectionSessionId,
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
                error = if (started) null else verification.reason,
                details = mapOf(
                    "connect_result_semantics" to "verified_dataplane",
                    "tunnel_state" to state.name.lowercase(),
                    "verification_reason" to verification.reason,
                    "verification_elapsed_ms" to verification.elapsedMs,
                    "latest_handshake_epoch_ms" to verification.latestHandshakeEpochMillis,
                    "rx_bytes" to verification.rxBytes,
                    "tx_bytes" to verification.txBytes,
                ),
            )
            ConnectResult(
                started = started,
                backend = "amneziawg",
                status = if (started) {
                    NativeVpnRuntimeState.RuntimeStatus.VERIFIED
                } else {
                    NativeVpnRuntimeState.RuntimeStatus.ERROR
                },
                error = if (started) null else verification.reason,
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
                waitForNativeReadyOrTerminal(
                    app,
                    connectionSessionId,
                    readyTimeoutMs,
                    operationToken,
                )
            } else {
                null
            }
            val success = readyResult?.ready ?: true
            val waitError = readyResult?.error
            val teardownDown = if (readyResult != null && !readyResult.ready) {
                teardownAfterFailedStartLocked(
                    app,
                    backend = "native",
                    source = source,
                    reason = waitError ?: "native_start_failed",
                    connectionSessionId = connectionSessionId,
                )
            } else {
                null
            }
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
                    "terminal_teardown_down" to teardownDown,
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
    ): Boolean = operationGate.withDisconnect {
        disconnectLocked(
            context = context,
            source = source,
            reason = reason,
            connectionSessionId = connectionSessionId,
            waitForDown = waitForDown,
        )
    }

    /**
     * One ownership transaction for a confirmed network handover failure.
     * The replacement start cannot race Flutter, Quick Tile, process recovery,
     * or a late start from the previous physical network.
     */
    fun reconnectAfterNetworkHandover(
        context: Context,
        config: String,
        protocol: String?,
        mtu: Int = 0,
        source: String = "network_handover",
        connectionSessionId: String? = null,
        readyTimeoutMs: Long = DEFAULT_WAIT_READY_MS,
    ): ConnectResult = operationGate.withReconnect { operationToken ->
        val app = context.applicationContext
        val backend = if (isAwgProtocol(protocol)) "amneziawg" else "native"
        try {
            val down = disconnectLocked(
                context = app,
                source = source,
                reason = "confirmed_dataplane_loss_after_network_handover",
                connectionSessionId = connectionSessionId,
                waitForDown = true,
            )
            if (!down || operationToken.isCancellationRequested()) {
                val error = if (operationToken.isCancellationRequested()) {
                    "handover_reconnect_superseded_by_disconnect"
                } else {
                    "handover_disconnect_barrier_failed"
                }
                Log.w(
                    TAG,
                    "handover reconnect aborted source=$source protocol=${protocol ?: "unknown"} " +
                        "session=${connectionSessionId ?: "null"} reason=$error",
                )
                return@withReconnect ConnectResult(
                    started = false,
                    backend = backend,
                    status = NativeVpnRuntimeState.getRuntimeSnapshot(app).status,
                    error = error,
                )
            }

            connectLocked(
                context = app,
                config = config,
                protocol = protocol,
                mtu = mtu,
                source = source,
                connectionSessionId = connectionSessionId,
                awaitReady = true,
                readyTimeoutMs = readyTimeoutMs,
                operationToken = operationToken,
            )
        } catch (error: Exception) {
            ProtocolRuntimeContract.markError(
                app,
                backend = backend,
                protocol = protocol,
                sessionId = connectionSessionId,
                source = source,
                error = error.message ?: error.javaClass.simpleName,
            )
            teardownAfterFailedStartLocked(
                context = app,
                backend = backend,
                source = source,
                reason = error.message ?: error.javaClass.simpleName,
                connectionSessionId = connectionSessionId,
            )
            ConnectResult(
                started = false,
                backend = backend,
                status = NativeVpnRuntimeState.getRuntimeSnapshot(app).status,
                error = error.message ?: error.javaClass.simpleName,
            )
        }
    }

    private fun disconnectLocked(
        context: Context,
        source: String,
        reason: String,
        connectionSessionId: String?,
        waitForDown: Boolean,
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
            waitUntilDown(
                app,
                DEFAULT_WAIT_DOWN_MS,
                acceptStaleSystemVpnAfterOwnRuntimeDown = true,
            )
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

    private fun cleanupBeforeStartLocked(context: Context, source: String) {
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
        disconnectLocked(
            app,
            source = "${source}_pre_start",
            reason = "cleanup_before_start",
            connectionSessionId = snapshot.sessionId,
            waitForDown = true,
        )
        clearIntentionallyStopped(app)
    }

    fun waitUntilDown(
        context: Context,
        timeoutMs: Long = DEFAULT_WAIT_DOWN_MS,
        acceptStaleSystemVpnAfterOwnRuntimeDown: Boolean = false,
    ): Boolean {
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
                    if (acceptStaleSystemVpnAfterOwnRuntimeDown) {
                        Log.i(
                            TAG,
                            "wait_until_down result=true stale_system_vpn_after_own_runtime_down " +
                                "timeout_ms=$timeoutMs grace_ms=$STALE_SYSTEM_VPN_GRACE_MS",
                        )
                        return true
                    }
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

    private fun canReuseVerifiedRuntime(
        snapshot: NativeVpnRuntimeState.RuntimeSnapshot,
        requestedProtocol: String?,
    ): Boolean {
        if (!snapshot.graniLikelyActive || !snapshot.systemVpnActive) return false
        if (
            snapshot.status != NativeVpnRuntimeState.RuntimeStatus.VERIFIED &&
            snapshot.status != NativeVpnRuntimeState.RuntimeStatus.CONNECTED
        ) {
            return false
        }
        val requested = canonicalProtocol(requestedProtocol) ?: return false
        val running = canonicalProtocol(snapshot.protocol) ?: return false
        return requested == running
    }

    private fun canonicalProtocol(protocol: String?): String? {
        return when (val normalized = protocol?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }) {
            "graniwg", "amneziawg", "awg", "wireguard" -> "graniwg"
            "vless", "vless_ws", "vless-ws" -> "vless_ws"
            "hysteria", "hysteria2", "hy2" -> "hysteria2"
            else -> normalized
        }
    }

    /**
     * A failed start is not complete until every GRANI runtime has crossed the
     * OFF barrier. Keep this inside the operation gate so a queued connect
     * cannot race a late service/binder callback from the failed session.
     */
    private fun teardownAfterFailedStartLocked(
        context: Context,
        backend: String,
        source: String,
        reason: String,
        connectionSessionId: String?,
    ): Boolean {
        val normalizedReason = reason.take(160)
        Log.w(
            TAG,
            "terminal start failure: enforcing teardown barrier backend=$backend " +
                "source=$source session=${connectionSessionId ?: "null"} reason=$normalizedReason",
        )
        val down = disconnectLocked(
            context = context,
            source = "${source}_terminal_failure",
            reason = "terminal_start_failure_$normalizedReason",
            connectionSessionId = connectionSessionId,
            waitForDown = true,
        )
        // Do not trust the already-published OFF state after a failed start.
        // The service/TUN may still be alive and keep the foreground
        // notification (and Android VPN ownership), which then poisons the
        // next VLESS/WireGuard start. This path is terminal and runs under the
        // global operation gate, so an unconditional service-instance fence
        // is safe and cannot race a legitimate concurrent connection.
        GraniVpnService.forceStopAfterTerminalFailure(
            context.applicationContext,
            source = "${source}_terminal_failure_fence",
            reason = "terminal_start_failure_$normalizedReason",
        )
        val fencedDown = waitUntilDown(
            context.applicationContext,
            HARD_CLEANUP_WAIT_MS,
            acceptStaleSystemVpnAfterOwnRuntimeDown = true,
        )
        Log.i(
            TAG,
            "terminal teardown barrier result=$down fenced_down=$fencedDown backend=$backend " +
                "session=${connectionSessionId ?: "null"}",
        )
        return down || fencedDown
    }

    private fun waitForNativeReadyOrTerminal(
        context: Context,
        connectionSessionId: String?,
        timeoutMs: Long,
        operationToken: VpnRuntimeOperationGate.ConnectToken,
    ): ReadyWaitResult {
        val app = context.applicationContext
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        val startedAt = SystemClock.elapsedRealtime()
        var lastSnapshot = NativeVpnRuntimeState.getRuntimeSnapshot(app)

        while (SystemClock.elapsedRealtime() < deadline) {
            if (operationToken.isCancellationRequested()) {
                val snapshot = NativeVpnRuntimeState.getRuntimeSnapshot(app)
                Log.i(
                    TAG,
                    "wait_ready native cancelled by disconnect " +
                        "session=${connectionSessionId ?: "null"} status=${snapshot.status}",
                )
                return ReadyWaitResult(
                    ready = false,
                    snapshot = snapshot,
                    error = "connect_superseded_by_disconnect",
                )
            }
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
            snapshot.status == NativeVpnRuntimeState.RuntimeStatus.CONNECTED
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
        val hadNativeTail =
            NativeVpnRuntimeState.isNativeVpnActiveOrClosing(app) ||
                NativeVpnRuntimeState.isSystemVpnActive(app)
        // A clean runtime has no remote bridge to clean up. Starting and then
        // killing :tun2socks here delayed WireGuard and could race its VPN
        // establishment even though the protocols are independent.
        if (!hadNativeTail) {
            Log.i(TAG, "awg_pre_start clean_fast_path=true source=$source settle_ms=0")
            return true
        }
        try {
            Tun2SocksProcessService.requestForceStop(
                app,
                source = "${source}_awg_pre_start",
                reason = "awg_pre_start_native_tail_cleanup",
            )
        } catch (e: Exception) {
            Log.w(TAG, "awg_pre_start: tun2socks cleanup failed source=$source: ${e.message}")
        }

        // A clean first AWG start does not need the full 1.5 s cross-runtime
        // stability window. Keep a short settle for the remote tun2socks
        // process' confirmed-stop kill, then proceed. Protocol switches still
        // use the conservative wait below.
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
        val serviceInstancePresent = GraniVpnService.hasServiceInstance()
        if (nativeActiveOrClosing || serviceInstancePresent || systemVpnActive) {
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
                    "do not restart :tun2socks merely to stop it",
            )
        }
        if (nativeActiveOrClosing || serviceInstancePresent || systemVpnActive) {
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
        } else {
            Log.i(
                TAG,
                "hard_cleanup_native: skip :tun2socks force-stop because GRANI native runtime is already down",
            )
        }
    }
}
