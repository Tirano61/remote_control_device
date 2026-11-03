package com.example.remote_control_device

import android.accessibilityservice.AccessibilityService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What happens to a gesture around `dispatchGesture`, which is replaced by a fake that records
 * the stroke and lets the test report the result when Android would.
 */
class RemoteGestureDispatcherTest {

    private val landscape = ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1)
    private val portrait = ScreenCaptureGeometry(width = 800, height = 1280, densityDpi = 160, rotation = 0)

    /** What `Display.getRealMetrics` / `getRotation` answer right now. */
    private var display = landscape

    private val strokes = mutableListOf<GestureStroke>()

    /** Where each gesture started. */
    private val dispatched: List<GesturePixel> get() = strokes.map { it.start }

    private var report: ((Boolean) -> Unit)? = null

    /** What `dispatchGesture` returns. */
    private var accepted = true

    /** Every action `performGlobalAction` received. */
    private val globalActions = mutableListOf<Int>()

    /** What `performGlobalAction` returns. */
    private var globalActionAccepted = true

    private val outcomes = mutableListOf<RemoteGestureOutcome>()

    private val recordGlobalAction: (Int) -> Boolean = { action ->
        globalActions += action
        globalActionAccepted
    }

    /** `set_text` has its own tests, in [RemoteSetTextTest]. */
    private val noWindow: () -> RemoteTextWindow? = { null }

    private val dispatcher = RemoteGestureDispatcher(
        readDisplay = { display },
        dispatch = { stroke, onResult ->
            strokes += stroke
            report = onResult
            accepted
        },
        performGlobalAction = recordGlobalAction,
        activeWindow = noWindow,
    )

    private fun tap(x: Double = 0.5, y: Double = 0.5) = dispatcher.tap(x, y) { outcomes += it }

    private fun swipe(
        startX: Double = 0.5,
        startY: Double = 0.75,
        endX: Double = 0.5,
        endY: Double = 0.25,
        durationMs: Long = 300L,
    ) = dispatcher.swipe(startX, startY, endX, endY, durationMs) { outcomes += it }

    @Test
    fun `asking for the gesture is not having done it`() {
        tap()

        assertEquals(listOf(GesturePixel(640, 400)), dispatched)
        assertTrue(outcomes.isEmpty())
    }

    @Test
    fun `completed is reported as completed`() {
        tap()
        report!!(true)

        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `cancelled is reported as cancelled`() {
        tap()
        report!!(false)

        assertEquals(listOf(RemoteGestureOutcome.CANCELLED), outcomes)
    }

    @Test
    fun `a gesture Android refused is rejected at once`() {
        accepted = false
        tap()

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
    }

    @Test
    fun `dispatchGesture throwing is a rejection, not a crash`() {
        val throwing = RemoteGestureDispatcher(
            readDisplay = { display },
            dispatch = { _, _ -> throw IllegalStateException("not connected") },
            performGlobalAction = recordGlobalAction,
            activeWindow = noWindow,
        )

        throwing.tap(0.5, 0.5) { outcomes += it }

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
    }

    @Test
    fun `a display that cannot be read is a rejection, and no gesture`() {
        val blind = RemoteGestureDispatcher(
            readDisplay = { throw IllegalStateException("no default display") },
            dispatch = { stroke, _ ->
                strokes += stroke
                true
            },
            performGlobalAction = recordGlobalAction,
            activeWindow = noWindow,
        )

        blind.tap(0.5, 0.5) { outcomes += it }

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
        assertTrue(dispatched.isEmpty())
    }

    @Test
    fun `a position off the screen never reaches a gesture`() {
        tap(x = 1.5)
        tap(y = Double.NaN)

        assertEquals(listOf(RemoteGestureOutcome.INVALID, RemoteGestureOutcome.INVALID), outcomes)
        assertTrue(dispatched.isEmpty())
    }

    @Test
    fun `a second tap while one is running is refused and does not disturb it`() {
        tap()
        val first = report!!

        tap()

        assertEquals(1, dispatched.size)
        assertEquals(listOf(RemoteGestureOutcome.BUSY), outcomes)

        first(true)
        assertEquals(listOf(RemoteGestureOutcome.BUSY, RemoteGestureOutcome.COMPLETED), outcomes)
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
        assertEquals(listOf(RemoteGestureOutcome.CANCELLED), outcomes)

        // Android reports it after all. It has been answered.
        late(true)
        assertEquals(listOf(RemoteGestureOutcome.CANCELLED), outcomes)
    }

    @Test
    fun `a late report about one tap is not taken for the next`() {
        tap()
        val late = report!!
        dispatcher.abandon()
        tap()

        late(true)

        assertEquals(listOf(RemoteGestureOutcome.CANCELLED), outcomes)
    }

    @Test
    fun `the same position lands on the centre of the screen as it is now`() {
        display = portrait
        tap()
        report!!(true)

        // Turned. No signal reached the dispatcher: it reads the display for every tap.
        display = landscape
        tap()

        assertEquals(listOf(GesturePixel(400, 640), GesturePixel(640, 400)), dispatched)
    }

    @Test
    fun `availability follows the service, and a tap without it is unavailable`() {
        val availability = RemoteControlAvailability()
        val changes = mutableListOf<Boolean>()
        availability.onChanged = { changes += it }

        assertFalse(availability.isAvailable)
        availability.tap(0.5, 0.5) { outcomes += it }
        assertEquals(listOf(RemoteGestureOutcome.UNAVAILABLE), outcomes)

        availability.connected(dispatcher)
        assertTrue(availability.isAvailable)

        availability.tap(0.5, 0.5) { outcomes += it }
        assertEquals(1, dispatched.size)

        availability.disconnected()
        assertFalse(availability.isAvailable)
        // The running tap is answered, and the next finds no service.
        assertEquals(listOf(RemoteGestureOutcome.UNAVAILABLE, RemoteGestureOutcome.CANCELLED), outcomes)
        availability.tap(0.5, 0.5) { outcomes += it }
        assertEquals(RemoteGestureOutcome.UNAVAILABLE, outcomes.last())
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

        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `a tap is a stroke that goes nowhere, for as long as it always was`() {
        tap()

        assertEquals(listOf(GestureStroke(GesturePixel(640, 400), null, 50L)), strokes)
    }

    @Test
    fun `asking for a swipe is not having done it`() {
        swipe()

        assertEquals(
            listOf(GestureStroke(GesturePixel(640, 600), GesturePixel(640, 200), 300L)),
            strokes,
        )
        assertTrue(outcomes.isEmpty())
    }

    @Test
    fun `the duration reaches the stroke as it was asked for`() {
        swipe(durationMs = 350L)

        assertEquals(350L, strokes.single().durationMs)
    }

    @Test
    fun `both ends of the allowed duration reach the stroke`() {
        swipe(durationMs = 50L)
        report!!(true)
        swipe(durationMs = 2000L)

        assertEquals(listOf(50L, 2000L), strokes.map { it.durationMs })
    }

    @Test
    fun `a completed swipe is reported as completed`() {
        swipe()
        report!!(true)

        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `a cancelled swipe is reported as cancelled`() {
        swipe()
        report!!(false)

        assertEquals(listOf(RemoteGestureOutcome.CANCELLED), outcomes)
    }

    @Test
    fun `a swipe Android refused is rejected at once`() {
        accepted = false
        swipe()

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
    }

    @Test
    fun `a display that cannot be read rejects a swipe, and no gesture`() {
        val blind = RemoteGestureDispatcher(
            readDisplay = { throw IllegalStateException("no default display") },
            dispatch = { stroke, _ ->
                strokes += stroke
                true
            },
            performGlobalAction = recordGlobalAction,
            activeWindow = noWindow,
        )

        blind.swipe(0.5, 0.75, 0.5, 0.25, 300L) { outcomes += it }

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `a swipe that is not valid never reaches a gesture`() {
        swipe(startX = 1.5)
        swipe(startY = -0.1)
        swipe(endX = Double.NaN)
        swipe(endY = Double.POSITIVE_INFINITY)
        swipe(durationMs = 49L)
        swipe(durationMs = 2001L)

        assertEquals(List(6) { RemoteGestureOutcome.INVALID }, outcomes)
        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `a swipe that lands on one pixel never reaches a gesture`() {
        swipe(startX = 0.5, startY = 0.5, endX = 0.5001, endY = 0.5001)

        assertEquals(listOf(RemoteGestureOutcome.INVALID), outcomes)
        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `no gesture of either kind starts while a swipe is running`() {
        swipe()
        val first = report!!

        tap()
        swipe()

        assertEquals(1, strokes.size)
        assertEquals(listOf(RemoteGestureOutcome.BUSY, RemoteGestureOutcome.BUSY), outcomes)

        first(true)
        assertEquals(RemoteGestureOutcome.COMPLETED, outcomes.last())
    }

    @Test
    fun `a swipe is refused while a tap is running, and runs after it`() {
        tap()
        val first = report!!

        swipe()

        assertEquals(1, strokes.size)
        assertEquals(listOf(RemoteGestureOutcome.BUSY), outcomes)

        first(true)
        swipe()
        assertEquals(2, strokes.size)
    }

    @Test
    fun `the service going away answers the running swipe, once`() {
        swipe()
        val late = report!!

        dispatcher.abandon()
        late(true)

        assertEquals(listOf(RemoteGestureOutcome.CANCELLED), outcomes)
    }

    @Test
    fun `each swipe reads the screen as it is when it starts`() {
        display = portrait
        swipe()
        report!!(true)

        // Turned. No signal reached the dispatcher.
        display = landscape
        swipe()

        assertEquals(
            listOf(
                GestureStroke(GesturePixel(400, 960), GesturePixel(400, 320), 300L),
                GestureStroke(GesturePixel(640, 600), GesturePixel(640, 200), 300L),
            ),
            strokes,
        )
    }

    @Test
    fun `turning during a swipe leaves its stroke as it was given to Android`() {
        display = portrait
        swipe()

        display = landscape
        report!!(true)

        assertEquals(
            listOf(GestureStroke(GesturePixel(400, 960), GesturePixel(400, 320), 300L)),
            strokes,
        )
        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `a swipe with no service is unavailable, and one with it runs`() {
        val availability = RemoteControlAvailability()

        availability.swipe(0.5, 0.75, 0.5, 0.25, 300L) { outcomes += it }
        assertEquals(listOf(RemoteGestureOutcome.UNAVAILABLE), outcomes)
        assertTrue(strokes.isEmpty())

        availability.connected(dispatcher)
        availability.swipe(0.5, 0.75, 0.5, 0.25, 300L) { outcomes += it }
        assertEquals(1, strokes.size)

        availability.disconnected()
        assertEquals(
            listOf(RemoteGestureOutcome.UNAVAILABLE, RemoteGestureOutcome.CANCELLED),
            outcomes,
        )
    }

    @Test
    fun `back is GLOBAL_ACTION_BACK`() {
        dispatcher.back { outcomes += it }

        assertEquals(listOf(AccessibilityService.GLOBAL_ACTION_BACK), globalActions)
    }

    @Test
    fun `home is GLOBAL_ACTION_HOME`() {
        dispatcher.home { outcomes += it }

        assertEquals(listOf(AccessibilityService.GLOBAL_ACTION_HOME), globalActions)
    }

    @Test
    fun `recents is GLOBAL_ACTION_RECENTS`() {
        dispatcher.recents { outcomes += it }

        assertEquals(listOf(AccessibilityService.GLOBAL_ACTION_RECENTS), globalActions)
    }

    @Test
    fun `the three actions are the ones Android defines`() {
        // The constants are inlined from android.jar. Spelled out so that a change there, or two
        // of them being swapped above, has something to disagree with.
        assertEquals(1, AccessibilityService.GLOBAL_ACTION_BACK)
        assertEquals(2, AccessibilityService.GLOBAL_ACTION_HOME)
        assertEquals(3, AccessibilityService.GLOBAL_ACTION_RECENTS)
    }

    @Test
    fun `performGlobalAction answering true is completed, at once`() {
        dispatcher.back { outcomes += it }
        dispatcher.home { outcomes += it }
        dispatcher.recents { outcomes += it }

        assertEquals(List(3) { RemoteGestureOutcome.COMPLETED }, outcomes)
    }

    @Test
    fun `performGlobalAction answering false is rejected`() {
        globalActionAccepted = false

        dispatcher.back { outcomes += it }
        dispatcher.home { outcomes += it }
        dispatcher.recents { outcomes += it }

        assertEquals(List(3) { RemoteGestureOutcome.REJECTED }, outcomes)
    }

    @Test
    fun `performGlobalAction throwing is a rejection, not a crash`() {
        val throwing = RemoteGestureDispatcher(
            readDisplay = { display },
            dispatch = { _, _ -> true },
            performGlobalAction = { throw IllegalStateException("not connected") },
            activeWindow = noWindow,
        )

        throwing.back { outcomes += it }
        throwing.recents { outcomes += it }

        assertEquals(List(2) { RemoteGestureOutcome.REJECTED }, outcomes)
    }

    @Test
    fun `a global action reads no display, and works where none can be read`() {
        var reads = 0
        val blind = RemoteGestureDispatcher(
            readDisplay = {
                reads++
                throw IllegalStateException("no default display")
            },
            dispatch = { _, _ -> true },
            performGlobalAction = recordGlobalAction,
            activeWindow = noWindow,
        )

        blind.back { outcomes += it }
        blind.home { outcomes += it }
        blind.recents { outcomes += it }

        assertEquals(0, reads)
        assertEquals(List(3) { RemoteGestureOutcome.COMPLETED }, outcomes)
    }

    @Test
    fun `a global action is no stroke`() {
        dispatcher.back { outcomes += it }
        dispatcher.home { outcomes += it }
        dispatcher.recents { outcomes += it }

        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `no global action starts while a gesture is running, and it is not disturbed`() {
        swipe()
        val first = report!!

        dispatcher.home { outcomes += it }
        dispatcher.back { outcomes += it }
        dispatcher.recents { outcomes += it }

        assertTrue(globalActions.isEmpty())
        assertEquals(List(3) { RemoteGestureOutcome.BUSY }, outcomes)

        first(true)
        assertEquals(RemoteGestureOutcome.COMPLETED, outcomes.last())

        dispatcher.home { outcomes += it }
        assertEquals(listOf(AccessibilityService.GLOBAL_ACTION_HOME), globalActions)
    }

    @Test
    fun `a recents runs once the gesture it was refused under has finished`() {
        tap()
        val first = report!!

        dispatcher.recents { outcomes += it }
        assertTrue(globalActions.isEmpty())

        first(true)
        dispatcher.recents { outcomes += it }

        assertEquals(listOf(AccessibilityService.GLOBAL_ACTION_RECENTS), globalActions)
        assertEquals(
            listOf(RemoteGestureOutcome.BUSY, RemoteGestureOutcome.COMPLETED, RemoteGestureOutcome.COMPLETED),
            outcomes,
        )
    }

    @Test
    fun `a global action leaves nothing running`() {
        dispatcher.home { outcomes += it }
        dispatcher.recents { outcomes += it }

        tap()

        assertEquals(1, strokes.size)
        assertEquals(List(2) { RemoteGestureOutcome.COMPLETED }, outcomes)
    }

    @Test
    fun `a global action with no service is unavailable, and never reaches Android`() {
        val availability = RemoteControlAvailability()

        availability.back { outcomes += it }
        availability.home { outcomes += it }
        availability.recents { outcomes += it }

        assertEquals(List(3) { RemoteGestureOutcome.UNAVAILABLE }, outcomes)
        assertTrue(globalActions.isEmpty())

        availability.connected(dispatcher)
        availability.back { outcomes += it }
        availability.home { outcomes += it }
        availability.recents { outcomes += it }
        assertEquals(
            listOf(
                AccessibilityService.GLOBAL_ACTION_BACK,
                AccessibilityService.GLOBAL_ACTION_HOME,
                AccessibilityService.GLOBAL_ACTION_RECENTS,
            ),
            globalActions,
        )

        availability.disconnected()
        availability.home { outcomes += it }
        availability.recents { outcomes += it }
        assertEquals(List(2) { RemoteGestureOutcome.UNAVAILABLE }, outcomes.takeLast(2))
        assertEquals(3, globalActions.size)
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
