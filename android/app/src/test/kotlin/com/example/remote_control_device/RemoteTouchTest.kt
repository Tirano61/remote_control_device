package com.example.remote_control_device

import android.accessibilityservice.AccessibilityService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A remote touch around `dispatchGesture`, with continued strokes.
 *
 * `dispatchGesture` is a fake that records each [TouchSegment] and lets the test report what
 * Android would, and time is a [FakeTouchClock] the test moves. What this can show is which strokes
 * are asked for, in which order, starting where, and what is answered. What Android then does with
 * them (one contact from DOWN to UP, the ACTION_CANCEL of a mismatched continuation) rests on CTS
 * and on the tablet, not on this file.
 */
class RemoteTouchTest {

    private val landscape = ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1)
    private val portrait = ScreenCaptureGeometry(width = 800, height = 1280, densityDpi = 160, rotation = 0)

    /** What the display reads right now. */
    private var display = landscape

    /** `ViewConfiguration.getLongPressTimeout()`: the hold is this plus 100 ms. */
    private var longPressTimeout = 400L

    private val clock = FakeTouchClock()

    /** Every stroke handed to Android, with its report. */
    private val segments = mutableListOf<TouchSegment>()
    private val reports = mutableListOf<(Boolean) -> Unit>()

    /** What `dispatchGesture` returns. */
    private var accepted = true
    private var throwOnDispatch = false

    private val gestureStrokes = mutableListOf<GestureStroke>()
    private var gestureReport: ((Boolean) -> Unit)? = null
    private val globalActions = mutableListOf<Int>()

    private val ended = mutableListOf<Int>()
    private val logs = mutableListOf<String>()

    private fun dispatcher(supported: Boolean = true) = RemoteGestureDispatcher(
        readDisplay = { display },
        dispatch = { stroke, onResult ->
            gestureStrokes += stroke
            gestureReport = onResult
            true
        },
        performGlobalAction = { action ->
            globalActions += action
            true
        },
        activeWindow = { null },
        longPressTimeoutMs = { longPressTimeout },
        touchPort = RemoteTouchPort(
            continuedStrokesSupported = supported,
            dispatch = { segment, onResult ->
                if (throwOnDispatch) throw IllegalStateException("only strokes marked willContinue")
                segments += segment
                reports += onResult
                accepted
            },
            clock = clock,
        ),
        onTouchEnded = { ended += it },
        log = { logs += it },
    )

    private val subject = dispatcher()

    private val holdAnswers = mutableListOf<RemoteTouchOutcome>()
    private val releaseAnswers = mutableListOf<RemoteTouchOutcome>()
    private val cancelAnswers = mutableListOf<RemoteTouchOutcome>()

    private fun start(x: Double = 0.5, y: Double = 0.5, handle: Int = 1) =
        subject.startTouch(handle, x, y) { holdAnswers += it }

    private fun move(seq: Long, x: Double, y: Double = 0.5, handle: Int = 1) =
        subject.moveTouch(handle, seq, x, y)

    private fun release(seq: Long, x: Double = 0.5, y: Double = 0.5, handle: Int = 1) =
        subject.releaseTouch(handle, seq, x, y) { releaseAnswers += it }

    private fun cancel(handle: Int = 1) = subject.cancelTouch(handle) { cancelAnswers += it }

    /** Android reports the latest stroke. */
    private fun report(completed: Boolean = true) = reports.last()(completed)

    /** Down, reported, and held: the state every drag starts from. */
    private fun held(x: Double = 0.5, y: Double = 0.5) {
        start(x, y)
        report()
        clock.advance(500)
        assertEquals(listOf(RemoteTouchOutcome.HELD), holdAnswers)
    }

    private fun kinds() = segments.map { it.kind }

    private val center = GesturePixel(640, 400)

    // ------------------------------------------------------------ the hold

    @Test
    fun `the first stroke puts the finger down and keeps it there`() {
        start()

        assertEquals(
            listOf(TouchSegment(center, center, 16, TouchSegment.Kind.DOWN)),
            segments,
        )
        assertTrue(TouchSegment.Kind.DOWN.willContinue)
        assertFalse(TouchSegment.Kind.DOWN.continuesPrevious)
        assertTrue(holdAnswers.isEmpty())
    }

    @Test
    fun `the first stroke completing is not the hold, and lifts nothing`() {
        start()
        report()

        assertTrue(holdAnswers.isEmpty())
        assertEquals(1, segments.size)
    }

    @Test
    fun `the hold is a timer of the long-press timeout plus 100 ms, from the first report`() {
        start()
        clock.advance(300)
        report()

        clock.advance(499)
        assertTrue(holdAnswers.isEmpty())

        clock.advance(1)
        assertEquals(listOf(RemoteTouchOutcome.HELD), holdAnswers)
        assertEquals("the finger is still down: nothing lifted it", 1, segments.size)
    }

    @Test
    fun `the hold follows the device's setting, read when the touch starts`() {
        longPressTimeout = 1500
        start()
        report()
        // Keepalives, so the watchdog has no say in this.
        for (seq in 1L..6L) {
            clock.advance(250)
            move(seq, 0.5)
        }
        clock.advance(99)
        assertTrue(holdAnswers.isEmpty())

        clock.advance(1)
        assertEquals(listOf(RemoteTouchOutcome.HELD), holdAnswers)
    }

    @Test
    fun `an unusable long-press timeout is rejected before any stroke`() {
        longPressTimeout = 0
        start()

        assertEquals(listOf(RemoteTouchOutcome.REJECTED), holdAnswers)
        assertTrue(segments.isEmpty())
    }

    @Test
    fun `logs name the touch by its handle and never a position`() {
        held(0.1234, 0.5678)
        move(1, 0.9)
        report()
        release(2, 0.9)
        report()

        assertEquals(
            listOf("touch 1 started", "touch 1 held", "touch 1 moving seq=1", "touch 1 released"),
            logs,
        )
    }

    // ---------------------------------------------------------- moving

    @Test
    fun `a move during the hold only waits`() {
        start()
        report()
        move(1, 0.75)
        move(2, 0.8)

        assertEquals(listOf(TouchSegment.Kind.DOWN), kinds())
    }

    @Test
    fun `once held, the finger goes to the latest position it was given`() {
        start()
        report()
        move(1, 0.75)
        clock.advance(100)
        move(2, 0.8)
        clock.advance(400)

        assertEquals(listOf(TouchSegment.Kind.DOWN, TouchSegment.Kind.MOVE), kinds())
        assertEquals(center, segments[1].from)
        assertEquals(GesturePixel(1024, 400), segments[1].to)
    }

    @Test
    fun `every continuation starts exactly where the last stroke ended`() {
        held()
        listOf(0.51, 0.6, 0.6001, 0.7, 0.2).forEachIndexed { i, x ->
            move(i + 1L, x, 0.3)
            report()
        }

        val moves = segments.drop(1)
        assertEquals(center, moves.first().from)
        moves.zipWithNext().forEach { (before, after) -> assertEquals(before.to, after.from) }
        assertTrue(moves.all { it.kind == TouchSegment.Kind.MOVE && it.kind.continuesPrevious })
    }

    @Test
    fun `a move to the same pixel is a keepalive, and no stroke`() {
        held()
        assertEquals(RemoteTouchOutcome.ACCEPTED, move(1, 0.5))
        assertEquals(RemoteTouchOutcome.ACCEPTED, move(2, 0.5001))

        assertEquals(listOf(TouchSegment.Kind.DOWN), kinds())
    }

    @Test
    fun `moves arriving while a stroke is in flight replace each other`() {
        held()
        move(1, 0.6)
        move(2, 0.7)
        move(3, 0.8)
        move(4, 0.9)

        assertEquals("one stroke in flight, and only one", 2, segments.size)

        report()
        assertEquals(3, segments.size)
        assertEquals(GesturePixel(768, 400), segments[2].from)
        assertEquals(GesturePixel(1152, 400), segments[2].to)

        report()
        assertEquals("nothing older is replayed", 3, segments.size)
    }

    @Test
    fun `a stroke lasts the time between its two positions, from 16 to 100 ms`() {
        held()
        // The reference for the first move is when the touch started, 500 ms ago.
        move(1, 0.6)
        assertEquals(100L, segments.last().durationMs)
        clock.advance(40)
        move(2, 0.7)
        report()
        assertEquals(40L, segments.last().durationMs)
        clock.advance(5)
        move(3, 0.8)
        report()
        assertEquals(16L, segments.last().durationMs)
        // Under the watchdog: 900 ms since the last move.
        clock.advance(900)
        move(4, 0.9)
        report()
        assertEquals(100L, segments.last().durationMs)

        assertEquals(16L, touchSegmentDurationMs(0))
        assertEquals(16L, touchSegmentDurationMs(-50))
        assertEquals(37L, touchSegmentDurationMs(37))
        assertEquals(100L, touchSegmentDurationMs(101))
    }

    // ---------------------------------------------------------- release

    @Test
    fun `a release takes the finger to its position and lifts it there`() {
        held()
        clock.advance(30)
        release(1, 0.75)

        val last = segments.last()
        assertEquals(TouchSegment(center, GesturePixel(960, 400), 100, TouchSegment.Kind.RELEASE), last)
        assertFalse(last.kind.willContinue)
        assertTrue(releaseAnswers.isEmpty())

        report()
        assertEquals(listOf(RemoteTouchOutcome.COMPLETED), releaseAnswers)
        assertFalse(subject.isTouchActive())
        assertEquals(listOf(1), ended)
    }

    @Test
    fun `a release on the spot is one point, for 16 ms, that ends the contact`() {
        held()
        release(1, 0.5)

        assertEquals(TouchSegment(center, center, 16, TouchSegment.Kind.RELEASE), segments.last())
        report()
        assertEquals(listOf(RemoteTouchOutcome.COMPLETED), releaseAnswers)
    }

    @Test
    fun `a release during the hold waits for it, then the hold and the release are both answered`() {
        start()
        report()
        clock.advance(100)
        release(1, 0.5)
        assertEquals(listOf(TouchSegment.Kind.DOWN), kinds())

        clock.advance(400)
        assertEquals(listOf(RemoteTouchOutcome.HELD), holdAnswers)
        assertEquals(listOf(TouchSegment.Kind.DOWN, TouchSegment.Kind.RELEASE), kinds())

        report()
        assertEquals(listOf(RemoteTouchOutcome.COMPLETED), releaseAnswers)
    }

    @Test
    fun `a release waiting on a long hold is not mistaken for silence`() {
        longPressTimeout = 1500
        start()
        report()
        clock.advance(200)
        release(1, 0.5)
        clock.advance(1399)
        assertTrue(holdAnswers.isEmpty())

        clock.advance(1)
        assertEquals(listOf(RemoteTouchOutcome.HELD), holdAnswers)
        report()
        assertEquals(listOf(RemoteTouchOutcome.COMPLETED), releaseAnswers)
    }

    @Test
    fun `a release during a move waits for it, and goes from where it ends`() {
        held()
        move(1, 0.6)
        release(2, 0.9)
        assertEquals(TouchSegment.Kind.MOVE, segments.last().kind)

        report()
        assertEquals(TouchSegment.Kind.RELEASE, segments.last().kind)
        assertEquals(GesturePixel(768, 400), segments.last().from)
        assertEquals(GesturePixel(1152, 400), segments.last().to)
    }

    @Test
    fun `nothing moves after a release, and a second release is ended`() {
        held()
        release(1, 0.5)

        assertEquals(RemoteTouchOutcome.ENDED, move(2, 0.9))
        release(3, 0.9)
        assertEquals(listOf(RemoteTouchOutcome.ENDED), releaseAnswers)
        assertEquals(2, segments.size)
    }

    // -------------------------------------------- Android has its say

    @Test
    fun `Android cancelling the first stroke ends the touch`() {
        start()
        report(completed = false)

        assertEquals(listOf(RemoteTouchOutcome.ENDED), holdAnswers)
        assertFalse(subject.isTouchActive())
        assertEquals(listOf(1), ended)
    }

    @Test
    fun `Android cancelling a move ends the touch, and the next move hears it`() {
        held()
        move(1, 0.8)
        report(completed = false)

        assertFalse(subject.isTouchActive())
        assertEquals(RemoteTouchOutcome.ENDED, move(2, 0.9))
        assertEquals(listOf(1), ended)
    }

    @Test
    fun `Android cancelling the release ends the touch, unreleased`() {
        held()
        release(1, 0.5)
        report(completed = false)

        assertEquals(listOf(RemoteTouchOutcome.ENDED), releaseAnswers)
        assertFalse(subject.isTouchActive())
    }

    @Test
    fun `a first stroke Android refuses is rejected, and leaves nothing behind`() {
        accepted = false
        start()

        assertEquals(listOf(RemoteTouchOutcome.REJECTED), holdAnswers)
        assertFalse(subject.isTouchActive())
        assertTrue("nothing went down, so nobody is told it ended", ended.isEmpty())
    }

    @Test
    fun `a move Android refuses ends the touch, and cancels the finger from where it was`() {
        held()
        accepted = false
        assertEquals(RemoteTouchOutcome.ENDED, move(1, 0.9))

        val cancel = segments.last()
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, cancel.kind)
        // The refused stroke never moved the finger, so the mismatch is beside the center.
        assertEquals(GesturePixel(641, 400), cancel.from)
        assertFalse(subject.isTouchActive())
    }

    @Test
    fun `dispatchGesture throwing ends the touch, not the app`() {
        held()
        throwOnDispatch = true

        assertEquals(RemoteTouchOutcome.ENDED, move(1, 0.9))
        assertFalse(subject.isTouchActive())
    }

    @Test
    fun `a late report about an earlier stroke changes nothing`() {
        held()
        move(1, 0.6)
        val firstMove = reports.last()
        firstMove(true)
        move(2, 0.7)

        firstMove(false)
        assertTrue(subject.isTouchActive())
        report()
        assertTrue(subject.isTouchActive())
    }

    // -------------------------------------------- Android 7.0 and 7.1

    @Test
    fun `below Android 8_0 a touch is unsupported, and nothing at all happens`() {
        val old = dispatcher(supported = false)
        val answers = mutableListOf<RemoteTouchOutcome>()

        old.startTouch(1, 0.5, 0.5) { answers += it }

        assertEquals(listOf(RemoteTouchOutcome.UNSUPPORTED), answers)
        assertTrue(segments.isEmpty())
        assertFalse(old.isTouchActive())
        assertEquals(RemoteTouchOutcome.ENDED, old.moveTouch(1, 1, 0.5, 0.5))
        assertTrue(clock.pending == 0)
    }

    @Test
    fun `with no port a touch is unsupported`() {
        val bare = RemoteGestureDispatcher(
            readDisplay = { display },
            dispatch = { _, _ -> true },
            performGlobalAction = { true },
            activeWindow = { null },
            longPressTimeoutMs = { 400L },
        )
        val answers = mutableListOf<RemoteTouchOutcome>()

        bare.startTouch(1, 0.5, 0.5) { answers += it }

        assertEquals(listOf(RemoteTouchOutcome.UNSUPPORTED), answers)
    }

    @Test
    fun `below Android 8_0 a long press still runs`() {
        val old = dispatcher(supported = false)
        val outcomes = mutableListOf<RemoteGestureOutcome>()

        old.longPress(0.5, 0.5) { outcomes += it }
        gestureReport!!(true)

        assertEquals(listOf(GestureStroke(center, null, 500)), gestureStrokes)
        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
    }

    // ------------------------------------------------------- one at a time

    @Test
    fun `nothing else runs while a touch is down`() {
        held()
        val outcomes = mutableListOf<RemoteGestureOutcome>()

        subject.tap(0.5, 0.5) { outcomes += it }
        subject.longPress(0.5, 0.5) { outcomes += it }
        subject.swipe(0.1, 0.1, 0.9, 0.9, 300) { outcomes += it }
        subject.back { outcomes += it }
        subject.home { outcomes += it }
        subject.recents { outcomes += it }
        subject.setText("x") { outcomes += it }
        subject.imeEnter { outcomes += it }

        assertEquals(List(8) { RemoteGestureOutcome.BUSY }, outcomes)
        assertTrue(gestureStrokes.isEmpty())
        assertTrue(globalActions.isEmpty())
        assertEquals(1, segments.size)
    }

    @Test
    fun `a touch does not start under a running gesture, or another touch`() {
        subject.tap(0.5, 0.5) { }
        start()
        assertEquals(listOf(RemoteTouchOutcome.BUSY), holdAnswers)
        gestureReport!!(true)

        start(handle = 1)
        start(handle = 2)
        assertEquals(RemoteTouchOutcome.BUSY, holdAnswers.last())
        assertEquals(1, segments.size)
    }

    @Test
    fun `once the touch is over the queue's next command runs`() {
        held()
        release(1, 0.5)
        report()
        val outcomes = mutableListOf<RemoteGestureOutcome>()

        subject.home { outcomes += it }

        assertEquals(listOf(AccessibilityService.GLOBAL_ACTION_HOME), globalActions)
        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
    }

    @Test
    fun `a message for another touch cannot move or end this one`() {
        held()

        assertEquals(RemoteTouchOutcome.ENDED, subject.moveTouch(2, 1, 0.9, 0.9))
        subject.releaseTouch(2, 1, 0.9, 0.9) { releaseAnswers += it }
        subject.cancelTouch(2) { cancelAnswers += it }
        subject.abandonTouch(2)

        assertEquals(listOf(RemoteTouchOutcome.ENDED), releaseAnswers)
        assertEquals(listOf(RemoteTouchOutcome.CANCELLED), cancelAnswers)
        assertTrue(subject.isTouchActive())
        assertEquals(1, segments.size)
        assertEquals(RemoteTouchOutcome.ACCEPTED, move(1, 0.6))
    }

    // ------------------------------------------------------------- seq

    @Test
    fun `a seq that is not greater than the last one ends the touch`() {
        held()
        move(5, 0.5)

        assertEquals(RemoteTouchOutcome.ENDED, move(5, 0.6))
        assertFalse(subject.isTouchActive())
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)
    }

    @Test
    fun `a lower seq on a release ends the touch unreleased`() {
        held()
        move(5, 0.5)
        release(4, 0.5)

        assertEquals(listOf(RemoteTouchOutcome.ENDED), releaseAnswers)
        assertTrue(kinds().none { it == TouchSegment.Kind.RELEASE })
    }

    @Test
    fun `gaps in seq are allowed`() {
        held()
        assertEquals(RemoteTouchOutcome.ACCEPTED, move(3, 0.6))
        assertEquals(RemoteTouchOutcome.ACCEPTED, move(90, 0.6))
    }

    // ---------------------------------------------------------- cancel

    @Test
    fun `cancel while held asks for a continuation beside the finger, and no new touch`() {
        held()
        cancel()

        val cancelSegment = segments.last()
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, cancelSegment.kind)
        assertTrue(cancelSegment.kind.continuesPrevious)
        assertFalse(cancelSegment.kind.willContinue)
        assertEquals(cancelSegment.from, cancelSegment.to)
        assertNotEquals(center, cancelSegment.from)
        assertEquals(1, Math.abs(cancelSegment.from.x - center.x) + Math.abs(cancelSegment.from.y - center.y))
        assertEquals("one DOWN, ever", 1, kinds().count { it == TouchSegment.Kind.DOWN })
        assertTrue(kinds().none { it == TouchSegment.Kind.RELEASE })
        assertTrue("answered when Android reports it", cancelAnswers.isEmpty())

        report(completed = false)
        assertEquals(listOf(RemoteTouchOutcome.CANCELLED), cancelAnswers)
        assertFalse(subject.isTouchActive())
        assertEquals(listOf(1), ended)
        assertEquals("touch 1 cancelled reason=cancel", logs.last())
    }

    @Test
    fun `cancel while moving cuts the stroke in flight, from where it was going`() {
        held()
        move(1, 0.75)
        val inFlight = reports.last()
        cancel()

        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)
        assertEquals(GesturePixel(961, 400), segments.last().from)

        inFlight(false)
        assertTrue("the cut stroke's report is not the cancel's", cancelAnswers.isEmpty())
        report(completed = false)
        assertEquals(listOf(RemoteTouchOutcome.CANCELLED), cancelAnswers)
        assertEquals(1, ended.size)
    }

    @Test
    fun `cancel while pressing cancels the finger and ends the hold`() {
        start()
        val down = reports.last()
        cancel()

        assertEquals(listOf(RemoteTouchOutcome.ENDED), holdAnswers)
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)

        down(true)
        clock.advance(1000)
        assertEquals("no hold after a cancel", listOf(RemoteTouchOutcome.ENDED), holdAnswers)
        report(completed = false)
        assertEquals(listOf(RemoteTouchOutcome.CANCELLED), cancelAnswers)
    }

    @Test
    fun `cancel after the first report and before the hold also ends the hold`() {
        start()
        report()
        clock.advance(200)
        cancel()
        clock.advance(1000)

        assertEquals(listOf(RemoteTouchOutcome.ENDED), holdAnswers)
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)
    }

    @Test
    fun `cancel while releasing cannot recall the release, and is answered when it ends`() {
        held()
        release(1, 0.5)
        cancel()

        assertEquals("no mismatch after a final stroke", TouchSegment.Kind.RELEASE, segments.last().kind)
        assertTrue(cancelAnswers.isEmpty())

        report()
        assertEquals(listOf(RemoteTouchOutcome.COMPLETED), releaseAnswers)
        assertEquals(listOf(RemoteTouchOutcome.CANCELLED), cancelAnswers)
        assertFalse(subject.isTouchActive())
    }

    @Test
    fun `cancel answers a waiting release as ended`() {
        start()
        report()
        release(1, 0.5)
        cancel()

        assertEquals(listOf(RemoteTouchOutcome.ENDED), releaseAnswers)
    }

    @Test
    fun `cancel twice is one cancel, and a cancel after the end is still ok`() {
        held()
        cancel()
        cancel()
        assertEquals(1, kinds().count { it == TouchSegment.Kind.CANCEL_VIA_MISMATCH })

        report(completed = false)
        assertEquals(List(2) { RemoteTouchOutcome.CANCELLED }, cancelAnswers)

        cancel()
        assertEquals(List(3) { RemoteTouchOutcome.CANCELLED }, cancelAnswers)
        assertEquals(1, kinds().count { it == TouchSegment.Kind.CANCEL_VIA_MISMATCH })
    }

    @Test
    fun `a cancel Android does not take still ends the touch`() {
        held()
        accepted = false
        cancel()

        assertEquals(listOf(RemoteTouchOutcome.CANCELLED), cancelAnswers)
        assertFalse(subject.isTouchActive())
    }

    @Test
    fun `the cancelling pixel is beside the finger, inside the screen, on every edge`() {
        val screens = listOf(landscape)
        assertEquals(GesturePixel(1, 0), mismatchPixelBeside(GesturePixel(0, 0), screens))
        assertEquals(GesturePixel(1278, 400), mismatchPixelBeside(GesturePixel(1279, 400), screens))
        assertEquals(GesturePixel(641, 0), mismatchPixelBeside(GesturePixel(640, 0), screens))
        assertEquals(GesturePixel(641, 799), mismatchPixelBeside(GesturePixel(640, 799), screens))
        assertEquals(GesturePixel(1278, 799), mismatchPixelBeside(GesturePixel(1279, 799), screens))

        // A screen one pixel wide has no left or right: down, and then up from the bottom.
        val narrow = listOf(ScreenCaptureGeometry(width = 1, height = 800, densityDpi = 160, rotation = 0))
        assertEquals(GesturePixel(0, 1), mismatchPixelBeside(GesturePixel(0, 0), narrow))
        assertEquals(GesturePixel(0, 798), mismatchPixelBeside(GesturePixel(0, 799), narrow))

        // On the screen as it was and as it is: after a rotation, x + 1 may fall off the new one.
        assertEquals(GesturePixel(798, 400), mismatchPixelBeside(GesturePixel(799, 400), listOf(landscape, portrait)))

        assertNull(
            mismatchPixelBeside(
                GesturePixel(0, 0),
                listOf(ScreenCaptureGeometry(width = 1, height = 1, densityDpi = 160, rotation = 0)),
            ),
        )
    }

    @Test
    fun `a finger on the right edge is cancelled from its left`() {
        held(x = 1.0, y = 0.0)
        cancel()

        assertEquals(GesturePixel(1278, 0), segments.last().from)
    }

    @Test
    fun `a finger on the left edge is cancelled from its right`() {
        held(x = 0.0, y = 1.0)
        cancel()

        assertEquals(GesturePixel(1, 799), segments.last().from)
    }

    // ------------------------------------------ watchdog and lifetime

    @Test
    fun `999 ms of silence is fine, 1000 ms is not`() {
        start()
        report()

        clock.advance(999)
        assertTrue(subject.isTouchActive())

        clock.advance(1)
        assertFalse(subject.isTouchActive())
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)
        assertEquals(listOf(1), ended)
        assertEquals("touch 1 cancelled reason=watchdog", logs.last())
    }

    @Test
    fun `the watchdog counts from the latest valid message`() {
        held()
        clock.advance(400)
        move(1, 0.5)
        clock.advance(999)
        assertTrue(subject.isTouchActive())
        clock.advance(1)
        assertFalse(subject.isTouchActive())
    }

    @Test
    fun `a finger held still with keepalives lasts for seconds, and strokes nothing`() {
        held()
        for (seq in 1L..20L) {
            clock.advance(250)
            assertEquals(RemoteTouchOutcome.ACCEPTED, move(seq, 0.5))
        }

        assertTrue(subject.isTouchActive())
        assertEquals(listOf(TouchSegment.Kind.DOWN), kinds())
    }

    @Test
    fun `keepalives cover the hold too, however long it is`() {
        longPressTimeout = 1500
        start()
        report()
        for (seq in 1L..7L) {
            clock.advance(250)
            move(seq, 0.5)
        }

        assertEquals(listOf(RemoteTouchOutcome.HELD), holdAnswers)
        assertTrue(subject.isTouchActive())
    }

    @Test
    fun `no touch outlives 30 seconds, keepalives or not`() {
        start()
        report()
        var seq = 0L
        while (clock.time < 29_750) {
            clock.advance(250)
            move(++seq, 0.5)
        }
        clock.advance(249)
        assertEquals(29_999L, clock.time)
        assertTrue(subject.isTouchActive())

        clock.advance(1)
        assertFalse(subject.isTouchActive())
        assertEquals("touch 1 cancelled reason=lifetime", logs.last())
        assertEquals(RemoteTouchOutcome.ENDED, move(++seq, 0.5))
    }

    @Test
    fun `the timers of an ended touch never reach the next one`() {
        held()
        release(1, 0.5)
        report()
        start(handle = 2)
        report()

        clock.advance(500)
        assertTrue(subject.isTouchActive())
        assertEquals(listOf(1), ended)
    }

    // ------------------------------------------------------ the display

    @Test
    fun `a rotation ends the touch at the next message`() {
        held()
        display = portrait

        assertEquals(RemoteTouchOutcome.ENDED, move(1, 0.5))
        assertFalse(subject.isTouchActive())
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)
        assertEquals("touch 1 cancelled reason=geometry", logs.last())
    }

    @Test
    fun `a change of size ends the touch, even at a release`() {
        held()
        display = landscape.copy(width = 1920)
        release(1, 0.5)

        assertEquals(listOf(RemoteTouchOutcome.ENDED), releaseAnswers)
        assertTrue(kinds().none { it == TouchSegment.Kind.RELEASE })
    }

    @Test
    fun `a change of rotation alone ends the touch`() {
        held()
        display = landscape.copy(rotation = 3)

        assertEquals(RemoteTouchOutcome.ENDED, move(1, 0.5))
    }

    @Test
    fun `a change during the hold ends it unheld`() {
        start()
        report()
        display = portrait
        clock.advance(500)

        assertEquals(listOf(RemoteTouchOutcome.ENDED), holdAnswers)
        assertFalse(subject.isTouchActive())
    }

    @Test
    fun `a display that cannot be read is a change`() {
        var broken = false
        val blind = RemoteGestureDispatcher(
            readDisplay = { if (broken) throw IllegalStateException("no display") else landscape },
            dispatch = { _, _ -> true },
            performGlobalAction = { true },
            activeWindow = { null },
            longPressTimeoutMs = { 400L },
            touchPort = RemoteTouchPort(true, { segment, onResult ->
                segments += segment
                reports += onResult
                true
            }, clock),
        )
        blind.startTouch(1, 0.5, 0.5) { holdAnswers += it }
        report()
        clock.advance(500)
        broken = true

        assertEquals(RemoteTouchOutcome.ENDED, blind.moveTouch(1, 1, 0.6, 0.5))
    }

    @Test
    fun `the same display goes on`() {
        held()
        display = landscape.copy()

        assertEquals(RemoteTouchOutcome.ACCEPTED, move(1, 0.6))
        assertTrue(subject.isTouchActive())
    }

    // ----------------------------------------------------------- abandon

    @Test
    fun `abandon ends the touch at once and cancels the finger without waiting`() {
        held()
        move(1, 0.6)
        subject.abandonTouch(1)

        assertFalse(subject.isTouchActive())
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)
        assertEquals("touch 1 cancelled reason=abandoned", logs.last())

        // Its reports come afterwards, to nobody.
        reports.forEach { it(false) }
        assertEquals(listOf(1), ended)
    }

    @Test
    fun `abandon answers everything still owed`() {
        start()
        report()
        release(1, 0.5)
        subject.abandonTouch(1)

        assertEquals(listOf(RemoteTouchOutcome.ENDED), holdAnswers)
        assertEquals(listOf(RemoteTouchOutcome.ENDED), releaseAnswers)
    }

    @Test
    fun `abandon during a release does not ask for a mismatch nothing can continue`() {
        held()
        release(1, 0.5)
        subject.abandonTouch(1)

        assertEquals(TouchSegment.Kind.RELEASE, segments.last().kind)
        assertFalse(subject.isTouchActive())
    }

    @Test
    fun `the service going away ends the touch too`() {
        held()
        subject.abandon()

        assertFalse(subject.isTouchActive())
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)
    }

    @Test
    fun `a new service connection abandons the previous one's touch`() {
        val availability = RemoteControlAvailability()
        val first = dispatcher()
        availability.connected(first)
        availability.startTouch(7, 0.5, 0.5) { }

        availability.connected(dispatcher())

        assertFalse(first.isTouchActive())
    }

    @Test
    fun `with no service a touch is unavailable, and abandoning it is harmless`() {
        val availability = RemoteControlAvailability()
        val answers = mutableListOf<RemoteTouchOutcome>()

        availability.startTouch(1, 0.5, 0.5) { answers += it }
        availability.releaseTouch(1, 1, 0.5, 0.5) { answers += it }
        availability.cancelTouch(1) { answers += it }
        answers += availability.moveTouch(1, 1, 0.5, 0.5)
        availability.abandonTouch(1)

        assertEquals(List(4) { RemoteTouchOutcome.UNAVAILABLE }, answers)
    }

    // ---------------------------------------------------------- privacy

    @Test
    fun `a touch reads nothing but positions, times and the display`() {
        val touch = code("src/main/kotlin/com/example/remote_control_device/RemoteTouch.kt")
        for (excluded in listOf(
            "AccessibilityNodeInfo",
            "rootInActiveWindow",
            "RootInActiveWindow",
            "findFocus",
            "performAction",
            "ClipboardManager",
            "KeyEvent",
            "Instrumentation",
            "InputManager",
            "Runtime",
            "ProcessBuilder",
            "Thread.sleep",
        )) {
            assertFalse(excluded, touch.contains(excluded))
        }
    }

    @Test
    fun `on Android the strokes are continued strokes, behind an API 26 guard`() {
        val service = code("src/main/kotlin/com/example/remote_control_device/RemoteControlAccessibilityService.kt")

        assertTrue(service.contains("continuedStrokesSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O"))
        assertTrue(service.contains("if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false"))
        assertTrue(service.contains("@RequiresApi(Build.VERSION_CODES.O)"))
        assertTrue(service.contains("previous.continueStroke(path, 0L, segment.durationMs, segment.kind.willContinue)"))
        assertTrue(
            service.contains(
                "GestureDescription.StrokeDescription(path, 0L, segment.durationMs, segment.kind.willContinue)",
            ),
        )
    }

    /** A Kotlin source without its comments, which may name what the code must not touch. */
    private fun code(path: String): String =
        java.io.File(path).readText()
            .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), "")
            .replace(Regex("""//[^\n]*"""), "")

    private fun RemoteGestureDispatcher.isTouchActive(): Boolean {
        // A touch is active exactly when a tap would be refused as busy with nothing else running.
        val outcomes = mutableListOf<RemoteGestureOutcome>()
        val before = globalActions.size
        back { outcomes += it }
        if (globalActions.size > before) globalActions.removeAt(globalActions.lastIndex)
        return outcomes.single() == RemoteGestureOutcome.BUSY
    }
}

/** Time that moves only when the test says so, running what falls due in order. */
class FakeTouchClock : TouchClock {
    var time = 0L
        private set

    private class Task(val due: Long, val order: Int, val action: () -> Unit) {
        var cancelled = false
    }

    private val tasks = mutableListOf<Task>()
    private var scheduled = 0

    /** Tasks still to run. */
    val pending: Int get() = tasks.count { !it.cancelled }

    override fun now(): Long = time

    override fun schedule(delayMs: Long, action: () -> Unit): () -> Unit {
        val task = Task(time + delayMs, scheduled++, action)
        tasks += task
        return { task.cancelled = true }
    }

    fun advance(ms: Long) {
        val end = time + ms
        while (true) {
            val next = tasks
                .filter { !it.cancelled && it.due <= end }
                .minWithOrNull(compareBy<Task>({ it.due }, { it.order }))
                ?: break
            tasks.remove(next)
            time = next.due
            next.action()
        }
        time = end
        tasks.removeAll { it.cancelled }
    }
}
