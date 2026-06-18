package com.granivpn.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.google.firebase.messaging.RemoteMessage

/**
 * Параллельно [io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingReceiver]:
 * при data payload `grani_action=stop_vpn` сразу останавливает VPN без ожидания Flutter engine.
 *
 * Контракт ключей — `EntitlementPushContract` (Dart) и `services/notification_service.py` на бэкенде.
 */
class EntitlementFcmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras ?: return
        try {
            val msg = RemoteMessage(extras)
            val data = msg.data
            if (data.isNullOrEmpty()) {
                return
            }
            val action = data[ACTION_KEY]?.trim()
            if (action != STOP_VPN) {
                return
            }
            val reason = data[REASON_KEY]?.trim()?.takeIf { it.isNotEmpty() }
            if (reason == null || !ALLOWED_STOP_REASONS.contains(reason)) {
                Log.w(TAG, "FCM entitlement: ignored stop_vpn with unsupported reason=${reason ?: "missing"}")
                EntitlementAuthSyncBridge.notifyAuthRefreshAfterEntitlementStop(
                    context,
                    traceSource = "fcm_native_stop_ignored:${reason ?: "missing"}",
                )
                return
            }
            Log.i(TAG, "FCM entitlement: stop VPN (reason=$reason)")
            try {
                SimpleAmneziaWgRunner.disconnect()
                GraniAwgNotificationService.stop(context.applicationContext)
            } catch (e: Exception) {
                Log.w(TAG, "AmneziaWG stop failed: ${e.message}")
            }
            GraniVpnService.stopService(
                context.applicationContext,
                source = "fcm_data_message",
                reason = reason,
                connectionSessionId = null,
            )
            QuickTileService.notifyVpnStateChanged(context.applicationContext)
            showStopNotification(context.applicationContext, msg)
            EntitlementAuthSyncBridge.notifyAuthRefreshAfterEntitlementStop(
                context,
                traceSource = "fcm_native_stop:$reason",
            )
        } catch (e: Exception) {
            Log.w(TAG, "parse/stop: ${e.message}")
        }
    }

    private fun showStopNotification(context: Context, msg: RemoteMessage) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "GRANI notifications",
                    NotificationManager.IMPORTANCE_DEFAULT,
                )
            )
        }
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = msg.notification?.title?.takeIf { it.isNotBlank() }
            ?: "Подписка истекла"
        val body = msg.notification?.body?.takeIf { it.isNotBlank() }
            ?: "Продлите подписку в приложении GRANI"
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_notification_g)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    companion object {
        private const val TAG = "EntitlementFcmRcvr"
        private const val CHANNEL_ID = "grani_notifications"
        private const val NOTIFICATION_ID = 1004
        const val ACTION_KEY = "grani_action"
        const val REASON_KEY = "reason"
        const val STOP_VPN = "stop_vpn"
        private val ALLOWED_STOP_REASONS = setOf(
            "subscription_expired",
            "subscription_revoked",
            "trial_ended",
            "access_expired",
            "logout",
            "auth_lost",
            "device_limit",
            "device_revoked",
        )
    }
}
