package com.granivpn.test

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MinimalVpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var pendingVpnConfig: String? = null
    private var pendingResult: MethodChannel.Result? = null
    private var vpnPermissionLauncher: ActivityResultLauncher<Intent>? = null

    companion object {
        private const val CHANNEL_NAME = "com.granivpn.test/vpn"
        private const val TAG = "MinimalVpnPlugin"
        private const val VPN_REQUEST_CODE = 100
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        Log.d(TAG, "MinimalVpnPlugin attached to engine")
    }
    
    fun attachToEngine(binaryMessenger: io.flutter.plugin.common.BinaryMessenger) {
        channel = MethodChannel(binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        Log.d(TAG, "MinimalVpnPlugin attached to engine (direct)")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        Log.d(TAG, "MinimalVpnPlugin detached from engine")
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        
        // Регистрируем ActivityResultLauncher для VPN разрешения
        if (activity is androidx.activity.ComponentActivity) {
            val componentActivity = activity as androidx.activity.ComponentActivity
            vpnPermissionLauncher = componentActivity.registerForActivityResult(
                ActivityResultContracts.StartActivityForResult()
            ) { result ->
                handleVpnPermissionResult(result.resultCode)
            }
            Log.d(TAG, "ActivityResultLauncher зарегистрирован для VPN разрешения")
        }
    }

    override fun onDetachedFromActivity() {
        activity = null
        vpnPermissionLauncher = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }
    
    private fun handleVpnPermissionResult(resultCode: Int) {
        if (resultCode == Activity.RESULT_OK) {
            Log.d(TAG, "Пользователь разрешил VPN подключение")
            if (pendingVpnConfig != null) {
                val result = pendingResult
                startVpnConnection(pendingVpnConfig!!, result)
            } else {
                pendingResult?.success(true)
                pendingResult = null
            }
        } else {
            Log.w(TAG, "Пользователь отклонил VPN разрешение")
            pendingResult?.error(
                "PERMISSION_DENIED", 
                "VPN разрешение отклонено", 
                null
            )
            pendingResult = null
            pendingVpnConfig = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> {
                val config = call.argument<String>("config")
                if (config == null) {
                    result.error("INVALID_ARGUMENT", "Config is required", null)
                    return
                }
                connectVpn(config, result)
            }
            "disconnect" -> {
                disconnectVpn(result)
            }
            "getStatus" -> {
                val vpnService = MinimalVpnService.getInstance()
                result.success(vpnService?.isConnected() ?: false)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun connectVpn(config: String, result: MethodChannel.Result) {
        Log.d(TAG, "connectVpn: Начало подключения VPN, длина конфигурации=${config.length}")
        
        try {
            if (activity == null) {
                Log.e(TAG, "connectVpn: Activity недоступна")
                result.error("ACTIVITY_NULL", "Activity недоступна", null)
                return
            }
            
            // Запрашиваем VPN разрешение
            val intent = VpnService.prepare(activity)
            if (intent != null) {
                // Нужно разрешение
                Log.d(TAG, "connectVpn: Требуется VPN разрешение")
                pendingVpnConfig = config
                pendingResult = result
                
                if (vpnPermissionLauncher != null) {
                    vpnPermissionLauncher!!.launch(intent)
                } else {
                    // Fallback на старый API
                    activity!!.startActivityForResult(intent, VPN_REQUEST_CODE)
                }
            } else {
                // Разрешение уже есть, подключаемся
                Log.d(TAG, "connectVpn: VPN разрешение уже есть, подключаемся")
                startVpnConnection(config, result)
            }
        } catch (e: Exception) {
            Log.e(TAG, "connectVpn: Ошибка: ${e.message}", e)
            result.error("CONNECTION_ERROR", "Ошибка подключения: ${e.message}", null)
        }
    }

    private fun startVpnConnection(config: String, result: MethodChannel.Result?) {
        try {
            val vpnService = MinimalVpnService.getInstance()
            if (vpnService == null) {
                // Запускаем сервис как foreground service (требуется с Android 8.0)
                val intent = Intent(activity, MinimalVpnService::class.java)
                
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    activity!!.startForegroundService(intent)
                } else {
                    activity!!.startService(intent)
                }
                
                Log.d(TAG, "startVpnConnection: Сервис запущен, ждем инициализации...")
                
                // Ждем инициализации сервиса (увеличиваем время ожидания)
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    var attempts = 0
                    val maxAttempts = 10
                    
                    // Пробуем несколько раз, так как сервис может инициализироваться с задержкой
                    fun tryConnect() {
                        val service = MinimalVpnService.getInstance()
                        if (service != null) {
                            Log.d(TAG, "startVpnConnection: Сервис найден, подключаемся...")
                            val connected = service.connect(config)
                            result?.success(connected)
                        } else if (attempts < maxAttempts) {
                            attempts++
                            Log.d(TAG, "startVpnConnection: Попытка $attempts/$maxAttempts найти сервис...")
                            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                tryConnect()
                            }, 200)
                        } else {
                            Log.e(TAG, "startVpnConnection: Сервис не найден после $maxAttempts попыток")
                            result?.error("SERVICE_ERROR", "Не удалось запустить VPN сервис", null)
                        }
                    }
                    
                    tryConnect()
                }, 300)
            } else {
                Log.d(TAG, "startVpnConnection: Сервис уже существует, подключаемся...")
                val connected = vpnService.connect(config)
                result?.success(connected)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startVpnConnection: Ошибка: ${e.message}", e)
            result?.error("CONNECTION_ERROR", "Ошибка подключения: ${e.message}", null)
        }
    }

    private fun disconnectVpn(result: MethodChannel.Result) {
        try {
            val vpnService = MinimalVpnService.getInstance()
            if (vpnService != null) {
                val disconnected = vpnService.disconnect()
                result.success(disconnected)
            } else {
                result.success(false)
            }
        } catch (e: Exception) {
            Log.e(TAG, "disconnectVpn: Ошибка: ${e.message}", e)
            result.error("DISCONNECT_ERROR", "Ошибка отключения: ${e.message}", null)
        }
    }
}
