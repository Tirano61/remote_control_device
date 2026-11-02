package com.example.remote_control_device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What happens to a tap around `dispatchGesture`, which is replaced by a fake that records the
 * pixel and lets the test report the result when Android would.
 */
class RemoteTapDispatcherTest {

    private val landscape = ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1)
    private val portrait = ScreenCaptureGeometry(width = 800, height = 1280, densityDpi = 160, rotation = 0)

    /** What `Display.getRealMetrics` / `getRotation` answer right now. */
    private var display = landscape

    private val dispatched = mutableListOf<TapPixel>()
    private var report: ((Boolean) -> Unit)? = null

    /** What `dispatchGesture` returns. */
    private var accepted = true

    private val outcomes = mutableListOf<RemoteTapOutcome>()

    private val dispatcher = RemoteTapDispatcher(
        readDisplay = { display },
        dispatch = { pixel, onResult ->
            dispatched += pixel
            report = onResult
            accepted
        },
    )

    private fun tap(x: Double = 0.5, y: Double = 0.5) = dispatcher.tap(x, y) { outcomes += it }

    @Test
    fun `asking for the gesture is not having done it`() {
        tap()

        assertEquals(listOf(TapPixel(640, 400)), dispatched)
        assertTrue(outcomes.isEmpty())
    }

    @Test
    fun `completed is reported as completed`() {
        tap()
        report!!(true)

        assertEquals(listOf(RemoteTapOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `cancelled is reported as cancelled`() {
        tap()
        report!!(false)

        assertEquals(listOf(RemoteTapOutcome.CANCELLED), outcomes)
    }

    @Test
    fun `a gesture Android refused is rejected at once`() {
        accepted = false
        tap()

        assertEquals(listOf(RemoteTapOutcome.REJECTED), outcomes)
    }

    @Test
    fun `dispatchGesture throwing is a rejection, not a crash`() {
        val throwing = RemoteTapDispatcher(
            readDisplay = { display },
            dispatch = { _, _ -> throw IllegalStateException("not connected") },
        )

        throwing.tap(0.5, 0.5) { outcomes += it }

        assertEquals(listOf(RemoteTapOutcome.REJECTED), outcomes)
    }

    @Test
    fun `a display that cannot be read is a rejection, and no gesture`() {
        val blind = RemoteTapDispatcher(
            readDisplay = { throw IllegalStateException("no default display") },
            dispatch = { pixel, _ ->
                dispatched += pixel
                true
            },
        )

        blind.tap(0.5, 0.5) { outcomes += it }

        assertEquals(listOf(RemoteTapOutcome.REJECTED), outcomes)
        assertTrue(dispatched.isEmpty())
    }

    @Test
    fun `a position off the screen never reaches a gesture`() {
        tap(x = 1.5)
        tap(y = Double.NaN)

        assertEquals(listOf(RemoteTapOutcome.INVALID, RemoteTapOutcome.INVALID), outcomes)
        assertTrue(dispatched.isEmpty())
    }

    @Test
    fun `a second tap while one is running is refused and does not disturb it`() {
        tap()
        val first = report!!

        tap()

        assertEquals(1, dispatched.size)
        assertEquals(listOf(RemoteTapOutcome.BUSY), outcomes)

        first(true)
        assertEquals(listOf(RemoteTapOutcome.BUSY, RemoteTapOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `the next tap runs once the previous one has finished`() {
        tap()
        report!!(true)
        tap()

        assertEquals(2, dispatched.size)
    }

    @Test
    fun `the service going away answers the running tap, once`() {
        tap()
        val late = report!!

        dispatcher.abandon()
        assertEquals(listOf(RemoteTapOutcome.CANCELLED), outcomes)

        // Android reports it after all. It has been answered.
        late(true)
        assertEquals(listOf(RemoteTapOutcome.CANCELLED), outcomes)
    }

    @Test
    fun `a late report about one tap is not taken for the next`() {
        tap()
        val late = report!!
        dispatcher.abandon()
        tap()

        late(true)

        assertEquals(listOf(RemoteTapOutcome.CANCELLED), outcomes)
    }

    @Test
    fun `the same position lands on the centre of the screen as it is now`() {
        display = portrait
        tap()
        report!!(true)

        // Turned. No signal reached the dispatcher: it reads the display for every tap.
        display = landscape
        tap()

        assertEquals(listOf(TapPixel(400, 640), TapPixel(640, 400)), dispatched)
    }

    @Test
    fun `availability follows the service, and a tap without it is unavailable`() {
        val availability = RemoteControlAvailability()
        val changes = mutableListOf<Boolean>()
        availability.onChanged = { changes += it }

        assertFalse(availability.isAvailable)
        availability.tap(0.5, 0.5) { outcomes += it }
        assertEquals(listOf(RemoteTapOutcome.UNAVAILABLE), outcomes)

        availability.connected(dispatcher)
        assertTrue(availability.isAvailable)

        availability.tap(0.5, 0.5) { outcomes += it }
        assertEquals(1, dispatched.size)

        availability.disconnected()
        assertFalse(availability.isAvailable)
        // The running tap is answered, and the next finds no service.
        assertEquals(listOf(RemoteTapOutcome.UNAVAILABLE, RemoteTapOutcome.CANCELLED), outcomes)
        availability.tap(0.5, 0.5) { outcomes += it }
        assertEquals(RemoteTapOutcome.UNAVAILABLE, outcomes.last())
        assertEquals(1, dispatched.size)

        assertEquals(listOf(true, false), changes)
    }

    @Test
    fun `a service enabled again works like the first time`() {
        val availability = RemoteControlAvailability()
        val changes = mutableListOf<Boolean>()
        availability.onChanged = { changes += it }

        availability.connected(dispatcher)
        availability.disconnected()
        availability.connected(dispatcher)

        assertEquals(listOf(true, false, true), changes)
        assertTrue(availability.isAvailable)

        availability.tap(0.5, 0.5) { outcomes += it }
        report!!(true)

        assertEquals(listOf(RemoteTapOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `being told twice that the service is gone reports it once`() {
        val availability = RemoteControlAvailability()
        val changes = mutableListOf<Boolean>()
        availability.connected(dispatcher)
        availability.onChanged = { changes += it }

        availability.disconnected()
        availability.disconnected()

        assertEquals(listOf(false), changes)
    }
}
