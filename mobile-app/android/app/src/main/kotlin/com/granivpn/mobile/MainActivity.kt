package com.granivpn.mobile

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class MainActivity: FlutterFragmentActivity() {
    private var vpnPlugin: VpnPlugin? = null
    private val activityResultListeners = mutableListOf<PluginRegistry.ActivityResultListener>()

    override fun onCreate(savedInstanceState: Bundle?) {
        Log.d("ACTIVITY", "onCreate ts=${System.currentTimeMillis()} saved=${savedInstanceState != null}")
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        Log.d("ACTIVITY", "onDestroy ts=${System.currentTimeMillis()}")
        try {
            FlutterEngineCache.getInstance().remove(EntitlementAuthSyncBridge.ENGINE_CACHE_ID)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        Log.d(
            "ACTIVITY",
            "onConfigurationChanged uiMode=${newConfig.uiMode} smallestWidthDp=${newConfig.smallestScreenWidthDp}",
        )
        super.onConfigurationChanged(newConfig)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        Log.d(
            "ACTIVITY",
            "onNewIntent quick_tile_action=${intent.getStringExtra(QuickTileService.EXTRA_QUICK_TILE_ACTION) ?: "-"}",
        )
    }

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLocaleHelper.wrapContext(newBase))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // We register plugins manually to skip wireguard_flutter auto-registration:
        // the plugin currently crashes on FlutterFragmentActivity with ClassCastException.
        SafePluginRegistrant.registerWith(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.granivpn.mobile/notifications")
            .setMethodCallHandler { call, result ->
                if (call.method == "createNotificationChannel") {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val id = call.argument<String>("id") ?: "grani_notifications"
                        val name = call.argument<String>("name") ?: "GRANI"
                        val desc = call.argument<String>("description") ?: ""
                        val importance = call.argument<Int>("importance") ?: NotificationManager.IMPORTANCE_HIGH
                        val channel = NotificationChannel(id, name, importance).apply {
                            description = desc
                        }
                        val nm = getSystemService(NotificationManager::class.java)
                        nm.createNotificationChannel(channel)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        try {
            // Регистрируем VPN плагин
            vpnPlugin = VpnPlugin()
            
            // Инициализируем плагин напрямую через BinaryMessenger
            // Это обходит проблему с FlutterPluginBinding (который является классом, а не интерфейсом)
            vpnPlugin?.attachToEngine(flutterEngine.dartExecutor.binaryMessenger)
            
            // Привязываем activity только если плагин успешно инициализирован
            vpnPlugin?.let { plugin ->
                val activityBinding: ActivityPluginBinding = object : ActivityPluginBinding {
                    private val currentActivity: Activity = this@MainActivity
                    private val currentLifecycle: androidx.lifecycle.Lifecycle = lifecycle
                    
                    override fun getActivity(): Activity = currentActivity
                    override fun getLifecycle(): androidx.lifecycle.Lifecycle = currentLifecycle
                    
                    override fun addRequestPermissionsResultListener(listener: PluginRegistry.RequestPermissionsResultListener) {
                        // Реализация для permissions (если понадобится в будущем)
                    }
                    
                    override fun removeRequestPermissionsResultListener(listener: PluginRegistry.RequestPermissionsResultListener) {
                        // Реализация для permissions (если понадобится в будущем)
                    }
                    
                    override fun addActivityResultListener(listener: PluginRegistry.ActivityResultListener) {
                        synchronized(activityResultListeners) {
                            activityResultListeners.add(listener)
                        }
                        Log.d("MainActivity", "Добавлен ActivityResultListener, всего: ${activityResultListeners.size}")
                    }
                    
                    override fun removeActivityResultListener(listener: PluginRegistry.ActivityResultListener) {
                        synchronized(activityResultListeners) {
                            activityResultListeners.remove(listener)
                        }
                        Log.d("MainActivity", "Удален ActivityResultListener, осталось: ${activityResultListeners.size}")
                    }
                    
                    override fun addOnNewIntentListener(listener: PluginRegistry.NewIntentListener) {}
                    override fun removeOnNewIntentListener(listener: PluginRegistry.NewIntentListener) {}
                    override fun addOnUserLeaveHintListener(listener: PluginRegistry.UserLeaveHintListener) {}
                    override fun removeOnUserLeaveHintListener(listener: PluginRegistry.UserLeaveHintListener) {}
                    override fun addOnWindowFocusChangedListener(listener: PluginRegistry.WindowFocusChangedListener) {}
                    override fun removeOnWindowFocusChangedListener(listener: PluginRegistry.WindowFocusChangedListener) {}
                    override fun addOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) {}
                    override fun removeOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) {}
                }
                
                plugin.onAttachedToActivity(activityBinding)
            }
        } catch (e: Exception) {
            // Логируем ошибку, но не крашим приложение
            Log.e("MainActivity", "Ошибка инициализации VPN плагина: ${e.message}", e)
            // Приложение продолжит работать без VPN плагина
        }

        FlutterEngineCache.getInstance().put(EntitlementAuthSyncBridge.ENGINE_CACHE_ID, flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EntitlementAuthSyncBridge.CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "takePendingEntitlementAuthSync") {
                    val (pending, src) = EntitlementAuthSyncBridge.takePendingAndClear(applicationContext)
                    result.success(
                        mapOf(
                            "pending" to pending,
                            "source" to src,
                        ),
                    )
                } else {
                    result.notImplemented()
                }
            }
    }
    
    // Устаревший метод onActivityResult оставлен для обратной совместимости
    // но основной функционал теперь работает через ActivityResultLauncher
    @Deprecated("Используется только для обратной совместимости. Основной функционал через ActivityResultLauncher.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        // Уведомляем все зарегистрированные слушатели (для обратной совместимости)
        synchronized(activityResultListeners) {
            activityResultListeners.forEach { listener ->
                try {
                    listener.onActivityResult(requestCode, resultCode, data)
                } catch (e: Exception) {
                    Log.e("MainActivity", "Ошибка в ActivityResultListener: ${e.message}", e)
                }
            }
        }
        
        // Также передаем результат в VPN плагин (только VPN_REQUEST_CODE). Другие requestCode (напр. Google Sign-In) — ожидаемо не обрабатываются.
        vpnPlugin?.let { plugin ->
            try {
                plugin.handleActivityResult(requestCode, resultCode, data)
            } catch (e: Exception) {
                Log.e("MainActivity", "Ошибка обработки результата в VPN плагине: ${e.message}", e)
            }
        }
    }
}
