package com.example.remote_control_device

import android.content.ContextWrapper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A2 of the Prompt 44 audit, on the Android side: the authority Dart withdraws must stop what is
 * running, and nothing that was running may be reported as done afterwards.
 *
 * `dispatchGesture` and the cancellation Android offers ([RemoteGestureDispatcher]'s
 * `cancelGesture`) are fakes the test answers when Android would; what Android itself does with
 * the cancelling gesture is read from its source and checked on the tablet, not here.
 */
class RemoteControlGateTest {

    // ------------------------------------------------------------- fakes

    private val display = ScreenCaptureGeometry(width = 1200, height = 1920, densityDpi = 248, rotation = 0)

    private val strokes = mutableListOf<GestureStroke>()

    /** The report of every gesture Android accepted, in order. */
    private val reports = mutableListOf<(Boolean) -> Unit>()

    /** How many times Android was asked to cancel the gesture it plays. */
    private var cancelsRequested = 0

    /** What asking for the cancellation answers; `null` stands for Android below 8.0. */
    private var cancelAvailable: Boolean? = true

    private val globalActions = mutableListOf<Int>()
    private val segments = mutableListOf<TouchSegment>()
    private val touchReports = mutableListOf<(Boolean) -> Unit>()
    private val logs = mutableListOf<String>()
    private val clock = FakeTouchClock()

    private val outcomes = mutableListOf<RemoteGestureOutcome>()

    private fun dispatcher() = RemoteGestureDispatcher(
        readDisplay = { display },
        dispatch = { stroke, onResult ->
            strokes += stroke
            reports += onResult
            true
        },
        performGlobalAction = { action ->
            globalActions += action
            true
        },
        activeWindow = { null },
        longPressTimeoutMs = { 500L },
        touchPort = RemoteTouchPort(
            continuedStrokesSupported = true,
            dispatch = { segment, onResult ->
                segments += segment
                touchReports += onResult
                true
            },
            clock = clock,
        ),
        log = { logs += it },
        cancelGesture = cancelAvailable?.let { available ->
            { _: (Boolean) -> Unit ->
                cancelsRequested++
                available
            }
        },
    )

    private val availability = RemoteControlAvailability()

    private fun connect() = availability.connected(dispatcher())

    private fun swipe(durationMs: Long = 2000L) =
        availability.swipe(0.5, 0.8, 0.5, 0.2, durationMs) { outcomes += it }

    // -------------------------------------------------------------- the gate

    @Test
    fun `a closed gate admits nothing, and a missing grant is never admitted`() {
        val gate = RemoteControlGate()

        assertFalse(gate.admits(1L))
        assertFalse(gate.admits(null))
        gate.open(1L, "s1")
        assertFalse(gate.admits(null))
    }

    @Test
    fun `an open gate admits its own grant and no other`() {
        val gate = RemoteControlGate()
        assertEquals(RemoteControlOpenOutcome.OPENED, gate.open(3L, "s1"))

        assertTrue(gate.admits(3L))
        assertFalse(gate.admits(2L))
        assertFalse(gate.admits(4L))
    }

    @Test
    fun `a grant is never reused, nor an older one opened`() {
        val gate = RemoteControlGate()
        gate.open(3L, "s1")
        gate.close()

        assertEquals(RemoteControlOpenOutcome.STALE, gate.open(3L, "s1"))
        assertEquals(RemoteControlOpenOutcome.STALE, gate.open(2L, "s1"))
        assertFalse(gate.isOpen)
        assertEquals(RemoteControlOpenOutcome.OPENED, gate.open(4L, "s1"))
    }

    @Test
    fun `a session reported ended is never opened again, under any grant`() {
        val gate = RemoteControlGate()
        gate.open(1L, "s1")
        gate.close(endedSession = "s1")

        assertEquals(RemoteControlOpenOutcome.ENDED, gate.open(2L, "s1"))
        assertEquals(RemoteControlOpenOutcome.ENDED, gate.open(99L, "s1"))
        assertFalse(gate.isOpen)
    }

    @Test
    fun `a new session after an ended one opens normally`() {
        val gate = RemoteControlGate()
        gate.open(1L, "s1")
        gate.close(endedSession = "s1")

        assertEquals(RemoteControlOpenOutcome.OPENED, gate.open(2L, "s2"))
        assertTrue(gate.admits(2L))
    }

    @Test
    fun `a new engine numbers its grants again, and ended sessions stay ended`() {
        val gate = RemoteControlGate()
        gate.open(5L, "s1")
        gate.close(endedSession = "s1")
        gate.open(6L, "s2")

        assertEquals(6L, gate.reset())
        assertFalse(gate.isOpen)
        assertEquals(RemoteControlOpenOutcome.OPENED, gate.open(1L, "s2"))
        assertEquals(RemoteControlOpenOutcome.ENDED, gate.open(2L, "s1"))
    }

    @Test
    fun `closing is idempotent and answers the grant that was open`() {
        val gate = RemoteControlGate()
        gate.open(7L, "s1")

        assertEquals(7L, gate.close())
        assertNull(gate.close())
        assertNull(gate.close(endedSession = "s1"))
        assertTrue(gate.hasEnded("s1"))
    }

    // ------------------------------------------------- revoking a running gesture

    @Test
    fun `A2 - a swipe revoked while Android plays it is answered revoked at once and cancelled`() {
        connect()
        availability.openControl(1L, "s1")
        swipe()
        assertEquals(1, strokes.size)
        assertTrue(outcomes.isEmpty())

        val revocation = availability.closeControl()

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertEquals(1, cancelsRequested)
        assertEquals(RemoteControlRevocation(gestureRunning = true, cancelRequested = true, touchAbandoned = false), revocation)
    }

    @Test
    fun `A2 - Android cancelling the revoked swipe answers nothing more`() {
        connect()
        availability.openControl(1L, "s1")
        swipe()
        availability.closeControl()

        reports.single()(false)

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertTrue(logs.last(), logs.last().contains("Android cancelled it"))
    }

    @Test
    fun `A2 - a swipe Android completes after the revocation is never reported completed`() {
        connect()
        availability.openControl(1L, "s1")
        swipe()
        availability.closeControl()

        // The race: Android had already played the last event when the cancellation reached it.
        reports.single()(true)

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertTrue(logs.last(), logs.last().contains("completed it anyway"))
    }

    @Test
    fun `a long press revoked while held is answered revoked and cancelled`() {
        connect()
        availability.openControl(1L, "s1")
        availability.longPress(0.5, 0.5) { outcomes += it }
        assertEquals(600L, strokes.single().durationMs)

        availability.closeControl()
        reports.single()(true)

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertEquals(1, cancelsRequested)
    }

    @Test
    fun `a tap still being played is revoked like any gesture`() {
        connect()
        availability.openControl(1L, "s1")
        availability.tap(0.5, 0.5) { outcomes += it }

        availability.closeControl()
        reports.single()(true)

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
    }

    @Test
    fun `a gesture that completed before the revocation stays completed, and nothing is cancelled`() {
        connect()
        availability.openControl(1L, "s1")
        swipe()
        reports.single()(true)

        val revocation = availability.closeControl()

        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
        assertEquals(0, cancelsRequested)
        assertEquals(RemoteControlRevocation(gestureRunning = false, cancelRequested = false, touchAbandoned = false), revocation)
    }

    @Test
    fun `below Android 8 the revoked gesture plays out, still answered revoked`() {
        cancelAvailable = null
        connect()
        availability.openControl(1L, "s1")
        swipe()

        val revocation = availability.closeControl()
        reports.single()(true)

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertFalse(revocation!!.cancelRequested)
        assertTrue(logs.any { it.contains("cannot cancel it here") })
    }

    @Test
    fun `Android refusing the cancellation still answers revoked`() {
        cancelAvailable = false
        connect()
        availability.openControl(1L, "s1")
        swipe()

        val revocation = availability.closeControl()

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertFalse(revocation!!.cancelRequested)
    }

    @Test
    fun `a cancellation that throws is not a crash`() {
        val throwing = RemoteGestureDispatcher(
            readDisplay = { display },
            dispatch = { _, onResult ->
                reports += onResult
                true
            },
            performGlobalAction = { true },
            activeWindow = { null },
            longPressTimeoutMs = { 500L },
            cancelGesture = { throw IllegalStateException("service gone") },
        )
        availability.connected(throwing)
        availability.openControl(1L, "s1")
        swipe()

        val revocation = availability.closeControl()

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertFalse(revocation!!.cancelRequested)
    }

    @Test
    fun `nothing new starts on top of a revoked stroke Android has not reported yet`() {
        connect()
        availability.openControl(1L, "s1")
        swipe()
        availability.closeControl()
        availability.openControl(2L, "s1")

        availability.tap(0.5, 0.5) { outcomes += it }
        assertEquals(listOf(RemoteGestureOutcome.REVOKED, RemoteGestureOutcome.BUSY), outcomes)
        assertEquals(1, strokes.size)

        reports.single()(false)
        availability.tap(0.5, 0.5) { outcomes += it }
        assertEquals(2, strokes.size)
    }

    @Test
    fun `revoking twice cancels once and answers once`() {
        connect()
        availability.openControl(1L, "s1")
        swipe()

        availability.closeControl()
        assertNull(availability.closeControl())

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertEquals(1, cancelsRequested)
    }

    @Test
    fun `opening a new grant revokes what the old one left running`() {
        connect()
        availability.openControl(1L, "s1")
        swipe()

        assertEquals(RemoteControlOpenOutcome.OPENED, availability.openControl(2L, "s1"))

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertEquals(1, cancelsRequested)
    }

    @Test
    fun `a global action is not revoked after the fact, Android has already acted on it`() {
        connect()
        availability.openControl(1L, "s1")
        availability.back { outcomes += it }

        val revocation = availability.closeControl()

        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
        assertEquals(1, globalActions.size)
        assertEquals(0, cancelsRequested)
        assertFalse(revocation!!.gestureRunning)
    }

    @Test
    fun `a remote touch held down is let go, never released, when the gate closes`() {
        val touchOutcomes = mutableListOf<RemoteTouchOutcome>()
        val ended = mutableListOf<Int>()
        availability.onTouchEnded = { ended += it }
        availability.connected(
            RemoteGestureDispatcher(
                readDisplay = { display },
                dispatch = { _, _ -> true },
                performGlobalAction = { true },
                activeWindow = { null },
                longPressTimeoutMs = { 400L },
                touchPort = RemoteTouchPort(
                    continuedStrokesSupported = true,
                    dispatch = { segment, onResult ->
                        segments += segment
                        touchReports += onResult
                        true
                    },
                    clock = clock,
                ),
                onTouchEnded = availability::touchEnded,
                log = { logs += it },
                cancelGesture = { _ -> cancelsRequested++; true },
            ),
        )
        availability.openControl(1L, "s1")
        availability.startTouch(7, 0.5, 0.5) { touchOutcomes += it }
        touchReports.last()(true)
        clock.advance(500L)
        assertEquals(listOf(RemoteTouchOutcome.HELD), touchOutcomes)

        val revocation = availability.closeControl()

        assertTrue(revocation!!.touchAbandoned)
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)
        assertTrue(segments.none { it.kind == TouchSegment.Kind.RELEASE })
        assertEquals(listOf(7), ended)
        assertTrue(logs.any { it.contains("touch 7 cancelled reason=revoked") })
        // The touch is cancelled its own way; the one-shot cancellation is for one-shot gestures.
        assertEquals(0, cancelsRequested)
    }

    @Test
    fun `with no service connected the gate still closes`() {
        availability.openControl(1L, "s1")

        val revocation = availability.closeControl()

        assertEquals(RemoteControlRevocation(gestureRunning = false, cancelRequested = false, touchAbandoned = false), revocation)
        assertFalse(availability.gate.isOpen)
    }

    @Test
    fun `the service going away with a revoked gesture in flight answers nothing more`() {
        connect()
        availability.openControl(1L, "s1")
        swipe()
        availability.closeControl()

        availability.disconnected()

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
    }

    @Test
    fun `a new engine closes what the old one opened, and revokes it`() {
        connect()
        availability.openControl(4L, "s1")
        swipe()

        availability.resetControl()

        assertEquals(listOf(RemoteGestureOutcome.REVOKED), outcomes)
        assertFalse(availability.gate.isOpen)
        assertEquals(RemoteControlOpenOutcome.OPENED, availability.openControl(1L, "s1"))
    }

    // ------------------------------------------------------------ the channel

    private val channel = RemoteControlAccessibilityChannel(ContextWrapper(null), availability)
    private val answers = mutableListOf<Any?>()
    private val result = object : MethodChannel.Result {
        override fun success(result: Any?) {
            answers += result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            throw AssertionError("answered as outcomes, not errors: $errorCode")
        }

        override fun notImplemented() {
            throw AssertionError("not implemented")
        }
    }

    private fun call(method: String, arguments: Map<String, Any?>? = null) =
        channel.onMethodCall(MethodCall(method, arguments), result)

    private val tapAt = mapOf("x" to 0.5, "y" to 0.5)

    @Test
    fun `openRemoteControl opens a numbered grant for a session`() {
        call("openRemoteControl", mapOf("grant" to 1, "session" to "s1"))

        assertEquals(listOf<Any?>("opened"), answers)
        assertTrue(availability.admits(1L))
    }

    @Test
    fun `a command with no grant is refused before it reaches the service`() {
        connect()
        call("openRemoteControl", mapOf("grant" to 1, "session" to "s1"))

        call("performTap", tapAt)

        assertEquals(listOf<Any?>("opened", "revoked"), answers)
        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `a command under the open grant runs`() {
        connect()
        call("openRemoteControl", mapOf("grant" to 1, "session" to "s1"))

        call("performTap", tapAt + ("grant" to 1))
        reports.single()(true)

        assertEquals(listOf<Any?>("opened", "completed"), answers)
    }

    @Test
    fun `a command that reaches Android after the close is refused, whatever it carries`() {
        connect()
        call("openRemoteControl", mapOf("grant" to 1, "session" to "s1"))
        call("closeRemoteControl", emptyMap())

        call("performTap", tapAt + ("grant" to 1))
        call("performSwipe", mapOf("startX" to 0.5, "startY" to 0.8, "endX" to 0.5, "endY" to 0.2, "durationMs" to 300, "grant" to 1))
        call("performBack", mapOf("grant" to 1))
        call("performSetText", mapOf("text" to "secret", "grant" to 1))
        call("performImeEnter", mapOf("grant" to 1))
        call("startRemoteTouch", mapOf("touch" to 1, "x" to 0.5, "y" to 0.5, "grant" to 1))
        call("moveRemoteTouch", mapOf("touch" to 1, "seq" to 1, "x" to 0.5, "y" to 0.5, "grant" to 1))

        assertEquals(listOf<Any?>("opened", null) + List(7) { "revoked" }, answers)
        assertTrue(strokes.isEmpty())
        assertTrue(globalActions.isEmpty())
        assertTrue(segments.isEmpty())
    }

    @Test
    fun `a command of an older grant does not run under a newer one`() {
        connect()
        call("openRemoteControl", mapOf("grant" to 1, "session" to "s1"))
        call("closeRemoteControl", emptyMap())
        call("openRemoteControl", mapOf("grant" to 2, "session" to "s2"))

        call("performTap", tapAt + ("grant" to 1))

        assertEquals("revoked", answers.last())
        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `closeRemoteControl revokes the running swipe, and its late report is not a success`() {
        connect()
        call("openRemoteControl", mapOf("grant" to 1, "session" to "s1"))
        call("performSwipe", mapOf("startX" to 0.5, "startY" to 0.8, "endX" to 0.5, "endY" to 0.2, "durationMs" to 2000, "grant" to 1))

        call("closeRemoteControl", emptyMap())
        reports.single()(true)

        assertEquals(listOf<Any?>("opened", "revoked", null), answers)
        assertEquals(1, cancelsRequested)
    }

    @Test
    fun `a session closed as ended cannot be opened again`() {
        call("openRemoteControl", mapOf("grant" to 1, "session" to "s1"))
        call("closeRemoteControl", mapOf("ended" to "s1"))

        call("openRemoteControl", mapOf("grant" to 2, "session" to "s1"))

        assertEquals(listOf<Any?>("opened", null, "ended"), answers)
        assertFalse(availability.gate.isOpen)
    }

    @Test
    fun `an opening with a missing argument opens nothing`() {
        call("openRemoteControl", mapOf("grant" to 1))
        call("openRemoteControl", mapOf("session" to "s1"))

        assertEquals(listOf<Any?>("stale", "stale"), answers)
        assertFalse(availability.gate.isOpen)
    }

    @Test
    fun `cancelling or abandoning a touch needs no grant, withdrawing never does`() {
        call("cancelRemoteTouch", mapOf("touch" to 1))
        call("abandonRemoteTouch", mapOf("touch" to 1))

        assertEquals(listOf<Any?>("unavailable", null), answers)
    }

    @Test
    fun `asking whether the service is available needs no grant`() {
        connect()

        call("isAccessibilityServiceAvailable")

        assertEquals(listOf<Any?>(true), answers)
    }
}
