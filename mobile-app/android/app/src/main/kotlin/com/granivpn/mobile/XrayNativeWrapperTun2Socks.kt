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
        private const val TUN2SOCKS_BIND_TIMEOUT_MS = 5000L
        private const val TUN2SOCKS_HEALTH_POLL_MS = 1200L
        // Fresh reconnect can produce short-lived binder/pipe blips before dataplane settles.
        private const val TUN2SOCKS_FAILURE_GRACE_MS = 7000L
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
    private val stopped = AtomicBoolean(false)
    @Volatile
    private var tunMtu: Int = TUN_MTU

    @Volatile
    private var tun2socksService: ITun2SocksProcess? = null
    private var tun2socksConnection: ServiceConnection? = null
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
        if (elapsed in 0 until TUN2SOCKS_FAILURE_GRACE_MS) {
            Log.w(
                TAG,
                "[DIAG] suppress tun2socks failure in grace window elapsed_ms=$elapsed reason=$reason",
            )
            return
        }
        onTun2SocksFailure?.invoke(reason)
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

    /**
     * Запуск tun2socks в отдельном процессе (:tun2socks). PFD передаётся через AIDL.
     */
    private fun startTun2SocksBridge(vpnInterface: ParcelFileDescriptor, bridgeSource: String = "start") {
        if (tun2socksRunning.getAndSet(true)) {
            Log.w(TAG, "[DIAG] tun2socks already started, пропуск")
            return
        }
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
                val pfdDup = ParcelFileDescriptor.dup(vpnInterface.fileDescriptor)
                Log.i(TAG, "[DIAG] tun2socks: TUN fd orig=${vpnInterface.fd} dup=${pfdDup.fd} -> 127.0.0.1:$XRAY_SOCKS_PORT (remote)")
                val latch = CountDownLatch(1)
                var remote: ITun2SocksProcess? = null
                val conn = object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                        remote = ITun2SocksProcess.Stub.asInterface(service)
                        latch.countDown()
                    }
                    override fun onServiceDisconnected(name: ComponentName?) {
                        tun2socksService = null
                        if (!stopped.get()) {
                            val reason = "tun2socks_service_disconnected"
                            Log.e(TAG, "[DIAG] $reason")
                            maybeReportTun2SocksFailure(reason)
                        }
                    }
                }
                tun2socksConnection = conn
                val intent = Intent(context, Tun2SocksProcessService::class.java)
                val bindFlags = Context.BIND_AUTO_CREATE or
                    (if (Build.VERSION.SDK_INT >= 34) Context.BIND_NOT_FOREGROUND else 0)
                context.bindService(intent, conn, bindFlags)
                if (!latch.await(TUN2SOCKS_BIND_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                    val reason = "tun2socks_bind_timeout"
                    Log.e(TAG, "[DIAG] $reason")
                    maybeReportTun2SocksFailure(reason)
                    pfdDup.close()
                    return@Thread
                }
                tun2socksService = remote
                remote?.startTun2Socks(pfdDup, tunMtu, "127.0.0.1", XRAY_SOCKS_PORT)
                Log.i(TAG, "[DIAG] tun2socks запущен в процессе :tun2socks")
                setRuntimeState(RuntimeState.CONNECTED, "tun2socks_started")
                updateTunState("attached", "tun2socks_started")
                startTun2SocksHealthWatcher(remote)
            } catch (e: Exception) {
                Log.e(TAG, "[DIAG] tun2socks bridge error: ${e.message}", e)
                maybeReportTun2SocksFailure("tun2socks_bridge_error:${e::class.java.simpleName}")
            } finally {
                tun2socksRunning.set(false)
            }
        }.apply {
            name = "tun2socks-bridge"
            start()
        }
    }

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

    /**
     * Остановка: закрываем TUN, ждём 200 ms, unbind без stopTun2Socks (избегаем краша pthread_mutex в BadVPN).
     */
    fun stopVpn() {
        if (!stopped.compareAndSet(false, true)) {
            Log.d(TAG, "stopVpn: уже остановлен, пропуск")
            return
        }
        setRuntimeState(RuntimeState.DISCONNECTING, "stop_vpn_confirmed")
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
        try {
            tun2socksService?.stopTun2Socks("stopVpn", "confirmed_stop", true)
        } catch (e: Exception) {
            Log.w(TAG, "stopTun2Socks IPC: ${e.message}")
        }
        tun2socksService = null
        tun2socksConnection?.let { conn ->
            try {
                context.unbindService(conn)
            } catch (e: Exception) {
                Log.w(TAG, "unbindService: ${e.message}")
            }
        }
        tun2socksConnection = null
        healthWatcherThread?.interrupt()
        healthWatcherThread = null
        try {
            Thread.sleep(DELAY_AFTER_TUN2SOCKS_STOP_MS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        delegate?.cleanupTunOnly(
            source = "stopVpn",
            reason = "ordered_shutdown_after_tun2socks",
            allowWhileRunning = false,
        )
        updateTunState("closed", "stop_vpn_confirmed")
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
    fun getLastTunState(): String = lastTunState

    /** Смена routing JSON без перезапуска TUN (см. [XrayNativeWrapper.tryApplyHotRoutingConfig]). */
    fun tryApplyHotRoutingConfig(json: String): Boolean =
        delegate?.tryApplyHotRoutingConfig(json) == true
}
