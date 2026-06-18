package com.granivpn.mobile

import android.net.TrafficStats
import android.os.Process

interface TrafficStatsProvider {
    fun uid(): Int
    fun rxBytes(uid: Int): Long
    fun txBytes(uid: Int): Long
}

class AndroidTrafficStatsProvider : TrafficStatsProvider {
    override fun uid(): Int = Process.myUid()
    override fun rxBytes(uid: Int): Long = TrafficStats.getUidRxBytes(uid)
    override fun txBytes(uid: Int): Long = TrafficStats.getUidTxBytes(uid)
}

class TrafficStatsTracker(private val provider: TrafficStatsProvider) {
    private var baselineRxBytes: Long = 0L
    private var baselineTxBytes: Long = 0L

    fun reset() {
        val uid = provider.uid()
        val rx = provider.rxBytes(uid)
        val tx = provider.txBytes(uid)
        baselineRxBytes = if (rx >= 0) rx else 0L
        baselineTxBytes = if (tx >= 0) tx else 0L
    }

    fun snapshot(): Pair<Long, Long> {
        val uid = provider.uid()
        val rx = provider.rxBytes(uid)
        val tx = provider.txBytes(uid)

        val safeRx = if (rx >= 0) rx else baselineRxBytes
        val safeTx = if (tx >= 0) tx else baselineTxBytes

        val deltaRx = (safeRx - baselineRxBytes).coerceAtLeast(0)
        val deltaTx = (safeTx - baselineTxBytes).coerceAtLeast(0)
        return deltaRx to deltaTx
    }
}
