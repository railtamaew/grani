package com.granivpn.mobile

import android.content.Intent
import android.net.VpnService
import android.util.Base64
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class VpnServiceIntegrationTest {

    companion object {
        private const val TAG = "VpnServiceTest"
    }

    @Test
    fun start_singbox_with_provided_config() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        GraniVpnService.setAppContext(context)

        // Добавлено: Логирование для диагностики
        val args = InstrumentationRegistry.getArguments()
        Log.d(TAG, "DEBUG: All args keys: ${args.keySet()}")
        Log.d(TAG, "DEBUG: singbox_config_b64 from args: ${args.getString("singbox_config_b64")?.take(50)}...")
        
        // Добавлено: Проверка системных переменных окружения
        val envConfig = System.getenv("singbox_config_b64")
        Log.d(TAG, "DEBUG: singbox_config_b64 from env: ${envConfig?.take(50)}...")

        val config = readConfigArg("singbox_config", "singbox_config_b64")
        Log.d(TAG, "DEBUG: Config after read: ${config?.take(100)}...")
        Log.d(TAG, "DEBUG: Config is null or blank: ${config.isNullOrBlank()}")
        
        assumeTrue("singbox_config not provided", !config.isNullOrBlank())

        // Ensure VPN permission is granted (auto-accept in Test Lab).
        val permissionGranted = ensureVpnPermission(context)
        Log.d(TAG, "DEBUG: VPN permission granted: $permissionGranted")
        assumeTrue("VPN permission not granted", permissionGranted)

        GraniVpnService.startService(context, config!!, "xray_vless")
        val started = waitForRunning(timeoutMs = 10000)
        assertTrue("Sing-box VPN did not start in time", started)

        // Verify real VPN connection by checking traffic stats
        verifyVpnTraffic(context)

        GraniVpnService.stopService(context)
    }

    @Test
    fun start_wireguard_with_provided_config() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        GraniVpnService.setAppContext(context)

        // Добавлено: Логирование для диагностики
        val args = InstrumentationRegistry.getArguments()
        Log.d(TAG, "DEBUG: All args keys: ${args.keySet()}")
        Log.d(TAG, "DEBUG: wireguard_config_b64 from args: ${args.getString("wireguard_config_b64")?.take(50)}...")
        
        // Добавлено: Проверка системных переменных окружения
        val envConfig = System.getenv("wireguard_config_b64")
        Log.d(TAG, "DEBUG: wireguard_config_b64 from env: ${envConfig?.take(50)}...")

        val config = readConfigArg("wireguard_config", "wireguard_config_b64")
        Log.d(TAG, "DEBUG: Config after read: ${config?.take(100)}...")
        Log.d(TAG, "DEBUG: Config is null or blank: ${config.isNullOrBlank()}")
        
        assumeTrue("wireguard_config not provided", !config.isNullOrBlank())

        // Ensure VPN permission is granted (auto-accept in Test Lab).
        val permissionGranted = ensureVpnPermission(context)
        Log.d(TAG, "DEBUG: VPN permission granted: $permissionGranted")
        assumeTrue("VPN permission not granted", permissionGranted)

        GraniVpnService.startService(context, config!!, "wireguard")
        val started = waitForRunning(timeoutMs = 10000)
        assertTrue("WireGuard VPN did not start in time", started)

        // Verify real VPN connection by checking traffic stats
        verifyVpnTraffic(context)

        GraniVpnService.stopService(context)
    }

    private fun readConfigArg(plainKey: String, b64Key: String): String? {
        val args = InstrumentationRegistry.getArguments()
        
        // Попытка 1: Чтение из instrumentation arguments
        var b64 = args.getString(b64Key)
        if (!b64.isNullOrBlank()) {
            Log.d(TAG, "DEBUG: Found config in instrumentation args: $b64Key")
            return try {
                String(Base64.decode(b64, Base64.DEFAULT))
            } catch (e: Exception) {
                Log.e(TAG, "DEBUG: Failed to decode base64 from args", e)
                null
            }
        }
        
        // Попытка 2: Чтение из системных переменных окружения
        b64 = System.getenv(b64Key)
        if (!b64.isNullOrBlank()) {
            Log.d(TAG, "DEBUG: Found config in environment: $b64Key")
            return try {
                String(Base64.decode(b64, Base64.DEFAULT))
            } catch (e: Exception) {
                Log.e(TAG, "DEBUG: Failed to decode base64 from env", e)
                null
            }
        }
        
        // Попытка 3: Fallback на plain key
        val plain = args.getString(plainKey)
        if (!plain.isNullOrBlank()) {
            Log.d(TAG, "DEBUG: Found config as plain text: $plainKey")
            return plain
        }
        
        Log.w(TAG, "DEBUG: Config not found in args or env: $b64Key / $plainKey")
        return null
    }

    private fun waitForRunning(timeoutMs: Long): Boolean {
        val start = System.currentTimeMillis()
        while (System.currentTimeMillis() - start < timeoutMs) {
            if (GraniVpnService.isVpnRunning()) {
                return true
            }
            Thread.sleep(200)
        }
        return false
    }

    private fun ensureVpnPermission(context: android.content.Context): Boolean {
        // Проверяем, нужно ли использовать mock (для Firebase Test Lab)
        if (shouldUseMockPermission()) {
            Log.d(TAG, "DEBUG: Using mock VPN permission (Firebase Test Lab mode)")
            return ensureVpnPermissionMock()
        }
        
        // Реальная логика для локального тестирования
        return ensureVpnPermissionReal(context)
    }

    /**
     * Определяет, нужно ли использовать mock для VPN разрешения.
     * Mock используется в Firebase Test Lab, где UI Automator не может взаимодействовать
     * с системными диалогами из-за процессной изоляции.
     */
    private fun shouldUseMockPermission(): Boolean {
        val args = InstrumentationRegistry.getArguments()
        
        // Проверка через instrumentation arguments
        val mockFlag = args.getString("mock_vpn_permission")
        if (mockFlag == "true") {
            Log.d(TAG, "DEBUG: Mock flag found in instrumentation args")
            return true
        }
        
        // Проверка через environment variables
        val envMock = System.getenv("mock_vpn_permission")
        if (envMock == "true") {
            Log.d(TAG, "DEBUG: Mock flag found in environment")
            return true
        }
        
        // Проверка через Firebase Test Lab environment variable
        val firebaseTestLab = System.getenv("FIREBASE_TEST_LAB")
        if (firebaseTestLab == "true") {
            Log.d(TAG, "DEBUG: Firebase Test Lab environment detected")
            return true
        }
        
        return false
    }

    /**
     * Mock-версия: всегда возвращает true (разрешение уже выдано).
     * Используется в Firebase Test Lab, где мы не можем автоматически выдать разрешение.
     */
    private fun ensureVpnPermissionMock(): Boolean {
        Log.d(TAG, "DEBUG: Mock VPN permission granted (always true)")
        return true
    }

    /**
     * Реальная логика выдачи VPN разрешения через UI Automator.
     * Используется для локального тестирования на эмуляторе или физическом устройстве.
     */
    private fun ensureVpnPermissionReal(context: android.content.Context): Boolean {
        val intent = VpnService.prepare(context)
        if (intent == null) {
            Log.d(TAG, "DEBUG: VPN permission already granted")
            return true
        }
        
        Log.d(TAG, "DEBUG: Requesting VPN permission...")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)

        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        
        // Даем время на появление диалога
        Log.d(TAG, "DEBUG: Waiting for VPN dialog to appear...")
        Thread.sleep(3000)

        // Увеличиваем таймауты для поиска кнопки
        val timeoutMs = 15000L
        var permissionGranted = false

        // Попытка 1: По разным resource IDs
        val resourceIds = listOf(
            "android:id/button1",
            "android:id/button_positive",
            "android:id/ok",
            "android:id/allow"
        )
        
        for (resId in resourceIds) {
            if (permissionGranted) break
            
            try {
                val parts = resId.split("/")
                val button = device.wait(
                    Until.findObject(By.res(parts[0], parts[1])), 
                    3000L
                )
                if (button != null) {
                    Log.d(TAG, "DEBUG: Found button by resource ID: $resId")
                    button.click()
                    Thread.sleep(2000)
                    permissionGranted = VpnService.prepare(context) == null
                    if (permissionGranted) {
                        Log.d(TAG, "DEBUG: Permission granted via resource ID: $resId")
                        break
                    }
                }
            } catch (e: Exception) {
                Log.d(TAG, "DEBUG: Failed to find button by $resId: ${e.message}")
            }
        }

        // Попытка 2: Поиск всех кнопок в диалоге и проверка текста
        if (!permissionGranted) {
            Log.d(TAG, "DEBUG: Searching for all buttons in dialog...")
            try {
                val buttons = device.findObjects(By.clazz("android.widget.Button"))
                Log.d(TAG, "DEBUG: Found ${buttons.size} buttons")
                
                for (button in buttons) {
                    if (permissionGranted) break
                    
                    val text = button.text?.toString()?.lowercase() ?: ""
                    val contentDesc = button.contentDescription?.toString()?.lowercase() ?: ""
                    
                    Log.d(TAG, "DEBUG: Button text: '$text', desc: '$contentDesc'")
                    
                    if (text.contains("ok") || text.contains("allow") || 
                        text.contains("разрешить") || text.contains("yes") ||
                        text.contains("подтвердить") || text.contains("accept") ||
                        contentDesc.contains("ok") || contentDesc.contains("allow")) {
                        
                        Log.d(TAG, "DEBUG: Found matching button, clicking...")
                        button.click()
                        Thread.sleep(2000)
                        permissionGranted = VpnService.prepare(context) == null
                        if (permissionGranted) {
                            Log.d(TAG, "DEBUG: Permission granted via button text: '$text'")
                            break
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "DEBUG: Error searching for buttons: ${e.message}", e)
            }
        }

        // Попытка 3: Поиск по тексту (fallback на старый метод)
        if (!permissionGranted) {
            val textSearches = listOf("OK", "Allow", "Разрешить", "Yes", "Подтвердить", "Accept")
            for (text in textSearches) {
                if (permissionGranted) break
                
                val button = device.wait(Until.findObject(By.textContains(text)), 2000L)
                if (button != null) {
                    Log.d(TAG, "DEBUG: Found button by text: '$text'")
                    button.click()
                    Thread.sleep(2000)
                    permissionGranted = VpnService.prepare(context) == null
                    if (permissionGranted) {
                        Log.d(TAG, "DEBUG: Permission granted via text search: '$text'")
                        break
                    }
                }
            }
        }

        // Попытка 4: Fallback на координаты (если ничего не помогло)
        if (!permissionGranted) {
            Log.d(TAG, "DEBUG: Trying fallback: clicking center-bottom of screen (typical button location)")
            try {
                val displayWidth = device.displayWidth
                val displayHeight = device.displayHeight
                // Кнопка обычно находится внизу по центру
                val x = displayWidth / 2
                val y = displayHeight - 200 // Примерные координаты кнопки
                Log.d(TAG, "DEBUG: Clicking at ($x, $y)")
                device.click(x, y)
                Thread.sleep(2000)
                permissionGranted = VpnService.prepare(context) == null
            } catch (e: Exception) {
                Log.e(TAG, "DEBUG: Error in fallback click: ${e.message}", e)
            }
        }

        Log.d(TAG, "DEBUG: VPN permission final status: $permissionGranted")
        return permissionGranted
    }

    /**
     * Verifies that VPN is actually routing traffic by checking traffic statistics.
     * This ensures that the VPN connection is not just started, but actually working.
     */
    private fun verifyVpnTraffic(context: android.content.Context) {
        // Wait for VPN to establish connection
        Thread.sleep(5000)

        // Get initial traffic stats
        val initialStats = GraniVpnService.getTrafficStatsSnapshot()
        val initialRx = initialStats["rx_bytes"] ?: 0L
        val initialTx = initialStats["tx_bytes"] ?: 0L

        // Generate some test traffic through VPN
        generateTestTraffic()

        // Wait for traffic to be processed
        Thread.sleep(3000)

        // Get final traffic stats
        val finalStats = GraniVpnService.getTrafficStatsSnapshot()
        val finalRx = finalStats["rx_bytes"] ?: 0L
        val finalTx = finalStats["tx_bytes"] ?: 0L

        // Verify that traffic increased (VPN is routing traffic)
        val rxIncreased = finalRx > initialRx
        val txIncreased = finalTx > initialTx

        // At least one direction should show traffic
        assertTrue(
            "VPN is not routing traffic. Initial: rx=$initialRx, tx=$initialTx; Final: rx=$finalRx, tx=$finalTx",
            rxIncreased || txIncreased
        )
    }

    /**
     * Generates test network traffic through VPN to verify connectivity.
     */
    private fun generateTestTraffic() {
        try {
            // Simple HTTP request through VPN
            val url = java.net.URL("http://8.8.8.8")
            val connection = url.openConnection() as java.net.HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.requestMethod = "GET"
            connection.connect()
            connection.inputStream.readBytes() // Read response to generate traffic
            connection.disconnect()
        } catch (e: Exception) {
            // Ignore errors - main goal is to generate traffic, not to get response
            // If VPN is working, traffic will be routed even if request fails
        }
    }
}
