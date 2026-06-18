package com.granivpn.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import androidx.core.content.ContextCompat
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

class GraniVpnService : android.net.VpnService() {

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLocaleHelper.wrapContext(newBase))
    }

    companion object {
        private const val TAG = "GraniVpnService"
        /** Вручную/скриптом sync_versions.sh перед релизной сборкой; flutter build apk сам не обновляет. */
        private const val CODE_VERSION = "2026-06-18-v26-0758017"
        private const val RUNTIME_STOP_GUARD_MARKER = "2026-04-30-runtime-stop-guard-v1"
        private const val VPN_ADDRESS = "10.0.0.2"
        private const val VPN_ROUTE = "0.0.0.0"
        private const val VPN_MTU = 1420
        private const val ACTION_START = "com.granivpn.mobile.action.START_VPN"
        private const val ACTION_STOP = "com.granivpn.mobile.action.STOP_VPN"
        /** Только hot-swap JSON в libXray (routing/DNS prefs), без stop/start TUN. */
        private const val ACTION_APPLY_ROUTING_HOTSWAP = "com.granivpn.mobile.action.APPLY_ROUTING_HOTSWAP"
        private const val EXTRA_CONFIG = "config"
        private const val EXTRA_PROTOCOL = "protocol"
        private const val EXTRA_MTU = "mtu"
        private const val EXTRA_SOURCE = "source"
        private const val EXTRA_STOP_REASON = "stop_reason"
        /** Сквозной id сессии подключения (Flutter ↔ logcat ↔ бэкенд). */
        private const val EXTRA_CONNECTION_SESSION_ID = "connection_session_id"
        private const val NOTIFICATION_CHANNEL_ID = "grani_vpn_channel"
        private const val NOTIFICATION_ID = 1001
        /** Единый поддерживаемый путь: libXray в процессе VPN + tun2socks в :tun2socks (см. XrayNativeWrapperTun2Socks). */
        /** Имя SharedPreferences для меток времени (reconnect). */
        private const val PREFS_RECONNECT = "grani_vpn_reconnect"
        private const val KEY_LAST_CONNECTION_SESSION_ID = "last_connection_session_id"
        private const val KEY_LAST_VPN_STOP_TS = "last_vpn_stop_ts"
        private const val KEY_INTENTIONALLY_STOPPED = "vpn_intentionally_stopped"
        private const val KEY_AUTO_RESTART_WINDOW_START_MS = "auto_restart_window_start_ms"
        private const val KEY_AUTO_RESTART_COUNT = "auto_restart_count"
        private const val AUTO_RESTART_WINDOW_MS = 60_000L
        private const val AUTO_RESTART_LIMIT = 3
        /** Если переподключение произошло в течение этого времени (мс), даём задержку перед establish(). */
        private const val RECONNECT_WINDOW_MS = 5000L
        /** Дебаунс смены сети (избегаем гонок Wi‑Fi ↔ LTE; 500–800 ms). */
        private const val NETWORK_CHANGE_DEBOUNCE_MS = 600L
        private const val NETWORK_RECONNECT_MIN_INTERVAL_MS = 2000L
        /** Post-connect HTTP probes: English-only log tag for logcat / client log export. */
        private const val CONNECTIVITY_PROBE_LOG = "[CONNECTIVITY_PROBE]"
        private const val PROBE_API_HEALTH_URL = "https://api.granilink.com/health"
        /**
         * Public internet: try several endpoints (HTTP captive check first — avoids TLS quirks;
         * then HTTPS gstatic; then example.com which is typically routed via proxy like user traffic).
         */
        private val PROBE_PUBLIC_CANDIDATES: List<Pair<String, String>> = listOf(
            "http://1.1.1.1/" to "cloudflare_ip_http",
            "http://connectivitycheck.gstatic.com/generate_204" to "captive_http",
            "https://www.gstatic.com/generate_204" to "gstatic_https",
            "https://example.com/" to "example_https",
        )
        private const val PROBE_CONNECT_TIMEOUT_MS = 6500
        private const val PROBE_READ_TIMEOUT_MS = 6500
        /** Tun2socks + routing stabilization before probing (was 400 ms; too early on some OEMs). */
        private const val PROBE_START_DELAY_MS = 1400L
        private const val PROBE_RETRY_GAP_MS = 400L
        private const val PROBE_DEGRADED_RETRY_GAP_MS = 10_000L
        private const val PROBE_DEGRADED_MAX_RETRIES = 6
        private const val DIAG_APP_CONFLICT_A_DISABLE_NETWORK_CALLBACK = true
        private const val DIAG_APP_CONFLICT_A_DISABLE_POST_CONNECT_PROBES = false
        // Diagnostic mode: ensure split-domain prefs do not affect routing.
        private const val FORCE_NEUTRAL_SPLIT_DOMAINS = true
        private const val MTU_WIFI = 1500
        private const val MTU_MOBILE = 1280
        private const val MTU_DEFAULT = 1420
        /** Базово 200 ms. Oplus (OPPO/OnePlus/realme) — 400 ms для стабильной маршрутизации. */
        private fun getReconnectDelayMs(): Long {
            val mfr = Build.MANUFACTURER.uppercase()
            if (mfr.contains("OPPO") || mfr.contains("ONEPLUS") || mfr.contains("REALME")) return 400L
            return 200L
        }

        // Статический контекст для использования когда сервис создан напрямую
        private var appContext: android.content.Context? = null
        @Volatile
        private var instance: GraniVpnService? = null
        
        fun setAppContext(context: android.content.Context) {
            appContext = context.applicationContext
            Log.d(TAG, "AppContext установлен: ${appContext?.packageName}")
        }
        
        fun getAppContext(): android.content.Context? = appContext

        fun startService(
            context: Context,
            config: String,
            protocol: String? = null,
            mtu: Int = 0,
            source: String? = null,
            connectionSessionId: String? = null,
        ) {
            val intent = Intent(context, GraniVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, config)
                if (!protocol.isNullOrBlank()) putExtra(EXTRA_PROTOCOL, protocol)
                if (mtu > 0) putExtra(EXTRA_MTU, mtu)
                if (!source.isNullOrBlank()) putExtra(EXTRA_SOURCE, source)
                if (!connectionSessionId.isNullOrBlank()) {
                    putExtra(EXTRA_CONNECTION_SESSION_ID, connectionSessionId)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopService(
            context: Context,
            source: String? = null,
            reason: String? = null,
            connectionSessionId: String? = null,
        ) {
            val intent = Intent(context, GraniVpnService::class.java).apply {
                action = ACTION_STOP
                if (!source.isNullOrBlank()) putExtra(EXTRA_SOURCE, source)
                if (!reason.isNullOrBlank()) putExtra(EXTRA_STOP_REASON, reason)
                if (!connectionSessionId.isNullOrBlank()) {
                    putExtra(EXTRA_CONNECTION_SESSION_ID, connectionSessionId)
                }
            }
            context.startService(intent)
        }

        /** Применить DNS/split routing из prefs через libXray без перезапуска туннеля. */
        fun requestApplyRoutingHotSwap(context: Context) {
            val intent = Intent(context, GraniVpnService::class.java).apply {
                action = ACTION_APPLY_ROUTING_HOTSWAP
            }
            ContextCompat.startForegroundService(context, intent)
        }

        @Volatile
        private var lastStartErrorSnapshot: String? = null

        private fun clearLastStartErrorSnapshot() {
            lastStartErrorSnapshot = null
        }

        private fun recordLastStartError(error: String?) {
            lastStartErrorSnapshot = error
        }

        fun isVpnRunning(): Boolean = instance?.isVpnRunning() == true
        fun isVpnCommitted(): Boolean = instance?.isVpnCommitted() == true

        fun getLastStartError(): String? = instance?.lastStartError ?: lastStartErrorSnapshot

        fun getTrafficStatsSnapshot(): Map<String, Long> {
            return instance?.getTrafficStats() ?: mapOf("rx_bytes" to 0L, "tx_bytes" to 0L)
        }

        /** Последний эффективный outbound-plan Xray (для logs/send корреляции с backend/node). */
        fun getLastEffectiveOutbounds(): String? = instance?.lastEffectiveOutbounds

        /** Снимок для EventChannel при подписке (без лишнего polling из Dart). */
        fun peekStateForFlutter(): Pair<Boolean, String> {
            val i = instance ?: return false to "idle"
        return i.isVpnCommitted() to i.serviceState.name.lowercase(Locale.US)
        }
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var isRunning = false
    @Volatile
    private var lastStartError: String? = null
    private var currentProtocol: VpnProtocol? = null
    private var currentAdapter: VpnAdapter? = null
    private var xrayNativeWrapper: XrayNativeWrapperTun2Socks? = null
    private var hysteria2Runtime: Hysteria2ProcessWrapper? = null
    @Volatile
    private var lastEffectiveOutbounds: String? = null
    // Статистика трафика
    @Volatile
    private var totalBytesRead: Long = 0L
    @Volatile
    private var totalBytesWritten: Long = 0L
    @Volatile
    private var trafficFirstLogged: Boolean = false
    private val trafficStatsTracker = TrafficStatsTracker(AndroidTrafficStatsProvider())

    // Последняя конфигурация для перезапуска при onTaskRemoved (сохраняем при каждом START)
    private var lastConfig: String? = null
    private var lastProtocol: String? = null
    private var lastMtu: Int = 0
    /** Последний известный connection_session_id (Flutter или prefs) для handover и корреляции логов. */
    @Volatile
    private var lastConnectionSessionId: String? = null
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var networkEvalRunnable: Runnable? = null
    @Volatile
    private var lastUnderlyingNetworkType: String? = null
    @Volatile
    private var networkReconnectInProgress = false
    @Volatile
    private var lastNetworkReconnectAtMs: Long = 0L
    private val runtimeFailureHandled = AtomicBoolean(false)
    private val orderedStopInProgress = AtomicBoolean(false)

    /** Явное состояние сервиса для наблюдаемости и корректного отображения в уведомлении. */
    enum class ServiceState { IDLE, PREPARE, LOCAL_UP, DATAPLANE_VERIFIED, COMMITTED, DISCONNECTING, ERROR }

    @Volatile
    private var serviceState: ServiceState = ServiceState.IDLE

    private fun setServiceState(s: ServiceState) {
        serviceState = s
        Log.d(TAG, "serviceState=$s")
        if (s == ServiceState.LOCAL_UP || s == ServiceState.DATAPLANE_VERIFIED || s == ServiceState.COMMITTED) {
            VpnNativeStateEmitter.maybeStartTrafficTicks()
        } else {
            VpnNativeStateEmitter.stopTrafficTicks()
        }
        VpnNativeStateEmitter.emit(isVpnRunning(), s.name.lowercase(Locale.US))
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        appContext = applicationContext
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        if (DIAG_APP_CONFLICT_A_DISABLE_NETWORK_CALLBACK) {
            Log.i(TAG, "[APP_CONFLICT_A] native NetworkCallback disabled")
        } else {
            registerUnderlyingNetworkCallback()
        }
        Log.d(TAG, "GraniVpnService создан")
    }

    override fun onDestroy() {
        unregisterUnderlyingNetworkCallback()
        networkEvalRunnable?.let { mainHandler.removeCallbacks(it) }
        networkEvalRunnable = null
        if (xrayNativeWrapper != null) {
            stopXrayFull()
        }
        if (hysteria2Runtime != null) {
            stopHysteria2()
        }
        super.onDestroy()
        instance = null
        Log.d(TAG, "GraniVpnService уничтожен")
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (isRunning && !lastConfig.isNullOrEmpty()) {
            val sid = lastConnectionSessionId ?: loadPersistedSessionId()
            // Task removed не является crash-сценарием: не учитываем в circuit breaker,
            // чтобы закрытие/свайп приложения не ломало удержание рабочего туннеля.
            Log.i(TAG, "onTaskRemoved: задача удалена при активном VPN — сохраняем туннель и перезапускаем сервис")
            Log.i(
                TAG,
                "[RESTART_TRACE] schedule source=task_removed_restart reason=task_removed connection_session_id=${sid ?: "null"}",
            )
            val restartIntent = Intent(applicationContext, GraniVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, lastConfig)
                if (!lastProtocol.isNullOrBlank()) putExtra(EXTRA_PROTOCOL, lastProtocol)
                if (lastMtu > 0) putExtra(EXTRA_MTU, lastMtu)
                putExtra(EXTRA_SOURCE, "task_removed_restart")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(restartIntent)
            } else {
                startService(restartIntent)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: action=${intent?.action}, flags=$flags, startId=$startId")
        when (intent?.action) {
            ACTION_START -> {
                val startSource = intent.getStringExtra(EXTRA_SOURCE) ?: "unknown"
                if (isRunning ||
                    serviceState == ServiceState.PREPARE ||
                    serviceState == ServiceState.LOCAL_UP ||
                    serviceState == ServiceState.DATAPLANE_VERIFIED ||
                    serviceState == ServiceState.COMMITTED
                ) {
                    Log.i(
                        TAG,
                        "onStartCommand: start_ignored_busy_state source=$startSource state=$serviceState isRunning=$isRunning",
                    )
                    ensureForegroundWithNotification(createNotification())
                    refreshQuickTile()
                    return START_STICKY
                }
                val config = intent.getStringExtra(EXTRA_CONFIG)
                val protocolHint = intent.getStringExtra(EXTRA_PROTOCOL)
                val mtuExtra = intent.getIntExtra(EXTRA_MTU, 0)
                val sidExtra = intent.getStringExtra(EXTRA_CONNECTION_SESSION_ID)?.trim()
                if (!sidExtra.isNullOrEmpty()) {
                    persistConnectionSessionId(sidExtra)
                } else if (lastConnectionSessionId.isNullOrBlank()) {
                    lastConnectionSessionId = loadPersistedSessionId()
                }
                Log.i(
                    TAG,
                    "[CORRELATION] connection_session_id=${lastConnectionSessionId ?: "null"} start_source=$startSource",
                )
                if (config.isNullOrEmpty()) {
                    Log.e(TAG, "onStartCommand: ❌ конфигурация отсутствует")
                    stopSelf()
                    return START_NOT_STICKY
                }
                setIntentionallyStopped(false)
                orderedStopInProgress.set(false)
                runtimeFailureHandled.set(false)
                lastConfig = config
                lastProtocol = protocolHint
                lastMtu = if (mtuExtra > 0) mtuExtra else 0
                Log.d(TAG, "onStartCommand: Конфигурация получена, длина=${config.length}, mtu=$mtuExtra")
                Log.d(TAG, "onStartCommand: Подсказка протокола: ${protocolHint ?: "null"}")
                Log.i(TAG, "onStartCommand: start_source=$startSource")

                ensureForegroundWithNotification(createNotification())
                val success = startVpn(config, protocolHint, if (mtuExtra > 0) mtuExtra else null)
                if (!success) {
                    Log.e(TAG, "onStartCommand: старт VPN не удался")
                    stopSelf()
                } else {
                    saveConfigToPreferences(config, protocolHint)
                }
                return START_STICKY
            }
            ACTION_STOP -> {
                val stopSource = intent.getStringExtra(EXTRA_SOURCE) ?: "unknown"
                val stopReason = intent.getStringExtra(EXTRA_STOP_REASON) ?: "unspecified"
                val sidExtra = intent.getStringExtra(EXTRA_CONNECTION_SESSION_ID)?.trim()
                if (!sidExtra.isNullOrEmpty()) {
                    persistConnectionSessionId(sidExtra)
                } else if (lastConnectionSessionId.isNullOrBlank()) {
                    lastConnectionSessionId = loadPersistedSessionId()
                }
                Log.i(
                    TAG,
                    "[DISCONNECT_TRACE] source=$stopSource reason=$stopReason connection_session_id=${lastConnectionSessionId ?: "null"}",
                )
                setIntentionallyStopped(true)
                orderedStopInProgress.set(true)
                stopVpn()
                refreshQuickTile()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_APPLY_ROUTING_HOTSWAP -> {
                Log.i(TAG, "onStartCommand: APPLY_ROUTING_HOTSWAP (без stop/start VPN)")
                ensureForegroundWithNotification(createNotification())
                Thread {
                    try {
                        applyRoutingHotSwapInternal()
                    } catch (e: Exception) {
                        Log.e(TAG, "APPLY_ROUTING_HOTSWAP failed: ${e.message}", e)
                    }
                }.start()
                return START_STICKY
            }
            else -> {
                Log.i(TAG, "onStartCommand: действие=${intent?.action ?: "null (sticky restart)"} source=sticky_restart")
                val sid = lastConnectionSessionId ?: loadPersistedSessionId()
                if (!registerAutoRestartAttempt("sticky_restart")) {
                    Log.e(
                        TAG,
                        "[AUTO_RESTART_CB] block source=sticky_restart connection_session_id=${sid ?: "null"}",
                    )
                    setIntentionallyStopped(true)
                    lastStartError = "Auto-restart blocked by circuit breaker (sticky_restart)"
                    setServiceState(ServiceState.ERROR)
                    ensureForegroundWithNotification(createRecoveryNotification())
                    stopSelf()
                    return START_NOT_STICKY
                }
                Log.i(
                    TAG,
                    "[RESTART_TRACE] attempt source=sticky_restart reason=service_recreated connection_session_id=${sid ?: "null"}",
                )
                if (wasIntentionallyStopped()) {
                    Log.i(TAG, "onStartCommand: VPN был остановлен пользователем, не восстанавливаем")
                    ensureForegroundWithNotification(createRecoveryNotification())
                    stopSelf()
                    return START_NOT_STICKY
                }
                val saved = VpnPlugin.loadLastConfig(applicationContext)
                if (saved != null && saved.config.isNotBlank()) {
                    Log.i(TAG, "onStartCommand: восстановление VPN из сохранённого конфига, длина=${saved.config.length}")
                    ensureForegroundWithNotification(createNotification())
                    lastConfig = saved.config
                    lastProtocol = saved.protocol
                    lastMtu = if (saved.mtu > 0) saved.mtu else 0
                    val success = startVpn(
                        saved.config,
                        saved.protocol,
                        if (saved.mtu > 0) saved.mtu else null
                    )
                    if (!success) {
                        Log.e(TAG, "onStartCommand: восстановление VPN не удалось")
                        stopSelf()
                    } else {
                        Log.i(TAG, "onStartCommand: VPN восстановлен после sticky restart")
                    }
                } else {
                    Log.w(TAG, "onStartCommand: сохранённого конфига нет, останавливаем сервис")
                    ensureForegroundWithNotification(createRecoveryNotification())
                    stopSelf()
                }
                return START_STICKY
            }
        }
    }

    /** Вызов startForeground в течение 5 с для соответствия требованиям Foreground Service. */
    private fun ensureForegroundWithNotification(notification: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun saveConfigToPreferences(config: String, protocol: String?) {
        try {
            val mtuToSave = if (lastMtu > 0) lastMtu else 0
            VpnPlugin.saveLastConfig(applicationContext, config, protocol, mtuToSave)
            Log.d(TAG, "saveConfigToPreferences: конфиг сохранён (mtu=$mtuToSave)")
        } catch (e: Exception) {
            Log.w(TAG, "saveConfigToPreferences: не удалось сохранить: ${e.message}")
        }
    }

    private fun createRecoveryNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                getString(R.string.vpn_notification_channel_name),
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(getString(R.string.vpn_notification_title))
            .setContentText(getString(R.string.vpn_notification_recovering))
            .setSmallIcon(R.drawable.ic_notification_g)
            .setOngoing(true)
            .build()
    }

    private fun createNotification(contentText: String? = null): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                getString(R.string.vpn_notification_channel_name),
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }

        val text = contentText ?: getString(R.string.vpn_notification_connected)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(getString(R.string.vpn_notification_title))
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification_g)
            .setOngoing(true)
            .build()
    }

    /** Обновляет текст уведомления (можно вызывать из фоновых потоков). */
    private fun updateNotificationContent(text: String) {
        Handler(Looper.getMainLooper()).post {
            ensureForegroundWithNotification(createNotification(text))
        }
    }

    enum class VpnProtocol {
        XRAY,
        HYSTERIA2
    }

    @Volatile
    private var requestedMtu: Int? = null
    @Volatile
    private var vpnStartTs: Long = 0L

    fun startVpn(config: String, protocolHint: String? = null, mtu: Int? = null): Boolean {
        vpnStartTs = System.currentTimeMillis()
        Log.i(TAG, "startVpn: ========== ЗАПУСК VPN (ВЕРСИЯ КОДА: $CODE_VERSION) ==========")
        Log.i(TAG, "startVpn: runtime_stop_guard_marker=$RUNTIME_STOP_GUARD_MARKER")
        Log.d(TAG, "startVpn: Начало, isRunning=$isRunning, длина конфигурации=${config.length}, mtu=$mtu")
        Log.d(TAG, "startVpn: Превью конфигурации: ${VpnLogRedaction.previewRedacted(config, 200)}")
        Log.d(TAG, "startVpn: Подсказка протокола: ${protocolHint ?: "null"}")

        lastStartError = null
        clearLastStartErrorSnapshot()
        
        if (isRunning) {
            Log.w(TAG, "VPN уже запущен")
            return false
        }

        try {
            // Определяем тип протокола
            Log.d(TAG, "startVpn: Определение протокола...")
            currentProtocol = detectProtocol(config, protocolHint)
            Log.i(TAG, "startVpn: Определен протокол: $currentProtocol")
            requestedMtu = clampMtuForXray(mtu, currentProtocol)

            when (currentProtocol) {
                VpnProtocol.XRAY -> {
                    currentAdapter = XrayAdapter()
                }
                VpnProtocol.HYSTERIA2 -> {
                    currentAdapter = Hysteria2Adapter()
                }
                null -> {
                    Log.e(TAG, "Не удалось определить протокол")
                    return false
                }
            }
            
            val adapter = currentAdapter
            if (adapter == null) {
                Log.e(TAG, "startVpn: Адаптер протокола не инициализирован")
                return false
            }
            setServiceState(ServiceState.PREPARE)
            val started = adapter.start(config)
            if (!started) {
                Log.e(TAG, "startVpn: Не удалось запустить VPN через адаптер")
                lastStartError = "Не удалось запустить VPN через адаптер"
                recordLastStartError(lastStartError)
                currentAdapter = null
                currentProtocol = null
                return false
            }
            resetTrafficStats()
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка запуска VPN: ${e.message}", e)
            lastStartError = e.message ?: "Ошибка запуска VPN"
            recordLastStartError(lastStartError)
            return false
        }
    }

    /**
     * Определяет тип протокола по конфигурации
     */
    private fun detectProtocol(config: String, protocolHint: String? = null): VpnProtocol? {
        val trimmed = config.trim()
        val hintProtocol = mapProtocolHint(protocolHint)
        if (hintProtocol != null) {
            Log.d(TAG, "detectProtocol: Используем подсказку протокола: $hintProtocol")
            return hintProtocol
        }

        return when {
            trimmed.startsWith("vless://") || trimmed.startsWith("vmess://") -> {
                Log.d(TAG, "Обнаружен XRay URL формат")
                VpnProtocol.XRAY
            }
            trimmed.startsWith("hysteria2://") || trimmed.startsWith("hy2://") -> {
                Log.d(TAG, "Обнаружен Hysteria2 URL формат")
                VpnProtocol.HYSTERIA2
            }
            trimmed.startsWith("{") -> {
                // Проверяем, это XRay JSON или другой JSON
                try {
                    val json = org.json.JSONObject(trimmed)
                    
                    val outbounds = json.optJSONArray("outbounds")
                    if (outbounds != null) {
                        for (i in 0 until outbounds.length()) {
                            val outbound = outbounds.optJSONObject(i)
                            if (outbound?.optString("type") == "hysteria2") {
                                Log.d(TAG, "Обнаружен sing-box Hysteria2 JSON")
                                return VpnProtocol.HYSTERIA2
                            }
                        }
                    }

                    // Проверяем полный формат XRay (с outbounds/inbounds)
                    if (json.has("outbounds") || json.has("inbounds")) {
                        Log.d(TAG, "Обнаружен XRay JSON формат (полный)")
                        return VpnProtocol.XRAY
                    }
                    
                    // Проверяем упрощенный формат XRay (из vpn_service.dart)
                    // Формат: {"v": "2", "add": "...", "port": "...", "id": "...", "net": "...", "tls": "..."}
                    if (json.has("add") && json.has("port") && json.has("id") && 
                        (json.has("net") || json.has("tls") || json.has("v") || json.has("scy"))) {
                        Log.d(TAG, "Обнаружен XRay JSON формат (упрощенный клиентский)")
                        return VpnProtocol.XRAY
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "Ошибка парсинга JSON: ${e.message}")
                }
                Log.w(TAG, "Неизвестный JSON формат, поддерживается только Xray")
                null
            }
            else -> {
                Log.w(TAG, "Формат конфига не распознан, поддерживается только Xray")
                null
            }
        }
    }

    /** Xray+tun2socks+VLESS: слишком большой MTU часто даёт «мёртвый» HTTPS при живом TCP. */
    private fun clampMtuForXray(mtu: Int?, protocol: VpnProtocol?): Int? {
        if (mtu == null || mtu <= 0) return null
        if (protocol != VpnProtocol.XRAY) return mtu
        val cap = 1420
        return if (mtu > cap) {
            Log.i(TAG, "clampMtuForXray: client_mtu=$mtu -> $cap (fragmentation safety)")
            cap
        } else {
            mtu
        }
    }

    private fun mapProtocolHint(protocolHint: String?): VpnProtocol? {
        if (protocolHint.isNullOrBlank()) {
            return null
        }
        val normalized = protocolHint.trim().lowercase()
        return when {
            normalized == "hysteria2" || normalized == "hy2" -> VpnProtocol.HYSTERIA2
            normalized == "vless_ws" -> VpnProtocol.XRAY
            normalized.startsWith("xray") -> VpnProtocol.XRAY
            else -> null
        }
    }

    private fun expectedNativeProtocolLabel(): String? {
        lastProtocol?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        return when (currentProtocol) {
            VpnProtocol.XRAY -> "xray"
            VpnProtocol.HYSTERIA2 -> "hysteria2"
            null -> null
        }
    }

    fun stopVpn(finalState: ServiceState = ServiceState.IDLE) {
        if (finalState != ServiceState.ERROR) {
            orderedStopInProgress.set(true)
        }
        try {
            NativeVpnRuntimeState.markNativeVpnExpectedUp(
                applicationContext,
                false,
                expectedNativeProtocolLabel(),
            )
            setServiceState(ServiceState.DISCONNECTING)
            isRunning = false
            lastStartError = null
            try {
                VpnCircuitBreaker.reset()
            } catch (_: Exception) {
            }

            val adapter = currentAdapter
            if (adapter != null) {
                adapter.stop()
            }
            waitForTunClosedBeforeForegroundRemove()
            
            currentProtocol = null
            currentAdapter = null
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            
            Log.i(TAG, "VPN остановлен")
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка остановки VPN: ${e.message}", e)
        } finally {
            setServiceState(finalState)
            saveLastVpnStopTimestamp()
            refreshQuickTile()
        }
    }

    /**
     * Не снимаем foreground-уведомление мгновенно: ждём короткое окно, пока TUN реально закроется.
     * Иначе в UI может исчезнуть иконка GRANI, а системный ключ VPN ещё останется.
     */
    private fun waitForTunClosedBeforeForegroundRemove() {
        val wrapper = xrayNativeWrapper ?: return
        val waitStart = SystemClock.elapsedRealtime()
        val waitBudgetMs = 4000L
        while (SystemClock.elapsedRealtime() - waitStart < waitBudgetMs) {
            val tunState = wrapper.getLastTunState()
            if (tunState == "closed" || tunState == "idle") {
                return
            }
            try {
                Thread.sleep(80L)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            }
        }
        Log.w(TAG, "waitForTunClosedBeforeForegroundRemove: timeout ${waitBudgetMs}ms, continue foreground remove")
    }

    /** Сохраняет время остановки VPN для задержки при быстром переподключении (reconnect). */
    private fun saveLastVpnStopTimestamp() {
        try {
            getSharedPreferences(PREFS_RECONNECT, Context.MODE_PRIVATE)
                .edit()
                .putLong(KEY_LAST_VPN_STOP_TS, System.currentTimeMillis())
                .apply()
        } catch (e: Exception) {
            Log.w(TAG, "saveLastVpnStopTimestamp: ${e.message}")
        }
    }

    /** Возвращает время последней остановки VPN (0 если не было). */
    private fun getLastVpnStopTimestamp(): Long {
        return try {
            getSharedPreferences(PREFS_RECONNECT, Context.MODE_PRIVATE)
                .getLong(KEY_LAST_VPN_STOP_TS, 0L)
        } catch (e: Exception) {
            0L
        }
    }

    private fun setIntentionallyStopped(stopped: Boolean) {
        try {
            getSharedPreferences(PREFS_RECONNECT, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_INTENTIONALLY_STOPPED, stopped)
                .apply()
            Log.d(TAG, "setIntentionallyStopped: $stopped")
        } catch (e: Exception) {
            Log.w(TAG, "setIntentionallyStopped: ${e.message}")
        }
    }

    private fun wasIntentionallyStopped(): Boolean {
        return try {
            getSharedPreferences(PREFS_RECONNECT, Context.MODE_PRIVATE)
                .getBoolean(KEY_INTENTIONALLY_STOPPED, false)
        } catch (e: Exception) {
            false
        }
    }

    private fun registerAutoRestartAttempt(source: String): Boolean {
        return try {
            val prefs = getSharedPreferences(PREFS_RECONNECT, Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val windowStart = prefs.getLong(KEY_AUTO_RESTART_WINDOW_START_MS, 0L)
            val prevCount = prefs.getInt(KEY_AUTO_RESTART_COUNT, 0)
            val inWindow = windowStart > 0L && (now - windowStart) <= AUTO_RESTART_WINDOW_MS
            val nextCount = if (inWindow) prevCount + 1 else 1
            val nextWindowStart = if (inWindow) windowStart else now
            prefs.edit()
                .putLong(KEY_AUTO_RESTART_WINDOW_START_MS, nextWindowStart)
                .putInt(KEY_AUTO_RESTART_COUNT, nextCount)
                .apply()
            val sid = lastConnectionSessionId ?: loadPersistedSessionId()
            Log.i(
                TAG,
                "[AUTO_RESTART_CB] source=$source count=$nextCount limit=$AUTO_RESTART_LIMIT " +
                    "window_ms=${now - nextWindowStart} connection_session_id=${sid ?: "null"}",
            )
            nextCount <= AUTO_RESTART_LIMIT
        } catch (e: Exception) {
            Log.w(TAG, "registerAutoRestartAttempt: ${e.message}")
            true
        }
    }

    private fun handleRuntimeFailure(reason: String, source: String) {
        val sid = lastConnectionSessionId ?: loadPersistedSessionId()
        val tunState = xrayNativeWrapper?.getLastTunState() ?: "unknown"
        if (orderedStopInProgress.get() || serviceState == ServiceState.DISCONNECTING || wasIntentionallyStopped()) {
            Log.i(
                TAG,
                "[RUNTIME_FAIL_SUPPRESSED] source=$source reason=$reason connection_session_id=${sid ?: "null"} " +
                    "state=$serviceState isRunning=$isRunning last_tun_state=$tunState ordered_stop=${orderedStopInProgress.get()}",
            )
            return
        }
        if (!runtimeFailureHandled.compareAndSet(false, true)) return
        Log.e(
            TAG,
            "[RUNTIME_FAIL] source=$source reason=$reason connection_session_id=${sid ?: "null"} " +
                "state=$serviceState isRunning=$isRunning last_tun_state=$tunState ordered_stop=${orderedStopInProgress.get()}",
        )
        VpnNativeStateEmitter.emitRuntimeDiag(
            "runtime_fail",
            mapOf(
                "source" to source,
                "reason" to reason,
                "vpn_session_id" to (sid ?: ""),
                "runtime_fail_reason" to reason,
                "last_tun_state" to tunState,
            ),
        )
        setIntentionallyStopped(true)
        lastStartError = reason
        recordLastStartError(reason)
        try {
            stopVpn(ServiceState.ERROR)
        } catch (e: Exception) {
            Log.e(TAG, "handleRuntimeFailure.stopVpn: ${e.message}", e)
        } finally {
            stopSelf()
        }
    }

    /** Остановка Xray при disconnect. Всегда полный stop (как Amnezia/v2rayNG) — без soft reconnect. */
    private fun stopXray() {
        stopXrayFull()
    }

    private fun stopHysteria2() {
        try {
            hysteria2Runtime?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Ошибка остановки Hysteria2 process runtime: ${e.message}", e)
        }
        hysteria2Runtime = null
    }

    /** Полная остановка Xray (при смене конфига/сервера или уничтожении сервиса). */
    private fun stopXrayFull() {
        try {
            xrayNativeWrapper?.stopVpn()
            xrayNativeWrapper = null
            Log.i(TAG, "XRay VPN полностью остановлен")
        } catch (e: Exception) {
            Log.w(TAG, "Ошибка остановки XRay: ${e.message}", e)
        }
        vpnInterface?.close()
        vpnInterface = null
    }

    /**
     * Собирает JSON для libXray: native или legacy → native + routing prefs.
     * @param resetBreaker сброс circuit breaker только при полном новом connect.
     */
    private fun buildProcessedXrayConfig(context: Context, config: String, resetBreaker: Boolean): String {
        if (resetBreaker) {
            VpnCircuitBreaker.reset()
        }
        val splitMode = SplitTunnelPrefs.getMode(context)
        val splitPackages = SplitTunnelPrefs.getSelectedPackages(context)
        val splitDirectDomains = if (FORCE_NEUTRAL_SPLIT_DOMAINS) {
            emptyList()
        } else {
            SplitTunnelPrefs.getDirectDomains(context)
        }
        Log.i(
            TAG,
            "buildProcessedXrayConfig: split_tunnel mode=$splitMode apps=${splitPackages.size} direct_domains=${splitDirectDomains.size}",
        )
        val trimmed = config.trim()
        val isXrayNativeFormat = trimmed.startsWith("{") &&
            trimmed.contains("\"protocol\"") &&
            trimmed.contains("\"vnext\"")
        val base = if (isXrayNativeFormat) {
            Log.i(TAG, "buildProcessedXrayConfig: нативный формат XRay")
            trimmed
        } else {
            Log.i(TAG, "buildProcessedXrayConfig: преобразование в нативный формат XRay")
            val parsedConfig = XrayConfigParser.parseConfig(config)
            if (!XrayConfigParser.validateConfig(parsedConfig)) {
                throw IllegalStateException("Невалидная конфигурация XRay")
            }
            parsedConfig.toXrayNativeJsonConfig()
        }
        val dnsMode = VpnRoutingPrefs.getDnsMode(context)
        return XrayRoutingHelper.applyFullVpnRouting(
            base,
            SplitTunnelPrefs.getDirectDomains(context),
            dnsMode,
        )
    }

    /** Повторная подача routing JSON в libXray без kill TUN (смена DNS policy / split domains). */
    private fun applyRoutingHotSwapInternal() {
        val raw = lastConfig
        if (raw.isNullOrBlank()) {
            Log.w(TAG, "applyRoutingHotSwapInternal: lastConfig пуст")
            return
        }
        val w = xrayNativeWrapper ?: run {
            Log.w(TAG, "applyRoutingHotSwapInternal: wrapper null")
            return
        }
        val ctx = appContext ?: return
        try {
            val processed = buildProcessedXrayConfig(ctx, raw, resetBreaker = false)
            val ok = w.tryApplyHotRoutingConfig(processed)
            Log.i(TAG, "applyRoutingHotSwapInternal: ok=$ok len=${processed.length}")
        } catch (e: Exception) {
            Log.e(TAG, "applyRoutingHotSwapInternal: ${e.message}", e)
        }
    }

    /**
     * Обрабатывает пакеты XRay протокола через нативный libXray
     * 
     * Использует нативный XRay-core (libXray) для обработки VPN трафика.
     * Полностью перешли на нативные протоколы, sing-box удален.
     */
    private fun processXrayPackets(config: String) {
        Log.i(TAG, "processXrayPackets: ========== ЗАПУСК VPN ЧЕРЕЗ НАТИВНЫЙ XRAY (ВЕРСИЯ: $CODE_VERSION) ==========")
        Log.i(TAG, "[DIAG] processXrayPackets вызван, t=0ms")
        Log.i(TAG, "processXrayPackets: Запуск VPN через нативный XRay (libXray)")

        try {
            Log.i(TAG, "processXrayPackets: Парсинг конфигурации (длина: ${config.length})")
            Log.i(TAG, "processXrayPackets: Превью конфигурации: ${VpnLogRedaction.previewRedacted(config, 200)}")
            
            // Получаем контекст
            val context = appContext
            if (context == null) {
                Log.e(TAG, "processXrayPackets: Контекст недоступен!")
                isRunning = false
                return
            }
            
            val dnsMode = VpnRoutingPrefs.getDnsMode(context)
            val xrayConfig = buildProcessedXrayConfig(context, config, resetBreaker = true)
            val effectiveOutbounds = XrayRoutingHelper.describeEffectiveOutbounds(xrayConfig)
            lastEffectiveOutbounds = effectiveOutbounds
            Log.i(
                TAG,
                "[XRAY_EFFECTIVE_OUTBOUNDS] session=${lastConnectionSessionId ?: "null"} outbounds=$effectiveOutbounds",
            )
            VpnNativeStateEmitter.emitRuntimeDiag(
                "effective_outbounds",
                mapOf(
                    "effective_outbounds" to effectiveOutbounds,
                    "connection_session_id" to (lastConnectionSessionId ?: ""),
                ),
            )
            Log.d(
                TAG,
                "processXrayPackets: full routing dnsMode=$dnsMode " +
                    "(controlPlane=${XrayRoutingHelper.CONTROL_PLANE_API_DOMAINS.size}+user, " +
                    "ips=${XrayRoutingHelper.CONTROL_PLANE_API_IPS.size})",
            )
            Log.d(TAG, "processXrayPackets: Передаем JSON в libXray (длина: ${xrayConfig.length})")

            processXrayPacketsInProcess(context, xrayConfig)
            Log.i(TAG, "processXrayPackets: VPN остановлен")
            
        } catch (e: Exception) {
            Log.e(TAG, "processXrayPackets: Ошибка: ${e.message}", e)
            isRunning = false
        } finally {
            // stopXray() уже вызван из adapter.stop() — полный tear down выполнен
        }
    }

    /** Имя сессии Android VPN (видно в настройках) + хвост connection_session_id для корреляции с Flutter/logcat. */
    private fun formatSessionName(protocolHint: String?): String {
        val proto = when (protocolHint?.trim()?.lowercase()) {
            "xray_vless" -> "Xray VLESS"
            "xray_vmess" -> "Xray VMESS"
            "xray_reality" -> "Xray Reality"
            "vless_ws" -> "VLESS WS"
            "hysteria2", "hy2" -> "Hysteria 2"
            else -> null
        }
        val base = if (proto != null) "GRANI · $proto" else "GRANI"
        val sid = lastConnectionSessionId?.trim()?.takeIf { it.isNotEmpty() }
        val suffix = if (sid == null) "" else " · ${sid.takeLast(minOf(16, sid.length))}"
        return (base + suffix).take(128)
    }

    private fun refreshQuickTile() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                QuickTileService.notifyVpnStateChanged(applicationContext)
            } catch (e: Exception) {
                Log.w(TAG, "quick tile stagger refresh failed: ${e.message}")
            }
        }
    }

    private fun processXrayPacketsInProcess(context: Context, xrayConfig: String) {
        val inProcessStartTs = System.currentTimeMillis()
        Log.i(TAG, "[DIAG] processXrayPacketsInProcess: начало (всегда полный start, без attachTun)")
        // Задержка перед establish() при быстром переподключении (как v2rayNG/Amnezia)
        val lastStopTs = getLastVpnStopTimestamp()
        val reconnectDelayMs = getReconnectDelayMs()
        if (lastStopTs > 0 && (System.currentTimeMillis() - lastStopTs) < RECONNECT_WINDOW_MS) {
            Log.i(TAG, "[DIAG] переподключение: задержка ${reconnectDelayMs}ms перед establish() (device=${Build.MANUFACTURER})")
            Thread.sleep(reconnectDelayMs)
        }
        val tunLabel = formatSessionName(lastProtocol)
        Log.i(
            TAG,
            "[CORRELATION] xray_tun_session=$tunLabel full_connection_session_id=${lastConnectionSessionId ?: "null"}",
        )
        xrayNativeWrapper = XrayNativeWrapperTun2Socks(context)
        xrayNativeWrapper?.startVpn(
            this,
            xrayConfig,
            requestedMtu,
            tunLabel,
            onTun2SocksFailure = { reason ->
                handleRuntimeFailure(reason, source = "tun2socks")
            },
        )
        if (!waitForNativeXrayRunning(timeoutMs = 10_000L)) {
            throw IllegalStateException("Нативный XRay не запустился")
        }
        isRunning = true
        NativeVpnRuntimeState.markNativeVpnExpectedUp(
            applicationContext,
            true,
            expectedNativeProtocolLabel(),
        )
        setServiceState(ServiceState.LOCAL_UP)
        lastUnderlyingNetworkType = detectUnderlyingNetworkType()
        refreshQuickTile()
        Log.i(TAG, "[DIAG] processXrayPacketsInProcess: VPN запущен, handshake_ms=${System.currentTimeMillis() - vpnStartTs}ms, total_process_ms=${System.currentTimeMillis() - inProcessStartTs}ms")
        if (DIAG_APP_CONFLICT_A_DISABLE_POST_CONNECT_PROBES) {
            Log.i(TAG, "[APP_CONFLICT_A] post-connect connectivity probes disabled")
        } else Thread({
            try {
                Thread.sleep(PROBE_START_DELAY_MS)
                var retry = 0
                while (isRunning &&
                    (serviceState == ServiceState.LOCAL_UP ||
                        serviceState == ServiceState.DATAPLANE_VERIFIED ||
                        serviceState == ServiceState.COMMITTED)
                ) {
                    val status = runPostConnectConnectivityProbes()
                    if (status != "degraded" || retry >= PROBE_DEGRADED_MAX_RETRIES) break
                    retry += 1
                    Log.i(TAG, "$CONNECTIVITY_PROBE_LOG degraded retry scheduled attempt=$retry gap_ms=$PROBE_DEGRADED_RETRY_GAP_MS")
                    Thread.sleep(PROBE_DEGRADED_RETRY_GAP_MS)
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }, "grani-connectivity-probe").start()
        while (isRunning && xrayNativeWrapper?.isRunning() == true) {
            Thread.sleep(1000)
        }
        // If native core stopped unexpectedly, force state/notification/tile reconciliation
        // to avoid stale "connected" UI when Android VPN icon is already gone. Ordered user/app
        // shutdown is not a runtime failure: wrapper.stopVpn() intentionally stops libXray first,
        // so the monitor thread can observe native=false before GraniVpnService reaches IDLE.
        if (isRunning && xrayNativeWrapper?.isRunning() != true) {
            val sid = lastConnectionSessionId ?: loadPersistedSessionId()
            val tunState = xrayNativeWrapper?.getLastTunState() ?: "unknown"
            if (orderedStopInProgress.get() || serviceState == ServiceState.DISCONNECTING || wasIntentionallyStopped()) {
                Log.i(
                    TAG,
                    "[RUNTIME_STOP_ORDERED] source=xray_core reason=native_core_stopped_after_confirmed_stop " +
                        "connection_session_id=${sid ?: "null"} state=$serviceState isRunning=$isRunning " +
                        "last_tun_state=$tunState ordered_stop=${orderedStopInProgress.get()}",
                )
                isRunning = false
                if (serviceState != ServiceState.IDLE) {
                    setServiceState(ServiceState.IDLE)
                }
                refreshQuickTile()
            } else {
                Log.w(TAG, "processXrayPacketsInProcess: нативный XRay остановился нештатно, выполняем принудительную синхронизацию состояния")
                handleRuntimeFailure("Нативный XRay остановился", source = "xray_core")
            }
        }
    }

    fun isVpnRunning(): Boolean {
        val nativeRunning = xrayNativeWrapper?.isRunning() == true
        val hy2Running = hysteria2Runtime?.isRunning() == true
        if (isRunning && !nativeRunning && !hy2Running) {
            Log.w(TAG, "isVpnRunning: найден stale-state (isRunning=true, native=false), корректируем")
            isRunning = false
            setServiceState(ServiceState.IDLE)
            refreshQuickTile()
        }
        return isRunning && (nativeRunning || hy2Running)
    }

    fun isVpnCommitted(): Boolean {
        val nativeRunning = xrayNativeWrapper?.isRunning() == true
        val hy2Running = hysteria2Runtime?.isRunning() == true
        return isRunning && (nativeRunning || hy2Running) && serviceState == ServiceState.COMMITTED
    }
    
    /**
     * Получает статистику трафика
     * @return Map с ключами "rx_bytes" (входящий) и "tx_bytes" (исходящий)
     */
    fun getTrafficStats(): Map<String, Long> {
        val (rx, tx) = trafficStatsTracker.snapshot()
        totalBytesRead = rx
        totalBytesWritten = tx
        if (!trafficFirstLogged && (rx > 0L || tx > 0L)) {
            trafficFirstLogged = true
            Log.i(TAG, "[VPN_TRAFFIC] Трафик через туннель зафиксирован: rx=$rx, tx=$tx")
        }
        return mapOf(
            "rx_bytes" to totalBytesRead,
            "tx_bytes" to totalBytesWritten
        )
    }
    
    /**
     * Сбрасывает статистику трафика
     */
    fun resetTrafficStats() {
        totalBytesRead = 0L
        totalBytesWritten = 0L
        trafficFirstLogged = false
        trafficStatsTracker.reset()
        Log.d(TAG, "Статистика трафика сброшена")
    }

    private fun waitForTunReady(timeoutMs: Long): Boolean {
        val start = System.currentTimeMillis()
        while (System.currentTimeMillis() - start < timeoutMs) {
            if (vpnInterface != null) {
                return true
            }
            Thread.sleep(50)
        }
        return false
    }

    /** Ожидание готовности стека libXray+tun2socks вместо фиксированного sleep. */
    private fun waitForNativeXrayRunning(timeoutMs: Long): Boolean {
        val start = System.currentTimeMillis()
        while (System.currentTimeMillis() - start < timeoutMs) {
            if (xrayNativeWrapper?.isRunning() == true) {
                return true
            }
            Thread.sleep(50)
        }
        return xrayNativeWrapper?.isRunning() == true
    }

    private interface VpnAdapter {
        fun start(config: String): Boolean
        fun stop()
    }

    private inner class XrayAdapter : VpnAdapter {
        override fun start(config: String): Boolean {
            Log.d(TAG, "XrayAdapter: Запуск через нативный libXray")
            isRunning = false
            Thread {
                processXrayPackets(config)
            }.start()
            return true
        }

        override fun stop() {
            stopXray()
        }
    }

    private inner class Hysteria2Adapter : VpnAdapter {
        override fun start(config: String): Boolean {
            Log.d(TAG, "Hysteria2Adapter: Запуск через отдельный hysteria native process")
            isRunning = false
            val runtime = Hysteria2ProcessWrapper(applicationContext)
            hysteria2Runtime = runtime
            Thread {
                try {
                    runtime.start(
                        vpnService = this@GraniVpnService,
                        rawConfig = config,
                        mtu = requestedMtu,
                        session = formatSessionName("hysteria2"),
                        onFailure = { reason ->
                            handleRuntimeFailure(reason, source = "hysteria2")
                        },
                    )
                    isRunning = true
                    NativeVpnRuntimeState.markNativeVpnExpectedUp(
                        applicationContext,
                        true,
                        expectedNativeProtocolLabel(),
                    )
                    setServiceState(ServiceState.LOCAL_UP)
                    lastUnderlyingNetworkType = detectUnderlyingNetworkType()
                    refreshQuickTile()
                    if (DIAG_APP_CONFLICT_A_DISABLE_POST_CONNECT_PROBES) {
                        Log.i(TAG, "[APP_CONFLICT_A] HY2 post-connect connectivity probes disabled")
                    } else {
                        Thread({
                            try {
                                Thread.sleep(PROBE_START_DELAY_MS)
                                var retry = 0
                                while (isRunning &&
                                    (serviceState == ServiceState.LOCAL_UP ||
                                        serviceState == ServiceState.DATAPLANE_VERIFIED ||
                                        serviceState == ServiceState.COMMITTED)
                                ) {
                                    val status = runPostConnectConnectivityProbes()
                                    if (status != "degraded" || retry >= PROBE_DEGRADED_MAX_RETRIES) break
                                    retry += 1
                                    Thread.sleep(PROBE_DEGRADED_RETRY_GAP_MS)
                                }
                            } catch (_: InterruptedException) {
                                Thread.currentThread().interrupt()
                            }
                        }, "grani-hy2-connectivity-probe").start()
                    }
                    while (isRunning && runtime.isRunning()) {
                        Thread.sleep(1000)
                    }
                    if (isRunning && !orderedStopInProgress.get() && !wasIntentionallyStopped()) {
                        handleRuntimeFailure("Hysteria2 process stopped", source = "hysteria2")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Hysteria2Adapter: ошибка запуска: ${e.message}", e)
                    handleRuntimeFailure(e.message ?: "Hysteria2 start failed", source = "hysteria2")
                }
            }.start()
            return true
        }

        override fun stop() {
            stopHysteria2()
        }
    }

    private fun registerUnderlyingNetworkCallback() {
        if (DIAG_APP_CONFLICT_A_DISABLE_NETWORK_CALLBACK) {
            Log.i(TAG, "[APP_CONFLICT_A] registerUnderlyingNetworkCallback skipped")
            return
        }
        if (networkCallback != null) return
        val cm = connectivityManager ?: return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                scheduleUnderlyingNetworkEvaluation("onAvailable")
            }

            override fun onLost(network: Network) {
                scheduleUnderlyingNetworkEvaluation("onLost")
            }

            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                scheduleUnderlyingNetworkEvaluation("onCapabilitiesChanged")
            }
        }
        try {
            cm.registerNetworkCallback(request, networkCallback!!)
            scheduleUnderlyingNetworkEvaluation("register")
            Log.i(TAG, "registerUnderlyingNetworkCallback: registered")
        } catch (e: Exception) {
            Log.w(TAG, "registerUnderlyingNetworkCallback: ${e.message}")
            networkCallback = null
        }
    }

    private fun unregisterUnderlyingNetworkCallback() {
        val cb = networkCallback ?: return
        try {
            connectivityManager?.unregisterNetworkCallback(cb)
        } catch (_: Exception) {
        } finally {
            networkCallback = null
        }
    }

    private fun scheduleUnderlyingNetworkEvaluation(reason: String) {
        if (DIAG_APP_CONFLICT_A_DISABLE_NETWORK_CALLBACK) {
            Log.i(TAG, "[APP_CONFLICT_A] network evaluation skipped reason=$reason")
            return
        }
        networkEvalRunnable?.let { mainHandler.removeCallbacks(it) }
        networkEvalRunnable = Runnable {
            val current = detectUnderlyingNetworkType()
            val previous = lastUnderlyingNetworkType
            if (previous == null) {
                lastUnderlyingNetworkType = current
                Log.d(TAG, "[NET_MONITOR] initialized type=$current reason=$reason")
                return@Runnable
            }
            if (current == previous) return@Runnable
            val meaningful = setOf("wifi", "mobile", "ethernet")
            if (!meaningful.contains(previous) || !meaningful.contains(current)) {
                lastUnderlyingNetworkType = current
                Log.d(TAG, "[NET_MONITOR] ignored transition $previous->$current reason=$reason")
                return@Runnable
            }
            lastUnderlyingNetworkType = current
            handleUnderlyingNetworkChanged(previous, current)
        }
        mainHandler.postDelayed(networkEvalRunnable!!, NETWORK_CHANGE_DEBOUNCE_MS)
    }

    private fun loadPersistedSessionId(): String? {
        return try {
            applicationContext.getSharedPreferences(PREFS_RECONNECT, Context.MODE_PRIVATE)
                .getString(KEY_LAST_CONNECTION_SESSION_ID, null)?.trim()?.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }

    private fun persistConnectionSessionId(id: String?) {
        lastConnectionSessionId = id?.trim()?.takeIf { it.isNotEmpty() }
        try {
            val prefs = applicationContext.getSharedPreferences(PREFS_RECONNECT, Context.MODE_PRIVATE)
            if (lastConnectionSessionId.isNullOrBlank()) {
                prefs.edit().remove(KEY_LAST_CONNECTION_SESSION_ID).apply()
            } else {
                prefs.edit().putString(KEY_LAST_CONNECTION_SESSION_ID, lastConnectionSessionId).apply()
            }
        } catch (_: Exception) {
        }
    }

    private fun handleUnderlyingNetworkChanged(from: String, to: String) {
        if (!isRunning || serviceState != ServiceState.COMMITTED) {
            Log.d(TAG, "[NET_MONITOR] skip $from->$to: vpn not connected")
            return
        }
        if (networkReconnectInProgress) {
            Log.d(TAG, "[NET_MONITOR] skip $from->$to: reconnect already in progress")
            return
        }
        val now = System.currentTimeMillis()
        val sinceLast = now - lastNetworkReconnectAtMs
        if (sinceLast < NETWORK_RECONNECT_MIN_INTERVAL_MS) {
            Log.d(
                TAG,
                "[NET_MONITOR] skip $from->$to: reconnect cooldown (${sinceLast}ms < ${NETWORK_RECONNECT_MIN_INTERVAL_MS}ms min interval)",
            )
            return
        }
        if (wasIntentionallyStopped()) {
            Log.d(TAG, "[NET_MONITOR] skip $from->$to: intentionally stopped")
            return
        }
        val config = lastConfig
        if (config.isNullOrBlank()) {
            Log.w(TAG, "[NET_MONITOR] skip $from->$to: no config for reconnect")
            return
        }
        val nextMtu = selectMtuForNetworkType(to)
        val protocol = lastProtocol
        networkReconnectInProgress = true
        lastNetworkReconnectAtMs = now
        Log.i(TAG, "[NET_MONITOR] network_change $from->$to, restart vpn with mtu=$nextMtu")
        // Анти-дребезг: scheduleUnderlyingNetworkEvaluation postDelayed(NETWORK_CHANGE_DEBOUNCE_MS);
        // плюс cooldown выше; плюс networkReconnectInProgress на время stop+start в этом потоке.
        Log.i(
            TAG,
            "[NET_MONITOR] HARD_RECONNECT stack: XrayAdapter.stop → stopXrayFull → " +
                "XrayNativeWrapperTun2Socks.stopVpn (unbind :tun2socks process, libXray stop+join, TUN close) → " +
                "new startVpn/new adapter/new TUN/new tun2socks bind. " +
                "TCP приложений идут через новый fd; медленный старт на LTE может быть TCP slow-start/радио, не «старый libXray». " +
                "session=${lastConnectionSessionId ?: loadPersistedSessionId() ?: "none"}",
        )
        Thread {
            try {
                updateNotificationContent(getString(R.string.vpn_notification_reconnecting))
                stopVpn()
                Thread.sleep(250L)
                val sessionForHandover = lastConnectionSessionId ?: loadPersistedSessionId()
                val startIntent = Intent(applicationContext, GraniVpnService::class.java).apply {
                    action = ACTION_START
                    putExtra(EXTRA_CONFIG, config)
                    if (!protocol.isNullOrBlank()) putExtra(EXTRA_PROTOCOL, protocol)
                    putExtra(EXTRA_MTU, nextMtu)
                    putExtra(EXTRA_SOURCE, "network_handover_native")
                    if (!sessionForHandover.isNullOrBlank()) {
                        putExtra(EXTRA_CONNECTION_SESSION_ID, sessionForHandover)
                    }
                }
                startService(startIntent)
            } catch (e: Exception) {
                Log.e(TAG, "[NET_MONITOR] reconnect failed: ${e.message}", e)
            } finally {
                networkReconnectInProgress = false
            }
        }.start()
    }

    /**
     * After TUN is up: measure RTT over the system VPN [Network] (if present) vs our API health URL.
     * Logs are English-only ([CONNECTIVITY_PROBE]) for a single language in exported diagnostics.
     */
    private fun findVpnTransportNetwork(): Network? {
        val cm = connectivityManager ?: return null
        return try {
            cm.allNetworks.firstOrNull { n ->
                val caps = cm.getNetworkCapabilities(n) ?: return@firstOrNull false
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            }
        } catch (_: Exception) {
            null
        }
    }

    private data class HttpProbeResult(
        val success: Boolean,
        val rttMs: Long,
        val httpStatus: Int,
        val error: String?,
        val fallbackUnbound: Boolean = false,
    )

    private fun isNetworkBindPermissionError(message: String): Boolean {
        val msg = message.lowercase(Locale.US)
        return msg.contains("binding socket to network") &&
            (msg.contains("eperm") || msg.contains("operation not permitted"))
    }

    private fun executeHttpProbe(urlString: String, network: Network?): HttpProbeResult {
        var conn: HttpURLConnection? = null
        val t0 = SystemClock.elapsedRealtime()
        return try {
            val url = URL(urlString)
            conn = if (network != null) {
                network.openConnection(url) as HttpURLConnection
            } else {
                url.openConnection() as HttpURLConnection
            }
            conn.instanceFollowRedirects = true
            conn.connectTimeout = PROBE_CONNECT_TIMEOUT_MS
            conn.readTimeout = PROBE_READ_TIMEOUT_MS
            conn.requestMethod = "GET"
            conn.setRequestProperty("Connection", "close")
            conn.connect()
            val code = conn.responseCode
            val ok = code in 200..399
            try {
                conn.errorStream?.use { es -> es.readBytes() }
            } catch (_: Exception) {
            }
            try {
                conn.inputStream.use { it.readBytes() }
            } catch (_: Exception) {
            }
            val elapsed = SystemClock.elapsedRealtime() - t0
            HttpProbeResult(ok, elapsed, code, null, fallbackUnbound = network == null)
        } catch (e: Exception) {
            val elapsed = SystemClock.elapsedRealtime() - t0
            HttpProbeResult(false, elapsed, -1, e.javaClass.simpleName + ":" + (e.message?.take(120) ?: ""), fallbackUnbound = network == null)
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Exception) {
            }
        }
    }

    private fun httpGetProbe(network: Network?, urlString: String): HttpProbeResult {
        val boundAttempt = executeHttpProbe(urlString, network)
        if (network != null && !boundAttempt.success) {
            val err = boundAttempt.error ?: ""
            if (isNetworkBindPermissionError(err)) {
                val fallback = executeHttpProbe(urlString, null)
                if (fallback.success) {
                    Log.w(
                        TAG,
                        "$CONNECTIVITY_PROBE_LOG fallback_unbound=1 reason=bind_eprem url=$urlString bound_err=$err",
                    )
                    return fallback.copy(fallbackUnbound = true)
                }
                return fallback.copy(
                    error = (fallback.error ?: "fallback_unbound_after_bind_eprem") + ";bind_err=${err.take(100)}",
                    fallbackUnbound = true,
                )
            }
        }
        return boundAttempt
    }

    private data class PublicInternetProbeAggregate(
        val success: Boolean,
        val rttMs: Long,
        val httpStatus: Int,
        val error: String?,
        val urlUsed: String,
        val labelUsed: String,
        val attempts: Int,
        val details: List<Map<String, Any>>,
    )

    /** Try several URLs so one slow/blocked host (e.g. gstatic HTTPS) does not look like «no internet». */
    private fun runPublicInternetProbes(vpnNet: Network?): PublicInternetProbeAggregate {
        var attempts = 0
        var last = HttpProbeResult(false, 0L, -1, "no_attempt")
        var lastUrl: String? = null
        var lastLabel: String? = null
        val details = mutableListOf<Map<String, Any>>()
        for ((url, label) in PROBE_PUBLIC_CANDIDATES) {
            attempts++
            last = httpGetProbe(vpnNet, url)
            lastUrl = url
            lastLabel = label
            details.add(
                mapOf(
                    "label" to label,
                    "url" to url,
                    "ok" to last.success,
                    "rtt_ms" to last.rttMs,
                    "http_status" to last.httpStatus,
                    "error" to (last.error ?: ""),
                    "fallback_unbound" to if (last.fallbackUnbound) 1 else 0,
                ),
            )
            if (last.success) {
                return PublicInternetProbeAggregate(
                    success = true,
                    rttMs = last.rttMs,
                    httpStatus = last.httpStatus,
                    error = null,
                    urlUsed = url,
                    labelUsed = label,
                    attempts = attempts,
                    details = details,
                )
            }
            try {
                Thread.sleep(PROBE_RETRY_GAP_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
        }
        return PublicInternetProbeAggregate(
            success = false,
            rttMs = last.rttMs,
            httpStatus = last.httpStatus,
            error = last.error,
            urlUsed = lastUrl ?: "",
            labelUsed = lastLabel ?: "",
            attempts = attempts,
            details = details,
        )
    }

    private fun runPostConnectConnectivityProbes(): String {
        val sid = lastConnectionSessionId ?: loadPersistedSessionId()
        val vpnNet = findVpnTransportNetwork()
        val bound = vpnNet != null
        val publicAgg = runPublicInternetProbes(vpnNet)
        val api = httpGetProbe(vpnNet, PROBE_API_HEALTH_URL)
        // Treat dataplane validation as primary commit gate:
        // if public internet is reachable, we keep the tunnel committed even when
        // control-plane API probe is temporarily degraded (e.g., DNS transient).
        val controlPlaneDegraded = publicAgg.success && !api.success
        val status = when {
            publicAgg.success && api.success -> "ok"
            controlPlaneDegraded -> "ok_dataplane_control_plane_degraded"
            !publicAgg.success && api.success -> "degraded"
            else -> "failed"
        }
        if (publicAgg.success && serviceState == ServiceState.LOCAL_UP) {
            setServiceState(ServiceState.DATAPLANE_VERIFIED)
        }
        if (publicAgg.success && serviceState != ServiceState.COMMITTED) {
            setServiceState(ServiceState.COMMITTED)
        }
        val publicDetails = if (publicAgg.details.isNotEmpty()) {
            publicAgg.details.joinToString(separator = ";") { detail ->
                "label=${detail["label"]},ok=${detail["ok"]},rtt_ms=${detail["rtt_ms"]},status=${detail["http_status"]},err=${detail["error"]}"
            }
        } else {
            "none"
        }
        Log.i(
            TAG,
            "$CONNECTIVITY_PROBE_LOG " +
                "correlation_session=${sid ?: "none"} " +
                "vpn_transport_bound=${if (bound) 1 else 0} " +
                "status=$status " +
                "public_internet ok=${publicAgg.success} rtt_ms=${publicAgg.rttMs} http_status=${publicAgg.httpStatus} " +
                "url=${publicAgg.urlUsed} label=${publicAgg.labelUsed} attempts=${publicAgg.attempts}" +
                (publicAgg.error?.let { " err=$it" } ?: "") +
                " control_plane_degraded=${if (controlPlaneDegraded) 1 else 0}" +
                " public_details=[$publicDetails]" +
                " api_health ok=${api.success} rtt_ms=${api.rttMs} http_status=${api.httpStatus}" +
                (api.error?.let { " err=$it" } ?: ""),
        )
        val probePayload = mutableMapOf<String, Any>(
            "correlation_session" to (sid ?: ""),
            "vpn_transport_bound" to if (bound) 1 else 0,
            "status" to status,
            "public_ok" to publicAgg.success,
            "public_rtt_ms" to publicAgg.rttMs,
            "public_http_status" to publicAgg.httpStatus,
            "public_url" to publicAgg.urlUsed,
            "public_label" to publicAgg.labelUsed,
            "public_probe_attempts" to publicAgg.attempts,
            "public_probe_details" to publicAgg.details,
            "public_fallback_unbound" to publicAgg.details.any { (it["fallback_unbound"] as? Int ?: 0) == 1 },
            "control_plane_degraded" to if (controlPlaneDegraded) 1 else 0,
            "api_ok" to api.success,
            "api_rtt_ms" to api.rttMs,
            "api_http_status" to api.httpStatus,
            "api_fallback_unbound" to if (api.fallbackUnbound) 1 else 0,
        )
        if (publicAgg.error != null) probePayload["public_err"] = publicAgg.error!!
        if (api.error != null) probePayload["api_err"] = api.error!!
        VpnNativeStateEmitter.emitConnectivityProbe(probePayload)
        return status
    }

    private fun detectUnderlyingNetworkType(): String {
        val cm = connectivityManager ?: return "unknown"
        return try {
            var hasWifi = false
            var hasMobile = false
            var hasEthernet = false
            cm.allNetworks.forEach { network ->
                val caps = cm.getNetworkCapabilities(network) ?: return@forEach
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@forEach
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) hasWifi = true
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) hasMobile = true
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) hasEthernet = true
            }
            when {
                hasWifi -> "wifi"
                hasMobile -> "mobile"
                hasEthernet -> "ethernet"
                else -> "unknown"
            }
        } catch (_: Exception) {
            "unknown"
        }
    }

    private fun selectMtuForNetworkType(networkType: String): Int {
        return when (networkType) {
            "wifi", "ethernet" -> MTU_WIFI
            "mobile" -> MTU_MOBILE
            else -> MTU_DEFAULT
        }
    }
}
