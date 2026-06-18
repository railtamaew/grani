package com.granivpn.mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private var vpnStateEventChannel: EventChannel? = null
    private var activity: Activity? = null
    private var appContext: Context? = null
    private var pendingVpnConfig: String? = null
    private var pendingProtocol: String? = null
    private var pendingMtu: Int = 0
    private var pendingConnectionSessionId: String? = null
    private var pendingSource: String? = null
    private var pendingVpnBackend: String? = null
    private var pendingResult: MethodChannel.Result? = null
    private var vpnPermissionLauncher: ActivityResultLauncher<Intent>? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private data class RuntimeContractCheck(
        val hasMismatch: Boolean,
        val mismatchFields: List<String>,
        val protocol: String?,
        val correlationId: String?,
    )

    companion object {
        private const val CHANNEL_NAME = "com.granivpn.mobile/vpn"
        private const val VPN_STATE_EVENT_CHANNEL = "com.granivpn.mobile/vpn_state"
        private const val TAG = "VpnPlugin"
        private const val VPN_REQUEST_CODE = 100
        private const val PREFS_NAME = "grani_vpn_prefs"
        private const val KEY_LAST_CONFIG = "last_vpn_config"
        private const val KEY_LAST_PROTOCOL = "last_vpn_protocol"
        private const val KEY_LAST_MTU = "last_vpn_mtu"
        private const val KEY_LAST_CONFIG_TIME = "last_vpn_config_time"
        private const val KEY_ALLOW_TILE_CONNECT = "allow_tile_connect"
        private const val CONFIG_TTL_MS = 24L * 60 * 60 * 1000 // 24 hours

        /** [mtu] как при последнем успешном connect из приложения; 0 = не задан (как раньше). */
        data class LastVpnConfig(val config: String, val protocol: String?, val mtu: Int = 0)

        fun saveLastConfig(context: Context, config: String, protocol: String?, mtu: Int = 0) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_LAST_CONFIG, config)
                .putString(KEY_LAST_PROTOCOL, protocol)
                .putInt(KEY_LAST_MTU, mtu.coerceAtLeast(0))
                .putLong(KEY_LAST_CONFIG_TIME, System.currentTimeMillis())
                .apply()
        }

        fun clearLastConfig(context: Context) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .remove(KEY_LAST_CONFIG)
                .remove(KEY_LAST_PROTOCOL)
                .remove(KEY_LAST_MTU)
                .remove(KEY_LAST_CONFIG_TIME)
                .apply()
        }

        fun loadLastConfig(context: Context): LastVpnConfig? {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val config = prefs.getString(KEY_LAST_CONFIG, null) ?: return null
            val savedAt = prefs.getLong(KEY_LAST_CONFIG_TIME, 0L)
            if (savedAt > 0 && System.currentTimeMillis() - savedAt > CONFIG_TTL_MS) {
                Log.w(TAG, "loadLastConfig: config expired (age=${(System.currentTimeMillis() - savedAt) / 1000}s)")
                clearLastConfig(context)
                return null
            }
            val protocol = prefs.getString(KEY_LAST_PROTOCOL, null)
            val mtu = prefs.getInt(KEY_LAST_MTU, 0)
            return LastVpnConfig(config, protocol, mtu)
        }

        fun setAllowTileConnect(context: Context, allow: Boolean) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_ALLOW_TILE_CONNECT, allow)
                .apply()
        }

        fun isAllowTileConnect(context: Context): Boolean {
            return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_ALLOW_TILE_CONNECT, false)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        appContext = binding.applicationContext
        setupVpnStateEventChannel(binding.binaryMessenger)
        VpnCircuitBreaker.clearLegacyDiskStateIfAny(binding.applicationContext)
        Log.d(TAG, "VpnPlugin attached to engine")
    }
    
    // Альтернативный метод инициализации без FlutterPluginBinding
    // Используется для ручной регистрации в MainActivity
    fun attachToEngine(binaryMessenger: BinaryMessenger) {
        channel = MethodChannel(binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        setupVpnStateEventChannel(binaryMessenger)
        Log.d(TAG, "VpnPlugin attached to engine (direct)")
    }

    private fun setupVpnStateEventChannel(messenger: BinaryMessenger) {
        vpnStateEventChannel?.setStreamHandler(null)
        vpnStateEventChannel = EventChannel(messenger, VPN_STATE_EVENT_CHANNEL)
        vpnStateEventChannel?.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    if (events != null) {
                        VpnNativeStateEmitter.attach(events)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    VpnNativeStateEmitter.detach()
                }
            },
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        vpnStateEventChannel?.setStreamHandler(null)
        vpnStateEventChannel = null
        VpnNativeStateEmitter.detach()
        Log.d(TAG, "VpnPlugin detached from engine")
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        appContext = binding.activity.applicationContext
        
        // Регистрируем ActivityResultLauncher для VPN разрешения
        if (activity is androidx.activity.ComponentActivity) {
            val componentActivity = activity as androidx.activity.ComponentActivity
            vpnPermissionLauncher = componentActivity.registerForActivityResult(
                ActivityResultContracts.StartActivityForResult()
            ) { result ->
                handleVpnPermissionResult(result.resultCode)
            }
            Log.d(TAG, "ActivityResultLauncher зарегистрирован для VPN разрешения")
        } else {
            // Fallback на старый API для обратной совместимости
            Log.w(TAG, "Activity не является ComponentActivity, используем старый API")
            binding.addActivityResultListener { requestCode, resultCode, data ->
                if (requestCode == VPN_REQUEST_CODE) {
                    handleVpnPermissionResult(resultCode)
                    true
                } else {
                    false
                }
            }
        }
    }
    

    private fun clearPendingVpnStart() {
        pendingResult = null
        pendingVpnConfig = null
        pendingProtocol = null
        pendingMtu = 0
        pendingConnectionSessionId = null
        pendingSource = null
        pendingVpnBackend = null
    }

    private fun completePendingVpnStart() {
        val config = pendingVpnConfig
        val result = pendingResult
        val backend = pendingVpnBackend ?: "xray"
        val protocol = pendingProtocol
        val mtu = pendingMtu
        val sessionId = pendingConnectionSessionId
        val source = pendingSource ?: "ui_tap"
        clearPendingVpnStart()
        if (config == null) {
            result?.success(true)
            return
        }
        if (backend == "amneziawg") {
            startAmneziaWgConnection(config, sessionId, source, result)
        } else {
            startVpnConnection(config, protocol, mtu, sessionId, source, result)
        }
    }

    private fun handleVpnPermissionResult(resultCode: Int) {
        if (resultCode == Activity.RESULT_OK) {
            // Пользователь разрешил VPN
            Log.d(TAG, "Пользователь разрешил VPN подключение")
            completePendingVpnStart()
        } else {
            // Пользователь отклонил разрешение
            Log.w(TAG, "Пользователь отклонил VPN разрешение")
            pendingResult?.error(
                "PERMISSION_DENIED", 
                "VPN разрешение отклонено. Для работы VPN необходимо предоставить разрешение.", 
                mapOf("userMessage" to "Для подключения к VPN необходимо предоставить разрешение в настройках системы.")
            )
            pendingResult = null
            pendingVpnConfig = null
            pendingProtocol = null
            pendingMtu = 0
            pendingConnectionSessionId = null
            pendingSource = null
            pendingVpnBackend = null
        }
    }
    
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                Log.d(TAG, "Пользователь разрешил VPN подключение (через handleActivityResult)")
                completePendingVpnStart()
            } else {
                Log.w(TAG, "Пользователь отклонил VPN разрешение (через handleActivityResult)")
                pendingResult?.error(
                    "PERMISSION_DENIED", 
                    "VPN разрешение отклонено. Для работы VPN необходимо предоставить разрешение.", 
                    mapOf("userMessage" to "Для подключения к VPN необходимо предоставить разрешение в настройках системы.")
                )
                pendingResult = null
                pendingVpnConfig = null
                pendingProtocol = null
                pendingMtu = 0
                pendingConnectionSessionId = null
                pendingSource = null
            }
            return true
        }
        return false
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
        vpnPermissionLauncher = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "onMethodCall: ${VpnLogRedaction.describeMethodCall(call.method, call.arguments)}")
        when (call.method) {
            "connect" -> {
                Log.d(TAG, "onMethodCall: обработка метода connect")
                
                // Пытаемся извлечь конфигурацию разными способами
                val config = when {
                    call.arguments is Map<*, *> -> {
                        val argsMap = call.arguments as Map<*, *>
                        Log.d(TAG, "onMethodCall: arguments это Map, ключи=${argsMap.keys}")
                        argsMap["config"] as? String
                    }
                    call.arguments is String -> {
                        Log.d(TAG, "onMethodCall: arguments это String")
                        call.arguments as String
                    }
                    else -> {
                        Log.d(TAG, "onMethodCall: пытаемся использовать call.argument<String>(\"config\")")
                        call.argument<String>("config")
                    }
                }

                val protocol = when {
                    call.arguments is Map<*, *> -> {
                        val argsMap = call.arguments as Map<*, *>
                        argsMap["protocol"] as? String
                    }
                    else -> call.argument<String>("protocol")
                }
                val mtu = when {
                    call.arguments is Map<*, *> -> {
                        val argsMap = call.arguments as Map<*, *>
                        (argsMap["mtu"] as? Number)?.toInt() ?: 0
                    }
                    else -> (call.argument<Number>("mtu"))?.toInt() ?: 0
                }
                val connectionSessionId = when {
                    call.arguments is Map<*, *> -> {
                        val argsMap = call.arguments as Map<*, *>
                        (argsMap["connection_session_id"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
                    }
                    else -> null
                }
                val source = when {
                    call.arguments is Map<*, *> -> {
                        val argsMap = call.arguments as Map<*, *>
                        (argsMap["source"] as? String)?.trim()?.takeIf { it.isNotEmpty() } ?: "ui_tap"
                    }
                    else -> "ui_tap"
                }
                if (config == null) {
                    Log.e(TAG, "onMethodCall: конфигурация VPN не предоставлена")
                    result.error("INVALID_ARGUMENT", "Конфигурация VPN не предоставлена", null)
                    return
                }
                Log.d(
                    TAG,
                    "onMethodCall: конфигурация получена, длина=${config.length}, превью=${VpnLogRedaction.previewRedacted(config, 120)}",
                )
                Log.d(TAG, "onMethodCall: протокол получен: ${protocol ?: "null"}, mtu=$mtu, source=$source session=${connectionSessionId ?: "null"}")
                val runtimeCheck = extractRuntimeContractCheck(call.arguments)
                if (runtimeCheck?.hasMismatch == true) {
                    val mismatchCsv = runtimeCheck.mismatchFields.joinToString(",")
                    Log.e(
                        TAG,
                        "connect blocked: config_mismatch protocol=${runtimeCheck.protocol ?: protocol ?: "unknown"} " +
                            "correlation_id=${runtimeCheck.correlationId ?: "none"} mismatches=$mismatchCsv",
                    )
                    result.error(
                        "CONFIG_MISMATCH",
                        "Получен несовместимый VPN-конфиг (config_mismatch). Повторите подключение.",
                        mapOf(
                            "reason" to "config_mismatch",
                            "mismatch_fields" to runtimeCheck.mismatchFields,
                            "protocol" to (runtimeCheck.protocol ?: protocol ?: ""),
                            "correlation_id" to (runtimeCheck.correlationId ?: ""),
                        ),
                    )
                    return
                }
                connectVpn(config, protocol, mtu, connectionSessionId, source, result)
            }
            "connectAmneziaWg" -> {
                val args = call.arguments as? Map<*, *>
                val config = args?.get("config") as? String
                val connectionSessionId = (args?.get("connection_session_id") as? String)
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                val source = (args?.get("source") as? String)?.trim()?.takeIf { it.isNotEmpty() } ?: "simple_vpn"
                if (config.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "AmneziaWG config is empty", null)
                    return
                }
                connectAmneziaWg(config, connectionSessionId, source, result)
            }
            "getAmneziaWgStatus" -> {
                val connected = isAmneziaWgConnected()
                if (connected) {
                    appContext?.let {
                        NativeVpnRuntimeState.reconcileAwgNotification(it, "method_get_status")
                    }
                } else {
                    cleanupStaleAmneziaWgNotification()
                }
                result.success(mapOf("connected" to connected))
            }
            "disconnectAmneziaWg" -> {
                Thread {
                    val ctx = appContext ?: activity?.applicationContext
                    SimpleAmneziaWgRunner.disconnect(ctx)
                    cleanupStaleAmneziaWgNotification()
                    mainHandler.post { result.success(true) }
                }.start()
            }
            "disconnect" -> {
                val args = call.arguments as? Map<*, *>
                val reason = args?.get("reason") as? String
                val source = args?.get("source") as? String
                val connectionSessionId = (args?.get("connection_session_id") as? String)
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                disconnectVpn(
                    result = result,
                    reason = reason,
                    source = source,
                    connectionSessionId = connectionSessionId,
                )
            }
            "setTelemetryTrafficInterval" -> {
                val args = call.arguments as? Map<*, *>
                val background = args?.get("background") as? Boolean ?: false
                VpnNativeStateEmitter.setTrafficTelemetryBackgroundMode(background)
                result.success(null)
            }
            "bindUnderlyingNetworkForControlPlane" -> {
                val ctx = activity ?: appContext
                if (ctx == null) {
                    result.success(mapOf("bound" to false, "reason" to "no_context"))
                } else {
                    Log.i(TAG, "[APP_CONFLICT_A] bindUnderlyingNetworkForControlPlane disabled")
                    result.success(mapOf("bound" to false, "reason" to "app_conflict_a_disabled"))
                }
            }
            "unbindUnderlyingNetworkForControlPlane" -> {
                val ctx = activity ?: appContext
                if (ctx != null) {
                    Log.i(TAG, "[APP_CONFLICT_A] unbindUnderlyingNetworkForControlPlane disabled")
                }
                result.success(null)
            }
            "getStatus" -> {
                getVpnStatus(result)
            }
            "getTrafficStats" -> {
                getTrafficStats(result)
            }
            "getEffectiveOutbounds" -> {
                getEffectiveOutbounds(result)
            }
            "isXrayAvailable" -> {
                result.success(XrayNativeWrapperTun2Socks.isAvailable())
            }
            "requestPermission" -> {
                requestVpnPermission(result)
            }
            "setAllowTileConnect" -> {
                val allow = call.argument<Boolean>("allow") ?: false
                appContext?.let { ctx -> setAllowTileConnect(ctx, allow) }
                result.success(null)
            }
            "getLaunchInitialRoute" -> {
                val route = activity?.intent?.getStringExtra(QuickTileService.EXTRA_INITIAL_ROUTE)
                result.success(route)
            }
            "takeQuickTileAction" -> {
                val intent = activity?.intent
                val action = intent?.getStringExtra(QuickTileService.EXTRA_QUICK_TILE_ACTION)
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                if (action != null) {
                    intent.removeExtra(QuickTileService.EXTRA_QUICK_TILE_ACTION)
                    Log.i(TAG, "takeQuickTileAction: action=$action")
                }
                result.success(action)
            }
            "requestQuickTileRefresh" -> {
                val ctx = appContext ?: activity?.applicationContext
                if (ctx != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    try {
                        QuickTileService.notifyVpnStateChanged(ctx)
                    } catch (e: Exception) {
                        Log.w(TAG, "requestQuickTileRefresh failed", e)
                    }
                }
                result.success(null)
            }
            "isIgnoringBatteryOptimizations" -> {
                val ctx = appContext ?: activity?.applicationContext
                if (ctx == null) {
                    result.success(false)
                } else {
                    val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
                    val ignoring = pm?.isIgnoringBatteryOptimizations(ctx.packageName) == true
                    result.success(ignoring)
                }
            }
            "getSplitTunnelMode" -> {
                val ctx = appContext ?: activity?.applicationContext
                result.success(ctx?.let { SplitTunnelPrefs.getMode(it) } ?: SplitTunnelPrefs.MODE_EXCLUDE)
            }
            "setSplitTunnelMode" -> {
                val mode = call.argument<String>("mode") ?: SplitTunnelPrefs.MODE_EXCLUDE
                appContext?.let { SplitTunnelPrefs.setMode(it, mode) }
                result.success(null)
            }
            "getSplitTunnelExcludedApps" -> {
                val ctx = appContext ?: activity?.applicationContext
                if (ctx == null) {
                    result.success(emptyList<String>())
                } else {
                    result.success(SplitTunnelPrefs.getSelectedPackages(ctx).toList())
                }
            }
            "setSplitTunnelExcludedApps" -> {
                @Suppress("UNCHECKED_CAST")
                val packages = (call.arguments as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
                val ctx = appContext ?: activity?.applicationContext
                if (ctx != null) {
                    SplitTunnelPrefs.setExcludedPackages(ctx, packages)
                }
                result.success(null)
            }
            "getSplitTunnelDirectDomains" -> {
                val ctx = appContext ?: activity?.applicationContext
                result.success(ctx?.let { SplitTunnelPrefs.getDirectDomains(it) } ?: emptyList<String>())
            }
            "setSplitTunnelDirectDomains" -> {
                @Suppress("UNCHECKED_CAST")
                val domains = (call.arguments as? List<*>)?.mapNotNull { it?.toString()?.trim() }?.filter { it.isNotEmpty() } ?: emptyList()
                appContext?.let { ctx ->
                    SplitTunnelPrefs.setDirectDomains(ctx, domains)
                    try {
                        Log.i(TAG, "[APP_CONFLICT_A] DNS policy hot swap disabled")
                    } catch (e: Exception) {
                        Log.w(TAG, "setSplitTunnelDirectDomains hot swap: ${e.message}")
                    }
                }
                result.success(null)
            }
            "getInstalledApps" -> {
                val ctx = appContext ?: activity?.applicationContext
                if (ctx == null) {
                    result.success(emptyList<Map<String, String>>())
                } else {
                    try {
                        val pm = ctx.packageManager
                        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                        val resolveList = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
                        } else {
                            @Suppress("DEPRECATION")
                            pm.queryIntentActivities(intent, 0)
                        }
                        val myPkg = ctx.packageName
                        val apps = resolveList
                            .mapNotNull { ri ->
                                val pkg = ri.activityInfo?.packageName ?: return@mapNotNull null
                                if (pkg == myPkg) return@mapNotNull null
                                val label = ri.loadLabel(pm)?.toString() ?: pkg
                                mapOf("package" to pkg, "label" to label)
                            }
                            .distinctBy { it["package"] }
                            .sortedBy { (it["label"] ?: "").lowercase() }
                        result.success(apps)
                    } catch (e: Exception) {
                        Log.w(TAG, "getInstalledApps failed: ${e.message}")
                        result.success(emptyList<Map<String, String>>())
                    }
                }
            }
            "requestIgnoreBatteryOptimizations" -> {
                val act = activity
                val ctx = appContext ?: act?.applicationContext
                if (ctx == null || act == null) {
                    result.success(false)
                    return
                }
                val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
                if (pm?.isIgnoringBatteryOptimizations(ctx.packageName) == true) {
                    result.success(true)
                    return
                }
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:${ctx.packageName}")
                    }
                    act.startActivity(intent)
                    result.success(false)
                } catch (e: Exception) {
                    Log.w(TAG, "requestIgnoreBatteryOptimizations: ${e.message}")
                    result.error("BATTERY_OPT", e.message, null)
                }
            }
            "getDnsPolicyMode" -> {
                val ctx = appContext ?: activity?.applicationContext
                result.success(ctx?.let { VpnRoutingPrefs.getDnsMode(it) } ?: VpnRoutingPrefs.DNS_PERFORMANCE)
            }
            "setDnsPolicyMode" -> {
                val mode = (call.arguments as? Map<*, *>)?.get("mode") as? String
                    ?: VpnRoutingPrefs.DNS_PERFORMANCE
                appContext?.let { ctx ->
                    VpnRoutingPrefs.setDnsMode(ctx, mode)
                    try {
                        GraniVpnService.requestApplyRoutingHotSwap(ctx)
                    } catch (e: Exception) {
                        Log.w(TAG, "setDnsPolicyMode hot swap: ${e.message}")
                    }
                }
                result.success(null)
            }
            "applyVpnRoutingHotSwap" -> {
                val ctx = appContext ?: activity?.applicationContext
                if (ctx == null) {
                    result.success(false)
                } else {
                    try {
                        Log.i(TAG, "[APP_CONFLICT_A] applyVpnRoutingHotSwap disabled")
                        result.success(false)
                    } catch (e: Exception) {
                        Log.e(TAG, "applyVpnRoutingHotSwap: ${e.message}", e)
                        result.error("HOTSWAP", e.message, null)
                    }
                }
            }
            "apiRequestViaLocalSocks" -> {
                apiRequestViaLocalSocks(call, result)
            }
            "circuitBreakerRecordHealthSuccess" -> {
                VpnCircuitBreaker.recordHealthCheckSuccess()
                result.success(null)
            }
            "circuitBreakerRecordHealthFailure" -> {
                VpnCircuitBreaker.recordHealthCheckFailure()
                if (VpnCircuitBreaker.shouldTripBreaker()) {
                    VpnCircuitBreaker.markOpen(VpnCircuitBreaker.tripReason())
                }
                result.success(null)
            }
            "circuitBreakerRecordTransportReset" -> {
                VpnCircuitBreaker.recordTransportResetSignal()
                if (VpnCircuitBreaker.shouldTripBreaker()) {
                    VpnCircuitBreaker.markOpen(VpnCircuitBreaker.tripReason())
                }
                result.success(null)
            }
            "isCircuitBreakerOpen" -> {
                result.success(VpnCircuitBreaker.isOpen())
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun extractRuntimeContractCheck(arguments: Any?): RuntimeContractCheck? {
        val argsMap = arguments as? Map<*, *> ?: return null
        val runtimeContract = argsMap["runtime_contract"] as? Map<*, *> ?: return null
        val hasMismatch = runtimeContract["has_mismatch"] as? Boolean ?: false
        val mismatchFieldsRaw = runtimeContract["mismatch_fields"] as? List<*>
        val mismatchFields = mismatchFieldsRaw
            ?.mapNotNull { it?.toString()?.trim() }
            ?.filter { it.isNotEmpty() }
            ?: emptyList()
        val protocol = (runtimeContract["protocol"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
        val correlationId = (argsMap["correlation_id"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
        return RuntimeContractCheck(
            hasMismatch = hasMismatch,
            mismatchFields = mismatchFields,
            protocol = protocol,
            correlationId = correlationId,
        )
    }

    /**
     * HTTP(S) через локальный SOCKS Xray (127.0.0.1:10808) — fallback API без перезапуска VPN.
     */
    private fun apiRequestViaLocalSocks(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: run {
            result.error("ARG", "url required", null)
            return
        }
        val method = (call.argument<String>("method") ?: "GET").uppercase()
        @Suppress("UNCHECKED_CAST")
        val headers = (call.argument<Map<String, String>>("headers")) ?: emptyMap()
        val bodyStr = call.argument<String>("body")
        Thread {
            try {
                val client = OkHttpClient.Builder()
                    .proxy(Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", 10808)))
                    .connectTimeout(15, TimeUnit.SECONDS)
                    .readTimeout(45, TimeUnit.SECONDS)
                    .writeTimeout(45, TimeUnit.SECONDS)
                    .build()
                val reqBuilder = Request.Builder().url(url)
                headers.forEach { (k, v) ->
                    if (k.equals("content-length", ignoreCase = true)) return@forEach
                    reqBuilder.header(k, v)
                }
                val body = if (bodyStr.isNullOrEmpty() || method == "GET" || method == "HEAD") {
                    null
                } else {
                    val ct = headers["Content-Type"] ?: headers["content-type"] ?: "application/json; charset=utf-8"
                    bodyStr.toRequestBody(ct.toMediaType())
                }
                reqBuilder.method(method, body)
                val resp = client.newCall(reqBuilder.build()).execute()
                val responseHeaders = mutableMapOf<String, String>()
                for (i in 0 until resp.headers.size) {
                    val name = resp.headers.name(i)
                    responseHeaders[name] = resp.headers.value(i)
                }
                val out = mapOf(
                    "statusCode" to resp.code,
                    "body" to (resp.body?.string() ?: ""),
                    "headers" to responseHeaders,
                )
                mainHandler.post { result.success(out) }
            } catch (e: Exception) {
                Log.e(TAG, "apiRequestViaLocalSocks: ${e.message}", e)
                mainHandler.post { result.error("SOCKS_HTTP", e.message, null) }
            }
        }.start()
    }


    private fun connectAmneziaWg(
        config: String,
        connectionSessionId: String?,
        source: String,
        result: MethodChannel.Result,
    ) {
        val act = activity
        if (act == null) {
            result.error("ACTIVITY_NULL", "Activity недоступна", null)
            return
        }
        try {
            val intent = VpnService.prepare(act)
            if (intent != null) {
                pendingVpnConfig = config
                pendingProtocol = "graniwg"
                pendingMtu = 0
                pendingConnectionSessionId = connectionSessionId
                pendingSource = source
                pendingVpnBackend = "amneziawg"
                pendingResult = result
                if (vpnPermissionLauncher != null) {
                    vpnPermissionLauncher?.launch(intent)
                } else {
                    act.startActivityForResult(intent, VPN_REQUEST_CODE)
                }
                Log.d(TAG, "connectAmneziaWg: requested VPN permission")
                return
            }
            startAmneziaWgConnection(config, connectionSessionId, source, result)
        } catch (e: Exception) {
            Log.e(TAG, "connectAmneziaWg: failed", e)
            result.error("VPN_ERROR", "Ошибка подключения AmneziaWG: ${e.message}", null)
        }
    }

    private fun startAmneziaWgConnection(
        config: String,
        connectionSessionId: String?,
        source: String,
        result: MethodChannel.Result?,
    ) {
        val ctx = activity?.applicationContext ?: appContext
        if (ctx == null) {
            result?.error("ACTIVITY_NULL", "Context недоступен для AmneziaWG", null)
            return
        }
        Thread {
            try {
                Log.i(TAG, "startAmneziaWgConnection: source=$source session=${connectionSessionId ?: "null"}")
                val state = SimpleAmneziaWgRunner.connect(ctx, config)
                val isUp = state == org.amnezia.awg.backend.Tunnel.State.UP
                if (isUp) {
                    saveLastConfig(ctx, config, "graniwg", 0)
                    Log.i(TAG, "startAmneziaWgConnection: cached last GRANIwg config for quick tile")
                }
                mainHandler.post { result?.success(isUp) }
            } catch (e: Exception) {
                Log.e(TAG, "startAmneziaWgConnection: failed", e)
                mainHandler.post {
                    result?.error(
                        "VPN_ERROR",
                        "Ошибка запуска AmneziaWG: ${e.message}",
                        mapOf("exception" to e.javaClass.simpleName),
                    )
                }
            }
        }.start()
    }

    private fun connectVpn(
        config: String,
        protocol: String?,
        mtu: Int,
        connectionSessionId: String?,
        source: String,
        result: MethodChannel.Result,
    ) {
        Log.d(TAG, "connectVpn: Начало подключения VPN, длина конфигурации=${config.length}")
        try {
            if (activity == null) {
                Log.e(TAG, "connectVpn: Activity недоступна")
                result.error("ACTIVITY_NULL", "Activity недоступна", null)
                return
            }
            Log.d(TAG, "connectVpn: Activity доступна: ${activity?.javaClass?.simpleName}")
            
            val intent = VpnService.prepare(activity)
            if (intent != null) {
                // Нужно запросить разрешение
                pendingVpnConfig = config
                pendingProtocol = protocol
                pendingMtu = mtu
                pendingConnectionSessionId = connectionSessionId
                pendingSource = source
                pendingVpnBackend = "xray"
                pendingResult = result
                
                // Используем ActivityResultLauncher если доступен, иначе fallback на старый API
                if (vpnPermissionLauncher != null) {
                    vpnPermissionLauncher?.launch(intent)
                    Log.d(TAG, "Запрос разрешения VPN у пользователя (через ActivityResultLauncher)")
                } else {
                    // Fallback на старый API для обратной совместимости
                    if (activity is androidx.activity.ComponentActivity) {
                        // Если ActivityResultLauncher не был зарегистрирован, пытаемся зарегистрировать сейчас
                        val componentActivity = activity as androidx.activity.ComponentActivity
                        vpnPermissionLauncher = componentActivity.registerForActivityResult(
                            ActivityResultContracts.StartActivityForResult()
                        ) { activityResult ->
                            handleVpnPermissionResult(activityResult.resultCode)
                        }
                        vpnPermissionLauncher?.launch(intent)
                        Log.d(TAG, "Запрос разрешения VPN у пользователя (ActivityResultLauncher зарегистрирован динамически)")
                    } else {
                        // Используем старый API
                        activity?.startActivityForResult(intent, VPN_REQUEST_CODE)
                        Log.d(TAG, "Запрос разрешения VPN у пользователя (через startActivityForResult - fallback)")
                    }
                }
            } else {
                // Разрешение уже есть, запускаем VPN
                Log.d(TAG, "Разрешение VPN уже получено, запускаем подключение")
                startVpnConnection(config, protocol, mtu, connectionSessionId, source, result)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка подключения VPN: ${e.message}", e)
            result.error("VPN_ERROR", "Ошибка подключения VPN: ${e.message}", null)
        }
    }

    private fun startVpnConnection(
        config: String,
        protocol: String?,
        mtu: Int = 0,
        connectionSessionId: String? = null,
        source: String = "ui_tap",
        result: MethodChannel.Result? = null,
    ) {
        try {
            Log.d(TAG, "startVpnConnection: Начало подключения VPN, mtu=$mtu")
            Log.d(TAG, "startVpnConnection: Длина конфигурации: ${config.length}")
            Log.d(TAG, "startVpnConnection: Превью конфигурации: ${config.take(100)}...")
            Log.d(TAG, "startVpnConnection: Протокол: ${protocol ?: "null"} source=$source session=${connectionSessionId ?: "null"}")
            
            val act = activity
            if (act == null) {
                result?.error("ACTIVITY_NULL", "Activity недоступна для установки контекста", null)
                return
            }

            GraniVpnService.startService(
                act.applicationContext,
                config,
                protocol,
                mtu,
                source = source,
                connectionSessionId = connectionSessionId,
            )
            Log.i(TAG, "startVpnConnection: Команда запуска VPN отправлена, ожидаем подтверждения запуска")

            val startTimeoutMs = 30000L
            Thread {
                val startTs = System.currentTimeMillis()
                var isStarted = false
                var startedMode = "unknown"
                var startError: String? = null
                val statusContext = appContext ?: act.applicationContext
                while (System.currentTimeMillis() - startTs < startTimeoutMs) {
                    val lastError = GraniVpnService.getLastStartError()
                    if (!lastError.isNullOrBlank()) {
                        startError = lastError
                        break
                    }
                    if (GraniVpnService.isVpnCommitted()) {
                        isStarted = true
                        startedMode = "committed"
                        break
                    }
                    if (NativeVpnRuntimeState.isNativeVpnLikelyActive(statusContext)) {
                        isStarted = true
                        startedMode = "local_up"
                        break
                    }
                    Thread.sleep(50)
                }

                act.runOnUiThread {
                    if (isStarted) {
                        Log.i(TAG, "startVpnConnection: VPN started mode=$startedMode")
                        appContext?.let { context ->
                            saveLastConfig(context, config, protocol, mtu)
                        }
                        result?.success(true)
                    } else if (!startError.isNullOrBlank()) {
                        Log.e(TAG, "startVpnConnection: VPN не запустился: $startError")
                        appContext?.let { context ->
                            clearLastConfig(context)
                        }
                        result?.error("VPN_START_FAILED", startError, null)
                    } else {
                        val errorMsg = "VPN не вышел в COMMITTED за отведенное время"
                        Log.e(TAG, "startVpnConnection: $errorMsg")
                        appContext?.let { context ->
                            clearLastConfig(context)
                        }
                        result?.error("VPN_TIMEOUT", errorMsg, mapOf("timeoutMs" to startTimeoutMs))
                    }
                }
            }.start()
            
            // Очищаем pending значения только если они использовались
            if (result == null) {
                pendingResult = null
                pendingVpnConfig = null
                pendingProtocol = null
            }
        } catch (e: Exception) {
            val errorMsg = "Ошибка запуска VPN: ${e.message}"
            Log.e(TAG, "startVpnConnection: $errorMsg", e)
            Log.e(TAG, "startVpnConnection: Stack trace: ${e.stackTraceToString()}")
            result?.error("VPN_ERROR", errorMsg, mapOf(
                "exception" to e.javaClass.simpleName,
                "message" to (e.message ?: "Unknown error"),
                "stackTrace" to e.stackTraceToString()
            ))
            
            // Очищаем pending значения только если они использовались
            if (result == null) {
                pendingResult = null
                pendingVpnConfig = null
                pendingProtocol = null
            }
        }
    }

    private fun disconnectVpn(
        result: MethodChannel.Result,
        reason: String? = null,
        source: String? = null,
        connectionSessionId: String? = null,
    ) {
        try {
            val act = activity
            if (act == null) {
                result.error("ACTIVITY_NULL", "Activity недоступна", null)
                return
            }
            Log.i(
                TAG,
                "disconnectVpn: source=${source ?: "unknown"} reason=${reason ?: "unspecified"} session=${connectionSessionId ?: "null"}",
            )
            GraniVpnService.stopService(
                context = act.applicationContext,
                source = source ?: "flutter_method_channel",
                reason = reason ?: "unspecified",
                connectionSessionId = connectionSessionId,
            )
            // Не очищаем lastConfig — позволяет Quick Tile reconnect без открытия приложения
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка отключения VPN: ${e.message}", e)
            result.error("VPN_ERROR", "Ошибка отключения VPN: ${e.message}", null)
        }
    }

    private fun getVpnStatus(result: MethodChannel.Result) {
        try {
            val ctx = appContext ?: activity?.applicationContext
            val isConnected = if (ctx != null) {
                NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(ctx)
            } else {
                GraniVpnService.isVpnCommitted()
            }
            if (isConnected && ctx != null) {
                NativeVpnRuntimeState.notifyQuickTile(ctx)
            }
            result.success(mapOf("connected" to isConnected))
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка получения статуса VPN: ${e.message}", e)
            result.error("VPN_ERROR", "Ошибка получения статуса VPN: ${e.message}", null)
        }
    }

    private fun isAmneziaWgConnected(): Boolean {
        val ctx = appContext ?: activity?.applicationContext ?: return SimpleAmneziaWgRunner.isUp()
        return NativeVpnRuntimeState.isAwgLikelyActive(ctx)
    }

    private fun cleanupStaleAmneziaWgNotification() {
        val ctx = appContext ?: activity?.applicationContext ?: return
        GraniAwgNotificationService.stop(ctx)
    }

    private fun getTrafficStats(result: MethodChannel.Result) {
        try {
            val stats = GraniVpnService.getTrafficStatsSnapshot()
            result.success(stats)
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка получения статистики трафика: ${e.message}", e)
            result.error("VPN_ERROR", "Ошибка получения статистики трафика: ${e.message}", null)
        }
    }

    private fun getEffectiveOutbounds(result: MethodChannel.Result) {
        try {
            result.success(
                mapOf(
                    "effective_outbounds" to GraniVpnService.getLastEffectiveOutbounds(),
                ),
            )
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка получения effective outbounds: ${e.message}", e)
            result.error("VPN_ERROR", "Ошибка получения effective outbounds: ${e.message}", null)
        }
    }

    private fun requestVpnPermission(result: MethodChannel.Result) {
        try {
            if (activity == null) {
                result.error("ACTIVITY_NULL", "Activity недоступна", null)
                return
            }
            
            val intent = VpnService.prepare(activity)
            if (intent != null) {
                // Нужно запросить разрешение
                pendingResult = result
                pendingVpnConfig = null // Нет конфигурации, только запрос разрешения
                pendingProtocol = null
                
                // Используем ActivityResultLauncher если доступен, иначе fallback на старый API
                if (vpnPermissionLauncher != null) {
                    vpnPermissionLauncher?.launch(intent)
                    Log.d(TAG, "Запрос разрешения VPN у пользователя (requestPermission через ActivityResultLauncher)")
                } else {
                    // Fallback на старый API для обратной совместимости
                    if (activity is androidx.activity.ComponentActivity) {
                        // Если ActivityResultLauncher не был зарегистрирован, пытаемся зарегистрировать сейчас
                        val componentActivity = activity as androidx.activity.ComponentActivity
                        vpnPermissionLauncher = componentActivity.registerForActivityResult(
                            ActivityResultContracts.StartActivityForResult()
                        ) { activityResult ->
                            handleVpnPermissionResult(activityResult.resultCode)
                        }
                        vpnPermissionLauncher?.launch(intent)
                        Log.d(TAG, "Запрос разрешения VPN у пользователя (ActivityResultLauncher зарегистрирован динамически)")
                    } else {
                        // Используем старый API
                        activity?.startActivityForResult(intent, VPN_REQUEST_CODE)
                        Log.d(TAG, "Запрос разрешения VPN у пользователя (requestPermission через startActivityForResult - fallback)")
                    }
                }
            } else {
                // Разрешение уже есть
                Log.d(TAG, "Разрешение VPN уже получено")
                result.success(true)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка запроса разрешения VPN: ${e.message}", e)
            result.error("VPN_ERROR", "Ошибка запроса разрешения VPN: ${e.message}", null)
        }
    }
}
