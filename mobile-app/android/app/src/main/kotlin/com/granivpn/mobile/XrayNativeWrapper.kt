package com.granivpn.mobile

import android.content.Context
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.Build.VERSION_CODES
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.lang.reflect.InvocationHandler
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.net.InetAddress

/**
 * Обертка для нативного XRay-core через libXray AAR
 * 
 * Использует Java API из libXray.aar для запуска XRay-core
 * вместо sing-box (libbox).
 */
class XrayNativeWrapper(private val context: Context) {
    companion object {
        private const val TAG = "XrayNativeWrapper"
        
        // Имена классов libXray (gobind AAR package: libXray.libXray.*).
        private val LIBXRAY_CLASS_CANDIDATES = arrayOf(
            "libXray.libXray.LibXray",
            "libXray.LibXray",
            "com.github.xtls.libxray.LibXray",
        )
        private val DIALER_CONTROLLER_CLASS_CANDIDATES = arrayOf(
            "libXray.libXray.DialerController",
            "libXray.DialerController",
        )
        
        @Volatile
        private var isLibXrayAvailable = false
        private var libXrayClass: Class<*>? = null
        /** Старый контракт libXray: `runXray(datDir, configPath, maxMemoryBytes)`. */
        private var runXrayLegacyThreeArg: Method? = null
        /** Новый контракт (25.x): `newXrayRunRequest(datDir, configPath)` → строка запроса → `runXray(request)`. */
        private var runXraySingleArg: Method? = null
        private var newXrayRunRequestMethod: Method? = null
        private var newXrayRunFromJSONRequestMethod: Method? = null
        private var runXrayFromJSONNativeMethod: Method? = null
        private var stopXrayMethod: Method? = null
        private var isRunningMethod: Method? = null
        private var registerDialerControllerMethod: Method? = null
        private var registerListenerControllerMethod: Method? = null
        private var initXrayMethod: Method? = null
        private var initDnsMethod: Method? = null
        private var resetDnsMethod: Method? = null
        private var lastConfigFile: java.io.File? = null
        
        init {
            checkLibXrayAvailability()
        }
        
        private fun checkLibXrayAvailability() {
            try {
                val classLoader = Thread.currentThread().contextClassLoader ?: XrayNativeWrapper::class.java.classLoader
                libXrayClass = LIBXRAY_CLASS_CANDIDATES.firstNotNullOfOrNull { name ->
                    try {
                        Class.forName(name, false, classLoader)
                    } catch (t: Throwable) {
                        Log.d(TAG, "LibXray candidate недоступен: $name (${t.javaClass.simpleName}: ${t.message})")
                        null
                    }
                }

                if (libXrayClass == null) {
                    Log.w(TAG, "libXray Java API недоступен (класс LibXray не найден)")
                    isLibXrayAvailable = false
                    return
                }

                try {
                    runXrayLegacyThreeArg = try {
                        libXrayClass!!.getMethod(
                            "runXray",
                            String::class.java,
                            String::class.java,
                            java.lang.Long.TYPE,
                        )
                    } catch (_: NoSuchMethodException) {
                        null
                    }
                    runXraySingleArg = try {
                        libXrayClass!!.getMethod("runXray", String::class.java)
                    } catch (_: NoSuchMethodException) {
                        null
                    }
                    newXrayRunRequestMethod = try {
                        libXrayClass!!.getMethod(
                            "newXrayRunRequest",
                            String::class.java,
                            String::class.java,
                        )
                    } catch (_: NoSuchMethodException) {
                        null
                    }
                    newXrayRunFromJSONRequestMethod = try {
                        libXrayClass!!.getMethod(
                            "newXrayRunFromJSONRequest",
                            String::class.java,
                            String::class.java,
                        )
                    } catch (_: NoSuchMethodException) {
                        null
                    }
                    runXrayFromJSONNativeMethod = try {
                        libXrayClass!!.getMethod("runXrayFromJSON", String::class.java)
                    } catch (_: NoSuchMethodException) {
                        null
                    }

                    stopXrayMethod = libXrayClass!!.getMethod("stopXray")
                    val dialerControllerClass = DIALER_CONTROLLER_CLASS_CANDIDATES.firstNotNullOfOrNull { name ->
                        try {
                            Class.forName(name, false, classLoader)
                        } catch (t: Throwable) {
                            Log.d(TAG, "DialerController candidate недоступен: $name (${t.javaClass.simpleName}: ${t.message})")
                            null
                        }
                    }
                    registerDialerControllerMethod = try {
                        if (dialerControllerClass != null) {
                            libXrayClass!!.getMethod("registerDialerController", dialerControllerClass)
                        } else {
                            null
                        }
                    } catch (_: Exception) {
                        null
                    }
                    registerListenerControllerMethod = try {
                        if (dialerControllerClass != null) {
                            libXrayClass!!.getMethod("registerListenerController", dialerControllerClass)
                        } else {
                            null
                        }
                    } catch (_: Exception) {
                        null
                    }
                    initXrayMethod = libXrayClass!!.methods.firstOrNull {
                        it.name == "initXray" && it.parameterTypes.size == 1
                    }
                    initDnsMethod = libXrayClass!!.methods.firstOrNull {
                        it.name.equals("initDns", ignoreCase = true) &&
                            it.parameterTypes.size == 2
                    } ?: libXrayClass!!.methods.firstOrNull {
                        it.name.equals("initDns", ignoreCase = true)
                    }
                    resetDnsMethod = libXrayClass!!.methods.firstOrNull {
                        it.name.equals("resetDns", ignoreCase = true) && it.parameterTypes.isEmpty()
                    }

                    isRunningMethod = try {
                        libXrayClass!!.getMethod("getXrayState")
                    } catch (_: NoSuchMethodException) {
                        try {
                            libXrayClass!!.getMethod("isXrayRunning")
                        } catch (_: NoSuchMethodException) {
                            Log.w(TAG, "Метод проверки состояния не найден, будет использован флаг isRunning")
                            null
                        }
                    }

                    val okLegacy = runXrayLegacyThreeArg != null
                    val okNewFile =
                        runXraySingleArg != null && newXrayRunRequestMethod != null
                    isLibXrayAvailable = okLegacy || okNewFile

                    if (!isLibXrayAvailable) {
                        Log.w(
                            TAG,
                            "Нет совместимого runXray: legacy3=$runXrayLegacyThreeArg " +
                                "single=$runXraySingleArg newXrayRunRequest=$newXrayRunRequestMethod",
                        )
                        Log.d(TAG, "Методы ${libXrayClass!!.name}:")
                        libXrayClass!!.declaredMethods.forEach { method ->
                            Log.d(
                                TAG,
                                "  - ${method.name}(${method.parameterTypes.joinToString { it.simpleName }})",
                            )
                        }
                    } else {
                        Log.i(
                            TAG,
                            "libXray Java API доступен (класс: ${libXrayClass!!.name}, " +
                                "legacy3=$okLegacy, newFile=$okNewFile, " +
                                "runXrayFromJSON=${runXrayFromJSONNativeMethod != null})",
                        )
                    }
                } catch (e: NoSuchMethodException) {
                    Log.w(TAG, "Критические методы libXray не найдены: ${e.message}")
                    isLibXrayAvailable = false
                }
            } catch (e: Throwable) {
                Log.w(TAG, "Ошибка проверки libXray: ${e.javaClass.simpleName}: ${e.message}", e)
                isLibXrayAvailable = false
            }
        }

        /** Запуск по файлу конфигурации: поддерживает старый и новый (25.x) JNI контракт. */
        private fun invokeRunXrayForFileConfig(datDir: String, configAbsolutePath: String): Any? {
            runXrayLegacyThreeArg?.let {
                return it.invoke(null, datDir, configAbsolutePath, 256L * 1024L * 1024L)
            }
            val single = runXraySingleArg
            val newReq = newXrayRunRequestMethod
            if (single != null && newReq != null) {
                val wire = try {
                    newReq.invoke(null, datDir, configAbsolutePath) as String
                } catch (e: Exception) {
                    throw IllegalStateException("newXrayRunRequest failed: ${e.message}", e)
                }
                return single.invoke(null, wire)
            }
            return null
        }

        fun isAvailable(): Boolean = isLibXrayAvailable
    }

    /** [DIAG] Выполняет ip route get 8.8.8.8 и пишет результат в лог (для отладки reconnect). */
    /**
     * Вызов VpnService.Builder.establish() на main thread.
     * ConnectivityService может некорректно обновлять маршруты при вызове из фона — при reconnect
     * трафик не попадает в новый TUN. Вызов с main thread устраняет проблему без увеличения задержек.
     */
    private fun establishOnMainThread(builder: VpnService.Builder): ParcelFileDescriptor? {
        return if (Looper.myLooper() == Looper.getMainLooper()) {
            builder.establish()
        } else {
            val latch = CountDownLatch(1)
            var result: ParcelFileDescriptor? = null
            Handler(Looper.getMainLooper()).post {
                result = builder.establish()
                latch.countDown()
            }
            if (!latch.await(15, TimeUnit.SECONDS)) {
                Log.e(TAG, "establishOnMainThread: timeout waiting for establish()")
                null
            } else {
                result
            }
        }
    }

    private fun logIpRouteDiagnostic() {
        try {
            val proc = Runtime.getRuntime().exec(arrayOf("ip", "route", "get", "8.8.8.8"))
            val output = BufferedReader(InputStreamReader(proc.inputStream)).readText().trim()
            val err = BufferedReader(InputStreamReader(proc.errorStream)).readText().trim()
            proc.waitFor()
            Log.i(TAG, "[DIAG] ip route get 8.8.8.8: $output")
            if (err.isNotEmpty()) Log.w(TAG, "[DIAG] ip route stderr: $err")
        } catch (e: Exception) {
            Log.w(TAG, "[DIAG] ip route get failed: ${e.message}")
        }
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private val tunCleanupExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "grani-tun-cleanup").apply { isDaemon = true }
    }
    private var isRunning = false
    private var xrayThread: Thread? = null
    private val vpnStartLock = Any()
    @Volatile
    private var vpnStartInProgress = false
    private var dialerControllerRef: Any? = null
    /** Сохраняем для reconnect: создать новый TUN без перезапуска Xray. */
    private var vpnServiceRef: GraniVpnService? = null
    private var lastTunMtu: Int = 1420
    private val hotSwapLock = Any()

    /**
     * Регистрирует DialerController в libXray: protect(fd) вызывается для исходящих сокетов Xray
     * (подключения к VPN-серверу), чтобы они не шли через TUN и не зацикливались.
     * TUN fd защищать не нужно — это сам VPN-интерфейс.
     */
    private fun registerDialerController(vpnService: VpnService): Boolean {
        try {
            if (libXrayClass == null) {
                Log.w(TAG, "registerDialerController: libXrayClass is null")
                return false
            }
            val dialerInterface = DIALER_CONTROLLER_CLASS_CANDIDATES.firstNotNullOfOrNull { name ->
                try {
                    Class.forName(name)
                } catch (_: ClassNotFoundException) {
                    null
                }
            } ?: run {
                Log.w(TAG, "registerDialerController: DialerController class not found")
                return false
            }
            if (registerDialerControllerMethod == null || registerListenerControllerMethod == null) {
                Log.w(TAG, "registerDialerController: required registration methods are missing")
                return false
            }
            var protectLogCount = 0
            val handler = InvocationHandler { _, method, args ->
                if (method.name == "protectFd") {
                    val fdLong = (args?.firstOrNull() as? Number)?.toLong() ?: return@InvocationHandler false
                    val fd = fdLong.toInt()
                    val protected = try {
                        vpnService.protect(fd)
                    } catch (e: Exception) {
                        Log.w(TAG, "registerDialerController: protectFd failed for fd=$fd: ${e.message}")
                        false
                    }
                    if (!protected || protectLogCount < 12) {
                        Log.i(TAG, "registerDialerController: protectFd fd=$fd result=$protected")
                        protectLogCount++
                    }
                    return@InvocationHandler protected
                }
                when (method.name) {
                    "toString" -> "GraniDialerControllerProxy"
                    "hashCode" -> System.identityHashCode(this)
                    "equals" -> args?.firstOrNull() === this
                    else -> null
                }
            }
            val controllerProxy = Proxy.newProxyInstance(
                dialerInterface.classLoader,
                arrayOf(dialerInterface),
                handler
            )
            registerDialerControllerMethod!!.invoke(null, controllerProxy)
            registerListenerControllerMethod!!.invoke(null, controllerProxy)
            dialerControllerRef = controllerProxy
            Log.i(TAG, "registerDialerController: DialerController зарегистрирован в libXray")
            return true
        } catch (e: Exception) {
            Log.w(TAG, "registerDialerController: не удалось зарегистрировать DialerController: ${e.message}")
            return false
        }
    }

    private fun initDnsForLibXray(configJson: String) {
        val controller = dialerControllerRef ?: return
        val method = initDnsMethod ?: return
        try {
            val dnsServer = extractPrimaryDnsServer(configJson)
            when (method.parameterTypes.size) {
                2 -> method.invoke(null, controller, dnsServer)
                1 -> method.invoke(null, dnsServer)
                else -> {
                    Log.w(TAG, "initDnsForLibXray: unsupported initDns args=${method.parameterTypes.size}")
                    return
                }
            }
            Log.i(TAG, "initDnsForLibXray: DNS initialized in libXray ($dnsServer)")
        } catch (e: Exception) {
            Log.w(TAG, "initDnsForLibXray: failed to init DNS: ${e.message}")
        }
    }

    private fun resetDnsForLibXray() {
        val method = resetDnsMethod ?: return
        try {
            method.invoke(null)
            Log.i(TAG, "resetDnsForLibXray: DNS reset in libXray")
        } catch (e: Exception) {
            Log.w(TAG, "resetDnsForLibXray: failed to reset DNS: ${e.message}")
        }
    }

    private fun extractPrimaryDnsServer(configJson: String): String {
        return try {
            val root = org.json.JSONObject(configJson)
            val dns = root.optJSONObject("dns")
            val servers = dns?.optJSONArray("servers")
            for (i in 0 until (servers?.length() ?: 0)) {
                val server = servers?.optString(i)?.trim().orEmpty()
                if (server.isNotEmpty()) {
                    return if (server.contains(":")) server else "$server:53"
                }
            }
            "1.1.1.1:53"
        } catch (_: Exception) {
            "1.1.1.1:53"
        }
    }

    private fun decodeLibXrayResult(result: Any?): org.json.JSONObject? {
        if (result !is String) {
            return null
        }
        val decodedBytes = try {
            android.util.Base64.decode(result, android.util.Base64.NO_WRAP)
        } catch (e: IllegalArgumentException) {
            null
        }
        val decodedResult = if (decodedBytes != null) {
            String(decodedBytes, Charsets.UTF_8)
        } else {
            result
        }
        return try {
            org.json.JSONObject(decodedResult)
        } catch (e: Exception) {
            null
        }
    }

    private fun sha256Short(value: String?): String {
        if (value.isNullOrBlank()) return "-"
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return digest.take(6).joinToString("") { "%02x".format(it) }
    }

    private fun logEffectiveOutboundDiagnostics(configJson: String) {
        try {
            val root = org.json.JSONObject(configJson)
            val outbounds = root.optJSONArray("outbounds") ?: return
            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.optJSONObject(i) ?: continue
                if (outbound.optString("tag") != "proxy") continue

                val protocol = outbound.optString("protocol", "-")
                val streamSettings = outbound.optJSONObject("streamSettings")
                val security = streamSettings?.optString("security", "none") ?: "none"
                val network = streamSettings?.optString("network", "tcp") ?: "tcp"
                val settings = outbound.optJSONObject("settings")
                val vnext = settings?.optJSONArray("vnext")?.optJSONObject(0)
                val address = vnext?.optString("address", "-") ?: "-"
                val port = vnext?.optInt("port", -1) ?: -1
                val user = vnext?.optJSONArray("users")?.optJSONObject(0)
                val flow = user?.optString("flow", "") ?: ""
                val encryption = user?.optString("encryption", "") ?: ""
                val packetEncoding = settings?.optString("packetEncoding", "") ?: ""
                val reality = streamSettings?.optJSONObject("realitySettings")
                val serverName = reality?.optString("serverName", "") ?: ""
                val fingerprint = reality?.optString("fingerprint", "") ?: ""
                val shortId = reality?.optString("shortId", "") ?: ""

                Log.i(
                    TAG,
                    "[XRAY_OUTBOUND_DIAG] tag=proxy protocol=$protocol address=$address port=$port " +
                        "security=$security network=$network serverName=$serverName " +
                        "fingerprint=$fingerprint shortId_len=${shortId.length} " +
                        "publicKey_sha=${sha256Short(reality?.optString("publicKey"))} " +
                        "user_id_sha=${sha256Short(user?.optString("id"))} " +
                        "flow=${flow.ifBlank { "-" }} encryption=${encryption.ifBlank { "-" }} " +
                        "packetEncoding=${packetEncoding.ifBlank { "-" }}",
                )
                return
            }
            Log.w(TAG, "[XRAY_OUTBOUND_DIAG] proxy outbound not found")
        } catch (e: Exception) {
            Log.w(TAG, "[XRAY_OUTBOUND_DIAG] parse failed: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun extractProxyOutboundAddress(configJson: String): String? {
        return try {
            val root = org.json.JSONObject(configJson)
            val outbounds = root.optJSONArray("outbounds") ?: return null
            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.optJSONObject(i) ?: continue
                if (outbound.optString("tag") != "proxy") continue
                val vnext = outbound
                    .optJSONObject("settings")
                    ?.optJSONArray("vnext")
                    ?.optJSONObject(0)
                val address = vnext?.optString("address", "")?.trim().orEmpty()
                if (address.isNotEmpty()) return address
            }
            null
        } catch (e: Exception) {
            Log.w(TAG, "extractProxyOutboundAddress failed: ${e.javaClass.simpleName}: ${e.message}")
            null
        }
    }

    private fun applyControlPlaneRouteExclusions(
        builder: VpnService.Builder,
        configJson: String,
    ): VpnService.Builder {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return builder
        val candidates = linkedSetOf(
            extractProxyOutboundAddress(configJson),
            "159.223.199.122",
        ).filterNotNull()

        var updated = builder
        for (host in candidates) {
            try {
                val address = InetAddress.getByName(host)
                if (address.address.size != 4) {
                    Log.i(TAG, "route_exclusion: skip non-ipv4 host=$host resolved=${address.hostAddress}")
                    continue
                }
                val prefix = IpPrefix(address, 32)
                updated = updated.excludeRoute(prefix)
                Log.i(TAG, "route_exclusion: excluded $prefix host=$host")
            } catch (e: Exception) {
                Log.w(TAG, "route_exclusion: failed host=$host: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
        return updated
    }

    private fun stripRealityArrayFields(configJson: String): String? {
        return try {
            val root = org.json.JSONObject(configJson)
            val outbounds = root.optJSONArray("outbounds") ?: return null
            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.optJSONObject(i) ?: continue
                val streamSettings = outbound.optJSONObject("streamSettings") ?: continue
                val realitySettings = streamSettings.optJSONObject("realitySettings") ?: continue
                realitySettings.remove("serverNames")
                realitySettings.remove("shortIds")
            }
            root.toString()
        } catch (e: Exception) {
            null
        }
    }

    private fun injectTunInbound(configJson: String, tunFd: Int): String {
        val root = org.json.JSONObject(configJson)
        val inbounds = root.optJSONArray("inbounds") ?: org.json.JSONArray()
        var hasTunInbound = false
        for (i in 0 until inbounds.length()) {
            val inbound = inbounds.optJSONObject(i) ?: continue
            if (inbound.optString("tag") == "tun-in") {
                hasTunInbound = true
                inbound.put("protocol", "tun")
                inbound.put("listen", "127.0.0.1")
                inbound.put("port", 10809)
                inbound.put("settings", org.json.JSONObject().apply {
                    put("fd", tunFd)
                    put("mtu", 1420)
                    put("stack", "system")
                })
                break
            }
        }

        if (!hasTunInbound) {
            val tunInbound = org.json.JSONObject().apply {
                put("tag", "tun-in")
                put("protocol", "tun")
                put("listen", "127.0.0.1")
                put("port", 10809)
                put("settings", org.json.JSONObject().apply {
                    put("fd", tunFd)
                    put("mtu", 1420)
                    put("stack", "system")
                })
            }
            inbounds.put(tunInbound)
        }

        root.put("inbounds", inbounds)

        val routing = root.optJSONObject("routing") ?: org.json.JSONObject().also { root.put("routing", it) }
        val rules = routing.optJSONArray("rules") ?: org.json.JSONArray().also { routing.put("rules", it) }

        var hasTunRule = false
        for (i in 0 until rules.length()) {
            val rule = rules.optJSONObject(i) ?: continue
            val inboundTag = rule.optJSONArray("inboundTag") ?: continue
            for (j in 0 until inboundTag.length()) {
                if (inboundTag.optString(j) == "tun-in") {
                    hasTunRule = true
                    break
                }
            }
            if (hasTunRule) break
        }

        if (!hasTunRule) {
            val tunRule = org.json.JSONObject().apply {
                put("type", "field")
                put("inboundTag", org.json.JSONArray().put("tun-in"))
                put("outboundTag", "proxy")
            }
            rules.put(tunRule)
        }

        return root.toString()
    }
    
    /**
     * Запускает VPN через нативный XRay-core
     * 
     * @param vpnService Android VpnService для создания TUN интерфейса
     * @param xrayConfigJson XRay нативная JSON конфигурация (не sing-box!)
     * @param onTunCreated Callback для передачи созданного TUN дескриптора
     */
    private var sessionName: String = "GRANI"

    fun startVpn(
        vpnService: GraniVpnService,
        xrayConfigJson: String,
        onTunCreated: (ParcelFileDescriptor) -> Unit,
        mtu: Int? = null,
        session: String? = null
    ) {
        vpnServiceRef = vpnService
        lastTunMtu = (mtu ?: 1420).coerceIn(1280, 1500)
        if (!session.isNullOrBlank()) sessionName = session
        val tunMtu = lastTunMtu
        synchronized(vpnStartLock) {
            if (isRunning) {
                Log.w(TAG, "startVpn: VPN уже запущен")
                return
            }
            if (xrayThread?.isAlive == true) {
                Log.w(TAG, "startVpn: поток XRay уже активен")
                return
            }
            if (vpnStartInProgress) {
                Log.w(TAG, "startVpn: запуск уже выполняется")
                return
            }
            vpnStartInProgress = true
        }
        try {
            Log.d(TAG, "startVpn: Начало запуска нативного XRay, MTU=$tunMtu")
            Log.d(TAG, "startVpn: Длина конфигурации: ${xrayConfigJson.length}")
            Log.d(TAG, "startVpn: Превью конфигурации: ${VpnLogRedaction.previewRedacted(xrayConfigJson, 200)}")
            
            // 1. Создаем TUN интерфейс через Android VpnService
            var builder = vpnService.Builder()
                .setSession(sessionName)
                .addAddress("10.0.0.2", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("1.1.1.1")
                .addDnsServer("9.9.9.9")
                .setMtu(tunMtu)
            // Split tunnel: исключаем выбранные пользователем приложения из VPN
            builder = SplitTunnelHelper.applySplitTunnel(builder, context)
            // Защита от self-capture: сокеты самого приложения/libXray не должны попадать
            // в созданный TUN, иначе outbound к Xray-серверу может зациклиться или зависнуть.
            if (Build.VERSION.SDK_INT >= VERSION_CODES.LOLLIPOP &&
                SplitTunnelPrefs.getMode(context) != SplitTunnelPrefs.MODE_INCLUDE
            ) {
                try {
                    builder.addDisallowedApplication(context.packageName)
                    Log.i(TAG, "startVpn: own package excluded from VPN (${context.packageName})")
                } catch (e: Exception) {
                    Log.w(TAG, "startVpn: own package VPN exclusion failed: ${e.message}")
                }
            }
            builder = applyControlPlaneRouteExclusions(builder, xrayConfigJson)
            // Явно разрешаем IPv4 — обеспечивает корректный routing при reconnect
            if (Build.VERSION.SDK_INT >= VERSION_CODES.LOLLIPOP) {
                builder.allowFamily(OsConstants.AF_INET)
            }
            // setUnderlyingNetworks(null) — VPN работает по текущей сети; важно при reconnect на dual-SIM / WiFi+cellular
            if (Build.VERSION.SDK_INT >= VERSION_CODES.LOLLIPOP_MR1) {
                builder.setUnderlyingNetworks(null)
            }
            val t0 = System.currentTimeMillis()
            vpnInterface = establishOnMainThread(builder)
            
            if (vpnInterface == null) {
                throw IllegalStateException("Не удалось создать TUN интерфейс")
            }
            
            Log.i(TAG, "[DIAG] TUN создан, t=${System.currentTimeMillis() - t0}ms от начала startVpn, FD=${vpnInterface!!.fd}")
            // Даём ядру время применить маршруты к новому TUN (важно при reconnect: иначе трафик может не попадать в новый интерфейс).
            val postEstablishDelayMs = 300L
            Thread.sleep(postEstablishDelayMs)
            Log.d(TAG, "[DIAG] после establish() пауза ${postEstablishDelayMs}ms выполнена")
            logIpRouteDiagnostic()
            Log.i(TAG, "[DIAG] onTunCreated вызывается (перед запуском tun2socks/libXray)")
            onTunCreated(vpnInterface!!)
            val dialerReady = registerDialerController(vpnService)
            if (!dialerReady) {
                throw IllegalStateException("DialerController/protectFd registration failed")
            }
            initDnsForLibXray(xrayConfigJson)

            // 2. Используем входной конфиг как есть.
            // Для libXray 25.x inbound protocol "tun" может отсутствовать, и принудительная
            // инъекция tun-in ломает запуск с ошибкой "unknown config id: tun".
            val effectiveConfig = xrayConfigJson
            logEffectiveOutboundDiagnostics(effectiveConfig)
            
            // 3. Запускаем XRay-core в отдельном потоке
            xrayThread = Thread {
                try {
                    Log.d(TAG, "startVpn [Thread]: Начало выполнения в потоке XRay")
                    Log.d(TAG, "startVpn [Thread]: Проверка доступности libXray...")
                    Log.d(TAG, "startVpn [Thread]: isAvailable() = ${isAvailable()}")
                    Log.d(TAG, "startVpn [Thread]: libXrayClass = ${libXrayClass?.name}")
                    Log.d(TAG, "startVpn [Thread]: runXray legacy3=${runXrayLegacyThreeArg != null} newFile=${runXraySingleArg != null && newXrayRunRequestMethod != null}")
                    
                    if (isAvailable() && libXrayClass != null) {
                        // Используем Java API из libXray.aar
                        // КРИТИЧНО: libXray ожидает base64-encoded JSON, fallback на обычный JSON при ошибке
                        Log.d(TAG, "startVpn [Thread]: Использование libXray Java API")
                        Log.d(TAG, "startVpn [Thread]: Длина конфигурации (JSON): ${effectiveConfig.length}")
                        Log.d(TAG, "startVpn [Thread]: Конфигурация (JSON, первые 200 символов): ${effectiveConfig.take(200)}...")
                        Log.d(TAG, "startVpn [Thread]: Конфигурация (JSON, последние 100 символов): ...${effectiveConfig.takeLast(100)}")
                        
                        // Проверяем, что конфигурация не пустая
                        if (effectiveConfig.isBlank()) {
                            throw IllegalStateException("Конфигурация XRay пуста")
                        }
                        
                        // Проверяем, что это валидный JSON
                        var isValidJson = false
                        try {
                            org.json.JSONObject(effectiveConfig)
                            Log.d(TAG, "startVpn [Thread]: Конфигурация является валидным JSON")
                            isValidJson = true
                        } catch (e: Exception) {
                            Log.w(TAG, "startVpn [Thread]: Предупреждение - конфигурация может быть невалидным JSON: ${e.message}")
                            // Пробуем как JSONArray
                            try {
                                org.json.JSONArray(effectiveConfig)
                                Log.d(TAG, "startVpn [Thread]: Конфигурация является валидным JSONArray")
                                isValidJson = true
                            } catch (e2: Exception) {
                                Log.e(TAG, "startVpn [Thread]: Конфигурация не является валидным JSON: ${e2.message}")
                                throw IllegalStateException("Конфигурация XRay не является валидным JSON: ${e2.message}")
                            }
                        }
                        
                        if (!isValidJson) {
                            throw IllegalStateException("Конфигурация XRay не является валидным JSON")
                        }
                        
                        val datDir = context.filesDir.absolutePath
                        lastConfigFile?.let {
                            if (it.exists()) {
                                it.delete()
                            }
                        }
                        val safeSession = sessionName.replace(Regex("[^A-Za-z0-9_.-]"), "_")
                        val configFile = java.io.File(context.cacheDir, "xray-config-$safeSession.json")
                        configFile.writeText(effectiveConfig)
                        lastConfigFile = configFile
                        try {
                            initXrayMethod?.invoke(null, datDir)
                        } catch (e: Exception) {
                            Log.w(TAG, "startVpn [Thread]: initXray failed/non-critical: ${e.message}")
                        }
                        Log.d(TAG, "startVpn [Thread]: datDir=$datDir")
                        Log.d(TAG, "startVpn [Thread]: configPath=${configFile.absolutePath}")
                        Log.i(
                            TAG,
                            "[CORRELATION] libXray_run_begin vpn_session=$sessionName (same id as TUN notification session; filter logcat by this string)",
                        )
                        Log.d(TAG, "startVpn [Thread]: Вызов runXray (файл конфига)...")
                        val libXrayStartTime = System.currentTimeMillis()
                        isRunning = true
                        var result = invokeRunXrayForFileConfig(datDir, configFile.absolutePath)
                            ?: throw IllegalStateException("invokeRunXrayForFileConfig: нет подходящего API")
                        val libXrayElapsed = System.currentTimeMillis() - libXrayStartTime
                        Log.i(TAG, "[DIAG] libXray runXray завершён за ${libXrayElapsed}ms")
                        Log.d(TAG, "startVpn [Thread]: Тип результата: ${result?.javaClass?.simpleName}")
                        Log.d(TAG, "startVpn [Thread]: Результат (первые 200 символов): ${result?.toString()?.take(200)}...")
                        
                        // runXray обычно блокирует поток до stopXray(). Если он вернул строку сразу,
                        // проверяем её как возможную ошибку старта.
                        if (result is String) {
                            Log.d(TAG, "startVpn [Thread]: Результат является String, длина: ${result.length}")
                            try {
                                val decodedBytes = try {
                                    android.util.Base64.decode(result, android.util.Base64.NO_WRAP)
                                } catch (e: IllegalArgumentException) {
                                    Log.w(TAG, "startVpn [Thread]: Результат не является base64, пробуем как обычный JSON")
                                    null
                                }
                                
                                val decodedResult = if (decodedBytes != null) {
                                    String(decodedBytes, Charsets.UTF_8)
                                } else {
                                    result // Используем исходную строку, если не base64
                                }
                                
                                Log.d(TAG, "startVpn [Thread]: Декодированный результат (длина: ${decodedResult.length}): $decodedResult")
                                
                                val resultJson = org.json.JSONObject(decodedResult)
                                val success = resultJson.optBoolean("success", false)
                                var startSucceeded = success
                                val error = resultJson.optString("error", null)
                                val message = resultJson.optString("message", null)
                                
                                Log.d(TAG, "startVpn [Thread]: Парсинг JSON результата:")
                                Log.d(TAG, "startVpn [Thread]:   - success: $success")
                                Log.d(TAG, "startVpn [Thread]:   - error: $error")
                                Log.d(TAG, "startVpn [Thread]:   - message: $message")
                                
                                if (!startSucceeded && isRunning) {
                                    val errorMsg = error ?: message ?: "Unknown error"
                                    Log.e(TAG, "startVpn [Thread]: libXray вернул ошибку: $errorMsg")

                                    if (errorMsg.contains("serverNames", ignoreCase = true)) {
                                        val fallbackConfig = stripRealityArrayFields(effectiveConfig)
                                        if (!fallbackConfig.isNullOrBlank() && fallbackConfig != effectiveConfig) {
                                            Log.w(TAG, "startVpn [Thread]: retry without serverNames/shortIds for REALITY")
                                            configFile.writeText(fallbackConfig)
                                            isRunning = true
                                            val fallbackResult = invokeRunXrayForFileConfig(
                                                datDir,
                                                configFile.absolutePath,
                                            )
                                                ?: throw IllegalStateException("invokeRunXrayForFileConfig fallback null")
                                            val fallbackJson = decodeLibXrayResult(fallbackResult)
                                            val fallbackSuccess = fallbackJson?.optBoolean("success", false) == true
                                            val fallbackError = fallbackJson?.optString("error", null)
                                            if (fallbackSuccess) {
                                                Log.i(TAG, "startVpn [Thread]: libXray успешно запущен без serverNames/shortIds")
                                                startSucceeded = true
                                            } else {
                                                Log.e(
                                                    TAG,
                                                    "startVpn [Thread]: retry без serverNames не удался: ${fallbackError ?: "Unknown error"}"
                                                )
                                            }
                                        }
                                    }

                                    throw IllegalStateException("libXray не смог запуститься: $errorMsg")
                                }
                                
                                Log.i(TAG, "startVpn [Thread]: libXray runXray вернул success/normal stop")
                            } catch (e: Exception) {
                                if (e is IllegalStateException) {
                                    throw e
                                }
                                Log.e(TAG, "startVpn [Thread]: Ошибка декодирования/парсинга результата libXray: ${e.message}")
                                Log.e(TAG, "startVpn [Thread]: Stack trace:", e)
                                Log.d(TAG, "startVpn [Thread]: Исходный результат: $result")
                                
                                // Если не удалось декодировать, пробуем интерпретировать как строку
                                val resultString = result?.toString() ?: ""
                                if (resultString.contains("success") || resultString.contains("error")) {
                                    Log.w(TAG, "startVpn [Thread]: Результат может быть уже декодированным JSON")
                                    // Пробуем распарсить как обычный JSON
                                    try {
                                        Log.d(TAG, "startVpn [Thread]: Попытка парсинга как обычного JSON...")
                                        val resultJson = org.json.JSONObject(resultString)
                                        val success = resultJson.optBoolean("success", false)
                                        val error = resultJson.optString("error", null)
                                        
                                        Log.d(TAG, "startVpn [Thread]: Парсинг успешен, success: $success, error: $error")
                                        
                                        if (!success) {
                                            val errorMsg = error ?: "Unknown error"
                                            Log.e(TAG, "startVpn [Thread]: libXray вернул ошибку в JSON: $errorMsg")
                                            throw IllegalStateException("libXray не смог запуститься: $errorMsg")
                                        }
                                        
                                        Log.i(TAG, "startVpn [Thread]: libXray успешно запущен (из обычного JSON)")
                                        isRunning = true
                                    } catch (e2: Exception) {
                                        Log.e(TAG, "startVpn [Thread]: Ошибка парсинга результата как JSON: ${e2.message}")
                                        Log.e(TAG, "startVpn [Thread]: Stack trace:", e2)
                                        throw IllegalStateException("libXray вернул неожиданный формат результата: ${e2.message}")
                                    }
                                } else {
                                    throw IllegalStateException("libXray вернул не-JSON результат: ${resultString.take(180)}")
                                }
                            }
                        } else {
                            throw IllegalStateException(
                                "libXray вернул неожиданный тип результата: ${result?.javaClass?.simpleName ?: "null"}"
                            )
                        }
                    } else {
                        // НЕ используем JNI fallback - он не работает из-за несоответствия имен
                        val errorMsg = buildString {
                            append("libXray Java API недоступен. ")
                            append("isAvailable()=${isAvailable()}, ")
                            append("libXrayClass=${libXrayClass?.name}, ")
                            append("legacy3=${runXrayLegacyThreeArg != null}, ")
                            append("newFile=${runXraySingleArg != null && newXrayRunRequestMethod != null}")
                        }
                        Log.e(TAG, "startVpn [Thread]: $errorMsg")
                        throw IllegalStateException(errorMsg)
                    }
                    
                    Log.d(TAG, "startVpn [Thread]: XRay поток запущен, isRunning=$isRunning")
                    
                    // Ждем пока VPN работает
                    var iterationCount = 0
                    while (isRunning) {
                        iterationCount++
                        if (iterationCount % 10 == 0) {
                            Log.d(TAG, "startVpn [Thread]: VPN работает, итерация $iterationCount")
                        }
                        
                        if (!isXrayRunning()) {
                            Log.w(TAG, "startVpn [Thread]: XRay остановился, завершаем поток (итерация $iterationCount)")
                            break
                        }
                        Thread.sleep(1000)
                    }
                    
                    Log.d(TAG, "startVpn [Thread]: Поток XRay завершен, isRunning=$isRunning")
                    
                } catch (e: Exception) {
                    Log.e(TAG, "startVpn [Thread]: Критическая ошибка в потоке XRay: ${e.message}", e)
                    Log.e(TAG, "startVpn [Thread]: Stack trace:", e)
                    isRunning = false
                }
            }
            Log.d(TAG, "startVpn: Запуск потока XRay...")
            xrayThread?.start()
            
            // Ожидание инициализации: опрос isXrayRunning() каждые 200 ms, макс. 1.5 с (сокращено для быстрого подключения)
            val pollIntervalMs = 200L
            val maxWaitMs = 1500L
            var waited = 0L
            if (isRunningMethod != null) {
                while (waited < maxWaitMs) {
                    Thread.sleep(pollIntervalMs)
                    waited += pollIntervalMs
                    if (isXrayRunning()) {
                        Log.d(TAG, "startVpn: XRay готов через ${waited}ms")
                        break
                    }
                }
                if (waited >= maxWaitMs) {
                    Log.d(TAG, "startVpn: Ожидание инициализации XRay (таймаут ${maxWaitMs}ms), продолжаем")
                }
            } else {
                Thread.sleep(1000)
                Log.d(TAG, "startVpn: Метод проверки состояния недоступен, ждём 1 с")
            }
            
            Log.d(TAG, "startVpn: isRunning флаг: $isRunning")
            Log.i(TAG, "startVpn: Нативный XRay VPN успешно запущен (isRunning=$isRunning)")
            
        } catch (e: Exception) {
            Log.e(TAG, "startVpn: Критическая ошибка: ${e.message}", e)
            isRunning = false
            cleanup()
            throw e
        } finally {
            synchronized(vpnStartLock) {
                vpnStartInProgress = false
            }
        }
    }
    
    /**
     * Останавливает VPN
     */
    fun stopVpn(closeTun: Boolean = true) {
        try {
            Log.d(TAG, "stopVpn: Начало остановки нативного XRay")

            val nativeRunning = try {
                isXrayRunning()
            } catch (_: Exception) {
                false
            }
            if (!isRunning && !nativeRunning) {
                Log.d(TAG, "stopVpn: VPN уже остановлен (flag/native=false)")
                if (closeTun) {
                    cleanup()
                }
                return
            }

            isRunning = false

            // Останавливаем XRay
            try {
                if (isAvailable() && libXrayClass != null && stopXrayMethod != null) {
                    stopXrayMethod!!.invoke(null)
                    Log.d(TAG, "stopVpn: XRay остановлен через Java API")
                } else {
                    Log.w(TAG, "stopVpn: libXray Java API недоступен, не удалось остановить XRay")
                }
            } catch (e: Exception) {
                Log.w(TAG, "stopVpn: Ошибка остановки XRay: ${e.message}")
            }
            
            // Ждем завершения потока
            xrayThread?.join(2000)
            xrayThread = null
            resetDnsForLibXray()
            
            // Закрываем TUN интерфейс только в полном stop.
            if (closeTun) {
                cleanup()
            }

            lastConfigFile?.let {
                if (it.exists()) {
                    it.delete()
                }
            }
            lastConfigFile = null
            dialerControllerRef = null
            
            Log.i(TAG, "stopVpn: Нативный XRay VPN остановлен close_tun=$closeTun")
            
        } catch (e: Exception) {
            Log.e(TAG, "stopVpn: Ошибка при остановке: ${e.message}", e)
        }
    }

    /**
     * Остановка только libXray (без закрытия TUN) — используется для упорядоченного teardown.
     */
    fun stopCoreOnly() {
        stopVpn(closeTun = false)
    }
    
    /**
     * Проверяет, запущен ли XRay
     */
    private fun isXrayRunning(): Boolean {
        return try {
            val method = isRunningMethod
            if (isAvailable() && libXrayClass != null && method != null) {
                val state = method.invoke(null)
                // getXrayState() может возвращать разные типы, обрабатываем
                when (state) {
                    is Boolean -> state
                    is String -> state.isNotEmpty() && state.lowercase() != "stopped"
                    is Int -> state != 0
                    else -> false
                }
            } else {
                Log.w(TAG, "isXrayRunning: state method unavailable")
                false
            }
        } catch (e: Exception) {
            Log.w(TAG, "isXrayRunning: Ошибка проверки: ${e.message}")
            false
        }
    }
    
    /**
     * Проверяет, запущен ли VPN
     */
    fun isRunning(): Boolean {
        return isRunning && isXrayRunning()
    }

    /**
     * Повторная подача JSON в libXray без остановки TUN/tun2socks (смена routing/DNS policy).
     * Поведение зависит от версии libXray; при ошибке возвращает false (без teardown).
     */
    fun tryApplyHotRoutingConfig(configJson: String): Boolean {
        synchronized(hotSwapLock) {
            if (!isRunning()) {
                Log.w(TAG, "tryApplyHotRoutingConfig: ядро не в состоянии running")
                return false
            }
            if (!isAvailable() || libXrayClass == null) {
                Log.w(TAG, "tryApplyHotRoutingConfig: libXray недоступен")
                return false
            }
            if (newXrayRunFromJSONRequestMethod == null || runXrayFromJSONNativeMethod == null) {
                Log.w(TAG, "tryApplyHotRoutingConfig: нет newXrayRunFromJSONRequest/runXrayFromJSON")
                return false
            }
            return try {
                org.json.JSONObject(configJson)
                val datDir = context.filesDir.absolutePath
                Log.i(TAG, "tryApplyHotRoutingConfig: runXrayFromJSON (len=${configJson.length})")
                val wire = newXrayRunFromJSONRequestMethod!!.invoke(null, datDir, configJson) as String
                val result = runXrayFromJSONNativeMethod!!.invoke(null, wire)
                val j = decodeLibXrayResult(result)
                if (j == null) {
                    Log.w(TAG, "tryApplyHotRoutingConfig: ответ не JSON — считаем успехом")
                    return true
                }
                val success = j.optBoolean("success", false)
                val err = j.optString("error", "")
                val msg = j.optString("message", "")
                if (success || (err.isEmpty() && msg.isEmpty())) {
                    Log.i(TAG, "tryApplyHotRoutingConfig: ok success=$success")
                    return true
                }
                Log.e(TAG, "tryApplyHotRoutingConfig: libXray вернул ошибку: ${err.ifEmpty { msg }}")
                false
            } catch (e: Exception) {
                Log.e(TAG, "tryApplyHotRoutingConfig: ${e.message}", e)
                false
            }
        }
    }
    
    /**
     * Очистка ресурсов
     */
    private fun cleanup() {
        try {
            vpnInterface?.close()
            vpnInterface = null
        } catch (e: Exception) {
            Log.w(TAG, "cleanup: Ошибка очистки ресурсов: ${e.message}")
        }
    }

    /**
     * Закрывает только TUN, не останавливает Xray (для soft disconnect — Xray остаётся живым).
     */
    fun cleanupTunOnly(
        source: String = "unknown",
        reason: String = "unspecified",
        allowWhileRunning: Boolean = false,
    ) {
        tunCleanupExecutor.execute {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                Log.w(TAG, "cleanupTunOnly: unexpected main-thread executor execution")
            }
            if (isRunning && !allowWhileRunning) {
                Log.w(
                    TAG,
                    "cleanupTunOnly: skip while core running source=$source reason=$reason",
                )
                VpnNativeStateEmitter.emitRuntimeDiag(
                    "cleanup_tun_only",
                    mapOf(
                        "source" to source,
                        "reason" to reason,
                        "result" to "skipped_running",
                        "thread" to Thread.currentThread().name,
                    ),
                )
                return@execute
            }
            try {
                vpnInterface?.close()
                vpnInterface = null
                Log.i(
                    TAG,
                    "cleanupTunOnly: TUN closed source=$source reason=$reason allow_while_running=$allowWhileRunning thread=${Thread.currentThread().name}",
                )
                VpnNativeStateEmitter.emitRuntimeDiag(
                    "cleanup_tun_only",
                    mapOf(
                        "source" to source,
                        "reason" to reason,
                        "result" to "closed",
                        "allow_while_running" to allowWhileRunning,
                        "thread" to Thread.currentThread().name,
                    ),
                )
            } catch (e: Exception) {
                Log.w(TAG, "cleanupTunOnly: Ошибка закрытия TUN: ${e.message}")
                VpnNativeStateEmitter.emitRuntimeDiag(
                    "cleanup_tun_only",
                    mapOf(
                        "source" to source,
                        "reason" to reason,
                        "result" to "error",
                        "error" to (e.message ?: "unknown"),
                        "thread" to Thread.currentThread().name,
                    ),
                )
            }
        }
    }

    /**
     * Xray запущен (для проверки reconnect — можно ли переиспользовать без полного рестарта).
     */
    fun isXrayAlive(): Boolean = isXrayRunning()

    /**
     * Reconnect: создаёт новый TUN и вызывает onTunCreated. Xray уже должен быть запущен.
     */
    fun attachTun(onTunCreated: (ParcelFileDescriptor) -> Unit) {
        val vpnService = vpnServiceRef ?: throw IllegalStateException("vpnServiceRef не сохранён")
        val ctx = vpnService.applicationContext
        Log.i(TAG, "attachTun: создание нового TUN для reconnect (MTU=$lastTunMtu)")
        var builder = vpnService.Builder()
            .setSession(sessionName)
            .addAddress("10.0.0.2", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("9.9.9.9")
            .setMtu(lastTunMtu)
        builder = SplitTunnelHelper.applySplitTunnel(builder, ctx)
        if (Build.VERSION.SDK_INT >= VERSION_CODES.LOLLIPOP &&
            SplitTunnelPrefs.getMode(ctx) != SplitTunnelPrefs.MODE_INCLUDE
        ) {
            try {
                builder.addDisallowedApplication(ctx.packageName)
                Log.i(TAG, "attachTun: own package excluded from VPN (${ctx.packageName})")
            } catch (e: Exception) {
                Log.w(TAG, "attachTun: own package VPN exclusion failed: ${e.message}")
            }
        }
        lastConfigFile?.takeIf { it.exists() }?.let {
            builder = applyControlPlaneRouteExclusions(builder, it.readText())
        }
        if (Build.VERSION.SDK_INT >= VERSION_CODES.LOLLIPOP) {
            builder.allowFamily(OsConstants.AF_INET)
        }
        if (Build.VERSION.SDK_INT >= VERSION_CODES.LOLLIPOP_MR1) {
            builder.setUnderlyingNetworks(null)
        }
        vpnInterface = establishOnMainThread(builder)
            ?: throw IllegalStateException("Не удалось создать TUN для reconnect")
        Log.i(TAG, "attachTun: TUN создан, FD=${vpnInterface!!.fd}")
        Thread.sleep(100)
        onTunCreated(vpnInterface!!)
    }
    
    /**
     * Получает статистику трафика (если поддерживается)
     */
    fun getTrafficStats(): Map<String, Long> {
        return try {
            // TODO: Реализовать получение статистики от XRay
            mapOf(
                "rx_bytes" to 0L,
                "tx_bytes" to 0L
            )
        } catch (e: Exception) {
            Log.w(TAG, "getTrafficStats: Ошибка получения статистики: ${e.message}")
            mapOf(
                "rx_bytes" to 0L,
                "tx_bytes" to 0L
            )
        }
    }
}
