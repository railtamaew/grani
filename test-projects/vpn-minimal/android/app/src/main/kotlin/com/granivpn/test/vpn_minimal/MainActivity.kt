package com.granivpn.test.vpn_minimal

import android.app.Activity
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import com.granivpn.test.MinimalVpnPlugin

class MainActivity : FlutterActivity() {
    private var vpnPlugin: MinimalVpnPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        try {
            // Регистрируем VPN плагин
            vpnPlugin = MinimalVpnPlugin()
            vpnPlugin?.attachToEngine(flutterEngine.dartExecutor.binaryMessenger)
            
            // Привязываем activity
            vpnPlugin?.let { plugin ->
                val activityBinding: ActivityPluginBinding = object : ActivityPluginBinding {
                    private val currentActivity: Activity = this@MainActivity
                    private val currentLifecycle: androidx.lifecycle.Lifecycle = lifecycle
                    
                    override fun getActivity(): Activity = currentActivity
                    override fun getLifecycle(): androidx.lifecycle.Lifecycle = currentLifecycle
                    override fun addRequestPermissionsResultListener(listener: io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener) {}
                    override fun removeRequestPermissionsResultListener(listener: io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener) {}
                    override fun addActivityResultListener(listener: io.flutter.plugin.common.PluginRegistry.ActivityResultListener) {}
                    override fun removeActivityResultListener(listener: io.flutter.plugin.common.PluginRegistry.ActivityResultListener) {}
                    override fun addOnNewIntentListener(listener: io.flutter.plugin.common.PluginRegistry.NewIntentListener) {}
                    override fun removeOnNewIntentListener(listener: io.flutter.plugin.common.PluginRegistry.NewIntentListener) {}
                    override fun addOnUserLeaveHintListener(listener: io.flutter.plugin.common.PluginRegistry.UserLeaveHintListener) {}
                    override fun removeOnUserLeaveHintListener(listener: io.flutter.plugin.common.PluginRegistry.UserLeaveHintListener) {}
                    override fun addOnWindowFocusChangedListener(listener: io.flutter.plugin.common.PluginRegistry.WindowFocusChangedListener) {}
                    override fun removeOnWindowFocusChangedListener(listener: io.flutter.plugin.common.PluginRegistry.WindowFocusChangedListener) {}
                    override fun addOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) {}
                    override fun removeOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) {}
                }
                
                plugin.onAttachedToActivity(activityBinding)
            }
            
            Log.d("MainActivity", "VPN плагин успешно инициализирован")
        } catch (e: Exception) {
            Log.e("MainActivity", "Ошибка инициализации VPN плагина: ${e.message}", e)
        }
    }
}
