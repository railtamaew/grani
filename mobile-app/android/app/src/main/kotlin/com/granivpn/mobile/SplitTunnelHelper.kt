package com.granivpn.mobile

import android.net.VpnService
import android.os.Build
import android.util.Log

/**
 * Применяет split tunnel к VpnService.Builder.
 * exclude: выбранные приложения в обход VPN (addDisallowedApplication)
 * include: только выбранные приложения используют VPN (addAllowedApplication)
 */
object SplitTunnelHelper {
    private const val TAG = "SplitTunnelHelper"
    // Keep this switch only for emergency diagnostics; product builds apply saved prefs.
    private const val FORCE_DISABLE_SPLIT_TUNNEL = false

    /**
     * Применяет split tunnel (exclude или include mode).
     * Вызывать перед establish().
     */
    fun applySplitTunnel(
        builder: VpnService.Builder,
        context: android.content.Context
    ): VpnService.Builder {
        if (FORCE_DISABLE_SPLIT_TUNNEL) {
            Log.i(TAG, "Split tunnel: force-disabled for diagnostic build")
            return builder
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return builder
        val packages = SplitTunnelPrefs.getSelectedPackages(context)
        val mode = SplitTunnelPrefs.getMode(context)
        if (packages.isEmpty()) {
            Log.i(TAG, "Split tunnel: disabled (mode=$mode, selected_packages=0)")
            return builder
        }
        Log.i(
            TAG,
            "Split tunnel: applying mode=$mode selected_packages=${packages.size}",
        )
        try {
            for (pkg in packages) {
                if (pkg.isNotBlank()) {
                    if (mode == SplitTunnelPrefs.MODE_INCLUDE) {
                        builder.addAllowedApplication(pkg)
                        Log.d(TAG, "Split tunnel (include): приложение $pkg использует VPN")
                    } else {
                        builder.addDisallowedApplication(pkg)
                        Log.d(TAG, "Split tunnel (exclude): приложение $pkg в обход VPN")
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "applySplitTunnel failed: ${e.message}")
        }
        return builder
    }
}
