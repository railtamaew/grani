package com.granivpn.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnLifecycleUiPolicyTest {

    @Test
    fun connected_like_states_are_active_and_expect_grani_notification() {
        val statuses = listOf(
            NativeVpnRuntimeState.RuntimeStatus.LOCAL_UP,
            NativeVpnRuntimeState.RuntimeStatus.VERIFIED,
            NativeVpnRuntimeState.RuntimeStatus.CONNECTED,
        )

        statuses.forEach { status ->
            val model = VpnLifecycleUiPolicy.modelFor(
                status,
                graniLikelyActive = true,
                systemVpnActive = true,
            )

            assertEquals(VpnLifecycleUiPolicy.TileVisualState.ACTIVE, model.tileState)
            assertEquals(VpnLifecycleUiPolicy.TileSubtitle.CONNECTED, model.tileSubtitle)
            assertTrue(model.notificationExpected)
            assertTrue(model.graniOwned)
            assertFalse(model.thirdPartyVpnActive)
        }
    }

    @Test
    fun transient_states_make_tile_temporarily_unavailable() {
        val connecting = VpnLifecycleUiPolicy.modelFor(
            NativeVpnRuntimeState.RuntimeStatus.CONNECTING,
            graniLikelyActive = false,
            systemVpnActive = false,
        )
        val disconnecting = VpnLifecycleUiPolicy.modelFor(
            NativeVpnRuntimeState.RuntimeStatus.DISCONNECTING,
            graniLikelyActive = true,
            systemVpnActive = true,
        )

        assertEquals(VpnLifecycleUiPolicy.TileVisualState.UNAVAILABLE, connecting.tileState)
        assertEquals(VpnLifecycleUiPolicy.TileSubtitle.CONNECTING, connecting.tileSubtitle)
        assertFalse(connecting.notificationExpected)
        assertTrue(connecting.graniOwned)

        assertEquals(VpnLifecycleUiPolicy.TileVisualState.UNAVAILABLE, disconnecting.tileState)
        assertEquals(VpnLifecycleUiPolicy.TileSubtitle.DISCONNECTING, disconnecting.tileSubtitle)
        assertTrue(disconnecting.notificationExpected)
        assertTrue(disconnecting.graniOwned)
    }

    @Test
    fun error_state_is_inactive_but_still_grani_owned_until_runtime_clears_it() {
        val model = VpnLifecycleUiPolicy.modelFor(
            NativeVpnRuntimeState.RuntimeStatus.ERROR,
            graniLikelyActive = true,
            systemVpnActive = true,
        )

        assertEquals(VpnLifecycleUiPolicy.TileVisualState.INACTIVE, model.tileState)
        assertEquals(VpnLifecycleUiPolicy.TileSubtitle.ERROR, model.tileSubtitle)
        assertTrue(model.notificationExpected)
        assertTrue(model.graniOwned)
        assertFalse(model.thirdPartyVpnActive)
    }

    @Test
    fun off_with_system_vpn_active_is_treated_as_third_party_vpn() {
        val model = VpnLifecycleUiPolicy.modelFor(
            NativeVpnRuntimeState.RuntimeStatus.OFF,
            graniLikelyActive = false,
            systemVpnActive = true,
        )

        assertEquals(VpnLifecycleUiPolicy.TileVisualState.INACTIVE, model.tileState)
        assertEquals(VpnLifecycleUiPolicy.TileSubtitle.OFF, model.tileSubtitle)
        assertFalse(model.notificationExpected)
        assertFalse(model.graniOwned)
        assertTrue(model.thirdPartyVpnActive)
    }
}
