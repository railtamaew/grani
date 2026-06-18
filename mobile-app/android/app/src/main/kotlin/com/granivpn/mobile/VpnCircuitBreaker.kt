package com.granivpn.mobile

import android.content.Context
import android.util.Log
import java.util.ArrayDeque

/**
 * Раннее отключение деградированного узла: только в памяти процесса (без SharedPreferences).
 */
object VpnCircuitBreaker {
    private const val TAG = "VpnCircuitBreaker"

    private const val RST_WINDOW_MS = 10_000L
    private const val RST_THRESHOLD = 8
    private const val HEALTH_FAIL_THRESHOLD = 3
    private const val HEALTH_WINDOW_MS = 60_000L

    private val rstTimestampsMs: ArrayDeque<Long> = ArrayDeque()

    @Volatile
    private var healthFailCount: Int = 0

    @Volatile
    private var lastHealthFailWindowStart: Long = 0L

    @Volatile
    private var open: Boolean = false

    @Volatile
    private var openReason: String? = null

    fun reset() {
        synchronized(rstTimestampsMs) {
            rstTimestampsMs.clear()
        }
        healthFailCount = 0
        lastHealthFailWindowStart = 0L
        open = false
        openReason = null
        Log.d(TAG, "reset")
    }

    fun recordTransportResetSignal() {
        val now = System.currentTimeMillis()
        synchronized(rstTimestampsMs) {
            rstTimestampsMs.addLast(now)
            while (rstTimestampsMs.isNotEmpty() && now - rstTimestampsMs.first() > RST_WINDOW_MS) {
                rstTimestampsMs.removeFirst()
            }
            if (rstTimestampsMs.size >= RST_THRESHOLD) {
                Log.w(TAG, "recordTransportResetSignal: threshold $RST_THRESHOLD in ${RST_WINDOW_MS}ms")
            }
        }
    }

    fun recordHealthCheckFailure() {
        val now = System.currentTimeMillis()
        if (now - lastHealthFailWindowStart > HEALTH_WINDOW_MS) {
            lastHealthFailWindowStart = now
            healthFailCount = 0
        }
        healthFailCount++
        Log.w(TAG, "recordHealthCheckFailure: count=$healthFailCount in window")
    }

    fun recordHealthCheckSuccess() {
        healthFailCount = 0
        open = false
        openReason = null
    }

    fun shouldTripBreaker(): Boolean {
        val now = System.currentTimeMillis()
        val rstBurst = synchronized(rstTimestampsMs) {
            while (rstTimestampsMs.isNotEmpty() && now - rstTimestampsMs.first() > RST_WINDOW_MS) {
                rstTimestampsMs.removeFirst()
            }
            rstTimestampsMs.size >= RST_THRESHOLD
        }
        val healthBurst = healthFailCount >= HEALTH_FAIL_THRESHOLD
        return rstBurst || healthBurst
    }

    fun tripReason(): String {
        val now = System.currentTimeMillis()
        val rstBurst = synchronized(rstTimestampsMs) {
            while (rstTimestampsMs.isNotEmpty() && now - rstTimestampsMs.first() > RST_WINDOW_MS) {
                rstTimestampsMs.removeFirst()
            }
            rstTimestampsMs.size >= RST_THRESHOLD
        }
        return when {
            rstBurst -> "rst_window_$RST_THRESHOLD/${RST_WINDOW_MS}ms"
            healthFailCount >= HEALTH_FAIL_THRESHOLD -> "health_fail_$healthFailCount/${HEALTH_WINDOW_MS}ms"
            else -> "unknown"
        }
    }

    fun markOpen(reason: String) {
        open = true
        openReason = reason.take(256)
        Log.w(TAG, "markOpen: $openReason")
    }

    fun clearOpen() {
        open = false
        openReason = null
    }

    fun isOpen(): Boolean = open

    /** Удаляет устаревшие ключи из старых версий (раньше breaker писался на диск). */
    fun clearLegacyDiskStateIfAny(context: Context) {
        try {
            context.getSharedPreferences("grani_vpn_reconnect", Context.MODE_PRIVATE)
                .edit()
                .remove("circuit_breaker_open")
                .remove("circuit_breaker_reason")
                .remove("circuit_breaker_open_at")
                .apply()
        } catch (e: Exception) {
            Log.w(TAG, "clearLegacyDiskStateIfAny: ${e.message}")
        }
    }
}
