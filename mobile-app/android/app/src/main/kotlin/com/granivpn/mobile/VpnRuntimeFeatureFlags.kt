package com.granivpn.mobile

import android.content.Context

/**
 * Small, local runtime switches for high-risk VPN lifecycle changes.
 * Defaults are production-safe and can be overridden without changing the
 * connection contract or stored VPN credentials.
 */
object VpnRuntimeFeatureFlags {
    private const val PREFS_NAME = "grani_vpn_runtime_feature_flags"
    private const val KEY_BRIDGE_RECOVERY_ON_BINDER_LOSS =
        "bridge_recovery_on_binder_loss"

    fun bridgeRecoveryOnBinderLoss(context: Context): Boolean =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_BRIDGE_RECOVERY_ON_BINDER_LOSS, true)

    fun setBridgeRecoveryOnBinderLoss(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_BRIDGE_RECOVERY_ON_BINDER_LOSS, enabled)
            .apply()
    }
}
