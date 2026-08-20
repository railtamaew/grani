package com.granivpn.mobile

import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Serializes ownership-changing VPN operations across Flutter, Quick Tile and
 * process-recovery entry points.
 *
 * A disconnect request advances [disconnectEpoch] before it waits for the
 * lock. The active connect can therefore cancel its readiness wait and perform
 * an ordered teardown. Connect requests that were queued before that
 * disconnect are rejected as superseded instead of starting a stale tunnel
 * after the user asked to stop.
 */
internal class VpnRuntimeOperationGate {
    internal class ConnectToken internal constructor(
        private val requestedAtDisconnectEpoch: Long,
        private val currentDisconnectEpoch: () -> Long,
    ) {
        fun isCancellationRequested(): Boolean =
            currentDisconnectEpoch() != requestedAtDisconnectEpoch
    }

    private val operationLock = ReentrantLock(true)
    private val disconnectEpoch = AtomicLong(0L)

    fun <T> withConnect(block: (ConnectToken) -> T): T {
        val requestedAtEpoch = disconnectEpoch.get()
        return operationLock.withLock {
            block(
                ConnectToken(
                    requestedAtDisconnectEpoch = requestedAtEpoch,
                    currentDisconnectEpoch = disconnectEpoch::get,
                ),
            )
        }
    }

    fun <T> withDisconnect(
        onRequested: () -> Unit = {},
        block: () -> T,
    ): T {
        disconnectEpoch.incrementAndGet()
        onRequested()
        return operationLock.withLock(block)
    }

    /**
     * A handover owns one atomic disconnect -> connect transaction. Advancing
     * the epoch first cancels an active/queued stale connect, while the token
     * created for this transaction remains valid for the replacement start.
     */
    fun <T> withReconnect(
        onRequested: () -> Unit = {},
        block: (ConnectToken) -> T,
    ): T {
        val reconnectEpoch = disconnectEpoch.incrementAndGet()
        onRequested()
        return operationLock.withLock {
            block(
                ConnectToken(
                    requestedAtDisconnectEpoch = reconnectEpoch,
                    currentDisconnectEpoch = disconnectEpoch::get,
                ),
            )
        }
    }
}
