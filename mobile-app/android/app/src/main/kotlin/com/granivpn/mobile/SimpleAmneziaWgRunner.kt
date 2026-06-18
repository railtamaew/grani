package com.granivpn.mobile

import android.content.Context
import android.util.Log
import org.amnezia.awg.backend.GoBackend
import org.amnezia.awg.backend.Tunnel
import org.amnezia.awg.config.Config
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.nio.charset.StandardCharsets

object SimpleAmneziaWgRunner {
    private const val TAG = "SimpleAmneziaWG"
    private const val PREFS_NAME = "grani_vpn_prefs"
    private const val DOMAIN_IP_CACHE_KEY = "split_tunnel_domain_ip_cache_v1"
    private const val DOMAIN_IP_CACHE_TTL_MS = 6L * 60L * 60L * 1000L
    private const val MAX_DIRECT_DOMAIN_IPS = 16
    private const val MAX_ALLOWED_IPS_CIDRS = 640
    private const val FORCE_GRANIWG_FULL_TUNNEL = false
    private val lock = Any()
    private var backend: GoBackend? = null
    private var lastAppContext: Context? = null
    private val tunnel = SimpleTunnel("grani-awg")

    fun connect(context: Context, configText: String): Tunnel.State = synchronized(lock) {
        val appContext = context.applicationContext
        lastAppContext = appContext
        val normalizedConfig = normalizeAmneziaObfuscation(configText)
        val configWithSplitTunnel = applySplitTunnelPrefs(appContext, normalizedConfig)
        Log.i(TAG, "connect: final config summary ${summarizeConfig(configWithSplitTunnel)}")
        val parsedConfig = ByteArrayInputStream(configWithSplitTunnel.toByteArray(StandardCharsets.UTF_8)).use { input ->
            Config.parse(input)
        }
        val activeBackend = backend ?: GoBackend(appContext).also { backend = it }
        Log.i(TAG, "connect: parsed AmneziaWG config, peers=${parsedConfig.peers.size}")
        val state = activeBackend.setState(tunnel, Tunnel.State.UP, parsedConfig)
        if (state == Tunnel.State.UP) {
            NativeVpnRuntimeState.markAwgExpectedUp(appContext, true)
            GraniAwgNotificationService.start(appContext)
            NativeVpnRuntimeState.notifyQuickTile(appContext)
        } else {
            NativeVpnRuntimeState.markAwgExpectedUp(appContext, false)
        }
        state
    }

    private fun normalizeAmneziaObfuscation(configText: String): String {
        val lines = configText.lines().toMutableList()
        val interfaceIndex = lines.indexOfFirst { it.trim().equals("[Interface]", ignoreCase = true) }
        if (interfaceIndex < 0) {
            Log.w(TAG, "obfuscation normalize: [Interface] section not found")
            return configText
        }

        var interfaceEnd = interfaceIndex + 1
        while (interfaceEnd < lines.size && !lines[interfaceEnd].trim().startsWith("[")) {
            interfaceEnd++
        }

        val presentKeys = mutableSetOf<String>()
        for (i in interfaceIndex + 1 until interfaceEnd) {
            val trimmed = lines[i].trim()
            if (trimmed.isBlank() || trimmed.startsWith("#") || !trimmed.contains("=")) continue
            presentKeys.add(trimmed.substringBefore("=").trim().lowercase())
        }

        val defaults = listOf(
            "Jc" to "4",
            "Jmin" to "5",
            "Jmax" to "60",
            "H1" to "1",
            "H2" to "2",
            "H3" to "3",
            "H4" to "4",
        )
        val missing = defaults.filter { (key, _) -> !presentKeys.contains(key.lowercase()) }
        if (missing.isEmpty()) {
            Log.i(TAG, "obfuscation normalize: all default J/H params present")
            return configText
        }

        val insertAt = findInterfaceInsertIndex(lines, interfaceIndex, interfaceEnd)
        lines.addAll(insertAt, missing.map { (key, value) -> "$key = $value" })
        Log.i(TAG, "obfuscation normalize: added ${missing.joinToString(",") { it.first }}")
        return lines.joinToString("\n")
    }

    private fun findInterfaceInsertIndex(lines: List<String>, interfaceIndex: Int, interfaceEnd: Int): Int {
        val preferredKeys = setOf(
            "mtu", "jmax", "jmin", "jc", "h4", "h3", "h2", "h1",
            "s4", "s3", "s2", "s1", "i5", "i4", "i3", "i2", "i1",
        )
        for (i in interfaceEnd - 1 downTo interfaceIndex + 1) {
            val key = lines[i].trim().substringBefore("=", "").trim().lowercase()
            if (preferredKeys.contains(key)) return i + 1
        }
        return interfaceEnd
    }

    private fun summarizeConfig(configText: String): String {
        val interestingKeys = setOf(
            "address", "dns", "mtu", "jc", "jmin", "jmax", "s1", "s2", "s3", "s4",
            "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5", "endpoint",
            "allowedips", "persistentkeepalive", "excludedapplications", "includedapplications",
            "presharedkey",
        )
        val secretKeys = setOf("presharedkey")
        return configText
            .lines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") && it.contains("=") }
            .mapNotNull { line ->
                val key = line.substringBefore("=").trim()
                val normalizedKey = key.lowercase()
                when {
                    secretKeys.contains(normalizedKey) -> "$key = (present)"
                    interestingKeys.contains(normalizedKey) -> line
                    else -> null
                }
            }
            .joinToString("; ")
            .ifBlank { "(empty-summary)" }
    }

    private fun applySplitTunnelPrefs(context: Context, configText: String): String {
        if (FORCE_GRANIWG_FULL_TUNNEL) {
            val packages = SplitTunnelPrefs.getSelectedPackages(context).size
            val domains = SplitTunnelPrefs.getDirectDomains(context).size
            if (packages > 0 || domains > 0) {
                Log.w(
                    TAG,
                    "split tunnel: ignored for GRANIwg stability packages=$packages direct_domains=$domains",
                )
            } else {
                Log.i(TAG, "split tunnel: disabled for GRANIwg full-tunnel runtime")
            }
            return configText
        }
        val appSplitConfig = applyAppSplitTunnelPrefs(context, configText)
        return applyDirectDomainBypass(context, appSplitConfig)
    }

    private fun applyAppSplitTunnelPrefs(context: Context, configText: String): String {
        val packages = SplitTunnelPrefs.getSelectedPackages(context)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
        if (packages.isEmpty()) {
            Log.i(TAG, "split tunnel apps: no selected apps")
            return configText
        }

        val mode = SplitTunnelPrefs.getMode(context)
        val key = if (mode == SplitTunnelPrefs.MODE_INCLUDE) {
            "IncludedApplications"
        } else {
            "ExcludedApplications"
        }
        val line = "$key = ${packages.joinToString(", ")}"
        val lines = configText.lines().toMutableList()
        val interfaceIndex = lines.indexOfFirst { it.trim().equals("[Interface]", ignoreCase = true) }
        if (interfaceIndex < 0) {
            Log.w(TAG, "split tunnel apps: [Interface] section not found")
            return configText
        }

        lines.removeAll {
            val trimmed = it.trim()
            trimmed.startsWith("ExcludedApplications", ignoreCase = true) ||
                trimmed.startsWith("IncludedApplications", ignoreCase = true)
        }
        var insertAt = interfaceIndex + 1
        while (insertAt < lines.size && !lines[insertAt].trim().startsWith("[")) {
            insertAt++
        }
        lines.add(insertAt, line)
        Log.i(TAG, "split tunnel apps: applied mode=$mode selected_packages=${packages.size}")
        return lines.joinToString("\n")
    }

    private fun applyDirectDomainBypass(context: Context, configText: String): String {
        val domains = SplitTunnelPrefs.getDirectDomains(context).distinct()
        if (domains.isEmpty()) {
            Log.i(TAG, "split tunnel domains: no direct domains")
            return configText
        }

        val resolvedIps = resolveDirectDomainIps(context, domains)
        if (resolvedIps.isEmpty()) {
            Log.w(TAG, "split tunnel domains: skipped, no resolved IPv4 domains=${domains.size}")
            return configText
        }
        if (resolvedIps.size > MAX_DIRECT_DOMAIN_IPS) {
            Log.w(
                TAG,
                "split tunnel domains: truncating resolved IPv4 ips from ${resolvedIps.size} to $MAX_DIRECT_DOMAIN_IPS",
            )
        }
        val ips = resolvedIps.take(MAX_DIRECT_DOMAIN_IPS).sorted()
        val bypassCidrs = ipv4FullTunnelMinus(ips)
        if (bypassCidrs.isEmpty() || bypassCidrs.size > MAX_ALLOWED_IPS_CIDRS) {
            Log.w(
                TAG,
                "split tunnel domains: skipped, cidr_count=${bypassCidrs.size} domains=${domains.size} ips=${ips.size}",
            )
            return configText
        }

        val lines = configText.lines().toMutableList()
        val peerIndex = lines.indexOfFirst { it.trim().equals("[Peer]", ignoreCase = true) }
        if (peerIndex < 0) {
            Log.w(TAG, "split tunnel domains: [Peer] section not found")
            return configText
        }
        var sectionEnd = peerIndex + 1
        while (sectionEnd < lines.size && !lines[sectionEnd].trim().startsWith("[")) {
            sectionEnd++
        }
        val allowedIndex = (peerIndex + 1 until sectionEnd).firstOrNull {
            lines[it].trim().startsWith("AllowedIPs", ignoreCase = true)
        }
        if (allowedIndex == null) {
            Log.w(TAG, "split tunnel domains: AllowedIPs not found")
            return configText
        }
        val currentAllowed = lines[allowedIndex].substringAfter("=", "").trim()
        if (!currentAllowed.split(',').map { it.trim() }.contains("0.0.0.0/0")) {
            Log.w(TAG, "split tunnel domains: skipped, config is not IPv4 full-tunnel allowed_ips=$currentAllowed")
            return configText
        }

        val preserved = currentAllowed.split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != "0.0.0.0/0" }
        val nextAllowed = (bypassCidrs + preserved).distinct().joinToString(", ")
        lines[allowedIndex] = "AllowedIPs = $nextAllowed"
        Log.i(
            TAG,
            "split tunnel domains: applied domains=${domains.size} resolved_ipv4=${ips.size} cidrs=${bypassCidrs.size}",
        )
        return lines.joinToString("\n")
    }

    private fun resolveDirectDomainIps(context: Context, domains: List<String>): List<String> {
        val now = System.currentTimeMillis()
        val cache = readDomainIpCache(context)
        val result = linkedSetOf<String>()
        var cacheHits = 0
        var cacheMisses = 0
        for (domain in domains) {
            for (host in hostVariants(domain)) {
                val cached = cache.optJSONObject(host)
                val expiresAt = cached?.optLong("expires_at", 0L) ?: 0L
                if (cached != null && expiresAt > now) {
                    val ips = cached.optJSONArray("ips") ?: JSONArray()
                    for (i in 0 until ips.length()) {
                        ips.optString(i).takeIf { isPublicIpv4(it) }?.let { result.add(it) }
                    }
                    cacheHits++
                    continue
                }
                cacheMisses++
                val resolved = resolveHostIpv4(host)
                if (resolved.isNotEmpty()) {
                    cache.put(host, JSONObject().apply {
                        put("expires_at", now + DOMAIN_IP_CACHE_TTL_MS)
                        put("ips", JSONArray(resolved))
                    })
                    result.addAll(resolved)
                }
            }
        }
        writeDomainIpCache(context, cache)
        Log.i(
            TAG,
            "split tunnel domains: resolve domains=${domains.size} ipv4=${result.size} cache_hits=$cacheHits cache_misses=$cacheMisses",
        )
        return result.toList()
    }

    private fun hostVariants(domain: String): List<String> {
        val d = domain.trim().lowercase().removePrefix("*.")
        if (d.isBlank()) return emptyList()
        return if (d.startsWith("www.")) {
            listOf(d)
        } else {
            listOf(d, "www.$d")
        }
    }

    private fun resolveHostIpv4(host: String): List<String> {
        return try {
            InetAddress.getAllByName(host)
                .filterIsInstance<Inet4Address>()
                .mapNotNull { it.hostAddress }
                .filter { isPublicIpv4(it) }
                .distinct()
        } catch (e: Exception) {
            Log.w(TAG, "split tunnel domains: resolve failed host=$host err=${e.javaClass.simpleName}:${e.message}")
            emptyList()
        }
    }

    private fun readDomainIpCache(context: Context): JSONObject {
        return try {
            val raw = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getString(DOMAIN_IP_CACHE_KEY, null)
            if (raw.isNullOrBlank()) JSONObject() else JSONObject(raw)
        } catch (_: Exception) {
            JSONObject()
        }
    }

    private fun writeDomainIpCache(context: Context, cache: JSONObject) {
        try {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(DOMAIN_IP_CACHE_KEY, cache.toString())
                .apply()
        } catch (e: Exception) {
            Log.w(TAG, "split tunnel domains: cache write failed ${e.message}")
        }
    }

    private fun ipv4FullTunnelMinus(excludedIps: List<String>): List<String> {
        val excluded = excludedIps.mapNotNull { ipv4ToLong(it) }.distinct().sorted()
        if (excluded.isEmpty()) return listOf("0.0.0.0/0")
        val ranges = mutableListOf<Pair<Long, Long>>()
        var start = 0L
        val max = 0xffffffffL
        for (ip in excluded) {
            if (ip > start) ranges.add(start to ip - 1)
            if (ip == max) {
                start = max + 1
                break
            }
            start = ip + 1
        }
        if (start <= max) ranges.add(start to max)
        return ranges.flatMap { rangeToCidrs(it.first, it.second) }
    }

    private fun rangeToCidrs(rangeStart: Long, rangeEnd: Long): List<String> {
        val out = mutableListOf<String>()
        var start = rangeStart
        while (start <= rangeEnd) {
            val remaining = rangeEnd - start + 1
            var block = if (start == 0L) 1L shl 32 else start and -start
            while (block > remaining) block = block shr 1
            val prefix = 32 - log2PowerOfTwo(block)
            out.add("${longToIpv4(start)}/$prefix")
            start += block
        }
        return out
    }

    private fun log2PowerOfTwo(value: Long): Int {
        var v = value
        var n = 0
        while (v > 1) {
            v = v shr 1
            n++
        }
        return n
    }

    private fun ipv4ToLong(ip: String): Long? {
        val parts = ip.split('.')
        if (parts.size != 4) return null
        var out = 0L
        for (part in parts) {
            val v = part.toIntOrNull() ?: return null
            if (v !in 0..255) return null
            out = (out shl 8) or v.toLong()
        }
        return out and 0xffffffffL
    }

    private fun longToIpv4(value: Long): String {
        return listOf(24, 16, 8, 0).joinToString(".") { shift ->
            ((value shr shift) and 0xff).toString()
        }
    }

    private fun isPublicIpv4(ip: String): Boolean {
        val v = ipv4ToLong(ip) ?: return false
        fun inRange(cidrBase: String, prefix: Int): Boolean {
            val base = ipv4ToLong(cidrBase) ?: return false
            val mask = if (prefix == 0) 0L else (0xffffffffL shl (32 - prefix)) and 0xffffffffL
            return (v and mask) == (base and mask)
        }
        return !(
            inRange("0.0.0.0", 8) ||
                inRange("10.0.0.0", 8) ||
                inRange("100.64.0.0", 10) ||
                inRange("127.0.0.0", 8) ||
                inRange("169.254.0.0", 16) ||
                inRange("172.16.0.0", 12) ||
                inRange("192.0.0.0", 24) ||
                inRange("192.0.2.0", 24) ||
                inRange("192.168.0.0", 16) ||
                inRange("198.18.0.0", 15) ||
                inRange("198.51.100.0", 24) ||
                inRange("203.0.113.0", 24) ||
                inRange("224.0.0.0", 4) ||
                inRange("240.0.0.0", 4)
            )
    }

    fun disconnect(context: Context? = null) = synchronized(lock) {
        val appContext = context?.applicationContext ?: lastAppContext
        val activeBackend = backend ?: appContext?.let { GoBackend(it).also { backend = it } } ?: return@synchronized
        try {
            activeBackend.setState(tunnel, Tunnel.State.DOWN, null)
            Log.i(TAG, "disconnect: AmneziaWG tunnel down")
        } catch (e: Exception) {
            Log.w(TAG, "disconnect: failed", e)
        } finally {
            appContext?.let {
                NativeVpnRuntimeState.markAwgExpectedUp(it, false)
                GraniAwgNotificationService.stop(it)
                NativeVpnRuntimeState.notifyQuickTile(it)
            }
        }
    }

    fun isUp(): Boolean = synchronized(lock) {
        backend?.getState(tunnel) == Tunnel.State.UP
    }

    private class SimpleTunnel(private val tunnelName: String) : Tunnel {
        override fun getName(): String = tunnelName

        override fun onStateChange(newState: Tunnel.State) {
            Log.i(TAG, "tunnel state changed: $newState")
        }
    }
}
