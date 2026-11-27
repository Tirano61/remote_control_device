package com.example.remote_control_device

import android.content.ContextWrapper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The remote touch methods of the bridge. Their names and arguments are the contract with
 * `MethodChannelRemoteControlAccessibilityClient`, so they are spelled out here, as in
 * [RemoteControlAccessibilityChannelTest].
 */
class RemoteTouchChannelTest {

    private val clock = FakeTouchClock()
    private val segments = mutableListOf<TouchSegment>()
    private val reports = mutableListOf<(Boolean) -> Unit>()
    private val ended = mutableListOf<Int>()

    private val availability = RemoteControlAvailability()
    private val channel = RemoteControlAccessibilityChannel(ContextWrapper(null), availability)

    private val answers = mutableListOf<Any?>()
    private val result = object : MethodChannel.Result {
        override fun success(result: Any?) {
            answers += result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            throw AssertionError("touches are answered as outcomes, not errors: $errorCode")
        }

        override fun notImplemented() {
            throw AssertionError("not implemented")
        }
    }

    private fun connect(supported: Boolean = true) {
        availability.onTouchEnded = { ended += it }
        availability.connected(
            RemoteGestureDispatcher(
                readDisplay = { ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1) },
                dispatch = { _, _ -> true },
                performGlobalAction = { true },
                activeWindow = { null },
                longPressTimeoutMs = { 400L },
                touchPort = RemoteTouchPort(
                    continuedStrokesSupported = supported,
                    dispatch = { segment, onResult ->
                        segments += segment
                        reports += onResult
                        true
                    },
                    clock = clock,
                ),
                onTouchEnded = availability::touchEnded,
            ),
        )
    }

    private fun call(method: String, arguments: Map<String, Any?>? = null) =
        channel.onMethodCall(MethodCall(method, withGrant(arguments)), result)

    /**
     * Every call here is made under an open grant, as Dart makes them; what the gate does with a
     * missing or a closed one has its own tests, in [RemoteControlGateTest].
     */
    private fun withGrant(arguments: Map<String, Any?>?): Map<String, Any?> =
        if (arguments?.containsKey("grant") == true) arguments else (arguments ?: emptyMap()) + ("grant" to OPEN_GRANT)

    init {
        availability.openControl(OPEN_GRANT.toLong(), "session-under-test")
    }

    private companion object {
        const val OPEN_GRANT = 1
    }

    private fun hold(touch: Any? = 3, x: Any? = 0.5, y: Any? = 0.5) =
        call("startRemoteTouch", mapOf("touch" to touch, "x" to x, "y" to y))

    private fun heldTouch() {
        hold()
        reports.last()(true)
        clock.advance(500)
    }

    @Test
    fun `a hold is answered once it is over`() {
        connect()
        hold()
        reports.last()(true)
        assertTrue(answers.isEmpty())

        clock.advance(500)
        assertEquals(listOf("held"), answers)
    }

    @Test
    fun `a move is answered at once, before any stroke completes`() {
        connect()
        heldTouch()
        answers.clear()

        call("moveRemoteTouch", mapOf("touch" to 3, "seq" to 1, "x" to 0.75, "y" to 0.5))

        assertEquals(listOf("accepted"), answers)
        assertEquals(TouchSegment.Kind.MOVE, segments.last().kind)
    }

    @Test
    fun `seq may arrive as a 64-bit integer, never as a double`() {
        connect()
        heldTouch()
        answers.clear()

        call("moveRemoteTouch", mapOf("touch" to 3, "seq" to 4_000_000_000L, "x" to 0.5, "y" to 0.5))
        call("moveRemoteTouch", mapOf("touch" to 3, "seq" to 4_000_000_001.0, "x" to 0.5, "y" to 0.5))

        assertEquals(listOf("accepted", "invalid"), answers)
    }

    @Test
    fun `a release is answered when its stroke completes`() {
        connect()
        heldTouch()
        answers.clear()

        call("releaseRemoteTouch", mapOf("touch" to 3, "seq" to 1, "x" to 0.5, "y" to 0.5))
        assertTrue(answers.isEmpty())

        reports.last()(true)
        assertEquals(listOf("completed"), answers)
        assertEquals(listOf(3), ended)
    }

    @Test
    fun `a cancel is answered when Android reports it`() {
        connect()
        heldTouch()
        answers.clear()

        call("cancelRemoteTouch", mapOf("touch" to 3, "seq" to 1))
        assertEquals(TouchSegment.Kind.CANCEL_VIA_MISMATCH, segments.last().kind)
        assertTrue(answers.isEmpty())

        reports.last()(false)
        assertEquals(listOf("cancelled"), answers)
    }

    @Test
    fun `abandon answers at once and the touch is gone`() {
        connect()
        heldTouch()
        answers.clear()

        call("abandonRemoteTouch", mapOf("touch" to 3))

        assertEquals(listOf(null), answers)
        assertEquals(listOf(3), ended)
        call("moveRemoteTouch", mapOf("touch" to 3, "seq" to 1, "x" to 0.5, "y" to 0.5))
        assertEquals("ended", answers.last())
    }

    @Test
    fun `arguments that are missing or of the wrong type are invalid, and start nothing`() {
        connect()

        hold(touch = null)
        hold(touch = "3")
        hold(x = null)
        hold(y = 1)
        call("moveRemoteTouch", mapOf("touch" to 3, "x" to 0.5, "y" to 0.5))
        call("releaseRemoteTouch", mapOf("touch" to 3, "seq" to 1, "x" to 0.5))
        call("cancelRemoteTouch", mapOf("seq" to 1))

        assertEquals(List(7) { "invalid" }, answers)
        assertTrue(segments.isEmpty())
    }

    @Test
    fun `below Android 8_0 the hold is unsupported`() {
        connect(supported = false)
        hold()

        assertEquals(listOf("unsupported"), answers)
        assertTrue(segments.isEmpty())
    }

    @Test
    fun `with no service every touch method is unavailable`() {
        hold()
        call("moveRemoteTouch", mapOf("touch" to 3, "seq" to 1, "x" to 0.5, "y" to 0.5))
        call("releaseRemoteTouch", mapOf("touch" to 3, "seq" to 1, "x" to 0.5, "y" to 0.5))
        call("cancelRemoteTouch", mapOf("touch" to 3, "seq" to 1))
        call("abandonRemoteTouch", mapOf("touch" to 3))

        assertEquals(listOf("unavailable", "unavailable", "unavailable", "unavailable", null), answers)
    }

    @Test
    fun `the names are the contract`() {
        assertEquals("startRemoteTouch", RemoteControlAccessibilityChannel.START_TOUCH_METHOD)
        assertEquals("moveRemoteTouch", RemoteControlAccessibilityChannel.MOVE_TOUCH_METHOD)
        assertEquals("releaseRemoteTouch", RemoteControlAccessibilityChannel.RELEASE_TOUCH_METHOD)
        assertEquals("cancelRemoteTouch", RemoteControlAccessibilityChannel.CANCEL_TOUCH_METHOD)
        assertEquals("abandonRemoteTouch", RemoteControlAccessibilityChannel.ABANDON_TOUCH_METHOD)
        assertEquals("remoteTouchEnded", RemoteControlAccessibilityChannel.TOUCH_ENDED_METHOD)
    }
}
