package com.example.remote_control_device

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A long press around `dispatchGesture`. The device's long-press timeout is a fake the test sets,
 * so nothing here depends on what `ViewConfiguration` answers on the machine running it.
 */
class RemoteLongPressTest {

    private val landscape = ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1)
    private val portrait = ScreenCaptureGeometry(width = 800, height = 1280, densityDpi = 160, rotation = 0)

    private var display = landscape

    /** What `ViewConfiguration.getLongPressTimeout()` answers right now. */
    private var longPressTimeout = 500L
    private var timeoutReads = 0

    private val strokes = mutableListOf<GestureStroke>()
    private var report: ((Boolean) -> Unit)? = null
    private var accepted = true

    private var windowReads = 0
    private val globalActions = mutableListOf<Int>()

    private val outcomes = mutableListOf<RemoteGestureOutcome>()

    private val dispatcher = RemoteGestureDispatcher(
        readDisplay = { display },
        dispatch = { stroke, onResult ->
            strokes += stroke
            report = onResult
            accepted
        },
        performGlobalAction = { action ->
            globalActions += action
            true
        },
        activeWindow = {
            windowReads++
            null
        },
        longPressTimeoutMs = {
            timeoutReads++
            longPressTimeout
        },
    )

    private fun longPress(x: Double = 0.5, y: Double = 0.5) = dispatcher.longPress(x, y) { outcomes += it }

    private fun tap(x: Double = 0.5, y: Double = 0.5) = dispatcher.tap(x, y) { outcomes += it }

    // Duration

    @Test
    fun `the duration is the device's timeout plus the margin`() {
        assertEquals(100L, LONG_PRESS_MARGIN_MS)
        assertEquals(600L, longPressDurationMs(500L))
        assertEquals(1100L, longPressDurationMs(1000L))
        assertEquals(1600L, longPressDurationMs(1500L))
        assertEquals(500L, longPressDurationMs(400L))
    }

    @Test
    fun `a timeout of 500 holds the stroke for 600`() {
        longPressTimeout = 500L
        longPress()

        assertEquals(600L, strokes.single().durationMs)
    }

    @Test
    fun `a timeout of 1000 holds the stroke for 1100`() {
        longPressTimeout = 1000L
        longPress()

        assertEquals(1100L, strokes.single().durationMs)
    }

    @Test
    fun `the timeout is read afresh for every long press`() {
        longPressTimeout = 500L
        longPress()
        report!!(true)

        // The user changed the touch-and-hold delay. No signal reached the dispatcher.
        longPressTimeout = 1500L
        longPress()

        assertEquals(listOf(600L, 1600L), strokes.map { it.durationMs })
        assertEquals(2, timeoutReads)
    }

    @Test
    fun `a timeout that cannot be used gives no duration`() {
        assertNull(longPressDurationMs(0L))
        assertNull(longPressDurationMs(-1L))
        assertNull(longPressDurationMs(MAX_LONG_PRESS_DURATION_MS))
        assertEquals(MAX_LONG_PRESS_DURATION_MS, longPressDurationMs(MAX_LONG_PRESS_DURATION_MS - LONG_PRESS_MARGIN_MS))
    }

    @Test
    fun `the cap leaves room under the 5 s the Dart side waits, and above every Android setting`() {
        // The longest touch-and-hold delay stock Android's settings offer is 1.5 s.
        assertTrue(longPressDurationMs(1500L)!! <= MAX_LONG_PRESS_DURATION_MS)
        assertTrue(MAX_LONG_PRESS_DURATION_MS < 5000L)
    }

    @Test
    fun `a timeout that cannot be used is rejected, and no gesture starts`() {
        longPressTimeout = 0L
        longPress()
        longPressTimeout = 60_000L
        longPress()

        assertEquals(List(2) { RemoteGestureOutcome.REJECTED }, outcomes)
        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `the timeout throwing is a rejection, not a crash`() {
        val throwing = RemoteGestureDispatcher(
            readDisplay = { display },
            dispatch = { stroke, _ ->
                strokes += stroke
                true
            },
            performGlobalAction = { true },
            activeWindow = { null },
            longPressTimeoutMs = { throw IllegalStateException("no configuration") },
        )

        throwing.longPress(0.5, 0.5) { outcomes += it }

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
        assertTrue(strokes.isEmpty())
    }

    // Coordinates: the tap's, through the same gesturePixel.

    @Test
    fun `the corners and the centre land where a tap's do`() {
        for ((x, y) in listOf(0.0 to 0.0, 1.0 to 1.0, 0.5 to 0.5)) {
            longPress(x, y)
            report!!(true)
            tap(x, y)
            report!!(true)
        }

        assertEquals(
            listOf(
                GesturePixel(0, 0), GesturePixel(0, 0),
                GesturePixel(1279, 799), GesturePixel(1279, 799),
                GesturePixel(640, 400), GesturePixel(640, 400),
            ),
            strokes.map { it.start },
        )
    }

    @Test
    fun `the same position lands on the screen as it is now`() {
        display = portrait
        longPress(0.25, 0.75)
        report!!(true)

        // Turned. No signal reached the dispatcher: it reads the display for every long press.
        display = landscape
        longPress(0.25, 0.75)

        assertEquals(listOf(GesturePixel(200, 960), GesturePixel(320, 600)), strokes.map { it.start })
    }

    @Test
    fun `turning during a long press leaves its stroke as it was given to Android`() {
        display = portrait
        longPress()
        display = landscape
        report!!(true)

        assertEquals(listOf(GestureStroke(GesturePixel(400, 640), null, 600L)), strokes)
        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `a position off the screen never reaches a gesture, nor the timeout`() {
        longPress(x = 1.5)
        longPress(x = -0.1)
        longPress(y = Double.NaN)
        longPress(y = Double.POSITIVE_INFINITY)

        assertEquals(List(4) { RemoteGestureOutcome.INVALID }, outcomes)
        assertTrue(strokes.isEmpty())
        assertEquals(0, timeoutReads)
    }

    // The gesture

    @Test
    fun `it is one stroke that stays where it lands`() {
        longPress(0.5, 0.25)

        assertEquals(listOf(GestureStroke(GesturePixel(640, 200), null, 600L)), strokes)
        assertNull(strokes.single().end)
    }

    @Test
    fun `asking for it is not having done it`() {
        longPress()

        assertEquals(1, strokes.size)
        assertTrue(outcomes.isEmpty())
    }

    @Test
    fun `completed is reported as completed`() {
        longPress()
        report!!(true)

        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `dispatchGesture answering false is rejected at once`() {
        accepted = false
        longPress()

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
    }

    @Test
    fun `Android cancelling it is reported as cancelled`() {
        longPress()
        report!!(false)

        assertEquals(listOf(RemoteGestureOutcome.CANCELLED), outcomes)
    }

    @Test
    fun `dispatchGesture throwing is a rejection, not a crash`() {
        val throwing = RemoteGestureDispatcher(
            readDisplay = { display },
            dispatch = { _, _ -> throw IllegalArgumentException("stroke too long") },
            performGlobalAction = { true },
            activeWindow = { null },
            longPressTimeoutMs = { 500L },
        )

        throwing.longPress(0.5, 0.5) { outcomes += it }

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
            performGlobalAction = { true },
            activeWindow = { null },
            longPressTimeoutMs = { 500L },
        )

        blind.longPress(0.5, 0.5) { outcomes += it }

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `with no service it is unavailable, and with it it runs`() {
        val availability = RemoteControlAvailability()

        availability.longPress(0.5, 0.5) { outcomes += it }
        assertEquals(listOf(RemoteGestureOutcome.UNAVAILABLE), outcomes)
        assertTrue(strokes.isEmpty())

        availability.connected(dispatcher)
        availability.longPress(0.5, 0.5) { outcomes += it }
        assertEquals(1, strokes.size)

        // The service going away answers the running long press, once.
        val late = report!!
        availability.disconnected()
        late(true)
        assertEquals(listOf(RemoteGestureOutcome.UNAVAILABLE, RemoteGestureOutcome.CANCELLED), outcomes)

        availability.longPress(0.5, 0.5) { outcomes += it }
        assertEquals(RemoteGestureOutcome.UNAVAILABLE, outcomes.last())
        assertEquals(1, strokes.size)
    }

    // Busy

    @Test
    fun `a long press while a gesture runs is busy, and does not disturb it`() {
        dispatcher.swipe(0.5, 0.75, 0.5, 0.25, 300L) { outcomes += it }
        val running = report!!

        longPress()

        assertEquals(1, strokes.size)
        assertEquals(listOf(RemoteGestureOutcome.BUSY), outcomes)

        running(true)
        assertEquals(RemoteGestureOutcome.COMPLETED, outcomes.last())
    }

    @Test
    fun `nothing else starts while a long press is held`() {
        longPress()
        val held = report!!

        tap()
        longPress()
        dispatcher.swipe(0.5, 0.75, 0.5, 0.25, 300L) { outcomes += it }
        dispatcher.home { outcomes += it }

        assertEquals(1, strokes.size)
        assertTrue(globalActions.isEmpty())
        assertEquals(List(4) { RemoteGestureOutcome.BUSY }, outcomes)

        held(true)
        tap()
        assertEquals(2, strokes.size)
    }

    // TAP regression: the primitive is shared, the duration is not.

    @Test
    fun `a tap is still 50 ms, whatever the long-press timeout`() {
        longPressTimeout = 1500L
        tap(0.5, 0.25)

        assertEquals(listOf(GestureStroke(GesturePixel(640, 200), null, 50L)), strokes)
        assertEquals(0, timeoutReads)
    }

    @Test
    fun `a tap after a long press is a tap again`() {
        longPress()
        report!!(true)
        tap()

        assertEquals(listOf(600L, 50L), strokes.map { it.durationMs })
        assertEquals(1, timeoutReads)
    }

    // Privacy

    @Test
    fun `it looks at no window and performs no action on any node`() {
        longPress()
        report!!(true)
        longPress()
        report!!(false)

        assertEquals(0, windowReads)
        assertTrue(globalActions.isEmpty())
    }

    @Test
    fun `nothing stands in for the gesture`() {
        val sources = listOf(
            code("src/main/kotlin/com/example/remote_control_device/RemoteGesture.kt"),
            code("src/main/kotlin/com/example/remote_control_device/RemoteControlAccessibilityChannel.kt"),
            code("src/main/kotlin/com/example/remote_control_device/RemoteControlAccessibilityService.kt"),
        )
        for (excluded in listOf(
            "ACTION_LONG_CLICK",
            "performAction",
            "AccessibilityNodeInfo",
            "FOCUS_INPUT",
            "ClipboardManager",
            "Thread.sleep",
            "KeyEvent",
            "Instrumentation",
            "InputManager",
            "Settings.Secure",
            "Settings.System",
        )) {
            for (source in sources) assertFalse(excluded, source.contains(excluded))
        }
    }

    @Test
    fun `the service reads the timeout from ViewConfiguration and nowhere else`() {
        val service = code("src/main/kotlin/com/example/remote_control_device/RemoteControlAccessibilityService.kt")

        assertTrue(service.contains("longPressTimeoutMs = { ViewConfiguration.getLongPressTimeout().toLong() }"))
        assertFalse(service.contains("500"))
    }

    /** A Kotlin source without its comments, which may name what the code must not touch. */
    private fun code(path: String): String =
        File(path).readText()
            .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), "")
            .replace(Regex("""//[^\n]*"""), "")
}
