package com.granivpn.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UnderlyingNetworkHandoverPolicyTest {
    private val wifi = candidate("wifi-1", UnderlyingNetworkHandoverPolicy.Transport.WIFI)
    private val secondWifi = candidate("wifi-2", UnderlyingNetworkHandoverPolicy.Transport.WIFI)
    private val mobile = candidate("mobile-1", UnderlyingNetworkHandoverPolicy.Transport.MOBILE)

    @Test
    fun secondVisibleWifiDoesNotReplaceHealthyCurrentNetwork() {
        val policy = policy()
        policy.evaluate(listOf(wifi), preferredNetworkId = wifi.id, nowMs = 0L)

        val decision = policy.evaluate(
            listOf(wifi, secondWifi, mobile),
            preferredNetworkId = secondWifi.id,
            nowMs = 100L,
        )

        assertTrue(decision is UnderlyingNetworkHandoverPolicy.Decision.Stable)
        assertEquals(wifi.id, policy.selectedCandidate()?.id)
    }

    @Test
    fun selectedLossWaitsForGraceBeforeRequestingDataplaneVerification() {
        val policy = policy(graceMs = 1_000L)
        policy.evaluate(listOf(wifi), wifi.id, 0L)

        val first = policy.evaluate(listOf(mobile), mobile.id, 100L)
        val early = policy.evaluate(listOf(mobile), mobile.id, 999L)
        val ready = policy.evaluate(listOf(mobile), mobile.id, 1_100L)

        assertTrue(first is UnderlyingNetworkHandoverPolicy.Decision.Pending)
        assertTrue(early is UnderlyingNetworkHandoverPolicy.Decision.Pending)
        assertTrue(ready is UnderlyingNetworkHandoverPolicy.Decision.VerifyDataplane)
        assertEquals(wifi.id, policy.selectedCandidate()?.id)
    }

    @Test
    fun oldNetworkRecoveryWithinGraceCancelsHandover() {
        val policy = policy(graceMs = 1_000L)
        policy.evaluate(listOf(wifi), wifi.id, 0L)
        policy.evaluate(listOf(mobile), mobile.id, 100L)

        val recovered = policy.evaluate(listOf(wifi, mobile), wifi.id, 900L)
        val later = policy.evaluate(listOf(wifi, mobile), mobile.id, 2_000L)

        assertTrue(recovered is UnderlyingNetworkHandoverPolicy.Decision.Stable)
        assertTrue(later is UnderlyingNetworkHandoverPolicy.Decision.Stable)
        assertEquals(wifi.id, policy.selectedCandidate()?.id)
    }

    @Test
    fun failedProbeMustRepeatBeforeReconnect() {
        val policy = policy(graceMs = 0L, failuresBeforeReconnect = 2)
        policy.evaluate(listOf(wifi), wifi.id, 0L)
        policy.evaluate(listOf(mobile), mobile.id, 1L)
        val verify = policy.evaluate(listOf(mobile), mobile.id, 1L)
        assertTrue(verify is UnderlyingNetworkHandoverPolicy.Decision.VerifyDataplane)

        val firstFailure = policy.recordDataplaneProbe(mobile, healthy = false)
        val secondFailure = policy.recordDataplaneProbe(mobile, healthy = false)

        assertTrue(firstFailure is UnderlyingNetworkHandoverPolicy.Decision.ProbeAgain)
        assertTrue(secondFailure is UnderlyingNetworkHandoverPolicy.Decision.ReconnectRequired)
        assertEquals(2, (secondFailure as UnderlyingNetworkHandoverPolicy.Decision.ReconnectRequired).failedProbes)
    }

    @Test
    fun healthyDataplaneCommitsHandoverWithoutReconnect() {
        val policy = policy(graceMs = 0L)
        policy.evaluate(listOf(wifi), wifi.id, 0L)
        policy.evaluate(listOf(mobile), mobile.id, 1L)
        policy.evaluate(listOf(mobile), mobile.id, 1L)

        val outcome = policy.recordDataplaneProbe(mobile, healthy = true)

        assertTrue(outcome is UnderlyingNetworkHandoverPolicy.Decision.HandoverSurvived)
        assertEquals(mobile.id, policy.selectedCandidate()?.id)
    }

    @Test
    fun suspendedOrUnvalidatedReplacementCannotTriggerVerification() {
        val policy = policy(graceMs = 100L)
        policy.evaluate(listOf(wifi), wifi.id, 0L)
        val suspendedMobile = mobile.copy(suspended = true)

        policy.evaluate(listOf(suspendedMobile), mobile.id, 10L)
        val decision = policy.evaluate(listOf(suspendedMobile), mobile.id, 500L)

        assertTrue(decision is UnderlyingNetworkHandoverPolicy.Decision.Pending)
        assertEquals(null, (decision as UnderlyingNetworkHandoverPolicy.Decision.Pending).replacement)
    }

    @Test
    fun deferredProbeCanBeRequestedAgainAfterRuntimeBecomesCommitted() {
        val policy = policy(graceMs = 0L)
        policy.evaluate(listOf(wifi), wifi.id, 0L)
        policy.evaluate(listOf(mobile), mobile.id, 1L)
        val firstVerify = policy.evaluate(listOf(mobile), mobile.id, 1L)
        assertTrue(firstVerify is UnderlyingNetworkHandoverPolicy.Decision.VerifyDataplane)

        policy.deferDataplaneVerification(mobile)
        val retried = policy.evaluate(listOf(mobile), mobile.id, 2L)

        assertTrue(retried is UnderlyingNetworkHandoverPolicy.Decision.VerifyDataplane)
    }

    private fun policy(
        graceMs: Long = 600L,
        failuresBeforeReconnect: Int = 2,
    ) = UnderlyingNetworkHandoverPolicy(graceMs, failuresBeforeReconnect)

    private fun candidate(
        id: String,
        transport: UnderlyingNetworkHandoverPolicy.Transport,
    ) = UnderlyingNetworkHandoverPolicy.Candidate(
        id = id,
        transport = transport,
        hasInternet = true,
        validated = true,
    )
}
