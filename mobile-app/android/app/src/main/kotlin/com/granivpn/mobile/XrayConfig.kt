package com.granivpn.mobile

/**
 * Конфигурация XRay протокола
 * 
 * Хранит параметры подключения для VLESS/VMESS протоколов
 */
data class XrayConfig(
    val protocol: String, // vless, vmess
    val address: String,
    val port: Int,
    val uuid: String,
    val security: String = "tls", // tls, reality, none
    val network: String = "ws", // ws, tcp
    val host: String? = null, // для WebSocket
    val path: String? = null, // для WebSocket
    val sni: String? = null, // Server Name Indication для TLS
    val remark: String? = null, // Название сервера
    // Поля для REALITY
    val realityPublicKey: String? = null, // pbk - публичный ключ REALITY
    val realityShortId: String? = null, // sid - короткий ID REALITY
    val realitySpx: String? = null, // spx - путь для REALITY
    val realityFp: String? = null, // fp - fingerprint для REALITY (например, "chrome")
    val flow: String? = null // flow - для VLESS с REALITY (xtls-rprx-vision)
) {
    /**
     * Преобразует конфигурацию в полный JSON формат XRay
     */
    fun toFullJsonConfig(): String {
        val json = org.json.JSONObject()
        
        // Логирование
        val log = org.json.JSONObject()
        log.put("loglevel", "info")
        json.put("log", log)
        
        // DNS конфигурация - критически важно для разрешения доменов
        // Используем 2 DNS (вместо 3) для снижения нагрузки на fd при "too many fds" в tun2socks
        val dns = org.json.JSONObject()
        val dnsServers = org.json.JSONArray()
        dnsServers.put(org.json.JSONObject().apply { put("address", "1.1.1.1") })
        dnsServers.put(org.json.JSONObject().apply { put("address", "8.8.8.8") })
        dns.put("servers", dnsServers)
        dns.put("queryStrategy", "UseIP") // Использовать IP для запросов
        json.put("dns", dns)
        
        // Inbounds - SOCKS прокси для приема пакетов
        // libXray не поддерживает dokodemo-door с port: 0 для VPN интерфейса
        // Используем SOCKS прокси, через который будет перенаправляться трафик из VPN интерфейса
        val inbounds = org.json.JSONArray()
        val socksInbound = org.json.JSONObject()
        socksInbound.put("tag", "socks-in")
        socksInbound.put("port", 10808)
        socksInbound.put("protocol", "socks")
        socksInbound.put("settings", org.json.JSONObject().apply {
            put("auth", "noauth")
            put("udp", true)
        })
        inbounds.put(socksInbound)
        
        json.put("inbounds", inbounds)
        
        // Outbounds
        val outbounds = org.json.JSONArray()
        val outbound = org.json.JSONObject()
        outbound.put("protocol", protocol)
        
        // Settings для outbound
        val settings = org.json.JSONObject()
        val vnext = org.json.JSONArray()
        val server = org.json.JSONObject()
        server.put("address", address)
        server.put("port", port)
        
        val users = org.json.JSONArray()
        val user = org.json.JSONObject()
        user.put("id", uuid)
        if (protocol == "vmess") {
            user.put("alterId", 0)
        }
        // Для VLESS обязательно нужно encryption: "none"
        if (protocol == "vless") {
            user.put("encryption", "none")
        }
        // Добавляем flow только если он явно задан и не для REALITY
        if (protocol == "vless" && security != "reality") {
            val flowValue = flow?.takeIf { it.isNotBlank() }
            if (flowValue != null) {
                user.put("flow", flowValue)
            }
        }
        users.put(user)
        server.put("users", users)
        vnext.put(server)
        settings.put("vnext", vnext)
        outbound.put("settings", settings)
        
        // StreamSettings
        val streamSettings = org.json.JSONObject()
        streamSettings.put("network", network)
        streamSettings.put("security", security)
        
        // TLS Settings - только если security == "tls"
        if (security == "tls") {
            val tlsSettings = org.json.JSONObject()
            tlsSettings.put("serverName", sni ?: address) // Используем address как fallback
            tlsSettings.put("allowInsecure", false)
            streamSettings.put("tlsSettings", tlsSettings)
        }
        
        // REALITY Settings - только если security == "reality" и есть обязательные поля
        if (security == "reality") {
            // Проверяем наличие обязательных полей для REALITY
            if (realityPublicKey == null || realityPublicKey.isEmpty()) {
                throw IllegalStateException("REALITY требует realityPublicKey (pbk)")
            }
            val realitySettings = org.json.JSONObject()
            realitySettings.put("publicKey", realityPublicKey)
            realitySettings.put("serverName", sni ?: address) // Обязательное поле для REALITY
            realityShortId?.let { 
                if (it.isNotEmpty()) {
                    realitySettings.put("shortId", it)
                }
            }
            realitySpx?.let { 
                if (it.isNotEmpty()) {
                    realitySettings.put("spx", it)
                }
            }
            realityFp?.let { 
                if (it.isNotEmpty()) {
                    realitySettings.put("fingerprint", it)
                } else {
                    // Значение по умолчанию для fingerprint
                    realitySettings.put("fingerprint", "chrome")
                }
            } ?: run {
                // Если fingerprint не указан, используем значение по умолчанию
                realitySettings.put("fingerprint", "chrome")
            }
            streamSettings.put("realitySettings", realitySettings)
        }
        
        // WebSocket Settings - только если network == "ws"
        if (network == "ws") {
            val wsSettings = org.json.JSONObject()
            // Path обязателен для WebSocket
            val wsPath = path?.takeIf { it.isNotEmpty() } ?: "/ray"
            wsSettings.put("path", wsPath)
            
            // Host header - используем host или address
            val wsHost = host?.takeIf { it.isNotEmpty() } ?: address
            val headers = org.json.JSONObject()
            headers.put("Host", wsHost)
            wsSettings.put("headers", headers)
            
            streamSettings.put("wsSettings", wsSettings)
        }
        
        outbound.put("streamSettings", streamSettings)
        outbound.put("tag", "proxy")
        outbounds.put(outbound)
        json.put("outbounds", outbounds)
        
        // Routing - маршрутизация всех пакетов через proxy
        // 1) VPN-сервер (address) в direct — КРИТИЧНО: иначе трафик к серверу идёт через proxy,
        //    образуется петля и интернет не работает.
        // 2) DNS-серверы в direct — иначе DNS через proxy может не проходить
        // Базовый каркас: отдельного правила для API нет — иначе весь default шёл бы через proxy.
        // На Android контрольный план (api.* + fallback IP) принудительно в direct в XrayRoutingHelper.
        val routing = org.json.JSONObject()
        val rules = org.json.JSONArray()
        
        // VPN-сервер — всегда direct (предотвращает routing loop)
        val isServerIp = address.matches(Regex("^[\\d.]+$")) || address.contains(":")
        if (isServerIp) {
            val serverDirectRule = org.json.JSONObject()
            serverDirectRule.put("type", "field")
            val serverIpArray = org.json.JSONArray()
            serverIpArray.put(address)
            serverDirectRule.put("ip", serverIpArray)
            serverDirectRule.put("outboundTag", "direct")
            rules.put(serverDirectRule)
        } else {
            val serverDomainRule = org.json.JSONObject()
            serverDomainRule.put("type", "field")
            val serverDomainArray = org.json.JSONArray()
            serverDomainArray.put(address)
            serverDomainArray.put("domain:$address")
            serverDomainRule.put("domain", serverDomainArray)
            serverDomainRule.put("outboundTag", "direct")
            rules.put(serverDomainRule)
        }
        
        // DNS-серверы — direct
        val dnsDirectRuleFull = org.json.JSONObject()
        dnsDirectRuleFull.put("type", "field")
        val dnsIpArrayFull = org.json.JSONArray()
        dnsIpArrayFull.put("1.1.1.1").put("1.0.0.1").put("9.9.9.9").put("8.8.8.8").put("8.8.4.4")
        dnsDirectRuleFull.put("ip", dnsIpArrayFull)
        dnsDirectRuleFull.put("outboundTag", "direct")
        rules.put(dnsDirectRuleFull)
        
        val socksRule = org.json.JSONObject()
        socksRule.put("type", "field")
        val socksInboundTag = org.json.JSONArray()
        socksInboundTag.put("socks-in")
        socksRule.put("inboundTag", socksInboundTag)
        socksRule.put("outboundTag", "proxy")
        rules.put(socksRule)
        
        routing.put("rules", rules)
        json.put("routing", routing)
        
        // Валидация JSON перед возвратом
        val configString = json.toString()
        
        // ВАЖНО: libXray может требовать компактный JSON без пробелов
        // Удаляем все пробелы и переносы строк для совместимости
        val compactJson = configString.replace("\\s+".toRegex(), "")
        
        try {
            // Проверяем, что JSON валиден
            val testJson = org.json.JSONObject(compactJson)
            // Проверяем наличие обязательных полей
            if (!testJson.has("outbounds") || testJson.getJSONArray("outbounds").length() == 0) {
                throw IllegalStateException("JSON конфигурация не содержит outbounds")
            }
            android.util.Log.d("XrayConfig", "toFullJsonConfig: JSON конфигурация валидна (длина: ${compactJson.length})")
            android.util.Log.d("XrayConfig", "toFullJsonConfig: Компактный JSON: $compactJson")
        } catch (e: Exception) {
            android.util.Log.e("XrayConfig", "ОШИБКА: Создан невалидный JSON: ${e.message}")
            android.util.Log.e("XrayConfig", "JSON конфигурация: $compactJson")
            throw IllegalStateException("Невалидный JSON конфигурация: ${e.message}", e)
        }
        
        return compactJson
    }
    
    /**
     * Преобразует в упрощенный JSON формат (для совместимости с V2rayNG)
     */
    fun toSimpleJson(): String {
        val json = org.json.JSONObject()
        // Для VMESS добавляем поле "v", для VLESS не добавляем (не включаем пустую строку)
        if (protocol == "vmess") {
            json.put("v", "2")
        }
        json.put("ps", remark ?: "GRANI")
        json.put("add", address)
        json.put("port", port.toString())
        json.put("id", uuid)
        json.put("aid", "0")
        json.put("scy", "none")
        json.put("net", network)
        json.put("type", "none")
        json.put("host", host ?: address)
        json.put("path", path ?: "/ray")
        json.put("tls", security)
        json.put("sni", sni ?: address)
        json.put("alpn", "")
        
        // REALITY параметры
        realityPublicKey?.let { json.put("pbk", it) }
        realityShortId?.let { json.put("sid", it) }
        realitySpx?.let { json.put("spx", it) }
        realityFp?.let { json.put("fp", it) }
        
        return json.toString()
    }
    
    /**
     * Преобразует конфигурацию в нативный формат XRay-core (не sing-box)
     * 
     * XRay-core использует другой формат конфигурации, чем sing-box.
     * Этот метод преобразует XrayConfig в формат, который понимает libXray.
     */
    fun toXrayNativeJsonConfig(): String {
        val json = org.json.JSONObject()
        
        // Логирование
        val log = org.json.JSONObject()
        log.put("loglevel", "info")
        json.put("log", log)
        
        // Inbounds - SOCKS для перенаправления трафика из VPN интерфейса
        // sniffing: при подключении по IP Xray извлекает домен из TLS SNI для routing
        val inbounds = org.json.JSONArray()
        val socksInbound = org.json.JSONObject()
        socksInbound.put("tag", "socks-in")
        socksInbound.put("port", 10808)
        socksInbound.put("protocol", "socks")
        socksInbound.put("settings", org.json.JSONObject().apply {
            put("auth", "noauth")
            put("udp", true)
        })
        val sniffing = org.json.JSONObject()
        sniffing.put("enabled", true)
        sniffing.put("destOverride", org.json.JSONArray().apply {
            put("http")
            put("tls")
        })
        socksInbound.put("sniffing", sniffing)
        inbounds.put(socksInbound)
        json.put("inbounds", inbounds)
        
        // Outbounds
        val outbounds = org.json.JSONArray()
        val outbound = org.json.JSONObject()
        outbound.put("tag", "proxy")
        
        // Определяем тип протокола для XRay-core
        when (protocol.lowercase()) {
            "vless" -> {
                outbound.put("protocol", "vless")
                val settings = org.json.JSONObject()
                val vnext = org.json.JSONArray()
                val server = org.json.JSONObject()
                server.put("address", address)
                server.put("port", port)
                val users = org.json.JSONArray()
                val user = org.json.JSONObject()
                user.put("id", uuid)
                val flowValue = flow?.takeIf { it.isNotBlank() && security.lowercase() != "reality" }
                if (flowValue != null) {
                    user.put("flow", flowValue)
                }
                // Для VLESS encryption всегда "none"
                user.put("encryption", "none")
                users.put(user)
                server.put("users", users)
                vnext.put(server)
                settings.put("vnext", vnext)
                // Keep REALITY on plain TCP framing for stability under churn.
                // packetEncoding=xudp amplifies UDP churn and may trigger retry storms.
                outbound.put("settings", settings)
            }
            "vmess" -> {
                outbound.put("protocol", "vmess")
                val settings = org.json.JSONObject()
                val vnext = org.json.JSONArray()
                val server = org.json.JSONObject()
                server.put("address", address)
                server.put("port", port)
                val users = org.json.JSONArray()
                val user = org.json.JSONObject()
                user.put("id", uuid)
                user.put("alterId", 0)
                // Для VMESS используем security "none" для совместимости
                user.put("security", "none")
                users.put(user)
                server.put("users", users)
                vnext.put(server)
                settings.put("vnext", vnext)
                outbound.put("settings", settings)
            }
            else -> {
                throw IllegalArgumentException("Неподдерживаемый протокол для XRay-core: $protocol")
            }
        }
        
        // Stream settings (TLS/Reality/Transport)
        val streamSettingsOutbound = org.json.JSONObject()
        
        // TLS/Reality settings
        when (security.lowercase()) {
            "tls" -> {
                streamSettingsOutbound.put("security", "tls")
                val tlsSettings = org.json.JSONObject()
                tlsSettings.put("serverName", sni ?: address)
                tlsSettings.put("allowInsecure", false)
                streamSettingsOutbound.put("tlsSettings", tlsSettings)
            }
            "reality" -> {
                if (realityPublicKey == null || realityPublicKey.isEmpty()) {
                    throw IllegalStateException("REALITY требует realityPublicKey (pbk)")
                }
                streamSettingsOutbound.put("security", "reality")
                val realitySettings = org.json.JSONObject()
                realitySettings.put("publicKey", realityPublicKey)
                realitySettings.put("serverName", sni ?: address)
                if (realityShortId != null && realityShortId.isNotEmpty()) {
                    realitySettings.put("shortId", realityShortId)
                }
                if (realitySpx != null && realitySpx.isNotEmpty()) {
                    realitySettings.put("spiderX", realitySpx)
                }
                realitySettings.put("fingerprint", realityFp ?: "chrome")
                streamSettingsOutbound.put("realitySettings", realitySettings)
            }
        }
        
        // Transport settings
        when (network.lowercase()) {
            "ws" -> {
                streamSettingsOutbound.put("network", "ws")
                val wsSettings = org.json.JSONObject()
                wsSettings.put("path", path ?: "/")
                val headers = org.json.JSONObject()
                headers.put("Host", host ?: address)
                wsSettings.put("headers", headers)
                streamSettingsOutbound.put("wsSettings", wsSettings)
            }
            "tcp" -> {
                streamSettingsOutbound.put("network", "tcp")
            }
        }
        
        if (streamSettingsOutbound.length() > 0) {
            outbound.put("streamSettings", streamSettingsOutbound)
        }
        
        outbounds.put(outbound)
        
        // Direct outbound для DNS
        val directOutbound = org.json.JSONObject()
        directOutbound.put("protocol", "freedom")
        directOutbound.put("tag", "direct")
        directOutbound.put("settings", org.json.JSONObject())
        outbounds.put(directOutbound)
        json.put("outbounds", outbounds)
        
        // Routing - правила маршрутизации
        // 1) VPN-сервер (address) в direct — предотвращает routing loop
        // 2) DNS-серверы в direct — иначе DNS через proxy может не проходить
        // API идёт через VPN (API и VPN на разных серверах)
        val routing = org.json.JSONObject()
        val rules = org.json.JSONArray()
        
        // VPN-сервер — всегда direct
        val isServerIp2 = address.matches(Regex("^[\\d.]+$")) || address.contains(":")
        if (isServerIp2) {
            val serverDirectRule2 = org.json.JSONObject()
            serverDirectRule2.put("type", "field")
            val serverIpArray2 = org.json.JSONArray()
            serverIpArray2.put(address)
            serverDirectRule2.put("ip", serverIpArray2)
            serverDirectRule2.put("outboundTag", "direct")
            rules.put(serverDirectRule2)
        } else {
            val serverDomainRule2 = org.json.JSONObject()
            serverDomainRule2.put("type", "field")
            val serverDomainArray2 = org.json.JSONArray()
            serverDomainArray2.put(address)
            serverDomainArray2.put("domain:$address")
            serverDomainRule2.put("domain", serverDomainArray2)
            serverDomainRule2.put("outboundTag", "direct")
            rules.put(serverDomainRule2)
        }
        
        // DNS-серверы — direct
        val dnsDirectRule = org.json.JSONObject()
        dnsDirectRule.put("type", "field")
        val dnsIpArray = org.json.JSONArray()
        dnsIpArray.put("1.1.1.1").put("1.0.0.1").put("9.9.9.9").put("8.8.8.8").put("8.8.4.4")
        dnsDirectRule.put("ip", dnsIpArray)
        dnsDirectRule.put("outboundTag", "direct")
        rules.put(dnsDirectRule)
        
        val proxyRule = org.json.JSONObject()
        proxyRule.put("type", "field")
        val inboundTag = org.json.JSONArray()
        inboundTag.put("socks-in")
        proxyRule.put("inboundTag", inboundTag)
        proxyRule.put("outboundTag", "proxy")
        rules.put(proxyRule)
        
        routing.put("rules", rules)
        json.put("routing", routing)
        
        return json.toString()
    }
}


