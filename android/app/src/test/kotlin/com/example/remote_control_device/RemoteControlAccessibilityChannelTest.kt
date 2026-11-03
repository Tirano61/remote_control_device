package com.example.remote_control_device

import android.accessibilityservice.AccessibilityService
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

    private val globalActions = mutableListOf<Int>()
    private var globalActionAccepted = true

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
            performGlobalAction = { action ->
                globalActions += action
                globalActionAccepted
            },
            activeWindow = { window },
        ),
    )

    /** What the service would find as the active window. */
    private var window: RemoteTextWindow? = null

    /** A window whose focused field records what it is given, and takes it or does not. */
    private val written = mutableListOf<String>()

    private fun windowWithField(accepts: Boolean = true) = object : RemoteTextWindow {
        override fun findInputFocus() = object : RemoteTextNode {
            override val isEditable = true
            override val isEnabled = true

            override fun setText(text: String): Boolean {
                written += text
                return accepts
            }

            override fun release() = Unit
        }

        override fun release() = Unit
    }

    private fun swipeArguments(): MutableMap<String, Any?> = mutableMapOf(
        "startX" to 0.5,
        "startY" to 0.75,
        "endX" to 0.5,
        "endY" to 0.25,
        "durationMs" to 350,
    )

    private fun call(method: String, arguments: Map<String, Any?>?) =
        channel.onMethodCall(MethodCall(method, arguments), result)

    @Test
    fun `performBack, performHome and performRecents reach their global actions, with no arguments`() {
        connect()

        call("performBack", null)
        call("performHome", null)
        call("performRecents", null)

        assertEquals(
            listOf(
                AccessibilityService.GLOBAL_ACTION_BACK,
                AccessibilityService.GLOBAL_ACTION_HOME,
                AccessibilityService.GLOBAL_ACTION_RECENTS,
            ),
            globalActions,
        )
        assertEquals(listOf<Any?>("completed", "completed", "completed"), answers)
        assertTrue(strokes.isEmpty())
    }

    @Test
    fun `a global action Android refuses answers rejected`() {
        connect()
        globalActionAccepted = false

        call("performBack", null)
        call("performHome", null)
        call("performRecents", null)

        assertEquals(listOf<Any?>("rejected", "rejected", "rejected"), answers)
    }

    @Test
    fun `a global action with no service answers unavailable`() {
        call("performBack", null)
        call("performHome", null)
        call("performRecents", null)

        assertEquals(listOf<Any?>("unavailable", "unavailable", "unavailable"), answers)
        assertTrue(globalActions.isEmpty())
    }

    @Test
    fun `a global action while a swipe runs answers busy, and does not happen`() {
        connect()

        call("performSwipe", swipeArguments())
        call("performHome", null)
        call("performRecents", null)

        assertEquals(listOf<Any?>("busy", "busy"), answers)
        assertTrue(globalActions.isEmpty())
    }

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
    fun `performSetText reaches the focused field with its exact text`() {
        connect()
        window = windowWithField()

        call("performSetText", mapOf("text" to "Hola 👋\náéíóú ñ"))

        assertEquals(listOf("Hola 👋\náéíóú ñ"), written)
        assertEquals(listOf<Any?>("completed"), answers)
    }

    @Test
    fun `performSetText with an empty text writes an empty text`() {
        connect()
        window = windowWithField()

        call("performSetText", mapOf("text" to ""))

        assertEquals(listOf(""), written)
        assertEquals(listOf<Any?>("completed"), answers)
    }

    @Test
    fun `a field that refuses the text answers rejected`() {
        connect()
        window = windowWithField(accepts = false)

        call("performSetText", mapOf("text" to "Hola"))

        assertEquals(listOf<Any?>("rejected"), answers)
    }

    @Test
    fun `no window answers targetUnavailable`() {
        connect()

        call("performSetText", mapOf("text" to "Hola"))

        assertEquals(listOf<Any?>("targetUnavailable"), answers)
    }

    @Test
    fun `a set_text with no service answers unavailable`() {
        window = windowWithField()

        call("performSetText", mapOf("text" to "Hola"))

        assertEquals(listOf<Any?>("unavailable"), answers)
        assertTrue(written.isEmpty())
    }

    @Test
    fun `a set_text while a swipe runs answers busy, and writes nothing`() {
        connect()
        window = windowWithField()

        call("performSwipe", swipeArguments())
        call("performSetText", mapOf("text" to "Hola"))

        assertEquals(listOf<Any?>("busy"), answers)
        assertTrue(written.isEmpty())
    }

    @Test
    fun `a text that is missing or not a string answers invalid, and writes nothing`() {
        connect()
        window = windowWithField()

        call("performSetText", emptyMap())
        call("performSetText", null)
        call("performSetText", mapOf("text" to 7))

        assertEquals(List<Any?>(3) { "invalid" }, answers)
        assertTrue(written.isEmpty())
    }

    @Test
    fun `a method it does not know is not implemented`() {
        call("performPinch", emptyMap())

        assertTrue(notImplemented)
    }
}
