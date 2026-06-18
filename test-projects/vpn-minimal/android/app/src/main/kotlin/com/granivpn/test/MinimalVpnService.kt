package com.granivpn.test

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.ServiceCompat

class MinimalVpnService : VpnService() {
    companion object {
        private const val TAG = "MinimalVpnService"
        private const val NOTIFICATION_CHANNEL_ID = "minimal_vpn_channel"
        private const val NOTIFICATION_ID = 1001
        private var instance: MinimalVpnService? = null
        
        fun getInstance(): MinimalVpnService? = instance
    }
    
    private var vpnInterface: ParcelFileDescriptor? = null
    private var isRunning = false
    
    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        Log.d(TAG, "MinimalVpnService создан")
    }
    
    override fun onDestroy() {
        super.onDestroy()
        disconnect()
        instance = null
        Log.d(TAG, "MinimalVpnService уничтожен")
    }
    
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "VPN Minimal Test",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "VPN connection status"
            }
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }
    
    fun connect(config: String): Boolean {
        if (isRunning) {
            Log.w(TAG, "VPN уже запущен")
            return false
        }
        
        try {
            Log.d(TAG, "Подключение VPN с конфигурацией (${config.length} символов)")
            Log.d(TAG, "Конфигурация (первые 200 символов): ${config.take(200)}")
            
            // Запускаем foreground service
            startForeground(NOTIFICATION_ID, createNotification("Подключение VPN..."))
            
            // Создаем VPN интерфейс
            val builder = Builder()
            builder.setSession("MinimalVPN")
            builder.addAddress("10.0.0.2", 30)
            builder.addRoute("0.0.0.0", 0)
            builder.addDnsServer("8.8.8.8")
            builder.addDnsServer("8.8.4.4")
            builder.setMtu(1420)
            
            Log.d(TAG, "Создание VPN интерфейса...")
            vpnInterface = builder.establish()
            
            if (vpnInterface == null) {
                Log.e(TAG, "Не удалось создать VPN интерфейс")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(ServiceCompat.STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                return false
            }
            
            isRunning = true
            updateNotification("VPN подключен")
            Log.i(TAG, "✅ VPN интерфейс создан успешно")
            Log.i(TAG, "File descriptor: ${vpnInterface!!.fd}")
            
            // TODO: Здесь будет интеграция с библиотеками протоколов
            // Пока просто создаем интерфейс для тестирования
            
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка подключения VPN: ${e.message}", e)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(ServiceCompat.STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            return false
        }
    }
    
    fun disconnect(): Boolean {
        if (!isRunning) {
            return false
        }
        
        try {
            Log.d(TAG, "Отключение VPN")
            
            vpnInterface?.close()
            vpnInterface = null
            isRunning = false
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(ServiceCompat.STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            Log.i(TAG, "✅ VPN отключен успешно")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка отключения VPN: ${e.message}", e)
            return false
        }
    }
    
    fun isConnected(): Boolean = isRunning
    
    private fun createNotification(text: String): Notification {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle("VPN Minimal Test")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("VPN Minimal Test")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .build()
        }
    }
    
    private fun updateNotification(text: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, createNotification(text))
    }
}
