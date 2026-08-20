package com.granivpn.mobile

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.SystemClock
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

object NetworkDiagnostics {
    private const val TAG = "NetworkDiagnostics"
    private const val PROBE_URL = "http://1.1.1.1/"
    private const val CONNECT_TIMEOUT_MS = 3500
    private const val READ_TIMEOUT_MS = 3500

    fun snapshot(context: Context, runInternetProbe: Boolean = true): Map<String, Any> {
        val app = context.applicationContext
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return mapOf(
                "network_type" to "unknown",
                "underlying_network_type" to "unknown",
                "underlying_network_available" to false,
                "internet_without_vpn_ok" to false,
                "underlying_internet_ok" to false,
                "underlying_probe_error" to "connectivity_manager_unavailable",
            )

        val selected = selectUnderlyingNetwork(cm)
        val network = selected?.first
        val type = selected?.second ?: "none"
        val base = linkedMapOf<String, Any>(
            "network_type" to type,
            "underlying_network_type" to type,
            "underlying_network_available" to (network != null),
        )
        if (!runInternetProbe) return base

        val probe = probeInternet(network)
        base["internet_without_vpn_ok"] = probe.ok
        base["underlying_internet_ok"] = probe.ok
        base["underlying_probe_url"] = PROBE_URL
        base["underlying_probe_rtt_ms"] = probe.rttMs
        base["underlying_probe_http_status"] = probe.httpStatus
        if (!probe.error.isNullOrBlank()) {
            base["underlying_probe_error"] = probe.error
        }
        return base
    }

    private fun selectUnderlyingNetwork(cm: ConnectivityManager): Pair<Network, String>? {
        val active = cm.activeNetwork
        if (active != null) {
            val caps = cm.getNetworkCapabilities(active)
            if (isUsableUnderlying(caps)) {
                return active to networkType(caps)
            }
        }

        val candidates = mutableListOf<Pair<Network, NetworkCapabilities>>()
        try {
            cm.allNetworks.forEach { network ->
                val caps = cm.getNetworkCapabilities(network) ?: return@forEach
                if (isUsableUnderlying(caps)) candidates.add(network to caps)
            }
        } catch (e: Exception) {
            Log.w(TAG, "selectUnderlyingNetwork failed: ${e.message}")
        }

        val preferred = candidates.firstOrNull { it.second.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) }
            ?: candidates.firstOrNull { it.second.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) }
            ?: candidates.firstOrNull { it.second.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) }
            ?: candidates.firstOrNull()
        return preferred?.let { it.first to networkType(it.second) }
    }

    private fun isUsableUnderlying(caps: NetworkCapabilities?): Boolean {
        if (caps == null) return false
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return false
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
        return true
    }

    private fun networkType(caps: NetworkCapabilities?): String {
        if (caps == null) return "unknown"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
            else -> "other"
        }.lowercase(Locale.US)
    }

    private data class ProbeResult(
        val ok: Boolean,
        val rttMs: Long,
        val httpStatus: Int,
        val error: String?,
    )

    private fun probeInternet(network: Network?): ProbeResult {
        if (network == null) {
            return ProbeResult(
                ok = false,
                rttMs = -1L,
                httpStatus = -1,
                error = "no_underlying_not_vpn_network",
            )
        }
        var conn: HttpURLConnection? = null
        val started = SystemClock.elapsedRealtime()
        return try {
            val url = URL(PROBE_URL)
            conn = (network.openConnection(url) as HttpURLConnection).apply {
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                instanceFollowRedirects = false
                requestMethod = "GET"
                useCaches = false
            }
            val code = conn.responseCode
            val ok = code in 200..399
            ProbeResult(
                ok = ok,
                rttMs = SystemClock.elapsedRealtime() - started,
                httpStatus = code,
                error = if (ok) null else "http_$code",
            )
        } catch (e: Exception) {
            ProbeResult(
                ok = false,
                rttMs = SystemClock.elapsedRealtime() - started,
                httpStatus = -1,
                error = "${e.javaClass.simpleName}:${e.message ?: "unknown"}",
            )
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Exception) {
            }
        }
    }
}
