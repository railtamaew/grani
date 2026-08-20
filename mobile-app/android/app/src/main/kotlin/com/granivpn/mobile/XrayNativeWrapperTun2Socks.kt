package com.granivpn.mobile

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Xray wrapper with tun2socks bridge: TUN -> tun2socks -> Xray SOCKS-in (127.0.0.1:10808).
 * tun2socks запускается в отдельном процессе (:tun2socks) — каждый connect получает свежий процесс,
 * решает tcp_bind_to_netif failed при reconnect (BadVPN не сбрасывает состояние при in-process restart).
 */
class XrayNativeWrapperTun2Socks(private val context: Context) {
    companion object {
        private const val TAG = "XrayTun2Socks"
        private const val XRAY_SOCKS_PORT = 10808
        private const val TUN_MTU = 1420
        /** 300 ms — баланс между скоростью и стабильностью bind. */
        private const val DELAY_BEFORE_TUN2SOCKS_MS = 300L
        private const val TUN2SOCKS_BIND_TIMEOUT_MS = 15000L
        private const val TUN2SOCKS_PREBIND_TIMEOUT_MS = 20000L
        private const val TUN2SOCKS_BIND_ATTEMPTS = 2
        private const val TUN2SOCKS_BIND_RETRY_DELAY_MS = 300L
        private const val TUN2SOCKS_READY_TIMEOUT_MS = 1500L
        private const val TUN2SOCKS_HEALTH_POLL_MS = 1200L
        // Fresh reconnect can produce short-lived binder/pipe blips before dataplane settles.
        private const val TUN2SOCKS_FAILURE_GRACE_MS = 7000L
        private const val TASK_REMOVED_BINDER_GRACE_MS = 12000L
        private const val TASK_REMOVED_REBIND_COOLDOWN_MS = 30000L
        /** Сокращено с 450ms — tun2socks в отдельном процессе, kill даёт быстрый cleanup. */
        private const val DELAY_AFTER_TUN2SOCKS_STOP_MS = 150L
        private const val CORE_STOP_WAIT_MS = 2000L
        private const val DIAG_APP_CONFLICT_A_DISABLE_SOFT_REINIT = true
        private const val DIAG_APP_CONFLICT_A_DISABLE_HEALTH_WATCHER_ACTIONS = true

        @JvmStatic
        fun isAvailable(): Boolean = XrayNativeWrapper.isAvailable()
    }

    private var delegate: XrayNativeWrapper? = null
    private val stateLock = Any()
    private enum class RuntimeState { IDLE, CONNECTING, CONNECTED, DISCONNECTING }
    @Volatile
    private var runtimeState: RuntimeState = RuntimeState.IDLE
    private val tun2socksRunning = AtomicBoolean(false)
    private val tun2socksReady = AtomicBoolean(false)
    private val bridgeGeneration = AtomicLong(0L)
    private val stopped = AtomicBoolean(false)
    @Volatile
    private var tunMtu: Int = TUN_MTU

    @Volatile
    private var tun2socksService: ITun2SocksProcess? = null
    private var tun2socksConnection: ServiceConnection? = null
    @Volatile
    private var tun2socksPrebindLatch: CountDownLatch? = null
    @Volatile
    private var onTun2SocksFailure: ((String) -> Unit)? = null
    @Volatile
    private var healthWatcherThread: Thread? = null
    @Volatile
    private var lastTunAttachStartedAtMs: Long = 0L
    @Volatile
    private var closedPipeGuardUsed = false
    @Volatile
    private var explicitStopVpnConfirmed = false
    @Volatile
    private var lastTunState: String = "init"
    @Volatile
    private var taskRemovedKeepaliveUntilMs: Long = 0L
    @Volatile
    private var taskRemovedRebindAttempted = false
    @Volatile
    private var lastTaskRemovedRebindAtMs: Long = 0L

    private fun setRuntimeState(next: RuntimeState, source: String) {
        synchronized(stateLock) {
            runtimeState = next
        }
        Log.i(TAG, "runtime_state=$next source=$source")
    }

    private fun updateTunState(next: String, source: String) {
        lastTunState = next
        VpnNativeStateEmitter.emitRuntimeDiag(
            "tun_state",
            mapOf(
                "state" to next,
                "source" to source,
                "runtime_state" to runtimeState.name.lowercase(),
            ),
        )
    }

    private fun maybeReportTun2SocksFailure(reason: String) {
        if (stopped.get()) return
        if (reason == "tun2socks_service_disconnected" && lastTunState == "attached") {
            if (VpnRuntimeFeatureFlags.bridgeRecoveryOnBinderLoss(context)) {
                val taskRemovedWindow = System.currentTimeMillis() < taskRemovedKeepaliveUntilMs
                Log.w(
                    TAG,
                    "[DIAG] defer tun2socks disconnect for bridge recovery; " +
                        "reason=$reason task_removed_window=$taskRemovedWindow " +
                        "state=$runtimeState tun=$lastTunState",
                )
                VpnNativeStateEmitter.emitRuntimeDiag(
                    "tun2socks_disconnect_recovery_scheduled",
                    mapOf(
                        "reason" to reason,
                        "task_removed_window" to taskRemovedWindow,
                        "runtime_state" to runtimeState.name.lowercase(),
                        "tun_state" to lastTunState,
                    ),
                )
                maybeRebindTun2SocksAfterDisconnect(reason)
                return
            }
            Log.e(TAG, "[DIAG] tun2socks disconnected after attach; report immediately")
            onTun2SocksFailure?.invoke(reason)
            return
        }
        if (reason.contains("closed pipe", ignoreCase = true) && !closedPipeGuardUsed) {
            closedPipeGuardUsed = true
            if (DIAG_APP_CONFLICT_A_DISABLE_SOFT_REINIT) {
                Log.w(TAG, "[APP_CONFLICT_A] closed-pipe soft reinit disabled reason=$reason")
                VpnNativeStateEmitter.emitRuntimeDiag(
                    "closed_pipe_guard",
                    mapOf("reason" to reason, "action" to "disabled_log_only"),
                )
                return
            }
            Log.w(TAG, "[DIAG] closed-pipe guard: soft bridge reinit")
            VpnNativeStateEmitter.emitRuntimeDiag(
                "closed_pipe_guard",
                mapOf("reason" to reason, "action" to "soft_reinit_bridge"),
            )
            softReinitializeBridge("closed_pipe_guard")
            return
        }
        val elapsed = System.currentTimeMillis() - lastTunAttachStartedAtMs
        if (!reason.startsWith("tun2socks_bind_timeout_after_retries") &&
            elapsed in 0 until TUN2SOCKS_FAILURE_GRACE_MS
        ) {
            Log.w(
                TAG,
                "[DIAG] suppress tun2socks failure in grace window elapsed_ms=$elapsed reason=$reason",
            )
            return
        }
        onTun2SocksFailure?.invoke(reason)
    }

    fun noteTaskRemovedKeepalive(source: String = "task_removed_keepalive") {
        val now = System.currentTimeMillis()
        taskRemovedKeepaliveUntilMs = now + TASK_REMOVED_BINDER_GRACE_MS
        if (now - lastTaskRemovedRebindAtMs > TASK_REMOVED_REBIND_COOLDOWN_MS) {
            taskRemovedRebindAttempted = false
        }
        Log.i(
            TAG,
            "[DIAG] task_removed_keepalive_grace source=$source duration_ms=$TASK_REMOVED_BINDER_GRACE_MS " +
                "state=$runtimeState tun=$lastTunState",
        )
        VpnNativeStateEmitter.emitRuntimeDiag(
            "task_removed_keepalive_grace",
            mapOf(
                "source" to source,
                "duration_ms" to TASK_REMOVED_BINDER_GRACE_MS,
                "runtime_state" to runtimeState.name.lowercase(),
                "tun_state" to lastTunState,
            ),
        )
    }

    private fun maybeRebindTun2SocksAfterDisconnect(reason: String) {
        val now = System.currentTimeMillis()
        val sinceLastRebind = now - lastTaskRemovedRebindAtMs
        if (lastTaskRemovedRebindAtMs > 0L && sinceLastRebind >= TASK_REMOVED_REBIND_COOLDOWN_MS) {
            taskRemovedRebindAttempted = false
        }
        if (lastTaskRemovedRebindAtMs > 0L && sinceLastRebind < TASK_REMOVED_REBIND_COOLDOWN_MS) {
            Log.w(
                TAG,
                "[DIAG] task_removed rebind skipped by cooldown reason=$reason " +
                    "elapsed_ms=$sinceLastRebind cooldown_ms=$TASK_REMOVED_REBIND_COOLDOWN_MS",
            )
            VpnNativeStateEmitter.emitRuntimeDiag(
                "task_removed_tun2socks_rebind_skipped",
                mapOf(
                    "reason" to reason,
                    "action" to "cooldown",
                    "elapsed_ms" to sinceLastRebind,
                    "cooldown_ms" to TASK_REMOVED_REBIND_COOLDOWN_MS,
                ),
            )
            return
        }
        if (taskRemovedRebindAttempted) {
            Log.w(TAG, "[DIAG] task_removed rebind already attempted reason=$reason")
            return
        }
        taskRemovedRebindAttempted = true
        lastTaskRemovedRebindAtMs = now
        if (delegate?.isXrayAlive() != true) {
            Log.w(TAG, "[DIAG] task_removed rebind skipped: xray is not alive reason=$reason")
            return
        }
        Log.w(TAG, "[DIAG] task_removed rebind: restart tun2socks on existing TUN reason=$reason")
        VpnNativeStateEmitter.emitRuntimeDiag(
            "task_removed_tun2socks_rebind",
            mapOf("reason" to reason, "action" to "reuse_existing_tun"),
        )
        Thread {
            try {
                Thread.sleep(250)
                if (stopped.get()) return@Thread
                val d = delegate ?: run {
                    Log.w(TAG, "[DIAG] task_removed rebind skipped: delegate null reason=$reason")
                    return@Thread
                }
                if (!d.isXrayAlive()) {
                    Log.w(TAG, "[DIAG] task_removed rebind skipped: xray stopped reason=$reason")
                    return@Thread
                }
                try {
                    val stoppedService = context.stopService(Intent(context, Tun2SocksProcessService::class.java))
                    Log.i(TAG, "[DIAG] task_removed rebind: stop stale :tun2socks result=$stoppedService")
                } catch (e: Exception) {
                    Log.w(TAG, "[DIAG] task_removed rebind: stop stale :tun2socks failed: ${e.message}")
                }
                val reused = d.reuseCurrentTun("task_removed_tun2socks_disconnect") { pfd ->
                    updateTunState("reusing_existing_tun_for_task_removed_rebind", "task_removed_tun2socks_disconnect")
                    startTun2SocksBridge(pfd, bridgeSource = "binder_disconnect_existing_tun")
                }
                if (!reused) {
                    Log.e(TAG, "[DIAG] task_removed rebind failed: current TUN unavailable")
                    onTun2SocksFailure?.invoke("task_removed_rebind_no_current_tun")
                }
            } catch (e: Exception) {
                Log.e(TAG, "task_removed rebind failed: ${e.message}", e)
                onTun2SocksFailure?.invoke("task_removed_rebind_failed:${e::class.java.simpleName}")
            }
        }.apply {
            name = "task-removed-tun2socks-rebind"
            start()
        }
    }

    private fun softReinitializeBridge(source: String) {
        val d = delegate ?: return
        if (!d.isXrayAlive()) return
        Thread {
            try {
                setRuntimeState(RuntimeState.CONNECTING, source)
                d.cleanupTunOnly(
                    source = source,
                    reason = "soft_reinit_old_tun_close",
                    allowWhileRunning = true,
                )
                updateTunState("closing_for_soft_reinit", source)
                d.attachTun { pfd ->
                    updateTunState("recreated_for_soft_reinit", source)
                    startTun2SocksBridge(pfd, bridgeSource = "soft_reinit")
                }
            } catch (e: Exception) {
                Log.e(TAG, "softReinitializeBridge failed: ${e.message}", e)
                onTun2SocksFailure?.invoke("soft_reinit_failed:${e::class.java.simpleName}")
            }
        }.start()
    }

    fun startVpn(
        vpnService: GraniVpnService,
        xrayConfigJson: String,
        mtu: Int? = null,
        session: String? = null,
        onTun2SocksFailure: ((String) -> Unit)? = null,
    ) {
        synchronized(stateLock) {
            if (runtimeState == RuntimeState.CONNECTING || runtimeState == RuntimeState.DISCONNECTING) {
                Log.w(TAG, "startVpn: skip while state=$runtimeState")
                return
            }
            runtimeState = RuntimeState.CONNECTING
        }
        tunMtu = (mtu ?: TUN_MTU).coerceIn(1280, 1500)
        Log.i(TAG, "[DIAG] startVpn: MTU=$tunMtu (tun2socks в отдельном процессе)")
        stopped.set(false)
        lastTunAttachStartedAtMs = System.currentTimeMillis()
        this.onTun2SocksFailure = onTun2SocksFailure
        explicitStopVpnConfirmed = false
        closedPipeGuardUsed = false
        taskRemovedKeepaliveUntilMs = 0L
        taskRemovedRebindAttempted = false
        lastTaskRemovedRebindAtMs = 0L
        delegate?.let { previous ->
            // Defensive cleanup: avoid overlapping cores when start is triggered while
            // previous wrapper is still attached due lifecycle race.
            try {
                Log.w(TAG, "startVpn: previous delegate detected, forcing stop before new start")
                previous.stopVpn(closeTun = true)
            } catch (e: Exception) {
                Log.w(TAG, "startVpn: previous delegate force-stop failed: ${e.message}")
            } finally {
                delegate = null
            }
        }
        // Start the remote worker while TUN and Xray are being prepared. This
        // hides process/class-loader startup behind useful work and prevents a
        // cold binder from becoming the critical path of every reconnect.
        beginTun2SocksPrebind()
        val wrapper = XrayNativeWrapper(context)
        delegate = wrapper
        wrapper.startVpn(
            vpnService = vpnService,
            xrayConfigJson = xrayConfigJson,
            onTunCreated = { pfd ->
                updateTunState("tun_created", "start_vpn")
                startTun2SocksBridge(pfd)
            },
            mtu = tunMtu,
            session = session
        )
    }

    private fun tun2SocksBindFlags(): Int =
        Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT or Context.BIND_ABOVE_CLIENT

    private fun beginTun2SocksPrebind() {
        if (tun2socksService != null || tun2socksPrebindLatch != null) return
        val latch = CountDownLatch(1)
        tun2socksPrebindLatch = latch
        val intent = Intent(context, Tun2SocksProcessService::class.java)
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                if (stopped.get() || tun2socksConnection !== this) {
                    Log.i(TAG, "[DIAG] ignore stale tun2socks prebind callback")
                    latch.countDown()
                    return
                }
                tun2socksService = ITun2SocksProcess.Stub.asInterface(service)
                Log.i(TAG, "[DIAG] tun2socks prebind connected")
                latch.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                if (tun2socksConnection === this) {
                    tun2socksService = null
                    tun2socksReady.set(false)
                }
                latch.countDown()
                if (!stopped.get() && lastTunState == "attached") {
                    maybeReportTun2SocksFailure("tun2socks_service_disconnected")
                }
            }
        }
        tun2socksConnection = conn
        val bound = try {
            context.bindService(intent, conn, tun2SocksBindFlags())
        } catch (e: Exception) {
            Log.w(TAG, "[DIAG] tun2socks prebind failed: ${e.message}")
            false
        }
        if (!bound) {
            if (tun2socksConnection === conn) tun2socksConnection = null
            tun2socksPrebindLatch = null
            latch.countDown()
        } else {
            Log.i(TAG, "[DIAG] tun2socks prebind requested")
        }
    }

    private fun awaitPreboundTun2Socks(): ITun2SocksProcess? {
        tun2socksService?.let { return it }
        val latch = tun2socksPrebindLatch ?: return null
        val connected = try {
            latch.await(TUN2SOCKS_PREBIND_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        tun2socksPrebindLatch = null
        val remote = if (connected) tun2socksService else null
        if (remote == null) {
            Log.w(TAG, "[DIAG] tun2socks prebind unavailable after ${TUN2SOCKS_PREBIND_TIMEOUT_MS}ms")
            tun2socksConnection?.let { conn ->
                try {
                    context.unbindService(conn)
                } catch (_: Exception) { }
                if (tun2socksConnection === conn) tun2socksConnection = null
            }
        }
        return remote
    }

    /**
     * Запуск tun2socks в отдельном процессе (:tun2socks). PFD передаётся через AIDL.
     */
    private fun startTun2SocksBridge(vpnInterface: ParcelFileDescriptor, bridgeSource: String = "start") {
        if (tun2socksRunning.getAndSet(true)) {
            Log.w(TAG, "[DIAG] tun2socks already started, пропуск")
            return
        }
        tun2socksReady.set(false)
        val generation = bridgeGeneration.incrementAndGet()
        Log.i(
            TAG,
            "[DIAG] startTun2SocksBridge: source=$bridgeSource ожидание готовности Xray " +
                "(до ${DELAY_BEFORE_TUN2SOCKS_MS}ms), затем bind к :tun2socks",
        )
        Thread {
            try {
                val deadline = System.currentTimeMillis() + DELAY_BEFORE_TUN2SOCKS_MS
                while (System.currentTimeMillis() < deadline) {
                    if (delegate?.isXrayAlive() == true) break
                    Thread.sleep(25)
                }
                if (!tun2socksRunning.get() || stopped.get()) return@Thread
                val intent = Intent(context, Tun2SocksProcessService::class.java)
                // The bridge must inherit foreground VPN service importance.
                // BIND_NOT_FOREGROUND made the :tun2socks process fragile when
                // the user closed the GRANI task while the tunnel was active.
                val bindFlags = tun2SocksBindFlags()
                var attachedRemote: ITun2SocksProcess? = awaitPreboundTun2Socks()
                for (attempt in 1..TUN2SOCKS_BIND_ATTEMPTS) {
                    if (attachedRemote != null) break
                    if (!isCurrentBridgeGeneration(generation)) return@Thread
                    val latch = CountDownLatch(1)
                    val attemptActive = AtomicBoolean(true)
                    var remote: ITun2SocksProcess? = null
                    val conn = object : ServiceConnection {
                        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                            if (!attemptActive.get() || !isCurrentBridgeGeneration(generation)) {
                                Log.i(TAG, "[DIAG] ignore stale tun2socks binder callback generation=$generation attempt=$attempt")
                                return
                            }
                            remote = ITun2SocksProcess.Stub.asInterface(service)
                            latch.countDown()
                        }

                        override fun onServiceDisconnected(name: ComponentName?) {
                            if (tun2socksConnection === this) {
                                tun2socksService = null
                                tun2socksReady.set(false)
                            }
                            if (attemptActive.get() && isCurrentBridgeGeneration(generation)) {
                                val reason = "tun2socks_service_disconnected"
                                Log.e(TAG, "[DIAG] $reason generation=$generation attempt=$attempt")
                                maybeReportTun2SocksFailure(reason)
                            }
                        }
                    }
                    tun2socksConnection = conn
                    val bound = try {
                        context.bindService(intent, conn, bindFlags)
                    } catch (e: Exception) {
                        Log.w(TAG, "[DIAG] tun2socks bind failed attempt=$attempt: ${e.message}")
                        false
                    }
                    val connected = bound && latch.await(
                        TUN2SOCKS_BIND_TIMEOUT_MS,
                        TimeUnit.MILLISECONDS,
                    )
                    if (connected && remote != null && isCurrentBridgeGeneration(generation)) {
                        attachedRemote = remote
                        break
                    }
                    attemptActive.set(false)
                    try {
                        context.unbindService(conn)
                    } catch (_: Exception) { }
                    if (tun2socksConnection === conn) tun2socksConnection = null
                    VpnNativeStateEmitter.emitRuntimeDiag(
                        "tun2socks_bind_retry",
                        mapOf(
                            "attempt" to attempt,
                            "max_attempts" to TUN2SOCKS_BIND_ATTEMPTS,
                            "bound" to bound,
                            "timeout_ms" to TUN2SOCKS_BIND_TIMEOUT_MS,
                            "bridge_generation" to generation,
                        ),
                    )
                    if (attempt < TUN2SOCKS_BIND_ATTEMPTS) {
                        Thread.sleep(TUN2SOCKS_BIND_RETRY_DELAY_MS)
                    }
                }
                val remote = attachedRemote
                if (remote == null || !isCurrentBridgeGeneration(generation)) {
                    val reason = "tun2socks_bind_timeout_after_retries"
                    Log.e(TAG, "[DIAG] $reason generation=$generation attempts=$TUN2SOCKS_BIND_ATTEMPTS")
                    maybeReportTun2SocksFailure(reason)
                    return@Thread
                }
                if (!isCurrentBridgeGeneration(generation)) return@Thread
                val pfdDup = ParcelFileDescriptor.dup(vpnInterface.fileDescriptor)
                Log.i(TAG, "[DIAG] tun2socks: TUN fd orig=${vpnInterface.fd} dup=${pfdDup.fd} -> 127.0.0.1:$XRAY_SOCKS_PORT (remote)")
                tun2socksService = remote
                val accepted = try {
                    if (!isCurrentBridgeGeneration(generation)) return@Thread
                    remote.startTun2Socks(pfdDup, tunMtu, "127.0.0.1", XRAY_SOCKS_PORT)
                } finally {
                    // AIDL duplicates the descriptor for the remote process.
                    // The sender must close its copy after the transaction.
                    try {
                        pfdDup.close()
                    } catch (_: Exception) { }
                }
                if (!accepted) {
                    throw IllegalStateException("tun2socks rejected stale/overlapping TUN")
                }
                if (!isCurrentBridgeGeneration(generation)) return@Thread
                val readyDeadline = System.currentTimeMillis() + TUN2SOCKS_READY_TIMEOUT_MS
                while (System.currentTimeMillis() < readyDeadline && isCurrentBridgeGeneration(generation)) {
                    if (remote.isTun2SocksRunning()) break
                    Thread.sleep(40)
                }
                if (!isCurrentBridgeGeneration(generation)) return@Thread
                if (!remote.isTun2SocksRunning()) {
                    throw IllegalStateException("tun2socks did not enter running state")
                }
                Log.i(TAG, "[DIAG] tun2socks запущен в процессе :tun2socks")
                tun2socksReady.set(true)
                setRuntimeState(RuntimeState.CONNECTED, "tun2socks_started")
                updateTunState("attached", "tun2socks_started")
                startTun2SocksHealthWatcher(remote)
            } catch (e: Exception) {
                Log.e(TAG, "[DIAG] tun2socks bridge error: ${e.message}", e)
                maybeReportTun2SocksFailure("tun2socks_bridge_error:${e::class.java.simpleName}")
            } finally {
                // Do not clear a newer generation's start-in-progress flag.
                if (bridgeGeneration.get() == generation) {
                    tun2socksRunning.set(false)
                }
            }
        }.apply {
            name = "tun2socks-bridge"
            start()
        }
    }

    private fun isCurrentBridgeGeneration(generation: Long): Boolean =
        generation == bridgeGeneration.get() && !stopped.get()

    private fun startTun2SocksHealthWatcher(remote: ITun2SocksProcess?) {
        if (DIAG_APP_CONFLICT_A_DISABLE_HEALTH_WATCHER_ACTIONS) {
            Log.i(TAG, "[APP_CONFLICT_A] tun2socks health watcher disabled")
            return
        }
        healthWatcherThread?.interrupt()
        healthWatcherThread = null
        if (remote == null) return
        val t = Thread {
            while (!stopped.get()) {
                try {
                    Thread.sleep(TUN2SOCKS_HEALTH_POLL_MS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
                if (stopped.get()) break
                val runningNow = try {
                    remote.isTun2SocksRunning()
                } catch (e: Exception) {
                    Log.e(TAG, "[DIAG] tun2socks health check failed: ${e.message}")
                    maybeReportTun2SocksFailure("tun2socks_health_check_error")
                    break
                }
                if (!runningNow) {
                    Log.e(TAG, "[DIAG] tun2socks exited unexpectedly while VPN still active")
                    maybeReportTun2SocksFailure("tun2socks_exited")
                    break
                }
            }
        }
        t.name = "tun2socks-health"
        healthWatcherThread = t
        t.start()
    }

    private fun waitForTun2SocksStopped(
        remote: ITun2SocksProcess?,
        source: String,
        timeoutMs: Long,
    ): Boolean {
        if (remote == null) {
            Log.i(TAG, "waitForTun2SocksStopped: remote=null source=$source")
            return true
        }
        val startedAt = System.currentTimeMillis()
        while (System.currentTimeMillis() - startedAt < timeoutMs) {
            val runningNow = try {
                remote.isTun2SocksRunning()
            } catch (e: Exception) {
                Log.i(TAG, "waitForTun2SocksStopped: binder gone source=$source err=${e::class.java.simpleName}")
                return true
            }
            if (!runningNow) {
                Log.i(TAG, "waitForTun2SocksStopped: stopped source=$source elapsed_ms=${System.currentTimeMillis() - startedAt}")
                return true
            }
            try {
                Thread.sleep(80)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        Log.w(TAG, "waitForTun2SocksStopped: timeout source=$source timeout_ms=$timeoutMs")
        VpnNativeStateEmitter.emitRuntimeDiag(
            "tun2socks_stop_wait_timeout",
            mapOf("source" to source, "timeout_ms" to timeoutMs),
        )
        return false
    }

    /**
     * Остановка: закрываем TUN, ждём 200 ms, unbind без stopTun2Socks (избегаем краша pthread_mutex в BadVPN).
     */
    fun stopVpn() {
        if (!stopped.compareAndSet(false, true)) {
            Log.d(TAG, "stopVpn: уже остановлен, пропуск")
            return
        }
        setRuntimeState(RuntimeState.DISCONNECTING, "stop_vpn_confirmed")
        bridgeGeneration.incrementAndGet()
        tun2socksReady.set(false)
        tun2socksRunning.set(false)
        explicitStopVpnConfirmed = true
        try {
            // Ordered shutdown: libXray -> tun2socks -> TUN close.
            delegate?.stopCoreOnly()
            updateTunState("core_stopped", "stop_vpn_confirmed")
            val waitStart = System.currentTimeMillis()
            while (
                delegate?.isXrayAlive() == true &&
                System.currentTimeMillis() - waitStart < CORE_STOP_WAIT_MS
            ) {
                Thread.sleep(50)
            }
            if (delegate?.isXrayAlive() == true) {
                Log.w(TAG, "stopVpn: libXray still alive after ${CORE_STOP_WAIT_MS}ms, continue teardown")
            } else {
                Log.i(TAG, "stopVpn: libXray fully stopped before tun2socks teardown")
            }
            Thread.sleep(120)
        } catch (e: Exception) {
            Log.w(TAG, "stop core: ${e.message}")
        }
        VpnNativeStateEmitter.emitRuntimeDiag(
            "tun2socks_kill_request",
            mapOf("source" to "stopVpn", "reason" to "confirmed_stop", "confirmed_stop_vpn" to true),
        )
        val remote = tun2socksService
        try {
            remote?.stopTun2Socks("stopVpn", "confirmed_stop", true)
        } catch (e: Exception) {
            Log.w(TAG, "stopTun2Socks IPC: ${e.message}")
        }
        // The remote process intentionally kills itself because BadVPN cannot
        // always tear down cleanly. Drop our binding before that kill happens;
        // otherwise Android treats the dead bound service as a crash and
        // schedules an unnecessary restart, delaying a quick reconnect.
        tun2socksConnection?.let { conn ->
            try {
                context.unbindService(conn)
            } catch (e: Exception) {
                Log.w(TAG, "unbindService: ${e.message}")
            }
        }
        tun2socksConnection = null
        tun2socksService = null
        tun2socksPrebindLatch?.countDown()
        tun2socksPrebindLatch = null
        val ipcStopped = waitForTun2SocksStopped(remote, "after_ipc_stop", 900L)
        try {
            val stoppedService = context.stopService(Intent(context, Tun2SocksProcessService::class.java))
            Log.i(TAG, "stopVpn: explicit stopService(:tun2socks) result=$stoppedService")
        } catch (e: Exception) {
            Log.w(TAG, "stopVpn: explicit stopService(:tun2socks) failed: ${e.message}")
        }
        val serviceStopped = waitForTun2SocksStopped(remote, "after_stop_service", 1200L)
        if (!ipcStopped || !serviceStopped) {
            Log.w(
                TAG,
                "stopVpn: tun2socks did not confirm clean stop " +
                    "ipc_stopped=$ipcStopped service_stopped=$serviceStopped; request process force-stop",
            )
            Tun2SocksProcessService.requestForceStop(
                context,
                source = "stopVpn_final",
                reason = "tun2socks_stop_not_confirmed",
            )
            waitForTun2SocksStopped(remote, "after_force_stop", 900L)
        }
        healthWatcherThread?.interrupt()
        healthWatcherThread = null
        try {
            Thread.sleep(DELAY_AFTER_TUN2SOCKS_STOP_MS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        val tunClosed = delegate?.cleanupTunOnlyBlocking(
            source = "stopVpn",
            reason = "ordered_shutdown_after_tun2socks",
            allowWhileRunning = false,
            timeoutMs = 2500L,
        ) ?: true
        if (!tunClosed) {
            Log.w(TAG, "stopVpn: blocking TUN close did not complete cleanly")
        }
        updateTunState(if (tunClosed) "closed" else "close_pending", "stop_vpn_confirmed")
        delegate = null
        onTun2SocksFailure = null
        setRuntimeState(RuntimeState.IDLE, "stop_vpn_done")
    }

    /**
     * Soft disconnect: закрываем TUN, ждём 200 ms, unbind без stopTun2Socks (избегаем краша pthread_mutex в BadVPN).
     */
    fun detachTun() {
        if (stopped.get()) {
            Log.d(TAG, "detachTun: уже остановлен")
            return
        }
        if (explicitStopVpnConfirmed.not()) {
            Log.w(TAG, "detachTun: skip non-explicit cleanup while active")
            VpnNativeStateEmitter.emitRuntimeDiag(
                "cleanup_tun_skipped",
                mapOf("source" to "detachTun", "reason" to "non_explicit_disconnect"),
            )
            return
        }
        tun2socksRunning.set(false)
        try {
            delegate?.cleanupTunOnly(
                source = "detachTun",
                reason = "explicit_disconnect",
                allowWhileRunning = false,
            )
            Thread.sleep(200)
        } catch (e: Exception) {
            Log.w(TAG, "cleanupTunOnly: ${e.message}")
        }
        tun2socksService = null
        tun2socksConnection?.let { try { context.unbindService(it) } catch (_: Exception) { } }
        tun2socksConnection = null
        healthWatcherThread?.interrupt()
        healthWatcherThread = null
        stopped.set(true)
        Log.i(TAG, "detachTun: TUN закрыт, Xray продолжает работать")
    }

    /**
     * Reconnect: Xray уже запущен — создаём новый TUN и запускаем tun2socks (remote).
     */
    fun attachTun(vpnService: GraniVpnService, xrayConfigJson: String, mtu: Int? = null) {
        val d = delegate ?: throw IllegalStateException("delegate null")
        if (!d.isXrayAlive()) {
            throw IllegalStateException("Xray не запущен — нужен полный startVpn")
        }
        tunMtu = (mtu ?: TUN_MTU).coerceIn(1280, 1500)
        stopped.set(false)
        lastTunAttachStartedAtMs = System.currentTimeMillis()
        d.attachTun { pfd ->
            startTun2SocksBridge(pfd)
        }
    }

    /** Xray запущен (можно использовать attachTun для reconnect). */
    fun isXrayAlive(): Boolean = delegate?.isXrayAlive() == true

    fun isRunning(): Boolean = delegate?.isRunning() == true
    fun isBridgeReady(): Boolean = tun2socksReady.get() && !stopped.get()
    fun getLastTunState(): String = lastTunState

    /** Смена routing JSON без перезапуска TUN (см. [XrayNativeWrapper.tryApplyHotRoutingConfig]). */
    fun tryApplyHotRoutingConfig(json: String): Boolean =
        delegate?.tryApplyHotRoutingConfig(json) == true
}
