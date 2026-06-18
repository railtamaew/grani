package com.granivpn.mobile

import android.util.Log
import org.json.JSONObject
import org.json.JSONException
import java.net.URLDecoder

/**
 * Парсер конфигураций XRay
 * 
 * Поддерживает парсинг:
 * - JSON конфигураций (полный формат XRay)
 * - VLESS/VMess URL конфигураций
 */
object XrayConfigParser {
    private const val TAG = "XrayConfigParser"
    
    /**
     * Парсит конфигурацию XRay из строки
     * 
     * @param configString JSON строка или VLESS/VMess URL
     * @return XrayConfig объект
     * @throws IllegalArgumentException если конфигурация невалидна
     */
    fun parseConfig(configString: String): XrayConfig {
        val trimmed = configString.trim()
        
        return when {
            trimmed.startsWith("{") -> parseJsonConfig(trimmed)
            trimmed.startsWith("vless://") -> parseUrlConfig(trimmed, "vless")
            trimmed.startsWith("vmess://") -> parseUrlConfig(trimmed, "vmess")
            else -> throw IllegalArgumentException("Неизвестный формат конфигурации XRay: $trimmed")
        }
    }
    
    /**
     * Парсит JSON конфигурацию
     */
    private fun parseJsonConfig(jsonString: String): XrayConfig {
        try {
            val json = JSONObject(jsonString)
            
            // Проверяем, это полная конфигурация XRay или упрощенная клиентская
            if (json.has("outbounds")) {
                // Полная конфигурация XRay - извлекаем первый outbound
                val outbounds = json.getJSONArray("outbounds")
                if (outbounds.length() == 0) {
                    throw IllegalArgumentException("Конфигурация не содержит outbounds")
                }
                val outbound = outbounds.getJSONObject(0)
                return parseOutbound(outbound)
            } else {
                // Упрощенная клиентская конфигурация (формат V2rayNG)
                return parseClientConfig(json)
            }
        } catch (e: JSONException) {
            Log.e(TAG, "Ошибка парсинга JSON конфигурации: ${e.message}", e)
            throw IllegalArgumentException("Невалидный JSON: ${e.message}", e)
        }
    }
    
    /**
     * Парсит outbound из полной конфигурации XRay
     */
    private fun parseOutbound(outbound: JSONObject): XrayConfig {
        val protocol = outbound.getString("protocol")
        if (protocol != "vless" && protocol != "vmess") {
            throw IllegalArgumentException("Неподдерживаемый протокол: $protocol")
        }
        
        val settings = outbound.getJSONObject("settings")
        val vnext = settings.getJSONArray("vnext")
        if (vnext.length() == 0) {
            throw IllegalArgumentException("Конфигурация не содержит серверов")
        }
        val server = vnext.getJSONObject(0)
        val address = server.getString("address")
        val port = server.getInt("port")
        val users = server.getJSONArray("users")
        if (users.length() == 0) {
            throw IllegalArgumentException("Конфигурация не содержит пользователей")
        }
        val user = users.getJSONObject(0)
        val uuid = user.getString("id")
        
        // Парсим streamSettings
        var security = "none"
        var network = "tcp"
        var host: String? = null
        var path: String? = null
        var sni: String? = null
        var realityPublicKey: String? = null
        var realityShortId: String? = null
        var realitySpx: String? = null
        var realityFp: String? = null
        
        if (outbound.has("streamSettings")) {
            val streamSettings = outbound.getJSONObject("streamSettings")
            network = streamSettings.optString("network", "tcp")
            
            if (streamSettings.has("security")) {
                security = streamSettings.getString("security")
            }
            
            if (streamSettings.has("tlsSettings")) {
                val tlsSettings = streamSettings.getJSONObject("tlsSettings")
                sni = tlsSettings.optString("serverName", null) ?: null
            }
            
            if (streamSettings.has("realitySettings")) {
                val realitySettings = streamSettings.getJSONObject("realitySettings")
                realityPublicKey = realitySettings.optString("publicKey", null) ?: null
                realityShortId = realitySettings.optString("shortId", null) ?: null
                realitySpx = realitySettings.optString("spx", null) ?: null
                realityFp = realitySettings.optString("fingerprint", null) ?: null
                security = "reality"
            }
            
            if (network == "ws" && streamSettings.has("wsSettings")) {
                val wsSettings = streamSettings.getJSONObject("wsSettings")
                path = wsSettings.optString("path", null) ?: null
                if (wsSettings.has("headers")) {
                    val headers = wsSettings.getJSONObject("headers")
                    host = headers.optString("Host", null) ?: null
                }
            }
        }
        
        // Извлекаем flow из user
        var flow: String? = null
        if (users.length() > 0) {
            val userObj = users.getJSONObject(0)
            flow = userObj.optString("flow", null) ?: null
        }
        
        return XrayConfig(
            protocol = protocol,
            address = address,
            port = port,
            uuid = uuid,
            security = security,
            network = network,
            host = host,
            path = path,
            sni = sni,
            realityPublicKey = realityPublicKey,
            realityShortId = realityShortId,
            realityFp = realityFp,
            realitySpx = realitySpx,
            flow = flow
        )
    }
    
    /**
     * Парсит упрощенную клиентскую конфигурацию (формат V2rayNG)
     */
    private fun parseClientConfig(json: JSONObject): XrayConfig {
        // ВАЖНО: backend передает канонический protocol в json_config.
        // Всегда предпочитаем его, чтобы не перепутать VLESS/VMESS по эвристикам.
        val protocolRaw = json.optString("protocol", "").trim().lowercase()
        val protocolFromPayload = when (protocolRaw) {
            "vless", "vmess" -> protocolRaw
            else -> null
        }

        // Fallback для legacy-конфигов без "protocol":
        // - REALITY всегда VLESS
        // - если явно задана версия VMESS, считаем vmess
        // - иначе vless
        val protocol = when {
            protocolFromPayload != null -> protocolFromPayload
            json.has("pbk") || json.optString("tls") == "reality" -> "vless" // REALITY всегда VLESS
            json.optString("v") == "2" -> "vmess"
            else -> "vless"
        }
        val address = json.getString("add")
        val portValue = json.opt("port")
        val port = when (portValue) {
            is Number -> portValue.toInt()
            is String -> portValue.toIntOrNull()
                ?: throw IllegalArgumentException("Невалидный порт: $portValue")
            else -> throw IllegalArgumentException("Невалидный порт: $portValue")
        }
        val uuid = json.getString("id")
        val security = json.optString("tls", "none")
        val network = json.optString("net", "tcp")
        val host: String? = json.optString("host", null) ?: null
        val path: String? = json.optString("path", null) ?: null
        val sni: String? = json.optString("sni", null) ?: null
        val remark: String? = json.optString("ps", null) ?: null
        
        // REALITY параметры
        val realityPublicKey: String? = json.optString("pbk", null) ?: null
        val realityShortId: String? = json.optString("sid", null) ?: null
        val realitySpx: String? = json.optString("spx", null) ?: null
        val realityFp: String? = json.optString("fp", null) ?: null
        val flow: String? = json.optString("flow", null) ?: null
        
        return XrayConfig(
            protocol = protocol,
            address = address,
            port = port,
            uuid = uuid,
            security = security,
            network = network,
            host = host,
            path = path,
            sni = sni,
            remark = remark,
            realityPublicKey = realityPublicKey,
            realityShortId = realityShortId,
            realityFp = realityFp,
            realitySpx = realitySpx,
            flow = flow
        )
    }
    
    /**
     * Парсит VLESS/VMess URL конфигурацию
     */
    private fun parseUrlConfig(urlString: String, protocol: String): XrayConfig {
        try {
            // Удаляем префикс протокола
            val cleanUrl = urlString.substringAfter("://")
            
            // Извлекаем UUID (до @)
            val atIndex = cleanUrl.indexOf('@')
            if (atIndex == -1) {
                throw IllegalArgumentException("Неверный формат URL конфигурации")
            }
            
            val uuid = cleanUrl.substring(0, atIndex)
            val rest = cleanUrl.substring(atIndex + 1)
            
            // Разбираем адрес и порт
            val parts = rest.split('?')
            val addressPort = parts[0].split(':')
            val address = addressPort[0]
            val port = addressPort[1].toInt()
            
            // Парсим параметры
            var security = "tls"
            var network = "ws"
            var host: String? = null
            var path: String? = null
            var sni: String? = null
            var realityPublicKey: String? = null
            var realityShortId: String? = null
            var realitySpx: String? = null
            var realityFp: String? = null
            
            var flow: String? = null
            
            if (parts.size > 1) {
                val queryString = parts[1].split('#')[0] // Убираем fragment
                val params = parseQueryString(queryString)
                
                security = params["security"] ?: "tls"
                network = params["type"] ?: "ws"
                host = params["host"]
                path = params["path"]
                sni = params["sni"]
                realityPublicKey = params["pbk"]
                realityShortId = params["sid"]
                realitySpx = params["spx"]
                realityFp = params["fp"]
                flow = params["flow"]
            }
            
            // Извлекаем remark из fragment
            val remark = if (urlString.contains("#")) {
                URLDecoder.decode(urlString.substringAfterLast("#"), "UTF-8")
            } else {
                null
            }
            
            return XrayConfig(
                protocol = protocol,
                address = address,
                port = port,
                uuid = uuid,
                security = security,
                network = network,
                host = host,
                path = path,
                sni = sni,
                remark = remark,
                realityPublicKey = realityPublicKey,
                realityShortId = realityShortId,
                realityFp = realityFp,
                realitySpx = realitySpx,
                flow = flow
            )
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка парсинга URL конфигурации: ${e.message}", e)
            throw IllegalArgumentException("Невалидный URL формат: ${e.message}", e)
        }
    }
    
    /**
     * Парсит query string в Map
     */
    private fun parseQueryString(query: String): Map<String, String> {
        val params = mutableMapOf<String, String>()
        val pairs = query.split('&')
        for (pair in pairs) {
            val keyValue = pair.split('=', limit = 2)
            if (keyValue.size == 2) {
                val key = URLDecoder.decode(keyValue[0], "UTF-8")
                val value = URLDecoder.decode(keyValue[1], "UTF-8")
                params[key] = value
            }
        }
        return params
    }
    
    /**
     * Валидирует конфигурацию
     */
    fun validateConfig(config: XrayConfig): Boolean {
        return try {
            config.uuid.isNotBlank() &&
            config.address.isNotBlank() &&
            config.port > 0 && config.port <= 65535 &&
            (config.protocol == "vless" || config.protocol == "vmess")
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка валидации конфигурации: ${e.message}", e)
            false
        }
    }
}


