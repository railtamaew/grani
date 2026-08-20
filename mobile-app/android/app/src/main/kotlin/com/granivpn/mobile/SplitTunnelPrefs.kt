package com.granivpn.mobile

import android.content.Context
import android.util.Log
import java.net.IDN
import org.json.JSONArray

/**
 * Хранилище split tunnel: режим (exclude/include) и выбранные приложения.
 * exclude: выбранные приложения работают в обход VPN
 * include: только выбранные приложения используют VPN
 */
object SplitTunnelPrefs {
    private const val TAG = "SplitTunnelPrefs"
    private const val PREFS_NAME = "grani_vpn_prefs"
    private const val KEY_SELECTED_PACKAGES = "split_tunnel_selected_packages"
    private const val KEY_MODE = "split_tunnel_mode"
    private const val KEY_DIRECT_DOMAINS = "split_tunnel_direct_domains"
    private const val KEY_APP_POLICY_REVISION = "split_tunnel_app_policy_revision"
    private const val KEY_APPLIED_APP_POLICY_REVISION = "split_tunnel_applied_app_policy_revision"
    const val MODE_EXCLUDE = "exclude"
    const val MODE_INCLUDE = "include"

    fun getMode(context: Context): String {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_MODE, MODE_EXCLUDE) ?: MODE_EXCLUDE
    }

    fun setMode(context: Context, mode: String) {
        val normalizedMode = if (mode == MODE_INCLUDE) MODE_INCLUDE else MODE_EXCLUDE
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if ((prefs.getString(KEY_MODE, MODE_EXCLUDE) ?: MODE_EXCLUDE) == normalizedMode) return
        val revision = prefs.getLong(KEY_APP_POLICY_REVISION, 0L) + 1L
        prefs.edit()
            .putString(KEY_MODE, normalizedMode)
            .putLong(KEY_APP_POLICY_REVISION, revision)
            .commit()
        Log.i(TAG, "setMode: mode=$normalizedMode app_policy_revision=$revision")
    }

    fun getSelectedPackages(context: Context): Set<String> {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val json = prefs.getString(KEY_SELECTED_PACKAGES, null) ?: return emptySet()
            val arr = JSONArray(json)
            (0 until arr.length()).mapNotNull { i ->
                arr.optString(i, null).takeIf { it.isNotEmpty() }
            }.toSet()
        } catch (e: Exception) {
            Log.w(TAG, "getExcludedPackages failed: ${e.message}")
            emptySet()
        }
    }

    fun getExcludedPackages(context: Context): Set<String> = getSelectedPackages(context)

    fun setSelectedPackages(context: Context, packages: Collection<String>) {
        try {
            val normalized = packages
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .distinct()
                .sorted()
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (getSelectedPackages(context).toSortedSet() == normalized.toSortedSet()) return
            val revision = prefs.getLong(KEY_APP_POLICY_REVISION, 0L) + 1L
            val arr = JSONArray(normalized)
            prefs.edit()
                .putString(KEY_SELECTED_PACKAGES, arr.toString())
                .putLong(KEY_APP_POLICY_REVISION, revision)
                .commit()
            Log.i(TAG, "setSelectedPackages: ${normalized.size} apps app_policy_revision=$revision")
        } catch (e: Exception) {
            Log.w(TAG, "setExcludedPackages failed: ${e.message}")
        }
    }

    fun setExcludedPackages(context: Context, packages: Collection<String>) = setSelectedPackages(context, packages)

    data class AppPolicyState(
        val mode: String,
        val packages: Set<String>,
        val revision: Long,
        val appliedRevision: Long,
    ) {
        val pendingReconnect: Boolean
            get() = revision > appliedRevision
    }

    fun getAppPolicyState(context: Context): AppPolicyState {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return AppPolicyState(
            mode = getMode(context),
            packages = getSelectedPackages(context),
            revision = prefs.getLong(KEY_APP_POLICY_REVISION, 0L),
            appliedRevision = prefs.getLong(KEY_APPLIED_APP_POLICY_REVISION, 0L),
        )
    }

    /** Вызывать только после успешного создания TUN/подъёма backend. */
    fun markAppPolicyApplied(context: Context): Long {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val revision = prefs.getLong(KEY_APP_POLICY_REVISION, 0L)
        prefs.edit().putLong(KEY_APPLIED_APP_POLICY_REVISION, revision).commit()
        Log.i(TAG, "app policy applied revision=$revision")
        return revision
    }

    /** Домены для маршрутизации в direct (обход VPN) */
    fun getDirectDomains(context: Context): List<String> {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val json = prefs.getString(KEY_DIRECT_DOMAINS, null) ?: return emptyList()
            val arr = JSONArray(json)
            (0 until arr.length()).mapNotNull { i ->
                arr.optString(i, null).takeIf { it.isNotBlank() }
            }.mapNotNull { normalizeDirectDomain(it) }.distinct()
        } catch (e: Exception) {
            Log.w(TAG, "getDirectDomains failed: ${e.message}")
            emptyList()
        }
    }

    fun setDirectDomains(context: Context, domains: Collection<String>) {
        try {
            val normalized = domains.mapNotNull { normalizeDirectDomain(it) }.distinct()
            val rejectedCount = domains.size - normalized.size
            val arr = JSONArray(normalized)
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_DIRECT_DOMAINS, arr.toString())
                .apply()
            if (rejectedCount > 0) {
                Log.w(TAG, "setDirectDomains: rejected $rejectedCount invalid domain(s)")
            }
            Log.d(TAG, "setDirectDomains: ${normalized.size} domains")
        } catch (e: Exception) {
            Log.w(TAG, "setDirectDomains failed: ${e.message}")
        }
    }

    private fun normalizeDirectDomain(raw: String): String? {
        var candidate = raw.trim().lowercase()
        if (candidate.isBlank()) return null
        if (candidate.contains("://")) {
            candidate = candidate.substringAfter("://")
        }
        candidate = candidate.substringBefore('/').substringBefore('?').substringBefore('#')
        candidate = candidate.substringAfter('@').substringBefore(':')
        candidate = candidate.trim().trim('.')
        val wildcard = candidate.startsWith("*.")
        if (wildcard) {
            candidate = candidate.removePrefix("*.")
        }
        if (candidate.length > 253 || "." !in candidate) return null
        return try {
            val ascii = IDN.toASCII(candidate, IDN.USE_STD3_ASCII_RULES).lowercase()
            if (ascii.length > 253) return null
            val labels = ascii.split('.')
            if (labels.size < 2) return null
            for (label in labels) {
                if (label.isEmpty() || label.length > 63) return null
                if (!label.matches(Regex("^[a-z0-9-]+$"))) return null
                if (label.startsWith('-') || label.endsWith('-')) return null
            }
            if (wildcard) "*.$ascii" else ascii
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}
