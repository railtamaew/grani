package com.granivpn.mobile

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log

object NativeVpnRuntimeState {
    private const val TAG = "NativeVpnRuntimeState"
    private const val PREFS_NAME = "grani_vpn_prefs"
    private const val KEY_LAST_PROTOCOL = "last_vpn_protocol"
    private const val KEY_AWG_EXPECTED_UP = "amneziawg_expected_up"
    private const val KEY_AWG_EXPECTED_UP_AT = "amneziawg_expected_up_at"
    private const val KEY_NATIVE_EXPECTED_UP = "native_vpn_expected_up"
    private const val KEY_NATIVE_EXPECTED_UP_AT = "native_vpn_expected_up_at"
    private const val KEY_NATIVE_EXPECTED_PROTOCOL = "native_vpn_expected_protocol"
    private const val EXPECTED_UP_GRACE_MS = 90_000L

    fun markAwgExpectedUp(context: Context, expected: Boolean) {
        val app = context.applicationContext
        app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_AWG_EXPECTED_UP, expected)
            .putLong(KEY_AWG_EXPECTED_UP_AT, if (expected) System.currentTimeMillis() else 0L)
            .apply()
        Log.i(TAG, "awg_expected_up=$expected")
    }

    fun markNativeVpnExpectedUp(context: Context, expected: Boolean, protocol: String? = null) {
        val normalizedProtocol = protocol?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        val app = context.applicationContext
        app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_NATIVE_EXPECTED_UP, expected)
            .putLong(KEY_NATIVE_EXPECTED_UP_AT, if (expected) System.currentTimeMillis() else 0L)
            .apply {
                if (!normalizedProtocol.isNullOrBlank()) {
                    putString(KEY_NATIVE_EXPECTED_PROTOCOL, normalizedProtocol)
                } else if (!expected) {
                    remove(KEY_NATIVE_EXPECTED_PROTOCOL)
                }
            }
            .apply()
        Log.i(TAG, "native_expected_up=$expected protocol=${normalizedProtocol ?: "unknown"}")
    }

    fun isAwgExpectedUp(context: Context): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_AWG_EXPECTED_UP, false)) return false
        if (!isExpectedFresh(prefs.getLong(KEY_AWG_EXPECTED_UP_AT, 0L))) return false
        return prefs.getString(KEY_LAST_PROTOCOL, null)?.equals("graniwg", ignoreCase = true) == true
    }

    private fun isAwgProtocol(protocol: String?): Boolean {
        val p = protocol?.trim()?.lowercase() ?: return false
        return p == "graniwg" || p == "amneziawg" || p == "awg"
    }

    fun isNativeVpnExpectedUp(context: Context): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_NATIVE_EXPECTED_UP, false)) return false
        val expectedAt = prefs.getLong(KEY_NATIVE_EXPECTED_UP_AT, 0L)
        if (!isExpectedFresh(expectedAt)) return false
        val expectedProtocol = prefs.getString(KEY_NATIVE_EXPECTED_PROTOCOL, null)
        val lastProtocol = prefs.getString(KEY_LAST_PROTOCOL, null)
        val protocol = expectedProtocol ?: lastProtocol
        return !isAwgProtocol(protocol)
    }

    private fun isExpectedFresh(expectedAt: Long): Boolean {
        if (expectedAt <= 0L) return false
        return System.currentTimeMillis() - expectedAt <= EXPECTED_UP_GRACE_MS
    }

    fun isSystemVpnActive(context: Context): Boolean {
        val connectivityManager =
            context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return false
        return connectivityManager.allNetworks.any { network ->
            val capabilities = connectivityManager.getNetworkCapabilities(network)
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
    }

    fun isAwgLikelyActive(context: Context): Boolean {
        if (SimpleAmneziaWgRunner.isUp()) return true
        return isAwgExpectedUp(context) && isSystemVpnActive(context)
    }

    fun isNativeVpnLikelyActive(context: Context): Boolean {
        return GraniVpnService.isVpnRunning() ||
            (isNativeVpnExpectedUp(context) && isSystemVpnActive(context))
    }

    fun isAnyGraniVpnLikelyActive(context: Context): Boolean {
        return isNativeVpnLikelyActive(context) || isAwgLikelyActive(context)
    }

    fun reconcileAwgNotification(context: Context, source: String) {
        val app = context.applicationContext
        if (!isAwgLikelyActive(app)) return
        try {
            Log.i(TAG, "reconcile_awg_notification source=$source")
            GraniAwgNotificationService.start(app)
        } catch (e: Exception) {
            Log.w(TAG, "reconcile_awg_notification_failed source=$source", e)
        }
    }

    fun notifyQuickTile(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            QuickTileService.notifyVpnStateChanged(context.applicationContext)
        }
    }
}
