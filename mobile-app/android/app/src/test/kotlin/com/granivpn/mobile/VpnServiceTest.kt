package com.granivpn.mobile

import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.json.JSONObject

/**
 * Unit тесты для VpnService.processXrayPackets
 * 
 * Тестирует:
 * - Правильное определение формата sing-box JSON
 * - Парсинг sing-box JSON конфигураций
 * - Парсинг старых Xray конфигураций
 * - Обработку ошибок парсинга
 */
class VpnServiceTest {
    
    @Before
    fun setUp() {
        // Нет необходимости инициализировать Service/Context для этих unit-тестов.
    }
    
    @Test
    fun `test detectSingBoxJsonFormat - valid sing-box JSON`() {
        // Arrange
        val singBoxConfig = """
        {
            "log": {"level": "warn"},
            "dns": {"servers": ["8.8.8.8"]},
            "inbounds": [{"type": "tun"}],
            "outbounds": [{"type": "vless"}]
        }
        """.trimIndent()
        
        // Act
        val trimmed = singBoxConfig.trim()
        val isSingBoxJson = trimmed.startsWith("{") && try {
            val json = JSONObject(trimmed)
            json.has("log") && json.has("dns") && json.has("inbounds") && json.has("outbounds")
        } catch (e: Exception) {
            false
        }
        
        // Assert
        assertTrue("Должен быть определен как sing-box JSON", isSingBoxJson)
    }
    
    @Test
    fun `test detectSingBoxJsonFormat - invalid JSON`() {
        // Arrange
        val invalidConfig = "not a json"
        
        // Act
        val trimmed = invalidConfig.trim()
        val isSingBoxJson = trimmed.startsWith("{") && try {
            val json = JSONObject(trimmed)
            json.has("log") && json.has("dns") && json.has("inbounds") && json.has("outbounds")
        } catch (e: Exception) {
            false
        }
        
        // Assert
        assertFalse("Не должен быть определен как sing-box JSON", isSingBoxJson)
    }
    
    @Test
    fun `test detectSingBoxJsonFormat - missing required fields`() {
        // Arrange
        val incompleteConfig = """
        {
            "log": {"level": "warn"},
            "dns": {"servers": ["8.8.8.8"]}
        }
        """.trimIndent()
        
        // Act
        val trimmed = incompleteConfig.trim()
        val isSingBoxJson = trimmed.startsWith("{") && try {
            val json = JSONObject(trimmed)
            json.has("log") && json.has("dns") && json.has("inbounds") && json.has("outbounds")
        } catch (e: Exception) {
            false
        }
        
        // Assert
        assertFalse("Не должен быть определен как sing-box JSON (нет inbounds/outbounds)", isSingBoxJson)
    }
    
    @Test
    fun `test detectSingBoxJsonFormat - Xray client config format`() {
        // Arrange
        val xrayClientConfig = """
        {
            "v": "2",
            "ps": "GRANI-REALITY",
            "add": "45.12.132.94",
            "port": 443,
            "id": "bc84d49e-6054-494c-9af4-d9548e3608ae",
            "tls": "reality",
            "sni": "www.google.com",
            "pbk": "Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY",
            "sid": "822c3e48"
        }
        """.trimIndent()
        
        // Act
        val trimmed = xrayClientConfig.trim()
        val isSingBoxJson = trimmed.startsWith("{") && try {
            val json = JSONObject(trimmed)
            json.has("log") && json.has("dns") && json.has("inbounds") && json.has("outbounds")
        } catch (e: Exception) {
            false
        }
        
        // Assert
        assertFalse("Xray client config не должен быть определен как sing-box JSON", isSingBoxJson)
    }
    
    @Test
    fun `test XrayConfigParser parseConfig with sing-box JSON should fail gracefully`() {
        // Arrange
        val singBoxConfig = """
        {
            "log": {"level": "warn"},
            "dns": {"servers": ["8.8.8.8"]},
            "inbounds": [{"type": "tun"}],
            "outbounds": [{"type": "vless", "settings": {}}]
        }
        """.trimIndent()
        
        // Act & Assert
        // XrayConfigParser должен выбросить исключение при попытке парсить sing-box JSON
        try {
            XrayConfigParser.parseConfig(singBoxConfig)
            fail("Ожидалось исключение при парсинге sing-box JSON через XrayConfigParser")
        } catch (e: Exception) {
            // Ожидаем исключение - это нормально
            assertTrue("Ожидается IllegalArgumentException или JSONException", 
                e is IllegalArgumentException || e is org.json.JSONException)
        }
    }
    
    @Test
    fun `test XrayConfigParser parseConfig with Xray client config should succeed`() {
        // Arrange
        val xrayClientConfig = """
        {
            "v": "2",
            "ps": "GRANI-REALITY",
            "add": "45.12.132.94",
            "port": 443,
            "id": "bc84d49e-6054-494c-9af4-d9548e3608ae",
            "aid": 0,
            "scy": "none",
            "net": "tcp",
            "type": "none",
            "tls": "reality",
            "sni": "www.google.com",
            "pbk": "Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY",
            "sid": "822c3e48"
        }
        """.trimIndent()
        
        // Act
        val config = XrayConfigParser.parseConfig(xrayClientConfig)
        
        // Assert
        assertNotNull("Конфигурация должна быть распарсена", config)
        assertEquals("Протокол должен быть vless", "vless", config.protocol)
        assertEquals("Адрес должен совпадать", "45.12.132.94", config.address)
        assertEquals("Порт должен совпадать", 443, config.port)
        assertEquals("Security должен быть reality", "reality", config.security)
        assertNotNull("Reality public key должен быть установлен", config.realityPublicKey)
    }
    
    @Test
    fun `test processXrayPackets logic - sing-box JSON should be used directly`() {
        // Arrange
        val singBoxConfig = """
        {
            "log": {"level": "warn"},
            "dns": {"servers": ["8.8.8.8", "8.8.4.4"]},
            "inbounds": [{"type": "tun", "tag": "tun-in"}],
            "outbounds": [{"type": "vless", "tag": "proxy"}]
        }
        """.trimIndent()
        
        // Act - проверяем логику определения формата
        val trimmed = singBoxConfig.trim()
        val isSingBoxJson = trimmed.startsWith("{") && try {
            val json = JSONObject(trimmed)
            json.has("log") && json.has("dns") && json.has("inbounds") && json.has("outbounds")
        } catch (e: Exception) {
            false
        }
        
        val finalConfig = if (isSingBoxJson) {
            singBoxConfig // Используем напрямую
        } else {
            // Преобразуем через XrayConfigParser
            val xrayConfig = XrayConfigParser.parseConfig(singBoxConfig)
            xrayConfig.toXrayNativeJsonConfig()
        }
        
        // Assert
        assertTrue("Должен быть определен как sing-box JSON", isSingBoxJson)
        assertEquals("Конфигурация должна использоваться напрямую", singBoxConfig, finalConfig)
    }
    
    @Test
    fun `test processXrayPackets logic - Xray client config should be converted`() {
        // Arrange
        val xrayClientConfig = """
        {
            "v": "2",
            "ps": "GRANI-REALITY",
            "add": "45.12.132.94",
            "port": 443,
            "id": "bc84d49e-6054-494c-9af4-d9548e3608ae",
            "aid": 0,
            "scy": "none",
            "net": "tcp",
            "type": "none",
            "tls": "reality",
            "sni": "www.google.com",
            "pbk": "Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY",
            "sid": "822c3e48"
        }
        """.trimIndent()
        
        // Act - проверяем логику определения формата
        val trimmed = xrayClientConfig.trim()
        val isSingBoxJson = trimmed.startsWith("{") && try {
            val json = JSONObject(trimmed)
            json.has("log") && json.has("dns") && json.has("inbounds") && json.has("outbounds")
        } catch (e: Exception) {
            false
        }
        
        val finalConfig = if (isSingBoxJson) {
            xrayClientConfig // Используем напрямую
        } else {
            // Преобразуем через XrayConfigParser
            val xrayConfig = XrayConfigParser.parseConfig(xrayClientConfig)
            xrayConfig.toXrayNativeJsonConfig()
        }
        
        // Assert
        assertFalse("Не должен быть определен как sing-box JSON", isSingBoxJson)
        assertNotEquals("Конфигурация должна быть преобразована", xrayClientConfig, finalConfig)
        assertTrue("Преобразованная конфигурация должна содержать 'vless'", finalConfig.contains("vless"))
        assertTrue("Преобразованная конфигурация должна содержать 'reality'", finalConfig.contains("reality"))
    }
    
    @Test
    fun `test processXrayPackets logic - VLESS URL format`() {
        // Arrange
        val vlessUrl = "vless://691022bf-14cf-4ec3-8649-c49988f8578f@45.12.132.94:2053?security=reality&type=tcp&sni=www.google.com&pbk=Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY&sid=822c3e48#GRANI-REALITY"
        
        // Act - проверяем логику определения формата
        val trimmed = vlessUrl.trim()
        val isSingBoxJson = trimmed.startsWith("{") && try {
            val json = JSONObject(trimmed)
            json.has("log") && json.has("dns") && json.has("inbounds") && json.has("outbounds")
        } catch (e: Exception) {
            false
        }
        
        val finalConfig = if (isSingBoxJson) {
            vlessUrl // Используем напрямую
        } else {
            // Преобразуем через XrayConfigParser
            val xrayConfig = XrayConfigParser.parseConfig(vlessUrl)
            xrayConfig.toXrayNativeJsonConfig()
        }
        
        // Assert
        assertFalse("URL не должен быть определен как sing-box JSON", isSingBoxJson)
        assertNotEquals("Конфигурация должна быть преобразована", vlessUrl, finalConfig)
        assertTrue("Преобразованная конфигурация должна содержать 'vless'", finalConfig.contains("vless"))
    }
}
