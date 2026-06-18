package com.granivpn.mobile

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CountDownLatch
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
        private const val TUN2SOCKS_BIND_TIMEOUT_MS = 5000L
        private const val HY2_PORT_READY_TIMEOUT_MS = 6000L
        private const val HY2_BINARY_NAME = "libhysteria2.so"
    }

    private val stopped = AtomicBoolean(true)
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
    private var monitorThread: Thread? = null

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
        Log.i(TAG, "start: binary=${binary.absolutePath} config=${configFile.absolutePath} mtu=$effectiveMtu")

        try {
            startProcess(binary, configFile, onFailure)
            if (!waitForSocksPort(HY2_PORT_READY_TIMEOUT_MS)) {
                throw IllegalStateException("Hysteria SOCKS port did not open")
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
        try {
            tun2socksService?.stopTun2Socks("hysteria2", "confirmed_stop", true)
        } catch (e: Exception) {
            Log.w(TAG, "stopTun2Socks IPC failed: ${e.message}")
        }
        tun2socksService = null
        tun2socksConnection?.let {
            try {
                context.unbindService(it)
            } catch (e: Exception) {
                Log.w(TAG, "unbindService failed: ${e.message}")
            }
        }
        tun2socksConnection = null
        try {
            vpnInterface?.close()
        } catch (_: Exception) {
        }
        vpnInterface = null
        try {
            process?.destroy()
            if (process?.waitFor(1200, TimeUnit.MILLISECONDS) != true) {
                process?.destroyForcibly()
            }
        } catch (e: Exception) {
            Log.w(TAG, "process stop failed: ${e.message}")
        }
        process = null
        Log.i(TAG, "stopped")
    }

    fun isRunning(): Boolean = running && process?.isAlive == true

    private fun resolveBinary(): File =
        File(context.applicationInfo.nativeLibraryDir, HY2_BINARY_NAME)

    private fun startProcess(binary: File, configFile: File, onFailure: (String) -> Unit) {
        val pb = ProcessBuilder(binary.absolutePath, "client", "-c", configFile.absolutePath)
        pb.directory(context.filesDir)
        pb.redirectErrorStream(true)
        val proc = pb.start()
        process = proc
        Thread {
            try {
                BufferedReader(InputStreamReader(proc.inputStream)).useLines { lines ->
                    lines.forEach { line ->
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
            if (!stopped.get()) {
                running = false
                onFailure("hysteria_process_exited:$code")
            }
        }.apply {
            name = "hy2-exit-watcher"
            start()
        }
    }

    private fun waitForSocksPort(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline && !stopped.get()) {
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress("127.0.0.1", HY2_SOCKS_PORT), 250)
                    return true
                }
            } catch (_: Exception) {
                Thread.sleep(100)
            }
        }
        return false
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
        return establishOnMainThread(builder) ?: throw IllegalStateException("failed to establish HY2 TUN")
    }

    private fun establishOnMainThread(builder: VpnService.Builder): ParcelFileDescriptor? {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return builder.establish()
        }
        val latch = CountDownLatch(1)
        var result: ParcelFileDescriptor? = null
        Handler(Looper.getMainLooper()).post {
            result = builder.establish()
            latch.countDown()
        }
        return if (latch.await(15, TimeUnit.SECONDS)) result else null
    }

    private fun startTun2SocksBridge(
        tunFd: ParcelFileDescriptor,
        mtu: Int,
        onFailure: (String) -> Unit,
    ) {
        val pfdDup = ParcelFileDescriptor.dup(tunFd.fileDescriptor)
        val latch = CountDownLatch(1)
        var remote: ITun2SocksProcess? = null
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: android.os.IBinder?) {
                remote = ITun2SocksProcess.Stub.asInterface(service)
                latch.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                tun2socksService = null
                if (!stopped.get()) onFailure("hy2_tun2socks_service_disconnected")
            }
        }
        tun2socksConnection = conn
        val intent = Intent(context, Tun2SocksProcessService::class.java)
        val bindFlags = Context.BIND_AUTO_CREATE or
            (if (Build.VERSION.SDK_INT >= 34) Context.BIND_NOT_FOREGROUND else 0)
        context.bindService(intent, conn, bindFlags)
        if (!latch.await(TUN2SOCKS_BIND_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            pfdDup.close()
            throw IllegalStateException("hy2_tun2socks_bind_timeout")
        }
        tun2socksService = remote
        remote?.startTun2Socks(pfdDup, mtu, "127.0.0.1", HY2_SOCKS_PORT)
        Log.i(TAG, "tun2socks attached to HY2 SOCKS 127.0.0.1:$HY2_SOCKS_PORT")
    }

    private fun startMonitor(onFailure: (String) -> Unit) {
        monitorThread = Thread {
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
        }.apply {
            name = "hy2-health"
            start()
        }
    }

    private fun writeClientConfig(rawConfig: String): File {
        val yaml = buildYaml(rawConfig)
        val file = File(context.cacheDir, "hysteria2-client.yaml")
        file.writeText(yaml)
        Log.i(TAG, "generated HY2 config: ${VpnLogRedaction.previewRedacted(yaml, 240)}")
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
        return renderYaml(server, port, auth, sni, insecure, obfs)
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
        return renderYaml(server, port, auth, sni, insecure, obfs)
    }

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
        sb.append("socks5:\n")
        sb.append("  listen: 127.0.0.1:").append(HY2_SOCKS_PORT).append('\n')
        sb.append("  disableUDP: false\n")
        return sb.toString()
    }

    private fun ensureLocalSocks(yaml: String): String {
        if (yaml.contains(Regex("(?m)^socks5:"))) return yaml
        return yaml.trimEnd() + "\n\nsocks5:\n  listen: 127.0.0.1:$HY2_SOCKS_PORT\n  disableUDP: false\n"
    }

    private fun yamlQuote(value: String): String =
        "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}
