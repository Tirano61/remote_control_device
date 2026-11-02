package com.example.remote_control_device

import android.content.ContextWrapper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Android half of the bridge. The method and argument names are the contract with
 * `MethodChannelRemoteControlAccessibilityClient`, so they are spelled out here too: a typo on
 * either side would otherwise only show up as a refused gesture on a tablet.
 */
class RemoteControlAccessibilityChannelTest {

    private val strokes = mutableListOf<GestureStroke>()
    private var report: ((Boolean) -> Unit)? = null

    private val availability = RemoteControlAvailability()
    private val channel = RemoteControlAccessibilityChannel(ContextWrapper(null), availability)

    private val answers = mutableListOf<Any?>()
    private var notImplemented = false
    private val result = object : MethodChannel.Result {
        override fun success(result: Any?) {
            answers += result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            throw AssertionError("gestures are answered as outcomes, not errors: $errorCode")
        }

        override fun notImplemented() {
            notImplemented = true
        }
    }

    private fun connect() = availability.connected(
        RemoteGestureDispatcher(
            readDisplay = { ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1) },
            dispatch = { stroke, onResult ->
                strokes += stroke
                report = onResult
                true
            },
        ),
    )

    private fun swipeArguments(): MutableMap<String, Any?> = mutableMapOf(
        "startX" to 0.5,
        "startY" to 0.75,
        "endX" to 0.5,
        "endY" to 0.25,
        "durationMs" to 350,
    )

    private fun call(method: String, arguments: Map<String, Any?>) =
        channel.onMethodCall(MethodCall(method, arguments), result)

    @Test
    fun `performSwipe reaches the gesture with its arguments`() {
        connect()

        call("performSwipe", swipeArguments())

        assertEquals(
            listOf(GestureStroke(GesturePixel(640, 600), GesturePixel(640, 200), 350L)),
            strokes,
        )
    }

    @Test
    fun `performSwipe is answered when Android says, not before`() {
        connect()

        call("performSwipe", swipeArguments())
        assertTrue(answers.isEmpty())

        report!!(true)
        assertEquals(listOf<Any?>("completed"), answers)
    }

    @Test
    fun `a cancelled swipe answers cancelled`() {
        connect()

        call("performSwipe", swipeArguments())
        report!!(false)

        assertEquals(listOf<Any?>("cancelled"), answers)
    }

    @Test
    fun `a swipe while another runs answers busy`() {
        connect()

        call("performSwipe", swipeArguments())
        call("performSwipe", swipeArguments())

        assertEquals(listOf<Any?>("busy"), answers)
        assertEquals(1, strokes.size)
    }

    @Test
    fun `a swipe with no service answers unavailable`() {
        call("performSwipe", swipeArguments())

        assertEquals(listOf<Any?>("unavailable"), answers)
    }

    @Test
    fun `a missing argument answers invalid, and no gesture`() {
        connect()

        for (name in listOf("startX", "startY", "endX", "endY", "durationMs")) {
            call("performSwipe", swipeArguments().apply { remove(name) })
        }

        assertEquals(List<Any?>(5) { "invalid" }, answers)
        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `performTap still goes through as it did`() {
        connect()

        call("performTap", mapOf("x" to 0.5, "y" to 0.25))

        assertEquals(listOf(GestureStroke(GesturePixel(640, 200), null, 50L)), strokes)
        report!!(true)
        assertEquals(listOf<Any?>("completed"), answers)
    }

    @Test
    fun `a method it does not know is not implemented`() {
        call("performPinch", emptyMap())

        assertTrue(notImplemented)
    }
}
