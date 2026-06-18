package com.granivpn.mobile

import android.content.Context

/**
 * Режим DNS — [grani_vpn_prefs], синхронно с split tunnel.
 * Смена маршрутизации API при блокировке direct — через SOCKS приложения (см. [VpnPlugin.apiRequestViaLocalSocks]), без правок Xray routing.
 */
object VpnRoutingPrefs {
    private const val PREFS_NAME = "grani_vpn_prefs"
    private const val KEY_DNS_MODE = "vpn_dns_policy_mode"

    const val DNS_PERFORMANCE = "performance"
    const val DNS_STRICT = "strict"

    fun getDnsMode(context: Context): String {
        val v = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_DNS_MODE, DNS_PERFORMANCE)?.trim()?.lowercase()
        return if (v == DNS_STRICT) DNS_STRICT else DNS_PERFORMANCE
    }

    fun setDnsMode(context: Context, mode: String) {
        val m = if (mode.trim().lowercase() == DNS_STRICT) DNS_STRICT else DNS_PERFORMANCE
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DNS_MODE, m)
            .apply()
    }
}
