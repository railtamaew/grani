package com.granivpn.mobile

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.ArrayDeque
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Hysteria2 runtime without libbox/gomobile.
 *
 * Architecture:
 * Android VpnService TUN -> remote tun2socks process -> local SOCKS5 ->
 * official hysteria Android executable -> HY2 server.
 */
class Hysteria2ProcessWrapper(private val context: Context) {
    companion object {
        private const val TAG = "Hy2Process"
        private const val HY2_SOCKS_PORT = 10818
        private const val TUN_MTU = 1280
        // A separate :tun2socks process can be cold-started by Android. Five
        // seconds was shorter than a legitimate process start on translated
        // or heavily loaded devices and caused a false HY2 failure.
        private const val TUN2SOCKS_BIND_TIMEOUT_MS = 45_000L
        private const val TUN2SOCKS_READY_TIMEOUT_MS = 4_000L
        // The native client opens its SOCKS listener only after the initial
        // QUIC handshake. Six seconds was not enough on loaded/translated
        // devices (and on slow mobile paths), so the app killed a healthy
        // process just before it became ready. This remains an upper bound:
        // waitForSocksPort returns immediately on the native ready signal.
        private const val HY2_PORT_READY_TIMEOUT_MS = 30_000L
        private const val HY2_DNS_TIMEOUT_MS = 4_000L
        private const val HY2_BINARY_NAME = "libhysteria2.so"
        private const val HY2_DNS_CACHE = "grani_hy2_dns_cache"
    }

    private val stopped = AtomicBoolean(true)
    private val socksListenerReady = AtomicBoolean(false)
    @Volatile
    private var running = false
    @Volatile
    private var process: Process? = null
    @Volatile
    private var vpnInterface: ParcelFileDescriptor? = null
    @Volatile
    private var tun2socksService: ITun2SocksProcess? = null
    private var tun2socksConnection: ServiceConnection? = null
    @Volatile
    private var tun2socksBindLatch: CountDownLatch? = null
    @Volatile
    private var tun2socksBindFailure: String? = null
    @Volatile
    private var monitorThread: Thread? = null
    private val outputLock = Any()
    private val recentOutput = ArrayDeque<String>()
    @Volatile
    private var processExitCode: Int? = null

    fun start(
        vpnService: GraniVpnService,
        rawConfig: String,
        mtu: Int?,
        session: String,
        onFailure: (String) -> Unit,
    ) {
        if (!stopped.compareAndSet(true, false)) {
            Log.w(TAG, "start: already running")
            return
        }
        val effectiveMtu = (mtu ?: TUN_MTU).coerceIn(1200, 1500)
        val binary = resolveBinary()
        if (!binary.exists()) {
            stopped.set(true)
            throw IllegalStateException("Hysteria binary not found: ${binary.absolutePath}")
        }
        val configFile = writeClientConfig(rawConfig)
        socksListenerReady.set(false)
        Log.i(TAG, "start: binary=${binary.absolutePath} config=${configFile.absolutePath} mtu=$effectiveMtu")

        try {
            // Start the isolated bridge process in parallel with the HY2 QUIC
            // handshake. On a normal phone it is ready before SOCKS opens; on
            // a cold/loaded device we wait for the same bind instead of
            // destroying a healthy Hysteria connection and retrying it all.
            prepareTun2SocksBridge(onFailure)
            startProcess(binary, configFile, onFailure)
            if (!waitForSocksPort(HY2_PORT_READY_TIMEOUT_MS)) {
                throw IllegalStateException(buildStartupFailureReason())
            }
            val pfd = createTun(vpnService, session, effectiveMtu)
            vpnInterface = pfd
            startTun2SocksBridge(pfd, effectiveMtu, onFailure)
            running = true
            startMonitor(onFailure)
        } catch (e: Exception) {
            stop()
            throw e
        }
    }

    fun stop() {
        if (!stopped.compareAndSet(false, true)) return
        running = false
        monitorThread?.interrupt()
        monitorThread = null

        // Detach runtime ownership before performing any potentially blocking
        // cross-process teardown. Closing the TUN first makes Android remove
        // the system VPN immediately and also wakes the native tun2socks read
        // loop. The previous order waited for the remote worker while the TUN
        // was still live, so the coordinator observed an active VPN, timed out
        // and launched a redundant hard cleanup.
        val bridge = tun2socksService
        val bridgeConnection = tun2socksConnection
        val tun = vpnInterface
        val hy2Process = process
        tun2socksService = null
        tun2socksConnection = null
        tun2socksBindLatch = null
        tun2socksBindFailure = null
        vpnInterface = null
        process = null

        try {
            tun?.close()
        } catch (e: Exception) {
            Log.w(TAG, "TUN close failed: ${e.message}")
        }
        try {
            hy2Process?.destroy()
            if (hy2Process?.waitFor(1200, TimeUnit.MILLISECONDS) != true) {
                hy2Process?.destroyForcibly()
            }
        } catch (e: Exception) {
            Log.w(TAG, "process stop failed: ${e.message}")
        }
        try {
            bridge?.stopTun2Socks("hysteria2", "confirmed_stop", true)
        } catch (e: Exception) {
            Log.w(TAG, "stopTun2Socks IPC failed: ${e.message}")
        }
        bridgeConnection?.let {
            try {
                context.unbindService(it)
            } catch (e: Exception) {
                Log.w(TAG, "unbindService failed: ${e.message}")
            }
        }
        try {
            context.stopService(Intent(context, Tun2SocksProcessService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "stopService failed: ${e.message}")
        }
        Log.i(TAG, "stopped")
    }

    fun isRunning(): Boolean = running && process?.isAlive == true

    fun isTunnelActiveOrClosing(): Boolean {
        if (running || process?.isAlive == true) return true
        return vpnInterface != null || tun2socksService != null || tun2socksConnection != null
    }

    fun getTunState(): String {
        return when {
            running && process?.isAlive == true -> "running"
            vpnInterface != null -> "closing"
            tun2socksService != null || tun2socksConnection != null -> "bridge_closing"
            else -> "closed"
        }
    }

    /** Sanitized snapshot for support/backend correlation; never includes config secrets. */
    fun diagnosticSnapshot(): Map<String, Any?> {
        return linkedMapOf(
            "process_alive" to (process?.isAlive == true),
            "runtime_running" to running,
            "stopped" to stopped.get(),
            "tun_state" to getTunState(),
            "bridge_bound" to (tun2socksService != null),
            "process_exit_code" to processExitCode,
            "last_output" to latestOutputLine(),
        )
    }

    private fun resolveBinary(): File =
        File(context.applicationInfo.nativeLibraryDir, HY2_BINARY_NAME)

    private fun startProcess(binary: File, configFile: File, onFailure: (String) -> Unit) {
        val pb = ProcessBuilder(binary.absolutePath, "client", "-c", configFile.absolutePath)
        pb.directory(context.filesDir)
        pb.redirectErrorStream(true)
        val proc = pb.start()
        process = proc
        processExitCode = null
        Thread {
            try {
                BufferedReader(InputStreamReader(proc.inputStream)).useLines { lines ->
                    lines.forEach { line ->
                        rememberOutput(line)
                        if (line.contains("SOCKS5 server listening", ignoreCase = true)) {
                            socksListenerReady.set(true)
                        }
                        Log.i(TAG, "[hysteria] $line")
                    }
                }
            } catch (e: Exception) {
                if (!stopped.get()) Log.w(TAG, "log reader failed: ${e.message}")
            }
        }.apply {
            name = "hy2-log-reader"
            start()
        }
        Thread {
            val code = proc.waitFor()
            processExitCode = code
            if (!stopped.get()) {
                running = false
                onFailure(buildProcessExitReason(code))
            }
        }.apply {
            name = "hy2-exit-watcher"
            start()
        }
    }

    private fun waitForSocksPort(timeoutMs: Long): Boolean {
        val startedAt = android.os.SystemClock.elapsedRealtime()
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline && !stopped.get()) {
            if (process?.isAlive == false) {
                Log.e(
                    TAG,
                    "SOCKS listener process exited after " +
                        "${android.os.SystemClock.elapsedRealtime() - startedAt}ms " +
                        "code=$processExitCode detail=${latestOutputLine()}",
                )
                return false
            }
            // Hysteria emits this line only after net.Listen succeeded. On a
            // small subset of Android reconnects a Java loopback probe can
            // still report ECONNREFUSED for the rest of its timeout even
            // though the listener is alive. Trust the native listener signal
            // as an equivalent readiness proof and avoid destroying a healthy
            // process only to make the automatic retry succeed.
            if (socksListenerReady.get()) {
                Log.i(
                    TAG,
                    "SOCKS listener ready from native process signal in " +
                        "${android.os.SystemClock.elapsedRealtime() - startedAt}ms",
                )
                return true
            }
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress("127.0.0.1", HY2_SOCKS_PORT), 250)
                    socksListenerReady.set(true)
                    Log.i(
                        TAG,
                        "SOCKS listener ready from loopback probe in " +
                            "${android.os.SystemClock.elapsedRealtime() - startedAt}ms",
                    )
                    return true
                }
            } catch (_: Exception) {
                Thread.sleep(100)
            }
        }
        Log.e(
            TAG,
            "SOCKS listener timeout after " +
                "${android.os.SystemClock.elapsedRealtime() - startedAt}ms " +
                "process_alive=${process?.isAlive == true} detail=${latestOutputLine()}",
        )
        return socksListenerReady.get()
    }

    private fun rememberOutput(line: String) {
        val cleaned = sanitizeProcessLine(line)
        if (cleaned.isBlank()) return
        synchronized(outputLock) {
            recentOutput.addLast(cleaned)
            while (recentOutput.size > 12) {
                recentOutput.removeFirst()
            }
        }
    }

    private fun latestOutputLine(): String? {
        return synchronized(outputLock) {
            recentOutput.lastOrNull()
        }
    }

    private fun buildProcessExitReason(code: Int): String {
        val detail = latestOutputLine()
        return if (detail.isNullOrBlank()) {
            "hysteria_process_exited:$code"
        } else {
            "hysteria_process_exited:$code:$detail"
        }
    }

    private fun buildStartupFailureReason(): String {
        val code = processExitCode
        val detail = latestOutputLine()
        if (code != null) {
            return buildProcessExitReason(code)
        }
        return if (detail.isNullOrBlank()) {
            "hysteria_socks_port_not_open"
        } else {
            "hysteria_socks_port_not_open:$detail"
        }
    }

    private fun sanitizeProcessLine(line: String): String {
        val noAnsi = line.replace(Regex("\u001B\\[[;\\d]*m"), "")
        val compact = noAnsi
            .replace(Regex("\\s+"), " ")
            .replace("\"auth\"\\s*:\\s*\"[^\"]+\"".toRegex(), "\"auth\":\"***\"")
            .replace("\"password\"\\s*:\\s*\"[^\"]+\"".toRegex(), "\"password\":\"***\"")
            .trim()
        return compact.take(260)
    }

    private fun createTun(
        vpnService: VpnService,
        session: String,
        mtu: Int,
    ): ParcelFileDescriptor {
        var builder = vpnService.Builder()
            .setSession(session)
            .addAddress("10.0.0.2", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("9.9.9.9")
            .setMtu(mtu)
        builder = SplitTunnelHelper.applySplitTunnel(builder, context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP &&
            SplitTunnelPrefs.getMode(context) != SplitTunnelPrefs.MODE_INCLUDE
        ) {
            try {
                builder.addDisallowedApplication(context.packageName)
                Log.i(TAG, "createTun: own package excluded from VPN (${context.packageName})")
            } catch (e: Exception) {
                Log.w(TAG, "createTun: own package VPN exclusion failed: ${e.message}")
            }
            builder.allowFamily(OsConstants.AF_INET)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            builder.setUnderlyingNetworks(null)
        }
        return establishTun(builder) ?: throw IllegalStateException("failed to establish HY2 TUN")
    }

    private fun establishTun(builder: VpnService.Builder): ParcelFileDescriptor? {
        // Builder.establish() is a Binder call and does not require the Android
        // main looper. Posting it to main and waiting with a shorter timeout is
        // unsafe: under load the call can finish after the waiter has already
        // returned null, leaking a live system VPN that the app immediately
        // reports as failed. Hysteria start already runs on a worker thread, so
        // make the call there and use the returned descriptor as the only
        // success signal.
        val startedAt = android.os.SystemClock.elapsedRealtime()
        val result = builder.establish()
        Log.i(
            TAG,
            "createTun: establish completed in " +
                "${android.os.SystemClock.elapsedRealtime() - startedAt}ms " +
                "success=${result != null}",
        )
        return result
    }

    private fun prepareTun2SocksBridge(onFailure: (String) -> Unit) {
        if (tun2socksService != null || tun2socksConnection != null) return
        val latch = CountDownLatch(1)
        tun2socksBindLatch = latch
        tun2socksBindFailure = null
        val bindStartedAt = android.os.SystemClock.elapsedRealtime()
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: android.os.IBinder?) {
                if (stopped.get() || tun2socksConnection !== this) {
                    Log.i(TAG, "ignore stale HY2 tun2socks binder callback")
                    latch.countDown()
                    return
                }
                tun2socksService = ITun2SocksProcess.Stub.asInterface(service)
                Log.i(
                    TAG,
                    "tun2socks service bound in " +
                        "${android.os.SystemClock.elapsedRealtime() - bindStartedAt}ms",
                )
                latch.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                tun2socksService = null
                if (!stopped.get()) onFailure("hy2_tun2socks_service_disconnected")
            }

            override fun onNullBinding(name: ComponentName?) {
                tun2socksBindFailure = "hy2_tun2socks_null_binding"
                latch.countDown()
            }

            override fun onBindingDied(name: ComponentName?) {
                tun2socksService = null
                tun2socksBindFailure = "hy2_tun2socks_binding_died"
                latch.countDown()
                if (!stopped.get()) onFailure("hy2_tun2socks_binding_died")
            }
        }
        tun2socksConnection = conn
        val intent = Intent(context, Tun2SocksProcessService::class.java)
        // Bound-only ownership ties the isolated worker to this VPN runtime.
        // A separate startService lifetime could leave a stale BadVPN process
        // after the client binding or activity task disappears.
        val bindFlags = Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT or Context.BIND_ABOVE_CLIENT
        if (!context.bindService(intent, conn, bindFlags)) {
            tun2socksConnection = null
            tun2socksBindFailure = "hy2_tun2socks_bind_rejected"
            latch.countDown()
            throw IllegalStateException("hy2_tun2socks_bind_rejected")
        }
        Log.i(TAG, "tun2socks service warmup requested")
    }

    private fun startTun2SocksBridge(
        tunFd: ParcelFileDescriptor,
        mtu: Int,
        onFailure: (String) -> Unit,
    ) {
        prepareTun2SocksBridge(onFailure)
        val pfdDup = ParcelFileDescriptor.dup(tunFd.fileDescriptor)
        val latch = tun2socksBindLatch
        if (tun2socksService == null &&
            (latch == null || !latch.await(TUN2SOCKS_BIND_TIMEOUT_MS, TimeUnit.MILLISECONDS))
        ) {
            pfdDup.close()
            throw IllegalStateException("hy2_tun2socks_bind_timeout")
        }
        tun2socksBindFailure?.let { reason ->
            pfdDup.close()
            throw IllegalStateException(reason)
        }
        val remote = tun2socksService ?: run {
            pfdDup.close()
            throw IllegalStateException("hy2_tun2socks_binder_missing")
        }
        val accepted = try {
            if (stopped.get()) throw IllegalStateException("hy2_tun2socks_start_cancelled")
            remote.startTun2Socks(pfdDup, mtu, "127.0.0.1", HY2_SOCKS_PORT)
        } finally {
            // The remote Binder transaction owns a duplicated descriptor.
            try {
                pfdDup.close()
            } catch (_: Exception) { }
        }
        if (!accepted) {
            throw IllegalStateException("hy2_tun2socks_rejected_stale_tun")
        }
        val readyDeadline = android.os.SystemClock.elapsedRealtime() + TUN2SOCKS_READY_TIMEOUT_MS
        while (!stopped.get() && android.os.SystemClock.elapsedRealtime() < readyDeadline) {
            if (remote.isTun2SocksRunning) break
            Thread.sleep(50)
        }
        if (stopped.get()) throw IllegalStateException("hy2_tun2socks_start_cancelled")
        if (!remote.isTun2SocksRunning) {
            throw IllegalStateException("hy2_tun2socks_not_running")
        }
        Log.i(TAG, "tun2socks attached to HY2 SOCKS 127.0.0.1:$HY2_SOCKS_PORT")
    }

    private fun startMonitor(onFailure: (String) -> Unit) {
        monitorThread = Thread {
            try {
                while (!stopped.get()) {
                    Thread.sleep(1200)
                    if (process?.isAlive != true) {
                        running = false
                        if (!stopped.get()) onFailure("hysteria_process_dead")
                        return@Thread
                    }
                    val bridgeAlive = try {
                        tun2socksService?.isTun2SocksRunning() == true
                    } catch (_: Exception) {
                        false
                    }
                    if (!bridgeAlive) {
                        running = false
                        if (!stopped.get()) onFailure("hy2_tun2socks_dead")
                        return@Thread
                    }
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                Log.i(TAG, "hy2-health monitor interrupted; stopped=${stopped.get()}")
            }
        }.apply {
            name = "hy2-health"
            start()
        }
    }

    private fun writeClientConfig(rawConfig: String): File {
        val yaml = buildYaml(rawConfig)
        val file = File(context.cacheDir, "hysteria2-client.yaml")
        file.writeText(yaml)
        Log.i(TAG, "generated HY2 config: file=${file.name} bytes=${file.length()}")
        return file
    }

    private fun buildYaml(rawConfig: String): String {
        val trimmed = rawConfig.trim()
        if (trimmed.startsWith("{")) {
            return buildYamlFromSingBoxJson(trimmed)
        }
        if (trimmed.startsWith("hysteria2://") || trimmed.startsWith("hy2://")) {
            return buildYamlFromUri(trimmed)
        }
        if (trimmed.contains("\n") && trimmed.contains("server:")) {
            return ensureLocalSocks(trimmed)
        }
        throw IllegalArgumentException("unsupported Hysteria2 config format")
    }

    private fun buildYamlFromSingBoxJson(jsonText: String): String {
        val root = org.json.JSONObject(jsonText)
        val outbound = root.optJSONArray("outbounds")
            ?.let { arr ->
                (0 until arr.length())
                    .mapNotNull { arr.optJSONObject(it) }
                    .firstOrNull { it.optString("type") == "hysteria2" }
            }
            ?: throw IllegalArgumentException("hysteria2 outbound not found")
        val server = outbound.optString("server")
        val port = outbound.optInt("server_port", 443)
        val auth = outbound.optString("password", outbound.optString("auth"))
        val tls = outbound.optJSONObject("tls")
        val sni = tls?.optString("server_name", tls.optString("sni", server)) ?: server
        val insecure = tls?.optBoolean("insecure", false) ?: false
        val obfs = outbound.optJSONObject("obfs")
        return renderYaml(resolveServerHost(server), port, auth, sni, insecure, obfs)
    }

    private fun buildYamlFromUri(uriText: String): String {
        val uri = android.net.Uri.parse(uriText)
        val server = uri.host ?: throw IllegalArgumentException("HY2 URI host missing")
        val port = if (uri.port > 0) uri.port else 443
        val auth = uri.userInfo ?: ""
        val sni = uri.getQueryParameter("sni") ?: server
        val insecure = uri.getQueryParameter("insecure") == "1" ||
            uri.getQueryParameter("insecure")?.equals("true", ignoreCase = true) == true
        val obfsType = uri.getQueryParameter("obfs")
        val obfsPassword = uri.getQueryParameter("obfs-password")
        val obfs = if (!obfsType.isNullOrBlank() && !obfsPassword.isNullOrBlank()) {
            org.json.JSONObject().apply {
                put("type", obfsType)
                put("password", obfsPassword)
            }
        } else {
            null
        }
        return renderYaml(resolveServerHost(server), port, auth, sni, insecure, obfs)
    }

    /**
     * Resolve the transport endpoint through Android's underlying network before
     * the Go child process starts. Some vendor Android builds don't give a
     * native child process a usable DNS context while VPN state is changing;
     * the resolver can then hang before Hysteria opens its local SOCKS port.
     *
     * TLS still receives the original hostname as SNI, so certificate
     * verification and domain fronting semantics are unchanged. A successful
     * answer is cached only as a short transport fallback for the same host.
     */
    private fun resolveServerHost(server: String): String {
        val host = server.trim().removePrefix("[").removeSuffix("]")
        if (isIpLiteral(host)) return formatEndpointHost(host)

        val preferences = context.getSharedPreferences(HY2_DNS_CACHE, Context.MODE_PRIVATE)
        val cacheKey = "address_${host.lowercase(Locale.US)}"
        val executor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "hy2-android-dns").apply { isDaemon = true }
        }

        return try {
            val future = executor.submit<List<InetAddress>> {
                resolveThroughUnderlyingNetworks(host)
            }
            val addresses = future.get(HY2_DNS_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            val selected = addresses.firstOrNull { it is Inet4Address }
                ?: addresses.firstOrNull()
                ?: throw IllegalStateException("empty DNS answer")
            val address = selected.hostAddress
                ?.substringBefore('%')
                ?.takeIf { it.isNotBlank() }
                ?: throw IllegalStateException("empty DNS address")
            preferences.edit().putString(cacheKey, address).apply()
            Log.i(TAG, "HY2 endpoint resolved by Android: host=$host address=$address")
            formatEndpointHost(address)
        } catch (error: Throwable) {
            val cached = preferences.getString(cacheKey, null)?.takeIf { it.isNotBlank() }
            if (cached != null) {
                Log.w(
                    TAG,
                    "HY2 Android DNS failed; using cached endpoint: host=$host " +
                        "address=$cached error=${error.javaClass.simpleName}",
                )
                formatEndpointHost(cached)
            } else {
                Log.w(
                    TAG,
                    "HY2 Android DNS failed without cache; native fallback remains: " +
                        "host=$host error=${error.javaClass.simpleName}",
                )
                host
            }
        } finally {
            executor.shutdownNow()
        }
    }

    private fun resolveThroughUnderlyingNetworks(host: String): List<InetAddress> {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val candidates = LinkedHashSet<Network>()
        connectivity?.allNetworks?.forEach { network ->
            val capabilities = connectivity.getNetworkCapabilities(network) ?: return@forEach
            if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            ) {
                candidates.add(network)
            }
        }
        connectivity?.activeNetwork?.let(candidates::add)

        var lastError: Throwable? = null
        candidates.forEach { network ->
            try {
                val answer = network.getAllByName(host).toList()
                if (answer.isNotEmpty()) return answer
            } catch (error: Throwable) {
                lastError = error
            }
        }
        return try {
            InetAddress.getAllByName(host).toList()
        } catch (error: Throwable) {
            throw lastError ?: error
        }
    }

    private fun isIpLiteral(host: String): Boolean {
        if (host.contains(':')) return true
        val parts = host.split('.')
        return parts.size == 4 && parts.all { part ->
            part.toIntOrNull()?.let { it in 0..255 } == true
        }
    }

    private fun formatEndpointHost(host: String): String =
        if (host.contains(':') && !host.startsWith("[")) "[$host]" else host

    private fun renderYaml(
        server: String,
        port: Int,
        auth: String,
        sni: String,
        insecure: Boolean,
        obfs: org.json.JSONObject?,
    ): String {
        val sb = StringBuilder()
        sb.append("server: ").append(yamlQuote("$server:$port")).append('\n')
        sb.append("auth: ").append(yamlQuote(auth)).append('\n')
        sb.append("tls:\n")
        sb.append("  sni: ").append(yamlQuote(sni)).append('\n')
        sb.append("  insecure: ").append(insecure).append('\n')
        val type = obfs?.optString("type", "")?.trim().orEmpty()
        val password = obfs?.optString("password", "")?.trim().orEmpty()
        if (type.isNotEmpty() && password.isNotEmpty()) {
            sb.append("obfs:\n")
            sb.append("  type: ").append(yamlQuote(type)).append('\n')
            sb.append("  ").append(type).append(":\n")
            sb.append("    password: ").append(yamlQuote(password)).append('\n')
        }
        sb.append("quic:\n")
        sb.append("  disablePathMTUDiscovery: true\n")
        // Chrome QUIC parroting forces a 1250-byte Initial packet. Salamander
        // adds another 8 bytes, which exceeds common 1280-byte mobile paths
        // after IP/UDP headers and black-holes the handshake. The bundled GRANI
        // client starts QUIC at the RFC minimum (1200); keep parroting disabled
        // so the configured safe size is actually used.
        sb.append("  disableChromeParrot: true\n")
        sb.append("socks5:\n")
        sb.append("  listen: 127.0.0.1:").append(HY2_SOCKS_PORT).append('\n')
        sb.append("  disableUDP: false\n")
        return sb.toString()
    }

    private fun ensureLocalSocks(yaml: String): String {
        var result = ensureQuicSetting(
            yaml.trimEnd(),
            "disablePathMTUDiscovery",
            "true",
        )
        result = ensureQuicSetting(result, "disableChromeParrot", "true")
        if (!result.contains(Regex("(?m)^socks5:"))) {
            result += "\n\nsocks5:\n  listen: 127.0.0.1:$HY2_SOCKS_PORT\n  disableUDP: false"
        }
        return result.trimEnd() + "\n"
    }

    private fun ensureQuicSetting(yaml: String, key: String, value: String): String {
        val setting = Regex("(?m)^\\s{2}${Regex.escape(key)}:\\s*.*$")
        if (setting.containsMatchIn(yaml)) {
            return setting.replaceFirst(yaml, "  $key: $value")
        }
        val quicHeader = Regex("(?m)^quic:\\s*$")
        if (quicHeader.containsMatchIn(yaml)) {
            return quicHeader.replaceFirst(yaml, "quic:\n  $key: $value")
        }
        return yaml.trimEnd() + "\n\nquic:\n  $key: $value"
    }

    private fun yamlQuote(value: String): String =
        "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}
