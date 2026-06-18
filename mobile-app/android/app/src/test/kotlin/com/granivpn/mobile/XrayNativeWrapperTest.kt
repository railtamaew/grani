package com.granivpn.mobile

import android.content.Context
import android.net.VpnService
import android.os.ParcelFileDescriptor
import io.mockk.*
import org.junit.After
import org.junit.Before
import org.junit.Ignore
import org.junit.Test
import org.junit.Assert.*

/**
 * Unit тесты для XrayNativeWrapperTun2Socks
 * 
 * Тестирует:
 * - Создание и инициализацию XrayNativeWrapperTun2Socks
 * - Проверку доступности libXray
 * - Базовую функциональность (без реального запуска VPN)
 */
@Ignore("Requires Android runtime; skip JVM unit tests")
class XrayNativeWrapperTest {
    
    private lateinit var mockContext: Context
    private lateinit var mockVpnService: GraniVpnService
    
    @Before
    fun setUp() {
        mockContext = mockk<Context>(relaxed = true)
        mockVpnService = mockk<GraniVpnService>(relaxed = true)
    }
    
    @After
    fun tearDown() {
        clearAllMocks()
    }
    
    @Test
    fun `test XrayNativeWrapperTun2Socks creation`() {
        // Act
        val wrapper = XrayNativeWrapperTun2Socks(mockContext)
        
        // Assert
        assertNotNull("XrayNativeWrapperTun2Socks должен быть создан", wrapper)
        assertFalse("VPN не должен быть запущен при создании", wrapper.isRunning())
    }
    
    @Test
    fun `test XrayNativeWrapperTun2Socks isAvailable check`() {
        // Act
        val isAvailable = XrayNativeWrapperTun2Socks.isAvailable()
        
        // Assert
        // Может быть true или false в зависимости от наличия libXray
        assertNotNull("isAvailable не должен быть null", isAvailable)
    }
    
    @Test
    fun `test XrayNativeWrapperTun2Socks isRunning returns false initially`() {
        // Arrange
        val wrapper = XrayNativeWrapperTun2Socks(mockContext)
        
        // Assert
        assertFalse("VPN не должен быть запущен изначально", wrapper.isRunning())
    }
    
    @Test
    fun `test XrayNativeWrapperTun2Socks stopVpn when not running`() {
        // Arrange
        val wrapper = XrayNativeWrapperTun2Socks(mockContext)
        
        // Act
        wrapper.stopVpn()
        
        // Assert
        assertFalse("VPN должен быть остановлен", wrapper.isRunning())
    }
    
    @Test
    fun `test XrayConfig toXrayNativeJsonConfig generates valid JSON`() {
        // Arrange
        val config = XrayConfig(
            protocol = "vless",
            address = "test.example.com",
            port = 443,
            uuid = "test-uuid",
            security = "tls",
            network = "tcp"
        )
        
        // Act
        val jsonConfig = config.toXrayNativeJsonConfig()
        
        // Assert
        assertNotNull("Конфигурация не должна быть null", jsonConfig)
        // Проверяем, что это валидный JSON (не падает при парсинге)
        try {
            val json = org.json.JSONObject(jsonConfig)
            assertTrue("JSON должен содержать log", json.has("log"))
            assertTrue("JSON должен содержать inbounds", json.has("inbounds"))
            assertTrue("JSON должен содержать outbounds", json.has("outbounds"))
            assertTrue("JSON должен содержать routing", json.has("routing"))
        } catch (e: org.json.JSONException) {
            fail("Конфигурация должна быть валидным JSON: ${e.message}")
        }
    }
    
    @Test
    fun `test XrayConfig toXrayNativeJsonConfig uses SOCKS inbound`() {
        // Arrange
        val config = XrayConfig(
            protocol = "vless",
            address = "test.example.com",
            port = 443,
            uuid = "test-uuid",
            security = "tls",
            network = "tcp"
        )
        
        // Act
        val jsonConfig = config.toXrayNativeJsonConfig()
        val json = org.json.JSONObject(jsonConfig)
        val inbounds = json.getJSONArray("inbounds")
        val inbound = inbounds.getJSONObject(0)
        
        // Assert
        assertEquals("Inbound должен использовать SOCKS", "socks", inbound.getString("protocol"))
        assertTrue("Inbound должен иметь tag", inbound.has("tag"))
    }
    
    @Test
    fun `test XrayConfig toXrayNativeJsonConfig uses vnext structure`() {
        // Arrange
        val config = XrayConfig(
            protocol = "vless",
            address = "server.example.com",
            port = 443,
            uuid = "test-uuid-1234",
            security = "tls",
            network = "tcp"
        )
        
        // Act
        val jsonConfig = config.toXrayNativeJsonConfig()
        val json = org.json.JSONObject(jsonConfig)
        val outbounds = json.getJSONArray("outbounds")
        val outbound = outbounds.getJSONObject(0)
        
        // Assert
        assertEquals("Outbound должен использовать protocol", "vless", outbound.getString("protocol"))
        assertTrue("Outbound должен иметь settings", outbound.has("settings"))
        val settings = outbound.getJSONObject("settings")
        assertTrue("Settings должен иметь vnext", settings.has("vnext"))
        val vnext = settings.getJSONArray("vnext")
        assertEquals("vnext должен содержать один сервер", 1, vnext.length())
        val server = vnext.getJSONObject(0)
        assertEquals("Сервер должен иметь правильный address", "server.example.com", server.getString("address"))
        assertEquals("Сервер должен иметь правильный port", 443, server.getInt("port"))
    }
}
