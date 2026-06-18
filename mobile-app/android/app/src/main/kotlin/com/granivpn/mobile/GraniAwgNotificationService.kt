package com.granivpn.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat

class GraniAwgNotificationService : Service() {
    private var stopRequested = false

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLocaleHelper.wrapContext(newBase))
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopRequested = true
            NativeVpnRuntimeState.markAwgExpectedUp(applicationContext, false)
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        if (!NativeVpnRuntimeState.isAwgLikelyActive(applicationContext)) {
            Log.i(TAG, "start ignored: AWG is not active/expected")
            stopSelf()
            return START_NOT_STICKY
        }

        stopRequested = false
        ensureForeground(createNotification())
        NativeVpnRuntimeState.notifyQuickTile(applicationContext)
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (NativeVpnRuntimeState.isAwgLikelyActive(applicationContext)) {
            Log.i(TAG, "onTaskRemoved: AWG is up, keeping foreground holder alive")
            ensureForeground(createNotification())
            requestForegroundHolderRestart("task_removed")
            NativeVpnRuntimeState.notifyQuickTile(applicationContext)
            return
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (!stopRequested && NativeVpnRuntimeState.isAwgLikelyActive(applicationContext)) {
            Log.w(TAG, "destroyed while AWG is UP; requesting foreground holder restart")
            requestForegroundHolderRestart("destroy")
            NativeVpnRuntimeState.notifyQuickTile(applicationContext)
        } else {
            stopForegroundCompat()
        }
        super.onDestroy()
        Log.d(TAG, "destroyed")
    }

    private fun ensureForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun requestForegroundHolderRestart(source: String) {
        val appContext = applicationContext
        try {
            start(appContext)
        } catch (e: Exception) {
            Log.w(TAG, "restart foreground holder failed source=$source", e)
        }
        Handler(Looper.getMainLooper()).postDelayed({
            if (!stopRequested && NativeVpnRuntimeState.isAwgLikelyActive(appContext)) {
                try {
                    start(appContext)
                } catch (e: Exception) {
                    Log.w(TAG, "delayed restart foreground holder failed source=$source", e)
                }
            }
        }, 750L)
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        cancelNotification(this)
    }

    private fun createNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.vpn_notification_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(getString(R.string.vpn_notification_title))
            .setContentText(getString(R.string.vpn_notification_connected))
            .setSmallIcon(R.drawable.ic_notification_g)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    companion object {
        private const val TAG = "GraniAwgNotifService"
        private const val CHANNEL_ID = "grani_vpn_channel"
        private const val NOTIFICATION_ID = 1002
        private const val ACTION_START = "com.granivpn.mobile.action.START_AWG_NOTIFICATION"
        private const val ACTION_STOP = "com.granivpn.mobile.action.STOP_AWG_NOTIFICATION"

        fun start(context: Context) {
            val intent = Intent(context.applicationContext, GraniAwgNotificationService::class.java).apply {
                action = ACTION_START
            }
            ContextCompat.startForegroundService(context.applicationContext, intent)
        }

        fun stop(context: Context) {
            val appContext = context.applicationContext
            NativeVpnRuntimeState.markAwgExpectedUp(appContext, false)
            cancelNotification(appContext)
            try {
                val intent = Intent(appContext, GraniAwgNotificationService::class.java).apply {
                    action = ACTION_STOP
                }
                appContext.startService(intent)
            } catch (e: Exception) {
                Log.w(TAG, "stop: failed to deliver stop intent", e)
            }
        }

        fun cancelNotification(context: Context) {
            try {
                val manager =
                    context.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.cancel(NOTIFICATION_ID)
            } catch (e: Exception) {
                Log.w(TAG, "cancelNotification: failed", e)
            }
        }
    }
}
