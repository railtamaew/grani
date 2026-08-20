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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.UUID

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
        private const val REQUEST_LISTENING_THROTTLE_MS = 1500L
        private const val QUICK_TILE_NOTICE_CHANNEL_ID = "grani_quick_tile"
        private const val QUICK_TILE_NOTICE_ID = 4207

        private val tileListeningLock = Any()
        private val tileActionInFlight = AtomicBoolean(false)
        @Volatile private var listeningInstance: QuickTileService? = null
        @Volatile private var lastRequestListeningStateMs = 0L
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
                val instance = synchronized(tileListeningLock) {
                    listeningInstance
                }
                instance?.updateTileState()

                val now = System.currentTimeMillis()
                val shouldRequestListeningState = synchronized(tileListeningLock) {
                    if (now - lastRequestListeningStateMs >= REQUEST_LISTENING_THROTTLE_MS) {
                        lastRequestListeningStateMs = now
                        true
                    } else {
                        false
                    }
                }
                if (!shouldRequestListeningState) return@post

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

        val snapshot = NativeVpnRuntimeState.getRuntimeSnapshot(applicationContext)
        if (
            snapshot.status == NativeVpnRuntimeState.RuntimeStatus.CONNECTING ||
            snapshot.status == NativeVpnRuntimeState.RuntimeStatus.LOCAL_UP ||
            snapshot.status == NativeVpnRuntimeState.RuntimeStatus.DISCONNECTING
        ) {
            Log.i(TAG, "quick_tile_click: ignored transient status=${snapshot.status}")
            updateTileState()
                return
        }

        val running =
            snapshot.status == NativeVpnRuntimeState.RuntimeStatus.CONNECTED ||
                snapshot.status == NativeVpnRuntimeState.RuntimeStatus.VERIFIED ||
                NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(applicationContext)

        if (running) {
            if (!beginTileAction("disconnect")) {
                updateTileState()
                return
            }
            setTilePending(R.string.quick_tile_state_disconnecting)
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
                    finishTileAction("disconnect")
                    notifyVpnStateChanged(applicationContext)
                }
            }.start()
            return
        }

        if (!running && !VpnPlugin.isAllowTileConnect(applicationContext)) {
            Log.i(
                TAG,
                "quick_tile_click: blocked allow_tile_connect=false status=${snapshot.status}"
            )
            showQuickTileNotice(
                this,
                getString(R.string.quick_tile_access_not_ready),
                routeToSubscription = false
            )
            updateTileState()
            openMainActivity(routeToSubscription = false)
            return
        }

        val lastConfig = VpnPlugin.loadLastConfig(applicationContext)
        if (lastConfig == null || lastConfig.config.isBlank()) {
            Log.i(TAG, "quick_tile_click: blocked missing_last_config")
            showQuickTileNotice(this, getString(R.string.quick_tile_missing_config))
            updateTileState()
            openMainActivity(routeToSubscription = false, quickTileToggle = true)
            return
        }

        val permissionIntent = VpnService.prepare(this)
        if (permissionIntent != null) {
            Log.i(
                TAG,
                "quick_tile_click: blocked vpn_permission_required protocol=${lastConfig.protocol}"
            )
            showQuickTileNotice(
                this,
                getString(R.string.quick_tile_permission_required),
                routeToSubscription = false
            )
            updateTileState()
            openMainActivity(routeToSubscription = false)
            return
        }

        if (!beginTileAction("connect")) {
            updateTileState()
            return
        }
        setTilePending(R.string.quick_tile_state_connecting)
        Log.i(TAG, "quick_tile_click: connect cached config in native background")
        val sessionId = newQuickTileSessionId()
        startCachedConfig(lastConfig.config, lastConfig.protocol, lastConfig.mtu, sessionId)
    }

    private fun startCachedConfig(
        config: String,
        protocol: String?,
        mtu: Int,
        sessionId: String,
    ) {
        Thread {
            try {
                val result = VpnRuntimeCoordinator.connect(
                    applicationContext,
                    config,
                    protocol,
                    mtu,
                    source = "quick_tile_cached",
                    connectionSessionId = sessionId,
                    awaitReady = true,
                )
                if (!result.started) {
                    throw IllegalStateException(
                        "cached_config_start_failed_${result.backend}_" +
                            "${result.status?.name?.lowercase() ?: "unknown"}" +
                            (result.error?.let { "_$it" } ?: "")
                    )
                }
            } catch (e: Exception) {
                Log.e(TAG, "quick_tile_connect_failed", e)
                ProtocolRuntimeContract.markError(
                    applicationContext,
                    backend = null,
                    protocol = protocol,
                    sessionId = sessionId,
                    source = "quick_tile_cached",
                    error = e.message ?: "quick_tile_connect_failed",
                )
                mainHandler.post {
                    showQuickTileNotice(
                        this,
                        getString(R.string.quick_tile_connect_failed)
                    )
                }
            } finally {
                finishTileAction("connect")
                notifyVpnStateChanged(applicationContext)
            }
        }.start()
    }

    private fun newQuickTileSessionId(): String {
        return "qt-${UUID.randomUUID()}"
    }

    private fun beginTileAction(action: String): Boolean {
        val started = tileActionInFlight.compareAndSet(false, true)
        if (!started) {
            Log.i(TAG, "quick_tile_click: ignored action_in_flight action=$action")
        }
        return started
    }

    private fun finishTileAction(action: String) {
        tileActionInFlight.set(false)
        Log.i(TAG, "quick_tile_click: action_finished action=$action")
    }

    private fun setTilePending(subtitleRes: Int) {
        val tile = qsTile ?: return
        // Отображаем промежуточное состояние «подключение/отключение».
        tile.state = Tile.STATE_UNAVAILABLE
        tile.label = getString(R.string.quick_tile_label)
        setTileSubtitleCompat(tile, getString(subtitleRes))
        tile.updateTile()
    }

    private fun updateTileState() {
        val tile = qsTile ?: return
        tile.label = getString(R.string.quick_tile_label)
        // Tile rendering must stay read-only. Running the runtime watchdog here
        // can restart foreground notifications while SystemUI is listening to
        // the tile, creating a notification/tile feedback loop.
        val snapshot = NativeVpnRuntimeState.getRuntimeSnapshot(applicationContext)
        val model = VpnLifecycleUiPolicy.modelFor(
            snapshot.status,
            graniLikelyActive = snapshot.graniLikelyActive,
            systemVpnActive = snapshot.systemVpnActive,
        )
        when (model.tileState) {
            VpnLifecycleUiPolicy.TileVisualState.ACTIVE -> {
                tile.state = Tile.STATE_ACTIVE
                tile.icon = iconOn
            }
            VpnLifecycleUiPolicy.TileVisualState.UNAVAILABLE -> {
                tile.state = Tile.STATE_UNAVAILABLE
                tile.icon = iconOff
            }
            VpnLifecycleUiPolicy.TileVisualState.INACTIVE -> {
                tile.state = Tile.STATE_INACTIVE
                tile.icon = iconOff
            }
        }
        setTileSubtitleCompat(tile, getTileSubtitle(model.tileSubtitle))
        tile.updateTile()
    }

    private fun getTileSubtitle(subtitle: VpnLifecycleUiPolicy.TileSubtitle): String {
        return when (subtitle) {
            VpnLifecycleUiPolicy.TileSubtitle.CONNECTED ->
                getString(R.string.quick_tile_state_connected)
            VpnLifecycleUiPolicy.TileSubtitle.CONNECTING ->
                getString(R.string.quick_tile_state_connecting)
            VpnLifecycleUiPolicy.TileSubtitle.DISCONNECTING ->
                getString(R.string.quick_tile_state_disconnecting)
            VpnLifecycleUiPolicy.TileSubtitle.ERROR ->
                getString(R.string.quick_tile_state_error)
            VpnLifecycleUiPolicy.TileSubtitle.OFF ->
                getString(R.string.quick_tile_state_off)
        }
    }

    private fun setTileSubtitleCompat(tile: Tile, subtitle: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = subtitle
        }
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
        if (Build.VERSION.SDK_INT >= 34) {
            val pendingIntent = PendingIntent.getActivity(
                this,
                if (quickTileToggle) 2 else if (routeToSubscription) 1 else 0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
