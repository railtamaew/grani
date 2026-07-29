package com.granivpn.mobile

object VpnLifecycleUiPolicy {
    enum class TileVisualState {
        ACTIVE,
        INACTIVE,
        UNAVAILABLE,
    }

    enum class TileSubtitle {
        CONNECTED,
        CONNECTING,
        DISCONNECTING,
        ERROR,
        OFF,
    }

    data class UiModel(
        val tileState: TileVisualState,
        val tileSubtitle: TileSubtitle,
        val notificationExpected: Boolean,
        val graniOwned: Boolean,
        val thirdPartyVpnActive: Boolean,
    )

    fun modelFor(
        status: NativeVpnRuntimeState.RuntimeStatus,
        graniLikelyActive: Boolean,
        systemVpnActive: Boolean,
    ): UiModel {
        val connectedLike = status == NativeVpnRuntimeState.RuntimeStatus.LOCAL_UP ||
            status == NativeVpnRuntimeState.RuntimeStatus.VERIFIED ||
            status == NativeVpnRuntimeState.RuntimeStatus.CONNECTED
        val graniOwned = status != NativeVpnRuntimeState.RuntimeStatus.OFF
        return when (status) {
            NativeVpnRuntimeState.RuntimeStatus.LOCAL_UP,
            NativeVpnRuntimeState.RuntimeStatus.VERIFIED,
            NativeVpnRuntimeState.RuntimeStatus.CONNECTED -> UiModel(
                tileState = TileVisualState.ACTIVE,
                tileSubtitle = TileSubtitle.CONNECTED,
                notificationExpected = graniLikelyActive,
                graniOwned = true,
                thirdPartyVpnActive = false,
            )
            NativeVpnRuntimeState.RuntimeStatus.CONNECTING -> UiModel(
                tileState = TileVisualState.UNAVAILABLE,
                tileSubtitle = TileSubtitle.CONNECTING,
                notificationExpected = graniLikelyActive,
                graniOwned = true,
                thirdPartyVpnActive = false,
            )
            NativeVpnRuntimeState.RuntimeStatus.DISCONNECTING -> UiModel(
                tileState = TileVisualState.UNAVAILABLE,
                tileSubtitle = TileSubtitle.DISCONNECTING,
                notificationExpected = graniLikelyActive,
                graniOwned = true,
                thirdPartyVpnActive = false,
            )
            NativeVpnRuntimeState.RuntimeStatus.ERROR -> UiModel(
                tileState = TileVisualState.INACTIVE,
                tileSubtitle = TileSubtitle.ERROR,
                notificationExpected = graniLikelyActive,
                graniOwned = true,
                thirdPartyVpnActive = false,
            )
            NativeVpnRuntimeState.RuntimeStatus.OFF -> UiModel(
                tileState = TileVisualState.INACTIVE,
                tileSubtitle = TileSubtitle.OFF,
                notificationExpected = false,
                graniOwned = false,
                thirdPartyVpnActive = systemVpnActive,
            )
        }.copy(
            notificationExpected = graniLikelyActive && (connectedLike || graniOwned),
        )
    }
}
