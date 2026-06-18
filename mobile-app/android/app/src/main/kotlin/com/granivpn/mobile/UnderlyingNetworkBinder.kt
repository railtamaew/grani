package com.granivpn.mobile

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log

/**
 * Временно привязывает процесс приложения к «сырой» сети (NOT_VPN), чтобы
 * control-plane (например GET /vpn/xray/apply-state) не шёл через только что
 * поднятый туннель в момент reload/restart Xray на ноде.
 */
object UnderlyingNetworkBinder {
    private const val TAG = "UnderlyingNetworkBinder"

    @JvmStatic
    fun bindProcessToUnderlyingInternet(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        val networks = cm.allNetworks ?: return false
        for (n in networks) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) continue
            return try {
                val ok = cm.bindProcessToNetwork(n)
                Log.i(TAG, "bindProcessToNetwork ok=$ok network=$n")
                ok
            } catch (e: Exception) {
                Log.w(TAG, "bindProcessToNetwork failed: ${e.message}")
                false
            }
        }
        Log.w(TAG, "no NOT_VPN+INTERNET network found")
        return false
    }

    @JvmStatic
    fun unbindProcessNetwork(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        try {
            @Suppress("DEPRECATION")
            val cleared = cm.bindProcessToNetwork(null as Network?)
            Log.i(TAG, "bindProcessToNetwork cleared ok=$cleared")
        } catch (e: Exception) {
            Log.w(TAG, "unbind failed: ${e.message}")
        }
    }
}
