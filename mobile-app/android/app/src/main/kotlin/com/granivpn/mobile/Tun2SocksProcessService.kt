package com.granivpn.mobile

import android.app.Application
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.Process
import android.util.Log
import com.LondonX.tun2socks.Tun2Socks
import com.LondonX.tun2socks.Tun2Socks.LogLevel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Сервис tun2socks в отдельном процессе (:tun2socks).
 * Каждый connect получает новый процесс — нет остаточного состояния BadVPN после stop.
 * Решает tcp_bind_to_netif failed при reconnect.
 */
class Tun2SocksProcessService : Service() {
    companion object {
        private const val TAG = "Tun2SocksProc"
        // Throughput mode for unstable UDP/443 environments:
        // disable UDP forwarding at tun2socks boundary to prevent
        // endless UDP->blocked->redial loops that starve TCP dataplane.
        private const val GLOBAL_UDP_REDIAL_GUARD_ENABLED = false
        private const val UDP_GUARD_MARKER = "udp_redial_guard_v1_2026_05_08"
    }

    private val binder = object : ITun2SocksProcess.Stub() {
        override fun startTun2Socks(
            tunFd: android.os.ParcelFileDescriptor?,
            mtu: Int,
            socksAddress: String?,
            socksPort: Int
        ) {
            if (tunFd == null || socksAddress.isNullOrBlank()) {
                Log.e(TAG, "startTun2Socks: tunFd или socksAddress пусты")
                return
            }
            startTun2SocksInternal(tunFd, mtu, socksAddress, socksPort)
        }

        override fun stopTun2Socks(source: String?, reason: String?, confirmedStopVpn: Boolean) {
            lastStopSource = source ?: "unknown"
            lastStopReason = reason ?: "unspecified"
            lastStopConfirmed = confirmedStopVpn
            stopTun2SocksInternal()
        }

        override fun isTun2SocksRunning(): Boolean = running.get()
    }

    @Volatile
    private var tun2socksThread: Thread? = null
    private val running = AtomicBoolean(false)
    @Volatile
    private var lastStopSource: String = "none"
    @Volatile
    private var lastStopReason: String = "none"
    @Volatile
    private var lastStopConfirmed: Boolean = false

    override fun onBind(intent: Intent?): IBinder = binder

    private fun startTun2SocksInternal(
        tunFd: android.os.ParcelFileDescriptor,
        mtu: Int,
        socksAddress: String,
        socksPort: Int
    ) {
        if (!running.compareAndSet(false, true)) {
            Log.w(TAG, "tun2socks уже запущен, пропуск")
            return
        }
        tun2socksThread = Thread({
            try {
                Tun2Socks.initialize(applicationContext)
                Log.i(TAG, "[DIAG] tun2socks: TUN fd=${tunFd.fd} mtu=$mtu -> $socksAddress:$socksPort")
                val forwardUdp = !GLOBAL_UDP_REDIAL_GUARD_ENABLED
                Log.i(
                    TAG,
                    "[UDP_GUARD] marker=$UDP_GUARD_MARKER enabled=$GLOBAL_UDP_REDIAL_GUARD_ENABLED forward_udp=$forwardUdp",
                )
                val ok = Tun2Socks.startTun2Socks(
                    LogLevel.NOTICE,
                    tunFd,
                    mtu,
                    socksAddress,
                    socksPort,
                    "10.0.0.2",
                    null,
                    "255.255.255.252",
                    forwardUdp,
                    emptyList()
                )
                if (ok) {
                    Log.i(TAG, "[DIAG] tun2socks завершился нормально")
                } else {
                    Log.e(TAG, "[DIAG] tun2socks start returned false")
                }
            } catch (e: Exception) {
                Log.e(TAG, "tun2socks error: ${e.message}", e)
            } finally {
                try {
                    tunFd.close()
                } catch (_: Exception) { }
                running.set(false)
            }
        }, "tun2socks-remote").apply { start() }
    }

    private fun stopTun2SocksInternal() {
        running.set(false)
        tun2socksThread?.join(2000)
        tun2socksThread = null
    }

    override fun onDestroy() {
        // НЕ вызывать stopTun2SocksInternal() — BadVPN крашится на pthread_mutex при teardown.
        // TUN уже закрыт в main process; tun2socks выйдет сам.
        // Доп. защита: убиваем процесс только если это именно :tun2socks.
        val processName = try {
            Application.getProcessName()
        } catch (_: Exception) {
            null
        }
        if (processName?.endsWith(":tun2socks") == true) {
            Log.i(
                TAG,
                "onDestroy: killProcess for $processName pid=${Process.myPid()} " +
                    "source=$lastStopSource reason=$lastStopReason confirmed_stop_vpn=$lastStopConfirmed",
            )
            Process.killProcess(Process.myPid())
        } else {
            Log.w(
                TAG,
                "onDestroy: skip killProcess, unexpected processName=$processName pid=${Process.myPid()}",
            )
        }
        super.onDestroy()
    }
}
