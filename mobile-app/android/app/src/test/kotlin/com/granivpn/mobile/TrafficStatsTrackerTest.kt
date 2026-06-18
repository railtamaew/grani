package com.granivpn.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class TrafficStatsTrackerTest {

    private class FakeProvider(
        private val uidValue: Int = 1234,
        private var rx: Long = 0L,
        private var tx: Long = 0L
    ) : TrafficStatsProvider {
        override fun uid(): Int = uidValue
        override fun rxBytes(uid: Int): Long = rx
        override fun txBytes(uid: Int): Long = tx

        fun set(rx: Long, tx: Long) {
            this.rx = rx
            this.tx = tx
        }
    }

    @Test
    fun snapshot_returns_delta_after_reset() {
        val provider = FakeProvider()
        val tracker = TrafficStatsTracker(provider)

        provider.set(100, 200)
        tracker.reset()

        provider.set(250, 320)
        val (rx, tx) = tracker.snapshot()

        assertEquals(150, rx)
        assertEquals(120, tx)
    }

    @Test
    fun snapshot_never_returns_negative_values() {
        val provider = FakeProvider()
        val tracker = TrafficStatsTracker(provider)

        provider.set(300, 400)
        tracker.reset()

        // Simulate stats reset/overflow
        provider.set(100, 200)
        val (rx, tx) = tracker.snapshot()

        assertEquals(0, rx)
        assertEquals(0, tx)
    }
}
