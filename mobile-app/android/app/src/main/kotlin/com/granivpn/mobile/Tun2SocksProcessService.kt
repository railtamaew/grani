package com.granivpn.mobile

import android.app.Application
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.Process
import android.util.Log
import com.LondonX.tun2socks.Tun2Socks
import com.LondonX.tun2socks.Tun2Socks.LogLevel
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.system.exitProcess

/**
 * Сервис tun2socks в отдельном процессе (:tun2socks).
 * Каждый connect получает новый процесс — нет остаточного состояния BadVPN после stop.
 * Решает tcp_bind_to_netif failed при reconnect.
 */
class Tun2SocksProcessService : Service() {
    companion object {
        private const val TAG = "Tun2SocksProc"
        private const val ACTION_FORCE_STOP =
            "com.granivpn.mobile.action.FORCE_STOP_TUN2SOCKS"
        private const val FORCE_KILL_DELAY_MS = 120L
        // Throughput mode for unstable UDP/443 environments:
        // disable UDP forwarding at tun2socks boundary to prevent
        // endless UDP->blocked->redial loops that starve TCP dataplane.
        private const val GLOBAL_UDP_REDIAL_GUARD_ENABLED = false
        private const val UDP_GUARD_MARKER = "udp_redial_guard_v1_2026_05_08"

        @JvmStatic
        fun requestForceStop(context: Context, source: String, reason: String) {
            val app = context.applicationContext
            val intent = Intent(app, Tun2SocksProcessService::class.java).apply {
                action = ACTION_FORCE_STOP
                putExtra("source", source)
                putExtra("reason", reason)
                putExtra("confirmed_stop_vpn", true)
            }
            try {
                app.startService(intent)
            } catch (e: Exception) {
                Log.w(TAG, "requestForceStop startService failed source=$source: ${e.message}")
            }
            try {
                val stopped = app.stopService(Intent(app, Tun2SocksProcessService::class.java))
                Log.i(TAG, "requestForceStop stopService result=$stopped source=$source reason=$reason")
            } catch (e: Exception) {
                Log.w(TAG, "requestForceStop stopService failed source=$source: ${e.message}")
            }
        }
    }

    private val binder = object : ITun2SocksProcess.Stub() {
        override fun startTun2Socks(
            tunFd: android.os.ParcelFileDescriptor?,
            mtu: Int,
            socksAddress: String?,
            socksPort: Int
        ): Boolean {
            if (tunFd == null || socksAddress.isNullOrBlank()) {
                Log.e(TAG, "startTun2Socks: tunFd или socksAddress пусты")
                try {
                    tunFd?.close()
                } catch (_: Exception) { }
                return false
            }
            return startTun2SocksInternal(tunFd, mtu, socksAddress, socksPort)
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

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate: lightweight worker ready pid=${Process.myPid()}")
    }

    override fun onBind(intent: Intent?): IBinder {
        Log.i(TAG, "onBind: binder published pid=${Process.myPid()}")
        return binder
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_FORCE_STOP) {
            lastStopSource = intent.getStringExtra("source") ?: "force_stop"
            lastStopReason = intent.getStringExtra("reason") ?: "force_stop"
            lastStopConfirmed = intent.getBooleanExtra("confirmed_stop_vpn", true)
            Log.w(
                TAG,
                "onStartCommand: force stop requested startId=$startId " +
                    "source=$lastStopSource reason=$lastStopReason confirmed=$lastStopConfirmed",
            )
            stopTun2SocksInternal(forceKill = true)
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    private fun startTun2SocksInternal(
        tunFd: android.os.ParcelFileDescriptor,
        mtu: Int,
        socksAddress: String,
        socksPort: Int
    ): Boolean {
        if (!running.compareAndSet(false, true)) {
            Log.w(TAG, "tun2socks уже запущен; новый TUN отклонён")
            try {
                tunFd.close()
            } catch (_: Exception) { }
            return false
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
        return true
    }

    private fun stopTun2SocksInternal(forceKill: Boolean = lastStopConfirmed) {
        val thread = tun2socksThread
        if (thread != null) {
            try {
                thread.interrupt()
                thread.join(600)
                if (thread.isAlive) {
                    Log.w(
                        TAG,
                        "stopTun2Socks: thread still alive after 600ms; force kill :tun2socks process",
                    )
                    scheduleProcessKill("thread_alive_after_stop", FORCE_KILL_DELAY_MS)
                } else {
                    running.set(false)
                }
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                Log.w(TAG, "stopTun2Socks interrupted: ${e.message}")
                scheduleProcessKill("stop_interrupted", FORCE_KILL_DELAY_MS)
            }
        } else {
            running.set(false)
        }
        tun2socksThread = null
        stopSelf()
        if (forceKill) {
            scheduleProcessKill("confirmed_stop", FORCE_KILL_DELAY_MS)
        }
    }

    private fun scheduleProcessKill(source: String, delayMs: Long) {
        Thread {
            try {
                if (delayMs > 0L) {
                    Thread.sleep(delayMs)
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            killTun2SocksProcess(source)
        }.apply {
            name = "tun2socks-force-kill"
            isDaemon = true
            start()
        }
    }

    private fun killTun2SocksProcess(source: String) {
        val processName = try {
            Application.getProcessName()
        } catch (_: Exception) {
            null
        }
        if (processName?.endsWith(":tun2socks") == true) {
            Log.w(
                TAG,
                "force killProcess for $processName pid=${Process.myPid()} " +
                    "source=$source last_source=$lastStopSource reason=$lastStopReason " +
                    "confirmed_stop_vpn=$lastStopConfirmed running=${running.get()}",
            )
            Process.killProcess(Process.myPid())
            exitProcess(0)
        } else {
            Log.w(
                TAG,
                "skip force killProcess source=$source unexpected processName=$processName pid=${Process.myPid()}",
            )
        }
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
            exitProcess(0)
        } else {
            Log.w(
                TAG,
                "onDestroy: skip killProcess, unexpected processName=$processName pid=${Process.myPid()}",
            )
        }
        super.onDestroy()
    }
}
