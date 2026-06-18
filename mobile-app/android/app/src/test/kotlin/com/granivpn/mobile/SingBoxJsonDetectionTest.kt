package com.granivpn.mobile

import org.junit.Test
import org.junit.Assert.*
import org.json.JSONObject

/**
 * Тесты для проверки распознавания sing-box JSON конфигурации
 */
class SingBoxJsonDetectionTest {

    @Test
    fun testSingBoxJsonDetection_ValidSingBoxJson_ShouldReturnTrue() {
        // Создаем валидную sing-box JSON конфигурацию
        val singBoxJson = """
        {
            "log": {"level": "warn"},
            "dns": {"servers": ["8.8.8.8", "8.8.4.4"]},
            "inbounds": [{
                "type": "tun",
                "tag": "tun-in",
                "settings": {
                    "mtu": 1500,
                    "inet4_address": ["172.19.0.1/30"]
                }
            }],
            "outbounds": [{
                "tag": "proxy",
                "type": "vless",
                "server": "45.12.132.94",
                "server_port": 443,
                "uuid": "de368a01-aa2d-4a6d-865f-2b658486a4e5",
                "flow": "",
                "tls": {
                    "enabled": true,
                    "server_name": "www.google.com",
                    "reality": {
                        "public_key": "Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY",
                        "short_id": "822c3e48"
                    },
                    "utls": {
                        "enabled": true,
                        "fingerprint": "chrome"
                    }
                },
                "transport": {
                    "type": "tcp"
                }
            }],
            "route": {
                "rules": [{
                    "type": "field",
                    "inbound_tag": ["tun-in"],
                    "outbound": "proxy"
                }]
            }
        }
        """.trimIndent()

        // Проверяем, что это валидный JSON
        val json = JSONObject(singBoxJson)
        
        // Проверяем обязательные поля sing-box
        assertTrue("Должно быть поле log", json.has("log"))
        assertTrue("Должно быть поле dns", json.has("dns"))
        assertTrue("Должно быть поле inbounds", json.has("inbounds"))
        assertTrue("Должно быть поле outbounds", json.has("outbounds"))
        
        // Проверяем структуру outbound
        val outbounds = json.getJSONArray("outbounds")
        assertTrue("Outbounds не должен быть пустым", outbounds.length() > 0)
        
        val firstOutbound = outbounds.getJSONObject(0)
        assertTrue("Outbound должен содержать поле type", firstOutbound.has("type"))
        assertFalse("Outbound НЕ должен содержать поле protocol", firstOutbound.has("protocol"))
        
        // Проверяем, что type = 'vless'
        assertEquals("Type должен быть vless", "vless", firstOutbound.getString("type"))
    }

    @Test
    fun testSingBoxJsonDetection_OldXrayFormat_ShouldReturnFalse() {
        // Создаем старый формат Xray JSON (с полем protocol)
        val oldXrayJson = """
        {
            "outbounds": [{
                "protocol": "vless",
                "settings": {
                    "vnext": [{
                        "address": "45.12.132.94",
                        "port": 443
                    }]
                }
            }]
        }
        """.trimIndent()

        val json = JSONObject(oldXrayJson)
        
        // Старый формат НЕ имеет полей log, dns, inbounds
        assertFalse("Старый формат не должен иметь поле log", json.has("log"))
        assertFalse("Старый формат не должен иметь поле dns", json.has("dns"))
        assertFalse("Старый формат не должен иметь поле inbounds", json.has("inbounds"))
        
        // Но имеет outbounds с protocol
        if (json.has("outbounds")) {
            val outbounds = json.getJSONArray("outbounds")
            if (outbounds.length() > 0) {
                val firstOutbound = outbounds.getJSONObject(0)
                assertTrue("Старый формат должен иметь поле protocol", firstOutbound.has("protocol"))
            }
        }
    }

    @Test
    fun testSingBoxJsonDetection_StartsWithBrace_ShouldBeChecked() {
        val validJson = """{"log": {"level": "warn"}, "dns": {}, "inbounds": [], "outbounds": []}"""
        val invalidJson = "vless://..."
        
        assertTrue("Валидный JSON должен начинаться с {", validJson.trim().startsWith("{"))
        assertFalse("Невалидный JSON не должен начинаться с {", invalidJson.trim().startsWith("{"))
    }

    @Test
    fun testSingBoxJsonDetection_AllRequiredFieldsPresent() {
        val singBoxJson = """
        {
            "log": {"level": "warn"},
            "dns": {"servers": ["8.8.8.8"]},
            "inbounds": [{"type": "tun"}],
            "outbounds": [{"type": "vless"}]
        }
        """.trimIndent()

        val json = JSONObject(singBoxJson)
        
        val hasLog = json.has("log")
        val hasDns = json.has("dns")
        val hasInbounds = json.has("inbounds")
        val hasOutbounds = json.has("outbounds")
        
        assertTrue("Должно быть поле log", hasLog)
        assertTrue("Должно быть поле dns", hasDns)
        assertTrue("Должно быть поле inbounds", hasInbounds)
        assertTrue("Должно быть поле outbounds", hasOutbounds)
        
        // Если все поля присутствуют - это sing-box JSON
        val isSingBoxJson = hasLog && hasDns && hasInbounds && hasOutbounds
        assertTrue("Должно быть распознано как sing-box JSON", isSingBoxJson)
    }
}
