package com.granivpn.mobile

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat

@RequiresApi(Build.VERSION_CODES.N)
class QuickTileService : TileService() {

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLocaleHelper.wrapContext(newBase))
    }

    companion object {
        const val EXTRA_INITIAL_ROUTE = "com.granivpn.mobile.INITIAL_ROUTE"
        const val EXTRA_QUICK_TILE_ACTION = "com.granivpn.mobile.QUICK_TILE_ACTION"
        const val QUICK_TILE_ACTION_TOGGLE = "toggle"
        private const val TAG = "QuickTileService"
        private const val CLICK_DEBOUNCE_MS = 2000L
        private const val QUICK_TILE_NOTICE_CHANNEL_ID = "grani_quick_tile"
        private const val QUICK_TILE_NOTICE_ID = 4207

        private val tileListeningLock = Any()
        @Volatile private var listeningInstance: QuickTileService? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        /**
         * Вызывать при любом изменении VPN (старт/стоп), в том числе с фонового потока.
         *
         * Пока шторка открыта, плитка уже в режиме listening — система не зовёт повторно
         * [onStartListening], и один лишь [TileService.requestListeningState] не обновляет UI.
         * Обновляем привязанный экземпляр на main и дублируем системным API для закрытой шторки.
         */
        fun notifyVpnStateChanged(context: Context) {
            val app = context.applicationContext
            mainHandler.post {
                synchronized(tileListeningLock) {
                    listeningInstance?.updateTileState()
                }
                try {
                    TileService.requestListeningState(
                        app,
                        ComponentName(app, QuickTileService::class.java)
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "notifyVpnStateChanged: requestListeningState failed", e)
                }
            }
        }

        fun showQuickTileNotice(
            context: Context,
            message: String,
            routeToSubscription: Boolean = false,
        ) {
            val app = context.applicationContext
            if (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(
                    app,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                Log.i(TAG, "quick_tile_notice_skipped: notification permission denied")
                return
            }

            val manager = app.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    QUICK_TILE_NOTICE_CHANNEL_ID,
                    app.getString(R.string.app_name),
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = app.getString(R.string.quick_tile_label)
                }
                manager.createNotificationChannel(channel)
            }

            val intent = Intent(app, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(EXTRA_INITIAL_ROUTE, if (routeToSubscription) "/subscription" else "/main")
            }
            val pendingIntent = PendingIntent.getActivity(
                app,
                if (routeToSubscription) 1 else 0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(app, QUICK_TILE_NOTICE_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(app)
            }

            val notification = builder
                .setSmallIcon(R.drawable.ic_notification_g)
                .setContentTitle(app.getString(R.string.app_name))
                .setContentText(message)
                .setStyle(Notification.BigTextStyle().bigText(message))
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setShowWhen(false)
                .build()

            manager.notify(QUICK_TILE_NOTICE_ID, notification)
        }
    }

    private var iconOn: Icon? = null
    private var iconOff: Icon? = null
    private var lastClickMs = 0L

    override fun onCreate() {
        super.onCreate()
        // Единый фирменный знак G, чтобы совпадал с notification/status bar.
        iconOn = Icon.createWithResource(this, R.drawable.ic_notification_g)
        iconOff = Icon.createWithResource(this, R.drawable.ic_notification_g)
    }

    override fun onStartListening() {
        synchronized(tileListeningLock) {
            listeningInstance = this
        }
        updateTileState()
    }

    override fun onStopListening() {
        synchronized(tileListeningLock) {
            if (listeningInstance === this) listeningInstance = null
        }
        super.onStopListening()
    }

    override fun onClick() {
        unlockAndRun { handleClick() }
    }

    private fun handleClick() {
        val now = System.currentTimeMillis()
        if (now - lastClickMs < CLICK_DEBOUNCE_MS) return
        lastClickMs = now

        setTilePending()

        val running = NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(applicationContext)
        if (running) {
            Log.i(TAG, "quick_tile_click: disconnect in native background")
            Thread {
                try {
                    VpnRuntimeCoordinator.disconnect(
                        applicationContext,
                        source = "quick_tile",
                        reason = "user",
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "quick_tile_disconnect_failed", e)
                } finally {
                    notifyVpnStateChanged(applicationContext)
                }
            }.start()
            return
        }

        if (!running && !VpnPlugin.isAllowTileConnect(applicationContext)) {
            showQuickTileNotice(
                this,
                getString(R.string.quick_tile_subscription_required),
                routeToSubscription = true
            )
            updateTileState()
            openMainActivity(routeToSubscription = true)
            return
        }

        val lastConfig = VpnPlugin.loadLastConfig(applicationContext)
        if (lastConfig == null || lastConfig.config.isBlank()) {
            showQuickTileNotice(this, getString(R.string.quick_tile_no_config))
            updateTileState()
            openMainActivity(routeToSubscription = false, quickTileToggle = true)
            return
        }

        val permissionIntent = VpnService.prepare(this)
        if (permissionIntent != null) {
            updateTileState()
            val toggleIntent = Intent(this, QuickTileToggleActivity::class.java)
            toggleIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(toggleIntent)
            return
        }

        Log.i(TAG, "quick_tile_click: connect cached config in native background")
        startCachedConfig(lastConfig.config, lastConfig.protocol, lastConfig.mtu)
    }

    private fun startCachedConfig(config: String, protocol: String?, mtu: Int) {
        Thread {
            try {
                VpnRuntimeCoordinator.connect(
                    applicationContext,
                    config,
                    protocol,
                    mtu,
                    source = "quick_tile_cached",
                )
            } catch (e: Exception) {
                Log.e(TAG, "quick_tile_connect_failed", e)
                mainHandler.post {
                    showQuickTileNotice(
                        this,
                        getString(R.string.quick_tile_no_config)
                    )
                }
            } finally {
                notifyVpnStateChanged(applicationContext)
            }
        }.start()
    }

    private fun setTilePending() {
        val tile = qsTile ?: return
        // Отображаем промежуточное состояние «подключение/отключение».
        tile.state = Tile.STATE_ACTIVE
        tile.label = getString(R.string.quick_tile_label)
        tile.updateTile()
    }

    private fun updateTileState() {
        val tile = qsTile ?: return
        tile.label = getString(R.string.quick_tile_label)
        val running = NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(applicationContext)
        if (running) {
            NativeVpnRuntimeState.reconcileAwgNotification(applicationContext, "quick_tile_update")
        }
        tile.state = if (running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.icon = if (running) iconOn else iconOff
        tile.updateTile()
    }

    private fun openMainActivity(
        routeToSubscription: Boolean = false,
        quickTileToggle: Boolean = false,
    ) {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_INITIAL_ROUTE, if (routeToSubscription) "/subscription" else "/main")
            if (quickTileToggle) putExtra(EXTRA_QUICK_TILE_ACTION, QUICK_TILE_ACTION_TOGGLE)
        }
        @Suppress("DEPRECATION")
        startActivityAndCollapse(intent)
    }
}
