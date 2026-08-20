package com.granivpn.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SimpleAmneziaWgRunnerTest {
    @Test
    fun `tun up without handshake is not verified traffic`() {
        assertFalse(SimpleAmneziaWgRunner.isVerifiedTraffic(0L, 512L))
    }

    @Test
    fun `handshake without inbound bytes is not verified traffic`() {
        assertFalse(SimpleAmneziaWgRunner.isVerifiedTraffic(1_786_994_752_000L, 0L))
    }

    @Test
    fun `handshake with inbound bytes verifies data plane`() {
        assertTrue(SimpleAmneziaWgRunner.isVerifiedTraffic(1_786_994_752_000L, 148L))
    }
}
