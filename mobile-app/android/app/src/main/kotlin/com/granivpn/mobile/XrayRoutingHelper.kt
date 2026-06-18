package com.granivpn.mobile

import android.util.Log

/**
 * Инжектирует правила domain-based split tunnel в Xray routing.
 * Домены из списка маршрутизируются в direct (обход VPN).
 *
 * Полный pipeline: control-plane, режим DNS (performance/strict), публичный DoH,
 * отдельный outbound для speedtest, policy connIdle для proxy_speedtest.
 */
object XrayRoutingHelper {
    private const val TAG = "XrayRoutingHelper"
    private const val REALITY_STRICT_PORT = 2053
    private const val MOBILE_SINGLE_PORT_POLICY = true
    // Diagnostic 2026-05-12: allow UDP/443 end-to-end to test YouTube QUIC path.
    // If UDP churn returns, fix transport/routing selectively instead of blocking all QUIC.
    private const val GLOBAL_UDP_443_BLOCK_ENABLED = false
    private const val QUIC_BLOCK_MARKER = "quic_block_forced_v2_2026_05_08"
    // Diagnostic hard switch for "reference profile":
    // keep only base routing + mandatory control-plane direct bypass,
    // skip extra mutations (single-port/quic block/speedtest/policy tuning).
    private const val DIAG_MINIMAL_ROUTING_MODE = true

    /** Макс. одновременных соединений на endpoint (подсказка policy.levels). */
    const val POLICY_MAX_CONCURRENT_HINT = 32

    /**
     * Домены управляющего плана API — direct при активном VPN.
     */
    val CONTROL_PLANE_API_DOMAINS: List<String> = listOf(
        "api.granilink.com",
    )

    val CONTROL_PLANE_API_IPS: List<String> = listOf(
        "45.12.132.94",
    )

    /**
     * Публичные DoH/DoT хосты — в режиме performance идут в direct (не через VLESS).
     */
    val PUBLIC_DNS_OVER_TLS_HTTPS_DOMAINS: List<String> = listOf(
        "cloudflare-dns.com",
        "mozilla.cloudflare-dns.com",
        "chrome.cloudflare-dns.com",
        "dns.google",
        "dns11.quad9.net",
        "dns10.quad9.net",
        "dns9.quad9.net",
        "dns.quad9.net",
        "one.one.one.one",
    )

    /**
     * Домены Ookla / speedtest — отдельный outbound [OUTBOUND_SPEEDTEST].
     */
    val SPEEDTEST_DOMAIN_SUFFIXES: List<String> = listOf(
        "speedtest.net",
        "ookla.com",
        "ooklaserver.net",
        "cdnst.net",
        "speedtestcustom.com",
    )

    const val OUTBOUND_PROXY = "proxy"
    const val OUTBOUND_SPEEDTEST = "proxy_speedtest"

    private fun outboundPort(outbound: org.json.JSONObject): Int? {
        return try {
            val settings = outbound.optJSONObject("settings") ?: return null
            val vnext = settings.optJSONArray("vnext") ?: return null
            if (vnext.length() == 0) return null
            vnext.optJSONObject(0)?.optInt("port")
        } catch (_: Exception) {
            null
        }
    }

    private fun outboundAddress(outbound: org.json.JSONObject): String? {
        return try {
            val settings = outbound.optJSONObject("settings") ?: return null
            val vnext = settings.optJSONArray("vnext") ?: return null
            if (vnext.length() == 0) return null
            vnext.optJSONObject(0)?.optString("address")
        } catch (_: Exception) {
            null
        }
    }

    private fun outboundSecurity(outbound: org.json.JSONObject): String {
        val stream = outbound.optJSONObject("streamSettings") ?: return "none"
        return stream.optString("security", "none")
    }

    private fun hasRealityOutbound(configJson: String): Boolean {
        return try {
            val root = org.json.JSONObject(configJson)
            val outbounds = root.optJSONArray("outbounds") ?: return false
            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.optJSONObject(i) ?: continue
                val stream = outbound.optJSONObject("streamSettings") ?: continue
                val security = stream.optString("security", "")
                if (security.equals("reality", ignoreCase = true) || stream.has("realitySettings")) {
                    return true
                }
            }
            false
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Строгий режим для mobile-теста Reality:
     * - оставляем только proxy outbounds с портом 2053
     * - удаляем speedtest-спец outbound/rules, чтобы исключить смешанные пути
     */
    private fun enforceRealityStrictPort(configJson: String, strictPort: Int = REALITY_STRICT_PORT): String {
        return try {
            val root = org.json.JSONObject(configJson)
            val outbounds = root.optJSONArray("outbounds") ?: return configJson
            val kept = org.json.JSONArray()
            var keptProxyTag = false
            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.optJSONObject(i) ?: continue
                val protocol = outbound.optString("protocol").lowercase()
                val tag = outbound.optString("tag")
                if (protocol == "freedom" || protocol == "blackhole" || protocol == "dns") {
                    kept.put(outbound)
                    continue
                }
                val port = outboundPort(outbound)
                if (port == strictPort) {
                    kept.put(outbound)
                    if (tag == OUTBOUND_PROXY) {
                        keptProxyTag = true
                    }
                } else {
                    Log.i(
                        TAG,
                        "enforceRealityStrictPort: drop outbound tag=${tag.ifEmpty { "-" }} protocol=${protocol.ifEmpty { "-" }} port=${port ?: -1}",
                    )
                }
            }
            if (!keptProxyTag) {
                Log.w(TAG, "enforceRealityStrictPort: no proxy outbound on port=$strictPort; keep original config")
                return configJson
            }
            root.put("outbounds", kept)
            val routing = root.optJSONObject("routing")
            val rules = routing?.optJSONArray("rules")
            if (rules != null) {
                val filtered = org.json.JSONArray()
                for (i in 0 until rules.length()) {
                    val rule = rules.optJSONObject(i) ?: continue
                    val outboundTag = rule.optString("outboundTag")
                    if (outboundTag == OUTBOUND_SPEEDTEST) {
                        continue
                    }
                    filtered.put(rule)
                }
                routing.put("rules", filtered)
            }
            Log.i(TAG, "enforceRealityStrictPort: strict mode enabled port=$strictPort")
            root.toString()
        } catch (e: Exception) {
            Log.w(TAG, "enforceRealityStrictPort failed: ${e.message}")
            configJson
        }
    }

    /**
     * Строка для диагностического лога: tag/protocol/address:port/security.
     */
    fun describeEffectiveOutbounds(configJson: String): String {
        return try {
            val root = org.json.JSONObject(configJson)
            val outbounds = root.optJSONArray("outbounds") ?: return "none"
            val parts = mutableListOf<String>()
            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.optJSONObject(i) ?: continue
                val tag = outbound.optString("tag").ifEmpty { "-" }
                val protocol = outbound.optString("protocol").ifEmpty { "-" }
                val address = outboundAddress(outbound) ?: "-"
                val port = outboundPort(outbound)?.toString() ?: "-"
                val security = outboundSecurity(outbound)
                parts.add("$tag/$protocol/$address:$port/$security")
            }
            if (parts.isEmpty()) "none" else parts.joinToString(", ")
        } catch (_: Exception) {
            "parse_error"
        }
    }

    fun injectDirectDomains(configJson: String, domains: List<String>): String {
        if (domains.isEmpty()) return configJson
        return try {
            val json = org.json.JSONObject(configJson)
            val routing = json.optJSONObject("routing") ?: return configJson
            val rules = routing.optJSONArray("rules") ?: return configJson
            val insertAt = findSocksInsertIndex(rules)
            val newRules = org.json.JSONArray()
            for (i in 0 until insertAt) {
                newRules.put(rules.opt(i))
            }
            for (domain in domains) {
                val d = domain.trim().lowercase()
                if (d.isEmpty()) continue
                val rule = org.json.JSONObject()
                rule.put("type", "field")
                val domainArr = org.json.JSONArray()
                domainArr.put(d)
                domainArr.put("domain:$d")
                domainArr.put("full:$d")
                rule.put("domain", domainArr)
                rule.put("outboundTag", "direct")
                newRules.put(rule)
                Log.d(TAG, "injectDirectDomains: added rule for $d")
            }
            for (i in insertAt until rules.length()) {
                newRules.put(rules.opt(i))
            }
            routing.put("rules", newRules)
            json.toString()
        } catch (e: Exception) {
            Log.w(TAG, "injectDirectDomains failed: ${e.message}")
            configJson
        }
    }

    fun injectDirectIps(configJson: String, ips: List<String>): String {
        val cleaned = ips.map { it.trim() }.filter { it.isNotEmpty() }
        if (cleaned.isEmpty()) return configJson
        return try {
            val json = org.json.JSONObject(configJson)
            val routing = json.optJSONObject("routing") ?: return configJson
            val rules = routing.optJSONArray("rules") ?: return configJson
            val insertAt = findSocksInsertIndex(rules)
            val newRules = org.json.JSONArray()
            for (i in 0 until insertAt) {
                newRules.put(rules.opt(i))
            }
            val ipRule = org.json.JSONObject()
            ipRule.put("type", "field")
            val ipArr = org.json.JSONArray()
            for (ip in cleaned) {
                ipArr.put(ip)
            }
            ipRule.put("ip", ipArr)
            ipRule.put("outboundTag", "direct")
            newRules.put(ipRule)
            Log.d(TAG, "injectDirectIps: added rule for ${cleaned.size} ip(s)")
            for (i in insertAt until rules.length()) {
                newRules.put(rules.opt(i))
            }
            routing.put("rules", newRules)
            json.toString()
        } catch (e: Exception) {
            Log.w(TAG, "injectDirectIps failed: ${e.message}")
            configJson
        }
    }

    /**
     * Правила: домены speedtest → [OUTBOUND_SPEEDTEST], вставка перед правилом socks-in.
     */
    private fun injectSpeedtestDomainRules(configJson: String): String {
        return try {
            val json = org.json.JSONObject(configJson)
            val routing = json.optJSONObject("routing") ?: return configJson
            val rules = routing.optJSONArray("rules") ?: return configJson
            if (json.optJSONArray("outbounds") == null) return configJson
            val insertAt = findSocksInsertIndex(rules)
            val newRules = org.json.JSONArray()
            for (i in 0 until insertAt) {
                newRules.put(rules.opt(i))
            }
            val rule = org.json.JSONObject()
            rule.put("type", "field")
            val domainArr = org.json.JSONArray()
            for (suffix in SPEEDTEST_DOMAIN_SUFFIXES) {
                val s = suffix.trim().lowercase()
                if (s.isEmpty()) continue
                domainArr.put("domain:$s")
            }
            if (domainArr.length() == 0) return configJson
            rule.put("domain", domainArr)
            rule.put("outboundTag", OUTBOUND_SPEEDTEST)
            newRules.put(rule)
            Log.d(TAG, "injectSpeedtestDomainRules: added speedtest rule -> $OUTBOUND_SPEEDTEST")
            for (i in insertAt until rules.length()) {
                newRules.put(rules.opt(i))
            }
            routing.put("rules", newRules)
            json.toString()
        } catch (e: Exception) {
            Log.w(TAG, "injectSpeedtestDomainRules failed: ${e.message}")
            configJson
        }
    }

    /**
     * Временный diag-режим: глобально блокируем UDP/443 (QUIC).
     * Это форсирует fallback на TCP/TLS и устраняет mixed UDP dataplane path.
     */
    private fun injectQuicBlockRules(configJson: String): String {
        return try {
            val json = org.json.JSONObject(configJson)
            val outbounds = json.optJSONArray("outbounds") ?: return configJson
            var blockTag: String? = null
            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.optJSONObject(i) ?: continue
                val protocol = outbound.optString("protocol").lowercase()
                if (protocol == "blackhole") {
                    val existingTag = outbound.optString("tag")
                    if (existingTag.isNotEmpty()) {
                        blockTag = existingTag
                        break
                    }
                }
            }
            if (blockTag == null) {
                val fallbackTag = "blocked"
                val blackhole = org.json.JSONObject()
                blackhole.put("tag", fallbackTag)
                blackhole.put("protocol", "blackhole")
                blackhole.put("settings", org.json.JSONObject())
                outbounds.put(blackhole)
                blockTag = fallbackTag
                Log.i(TAG, "injectQuicBlockRules: created fallback blackhole outbound tag=$fallbackTag")
            }
            val routing = json.optJSONObject("routing") ?: return configJson
            val rules = routing.optJSONArray("rules") ?: return configJson
            val insertAt = findSocksInsertIndex(rules)
            val newRules = org.json.JSONArray()
            for (i in 0 until insertAt) {
                newRules.put(rules.opt(i))
            }
            val rule = org.json.JSONObject()
            rule.put("type", "field")
            rule.put("network", "udp")
            rule.put("port", "443")
            rule.put("outboundTag", blockTag)
            newRules.put(rule)
            Log.i(
                TAG,
                "injectQuicBlockRules: enabled global UDP/443 block via tag=$blockTag marker=$QUIC_BLOCK_MARKER",
            )
            for (i in insertAt until rules.length()) {
                newRules.put(rules.opt(i))
            }
            routing.put("rules", newRules)
            json.toString()
        } catch (e: Exception) {
            Log.w(TAG, "injectQuicBlockRules failed: ${e.message}")
            configJson
        }
    }

    /**
     * Единый мобильный data-path:
     * - выбираем порт основного outbound tag=proxy
     * - удаляем любые дополнительные proxy outbounds на других портах
     * - удаляем speedtest-clone/rules, чтобы не было смешения 2053/4443 в одной сессии
     */
    private fun enforceSingleProxyPort(configJson: String): String {
        return try {
            val root = org.json.JSONObject(configJson)
            val outbounds = root.optJSONArray("outbounds") ?: return configJson
            var primaryPort: Int? = null
            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.optJSONObject(i) ?: continue
                if (outbound.optString("tag") == OUTBOUND_PROXY) {
                    primaryPort = outboundPort(outbound)
                    break
                }
            }
            if (primaryPort == null) {
                Log.w(TAG, "enforceSingleProxyPort: no primary proxy port, keep original config")
                return configJson
            }

            val kept = org.json.JSONArray()
            val keptTags = mutableSetOf<String>()
            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.optJSONObject(i) ?: continue
                val tag = outbound.optString("tag")
                val protocol = outbound.optString("protocol").lowercase()
                if (protocol == "freedom" || protocol == "blackhole" || protocol == "dns") {
                    kept.put(outbound)
                    if (tag.isNotEmpty()) keptTags.add(tag)
                    continue
                }
                val port = outboundPort(outbound)
                if (tag == OUTBOUND_PROXY && port == primaryPort) {
                    kept.put(outbound)
                    keptTags.add(tag)
                    continue
                }
                if (port == primaryPort && tag != OUTBOUND_SPEEDTEST) {
                    kept.put(outbound)
                    if (tag.isNotEmpty()) keptTags.add(tag)
                    continue
                }
                Log.i(
                    TAG,
                    "enforceSingleProxyPort: drop outbound tag=${tag.ifEmpty { "-" }} protocol=${protocol.ifEmpty { "-" }} port=${port ?: -1} primary=$primaryPort",
                )
            }

            root.put("outbounds", kept)
            val routing = root.optJSONObject("routing")
            val rules = routing?.optJSONArray("rules")
            if (rules != null) {
                val filtered = org.json.JSONArray()
                for (i in 0 until rules.length()) {
                    val rule = rules.optJSONObject(i) ?: continue
                    val outboundTag = rule.optString("outboundTag")
                    if (outboundTag.isEmpty() || keptTags.contains(outboundTag)) {
                        filtered.put(rule)
                    }
                }
                routing.put("rules", filtered)
            }
            Log.i(TAG, "enforceSingleProxyPort: single-port enabled port=$primaryPort")
            root.toString()
        } catch (e: Exception) {
            Log.w(TAG, "enforceSingleProxyPort failed: ${e.message}")
            configJson
        }
    }

    /**
     * Дублирует outbound [OUTBOUND_PROXY] в [OUTBOUND_SPEEDTEST] с userLevel=1 и policy.levels.1.connIdle=120.
     */
    fun ensureProxySpeedtestOutbound(configJson: String): String {
        return try {
            val json = org.json.JSONObject(configJson)
            val outbounds = json.optJSONArray("outbounds") ?: return configJson
            var hasSpeed = false
            var hasProxy = false
            for (i in 0 until outbounds.length()) {
                val ob = outbounds.optJSONObject(i) ?: continue
                when (ob.optString("tag")) {
                    OUTBOUND_SPEEDTEST -> hasSpeed = true
                    OUTBOUND_PROXY -> hasProxy = true
                }
            }
            if (hasSpeed) return configJson
            if (!hasProxy) {
                Log.w(TAG, "ensureProxySpeedtestOutbound: no outbound tag=$OUTBOUND_PROXY")
                return configJson
            }
            var proxyObj: org.json.JSONObject? = null
            for (i in 0 until outbounds.length()) {
                val ob = outbounds.optJSONObject(i) ?: continue
                if (ob.optString("tag") == OUTBOUND_PROXY) {
                    proxyObj = ob
                    break
                }
            }
            if (proxyObj == null) return configJson
            val clone = org.json.JSONObject(proxyObj.toString())
            clone.put("tag", OUTBOUND_SPEEDTEST)
            clone.put("userLevel", 1)
            outbounds.put(clone)
            val policy = json.optJSONObject("policy") ?: org.json.JSONObject().also { json.put("policy", it) }
            val levels = policy.optJSONObject("levels") ?: org.json.JSONObject().also { policy.put("levels", it) }
            val level0 = levels.optJSONObject("0") ?: org.json.JSONObject().also { levels.put("0", it) }
            if (!level0.has("connIdle")) {
                level0.put("connIdle", 300)
            }
            val level1 = org.json.JSONObject()
            level1.put("connIdle", 120)
            levels.put("1", level1)
            Log.d(TAG, "ensureProxySpeedtestOutbound: cloned $OUTBOUND_PROXY -> $OUTBOUND_SPEEDTEST (userLevel=1)")
            json.toString()
        } catch (e: Exception) {
            Log.w(TAG, "ensureProxySpeedtestOutbound failed: ${e.message}")
            configJson
        }
    }

    /**
     * Policy hints: levels.0 — основной proxy (лимит параллелизма подсказка для мобильных).
     */
    fun ensureMobileConcurrencyPolicy(configJson: String): String {
        return try {
            val json = org.json.JSONObject(configJson)
            val policy = json.optJSONObject("policy") ?: org.json.JSONObject().also { json.put("policy", it) }
            val levels = policy.optJSONObject("levels") ?: org.json.JSONObject().also { policy.put("levels", it) }
            val level0 = levels.optJSONObject("0") ?: org.json.JSONObject().also { levels.put("0", it) }
            if (!level0.has("handshake")) {
                level0.put("handshake", 4)
            }
            level0.put("connIdle", 300)
            json.toString()
        } catch (e: Exception) {
            Log.w(TAG, "ensureMobileConcurrencyPolicy failed: ${e.message}")
            configJson
        }
    }

    private fun findSocksInsertIndex(rules: org.json.JSONArray): Int {
        var insertAt = rules.length()
        for (i in 0 until rules.length()) {
            val rule = rules.optJSONObject(i) ?: continue
            if (rule.optJSONArray("inboundTag")?.toString()?.contains("socks-in") == true) {
                insertAt = i
                break
            }
        }
        return insertAt
    }

    /**
     * Совместимость: control plane + пользовательские direct-домены.
     */
    fun applyControlPlaneAndUserDirectRouting(
        configJson: String,
        userDomains: List<String>,
    ): String {
        return applyFullVpnRouting(
            configJson = configJson,
            userDomains = userDomains,
            dnsMode = VpnRoutingPrefs.DNS_PERFORMANCE,
        )
    }

    /**
     * Полная инъекция: control-plane API direct, DoH по режиму, speedtest outbound, policy.
     * API fallback при блокировке direct — на стороне HTTP-клиента (SOCKS 127.0.0.1:10808), без смены Xray routing.
     */
    fun applyFullVpnRouting(
        configJson: String,
        userDomains: List<String>,
        dnsMode: String,
    ): String {
        var cfg = configJson
        if (DIAG_MINIMAL_ROUTING_MODE) {
            Log.i(
                TAG,
                "applyFullVpnRouting: minimal mode (control-plane only; QUIC block switchable); skip split/speedtest/single-port",
            )
            if (CONTROL_PLANE_API_DOMAINS.isNotEmpty()) {
                cfg = injectDirectDomains(cfg, CONTROL_PLANE_API_DOMAINS)
            }
            if (CONTROL_PLANE_API_IPS.isNotEmpty()) {
                cfg = injectDirectIps(cfg, CONTROL_PLANE_API_IPS)
            }
            // Diagnostic switch: test UDP/443 end-to-end instead of blackholing QUIC locally.
            if (GLOBAL_UDP_443_BLOCK_ENABLED) {
                cfg = injectQuicBlockRules(cfg)
                Log.i(TAG, "[ROUTING_MARKER] marker=$QUIC_BLOCK_MARKER enabled=true (minimal mode)")
            }
            return cfg
        }
        val mergedDomains = (CONTROL_PLANE_API_DOMAINS + userDomains).distinct()
        if (mergedDomains.isNotEmpty()) {
            cfg = injectDirectDomains(cfg, mergedDomains)
        }
        if (CONTROL_PLANE_API_IPS.isNotEmpty()) {
            cfg = injectDirectIps(cfg, CONTROL_PLANE_API_IPS)
        }
        val mode = dnsMode.trim().lowercase()
        if (mode != VpnRoutingPrefs.DNS_STRICT) {
            if (PUBLIC_DNS_OVER_TLS_HTTPS_DOMAINS.isNotEmpty()) {
                cfg = injectDirectDomains(cfg, PUBLIC_DNS_OVER_TLS_HTTPS_DOMAINS)
            }
        }
        val realityStrict = hasRealityOutbound(cfg)
        if (realityStrict) {
            cfg = enforceRealityStrictPort(cfg)
        } else {
            if (MOBILE_SINGLE_PORT_POLICY) {
                cfg = enforceSingleProxyPort(cfg)
            } else {
                cfg = ensureProxySpeedtestOutbound(cfg)
                cfg = injectSpeedtestDomainRules(cfg)
            }
        }
        if (GLOBAL_UDP_443_BLOCK_ENABLED) {
            cfg = injectQuicBlockRules(cfg)
            Log.i(TAG, "[ROUTING_MARKER] marker=$QUIC_BLOCK_MARKER enabled=true")
        } else {
            Log.i(
                TAG,
                "injectQuicBlockRules: disabled (GLOBAL_UDP_443_BLOCK_ENABLED=false) marker=$QUIC_BLOCK_MARKER",
            )
        }
        cfg = ensureMobileConcurrencyPolicy(cfg)
        return cfg
    }
}
