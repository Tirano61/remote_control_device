package com.example.remote_control_device

import android.view.accessibility.AccessibilityNodeInfo
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What happens to an `ime_enter` around `ACTION_IME_ENTER`, with fakes where Android's nodes would
 * be.
 *
 * What these cannot show is what a real field does with the action — search, submit, move on or
 * nothing — or that a given field lists it: both need a device.
 */
class RemoteImeEnterTest {

    /**
     * A focused node. Every read of it is counted, so a test can say the path asked for nothing
     * beyond what it needs; [setText] failing the test says an `ime_enter` never writes.
     */
    private class FakeNode(
        private val editable: Boolean = true,
        private val enabled: Boolean = true,
        private val exposes: Boolean = true,
        val answer: () -> Boolean = { true },
    ) : RemoteTextNode {
        var released = 0
        var performed = 0
        val reads = mutableListOf<String>()

        override val isEditable: Boolean get() = editable.also { reads += "isEditable" }

        override val isEnabled: Boolean get() = enabled.also { reads += "isEnabled" }

        override val exposesImeEnter: Boolean get() = exposes.also { reads += "exposesImeEnter" }

        override fun setText(text: String): Boolean = throw AssertionError("an ime_enter writes no text")

        override fun imeEnter(): Boolean {
            performed++
            return answer()
        }

        override fun release() {
            released++
        }
    }

    private class FakeWindow(val focus: () -> RemoteTextNode?) : RemoteTextWindow {
        var lookups = 0
        var released = 0

        override fun findInputFocus(): RemoteTextNode? {
            lookups++
            return focus()
        }

        override fun release() {
            released++
        }
    }

    /** How many times the service was asked for the active window. */
    private var windowReads = 0

    /** What `rootInActiveWindow` answers right now. */
    private var window: FakeWindow? = FakeWindow { FakeNode() }

    private var report: ((Boolean) -> Unit)? = null
    private val outcomes = mutableListOf<RemoteGestureOutcome>()

    private val dispatcher = RemoteGestureDispatcher(
        readDisplay = { ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1) },
        dispatch = { _, onResult ->
            report = onResult
            true
        },
        performGlobalAction = { true },
        activeWindow = {
            windowReads++
            window
        },
        longPressTimeoutMs = { 500L },
    )

    private fun imeEnter() = dispatcher.imeEnter { outcomes += it }

    private fun focusOn(node: FakeNode): FakeNode {
        window = FakeWindow { node }
        return node
    }

    private val targetUnavailable = listOf(RemoteGestureOutcome.TARGET_UNAVAILABLE)

    // 1
    @Test
    fun `no active window has no target`() {
        window = null

        imeEnter()

        assertEquals(targetUnavailable, outcomes)
        assertEquals(1, windowReads)
    }

    // 2
    @Test
    fun `a window with no input focus has no target`() {
        val empty = FakeWindow { null }
        window = empty

        imeEnter()

        assertEquals(targetUnavailable, outcomes)
        assertEquals(1, empty.lookups)
    }

    // 3
    @Test
    fun `a focused node that is not editable has no target, and runs nothing`() {
        val node = focusOn(FakeNode(editable = false))

        imeEnter()

        assertEquals(targetUnavailable, outcomes)
        assertEquals(0, node.performed)
        assertFalse(node.reads.contains("exposesImeEnter"))
    }

    // 4
    @Test
    fun `a focused node that is disabled has no target, and runs nothing`() {
        val node = focusOn(FakeNode(enabled = false))

        imeEnter()

        assertEquals(targetUnavailable, outcomes)
        assertEquals(0, node.performed)
        assertFalse(node.reads.contains("exposesImeEnter"))
    }

    // 5
    @Test
    fun `a valid target without ACTION_IME_ENTER is actionUnavailable, and nothing stands in`() {
        val node = focusOn(FakeNode(exposes = false))

        imeEnter()

        assertEquals(listOf(RemoteGestureOutcome.ACTION_UNAVAILABLE), outcomes)
        assertEquals(0, node.performed)
    }

    // 6
    @Test
    fun `a node that takes the action is completed, once`() {
        val node = focusOn(FakeNode())

        imeEnter()

        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
        assertEquals(1, node.performed)
    }

    // 7
    @Test
    fun `a node that refuses the action is rejected`() {
        val node = focusOn(FakeNode(answer = { false }))

        imeEnter()

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
        assertEquals(1, node.performed)
    }

    // 8
    @Test
    fun `the action throwing is a rejection, not a crash`() {
        focusOn(FakeNode(answer = { throw IllegalStateException("window gone") }))

        imeEnter()

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
    }

    @Test
    fun `looking for the focus or the window throwing is a rejection, not a crash`() {
        window = FakeWindow { throw IllegalStateException("connection lost") }
        imeEnter()

        val throwing = RemoteGestureDispatcher(
            readDisplay = { throw AssertionError("an ime_enter names no position") },
            dispatch = { _, _ -> throw AssertionError("an ime_enter is no stroke") },
            performGlobalAction = { throw AssertionError("an ime_enter is no global action") },
            activeWindow = { throw IllegalStateException("connection lost") },
            longPressTimeoutMs = { 500L },
        )
        throwing.imeEnter { outcomes += it }

        assertEquals(List(2) { RemoteGestureOutcome.REJECTED }, outcomes)
    }

    // 9
    @Test
    fun `with no service it is unavailable, and nothing looks at any window`() {
        val availability = RemoteControlAvailability()

        availability.imeEnter { outcomes += it }
        assertEquals(listOf(RemoteGestureOutcome.UNAVAILABLE), outcomes)
        assertEquals(0, windowReads)

        availability.connected(dispatcher)
        availability.imeEnter { outcomes += it }
        assertEquals(RemoteGestureOutcome.COMPLETED, outcomes.last())

        availability.disconnected()
        availability.imeEnter { outcomes += it }
        assertEquals(RemoteGestureOutcome.UNAVAILABLE, outcomes.last())
        assertEquals(1, windowReads)
    }

    // 10
    @Test
    fun `while a gesture runs it answers busy, looks at nothing and disturbs nothing`() {
        val node = focusOn(FakeNode())
        dispatcher.swipe(0.5, 0.75, 0.5, 0.25, 300L) { outcomes += it }
        val running = report!!

        imeEnter()

        assertEquals(listOf(RemoteGestureOutcome.BUSY), outcomes)
        assertEquals(0, windowReads)
        assertEquals(0, node.performed)

        running(true)
        assertEquals(RemoteGestureOutcome.COMPLETED, outcomes.last())

        imeEnter()
        assertEquals(1, node.performed)
    }

    @Test
    fun `it leaves nothing running`() {
        imeEnter()

        dispatcher.tap(0.5, 0.5) { outcomes += it }
        report!!(true)

        assertEquals(List(2) { RemoteGestureOutcome.COMPLETED }, outcomes)
    }

    @Test
    fun `the focus is looked for afresh each time`() {
        val first = FakeNode()
        val second = FakeNode()
        val firstWindow = FakeWindow { first }
        window = firstWindow
        imeEnter()

        val secondWindow = FakeWindow { second }
        window = secondWindow
        imeEnter()

        assertEquals(1, first.performed)
        assertEquals(1, second.performed)
        assertEquals(1, firstWindow.lookups)
        assertEquals(1, secondWindow.lookups)
    }

    @Test
    fun `no node outlives the command, however it ends`() {
        val nodes = listOf(
            FakeNode(),
            FakeNode(answer = { false }),
            FakeNode(answer = { throw IllegalStateException("window gone") }),
            FakeNode(exposes = false),
            FakeNode(editable = false),
            FakeNode(enabled = false),
        )

        for (node in nodes) {
            val each = FakeWindow { node }
            window = each

            imeEnter()

            assertEquals(1, node.released)
            assertEquals(1, each.released)
        }
    }

    /**
     * Everything the path asks of a node, in order. That it can ask nothing else is pinned in
     * [RemoteSetTextTest], on the type itself.
     */
    @Test
    fun `it asks only whether the node is editable, enabled and lists the action`() {
        val node = focusOn(FakeNode())

        imeEnter()

        assertEquals(listOf("isEditable", "isEnabled", "exposesImeEnter"), node.reads)
    }

    /** The adapter over real nodes cannot run here, so its source is what can be held still. */
    private val adapter = code("src/main/kotlin/com/example/remote_control_device/RemoteTextInput.kt")

    @Test
    fun `the adapter checks and performs ACTION_IME_ENTER by its id, on the input focus`() {
        assertTrue(adapter.contains("findFocus(AccessibilityNodeInfo.FOCUS_INPUT)"))
        assertTrue(
            adapter.contains(
                "node.actionList.any { it.id == AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id }",
            ),
        )
        assertTrue(adapter.contains("node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)"))
    }

    @Test
    fun `the adapter reads no label of any action`() {
        assertFalse(Regex("""\.(label|getLabel)\b""").containsMatchIn(adapter))
    }

    @Test
    fun `nothing stands in for the action`() {
        val sources = listOf(
            adapter,
            code("src/main/kotlin/com/example/remote_control_device/RemoteGesture.kt"),
            code("src/main/kotlin/com/example/remote_control_device/RemoteControlAccessibilityChannel.kt"),
            code("src/main/kotlin/com/example/remote_control_device/RemoteControlAccessibilityService.kt"),
        )
        for (excluded in listOf(
            "KeyEvent",
            "KEYCODE_ENTER",
            "Instrumentation",
            "InputManager",
            "Runtime.getRuntime",
            "ProcessBuilder",
            "ClipboardManager",
            "\"\\n\"",
        )) {
            for (source in sources) assertFalse(excluded, source.contains(excluded))
        }
    }

    @Test
    fun `it resolves the input focus, never the accessibility focus`() {
        // Inlined from android.jar, as in RemoteSetTextTest.
        assertEquals(1, AccessibilityNodeInfo.FOCUS_INPUT)
        assertFalse(adapter.contains("FOCUS_ACCESSIBILITY"))
    }

    /** A Kotlin source without its comments, which may name what the code must not touch. */
    private fun code(path: String): String =
        File(path).readText()
            .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), "")
            .replace(Regex("""//[^\n]*"""), "")
}
