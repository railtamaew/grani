package com.granivpn.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class VpnRuntimeOperationGateTest {
    @Test
    fun disconnectCancelsActiveConnectBeforeTakingOwnership() {
        val gate = VpnRuntimeOperationGate()
        val connectEntered = CountDownLatch(1)
        val disconnectRequested = CountDownLatch(1)
        val events = Collections.synchronizedList(mutableListOf<String>())

        val connectThread = Thread {
            gate.withConnect { token ->
                events += "connect_enter"
                connectEntered.countDown()
                assertTrue(disconnectRequested.await(2, TimeUnit.SECONDS))
                assertTrue(token.isCancellationRequested())
                events += "connect_teardown"
            }
        }
        val disconnectThread = Thread {
            assertTrue(connectEntered.await(2, TimeUnit.SECONDS))
            gate.withDisconnect(onRequested = disconnectRequested::countDown) {
                events += "disconnect_enter"
            }
        }

        connectThread.start()
        disconnectThread.start()
        connectThread.join(2_000L)
        disconnectThread.join(2_000L)

        assertFalse(connectThread.isAlive)
        assertFalse(disconnectThread.isAlive)
        assertEquals(
            listOf("connect_enter", "connect_teardown", "disconnect_enter"),
            events,
        )
    }

    @Test
    fun connectQueuedBeforeDisconnectIsSuperseded() {
        val gate = VpnRuntimeOperationGate()
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val secondRequested = CountDownLatch(1)
        val disconnectRequested = CountDownLatch(1)
        val secondCancelled = CountDownLatch(1)

        val first = Thread {
            gate.withConnect {
                firstEntered.countDown()
                assertTrue(releaseFirst.await(2, TimeUnit.SECONDS))
            }
        }
        val second = Thread {
            assertTrue(firstEntered.await(2, TimeUnit.SECONDS))
            secondRequested.countDown()
            gate.withConnect { token ->
                if (token.isCancellationRequested()) secondCancelled.countDown()
            }
        }
        val disconnect = Thread {
            assertTrue(secondRequested.await(2, TimeUnit.SECONDS))
            gate.withDisconnect(onRequested = disconnectRequested::countDown) { }
        }

        first.start()
        second.start()
        assertTrue(secondRequested.await(2, TimeUnit.SECONDS))
        disconnect.start()
        assertTrue(disconnectRequested.await(2, TimeUnit.SECONDS))
        releaseFirst.countDown()

        first.join(2_000L)
        second.join(2_000L)
        disconnect.join(2_000L)
        assertTrue(secondCancelled.await(200, TimeUnit.MILLISECONDS))
    }

    @Test
    fun queuedConnectCannotPassTerminalTeardownBarrier() {
        val gate = VpnRuntimeOperationGate()
        val firstEntered = CountDownLatch(1)
        val secondQueued = CountDownLatch(1)
        val allowTeardown = CountDownLatch(1)
        val events = Collections.synchronizedList(mutableListOf<String>())

        val failedConnect = Thread {
            gate.withConnect {
                events += "first_start"
                firstEntered.countDown()
                assertTrue(allowTeardown.await(2, TimeUnit.SECONDS))
                events += "first_terminal_failure"
                events += "first_teardown_off"
            }
        }
        val nextConnect = Thread {
            assertTrue(firstEntered.await(2, TimeUnit.SECONDS))
            secondQueued.countDown()
            gate.withConnect {
                events += "second_start"
            }
        }

        failedConnect.start()
        nextConnect.start()
        assertTrue(secondQueued.await(2, TimeUnit.SECONDS))
        allowTeardown.countDown()
        failedConnect.join(2_000L)
        nextConnect.join(2_000L)

        assertEquals(
            listOf(
                "first_start",
                "first_terminal_failure",
                "first_teardown_off",
                "second_start",
            ),
            events,
        )
    }

    @Test
    fun reconnectCancelsOldConnectAndOwnsAtomicReplacementStart() {
        val gate = VpnRuntimeOperationGate()
        val firstEntered = CountDownLatch(1)
        val reconnectRequested = CountDownLatch(1)
        val allowFirstToExit = CountDownLatch(1)
        val events = Collections.synchronizedList(mutableListOf<String>())

        val firstConnect = Thread {
            gate.withConnect { token ->
                events += "first_connect"
                firstEntered.countDown()
                assertTrue(reconnectRequested.await(2, TimeUnit.SECONDS))
                assertTrue(token.isCancellationRequested())
                events += "first_teardown"
                allowFirstToExit.countDown()
            }
        }
        val reconnect = Thread {
            assertTrue(firstEntered.await(2, TimeUnit.SECONDS))
            gate.withReconnect(onRequested = reconnectRequested::countDown) { token ->
                assertFalse(token.isCancellationRequested())
                events += "reconnect_disconnect"
                events += "reconnect_connect"
            }
        }

        firstConnect.start()
        reconnect.start()
        assertTrue(allowFirstToExit.await(2, TimeUnit.SECONDS))
        firstConnect.join(2_000L)
        reconnect.join(2_000L)

        assertEquals(
            listOf(
                "first_connect",
                "first_teardown",
                "reconnect_disconnect",
                "reconnect_connect",
            ),
            events,
        )
    }
}
