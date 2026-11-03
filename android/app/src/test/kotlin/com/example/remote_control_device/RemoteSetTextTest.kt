package com.example.remote_control_device

import android.view.accessibility.AccessibilityNodeInfo
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What happens to a `set_text` around `ACTION_SET_TEXT`, with fakes where Android's nodes would be.
 *
 * What these cannot show is that a real node does what it should with the action, or that Android
 * grants the capability: both need a device.
 */
class RemoteSetTextTest {

    /** A focused node. The fields a real one would hold are here so a test can give them values. */
    private class FakeNode(
        val isPassword: Boolean = false,
        override val isEditable: Boolean = true,
        override val isEnabled: Boolean = true,
        val answer: () -> Boolean = { true },
    ) : RemoteTextNode {
        val written = mutableListOf<String>()
        var released = 0

        override fun setText(text: String): Boolean {
            written += text
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
    private val globalActions = mutableListOf<Int>()
    private val outcomes = mutableListOf<RemoteGestureOutcome>()

    private val dispatcher = RemoteGestureDispatcher(
        readDisplay = { ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1) },
        dispatch = { _, onResult ->
            report = onResult
            true
        },
        performGlobalAction = { action ->
            globalActions += action
            true
        },
        activeWindow = {
            windowReads++
            window
        },
    )

    private fun setText(text: String = "Hola") = dispatcher.setText(text) { outcomes += it }

    private fun focusOn(node: FakeNode): FakeNode {
        window = FakeWindow { node }
        return node
    }

    private val targetUnavailable = listOf(RemoteGestureOutcome.TARGET_UNAVAILABLE)

    @Test
    fun `no active window has no target`() {
        window = null

        setText()

        assertEquals(targetUnavailable, outcomes)
    }

    @Test
    fun `a window with no input focus has no target`() {
        val empty = FakeWindow { null }
        window = empty

        setText()

        assertEquals(targetUnavailable, outcomes)
        assertEquals(1, empty.lookups)
    }

    @Test
    fun `a focused node that is not editable has no target, and is not written to`() {
        val node = focusOn(FakeNode(isEditable = false))

        setText()

        assertEquals(targetUnavailable, outcomes)
        assertTrue(node.written.isEmpty())
    }

    @Test
    fun `a focused node that is disabled has no target, and is not written to`() {
        val node = focusOn(FakeNode(isEnabled = false))

        setText()

        assertEquals(targetUnavailable, outcomes)
        assertTrue(node.written.isEmpty())
    }

    @Test
    fun `a node that takes the text is completed, with exactly that text`() {
        val node = focusOn(FakeNode())

        setText("Hola mundo")

        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
        assertEquals(listOf("Hola mundo"), node.written)
    }

    @Test
    fun `the text reaches the node untouched`() {
        val node = focusOn(FakeNode())
        val texts = listOf("", " ", "  con espacios  ", "áéíóú ñ", "Hola 👋", "dos\nlíneas", "MiXtO")

        texts.forEach { setText(it) }

        assertEquals(texts, node.written)
        assertEquals(List(texts.size) { RemoteGestureOutcome.COMPLETED }, outcomes)
    }

    @Test
    fun `a node that refuses the text is rejected`() {
        focusOn(FakeNode(answer = { false }))

        setText()

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
    }

    @Test
    fun `the action throwing is a rejection, not a crash`() {
        focusOn(FakeNode(answer = { throw IllegalStateException("window gone") }))

        setText()

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
    }

    @Test
    fun `looking for the focus throwing is a rejection, not a crash`() {
        window = FakeWindow { throw IllegalStateException("connection lost") }

        setText()

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
    }

    @Test
    fun `asking for the window throwing is a rejection, not a crash`() {
        val throwing = RemoteGestureDispatcher(
            readDisplay = { throw AssertionError("a set_text names no position") },
            dispatch = { _, _ -> throw AssertionError("a set_text is no stroke") },
            performGlobalAction = { throw AssertionError("a set_text is no global action") },
            activeWindow = { throw IllegalStateException("connection lost") },
        )

        throwing.setText("Hola") { outcomes += it }

        assertEquals(listOf(RemoteGestureOutcome.REJECTED), outcomes)
    }

    @Test
    fun `the limit is 4096 code units, and an emoji is two of them`() {
        val node = focusOn(FakeNode())
        val atTheLimit = "a".repeat(4096)
        val emojiAtTheLimit = "👋".repeat(2048)

        setText("")
        setText("a")
        setText(atTheLimit)
        setText(emojiAtTheLimit)
        assertEquals(listOf("", "a", atTheLimit, emojiAtTheLimit), node.written)

        setText("a".repeat(4097))
        setText("👋".repeat(2049))
        setText(emojiAtTheLimit + "a")

        assertEquals(4, node.written.size)
        assertEquals(List(3) { RemoteGestureOutcome.INVALID }, outcomes.takeLast(3))
    }

    @Test
    fun `a text past the limit does not even look at the window`() {
        setText("a".repeat(4097))

        assertEquals(0, windowReads)
    }

    @Test
    fun `while a gesture runs it answers busy, looks at nothing and disturbs nothing`() {
        val node = focusOn(FakeNode())
        dispatcher.swipe(0.5, 0.75, 0.5, 0.25, 300L) { outcomes += it }
        val running = report!!

        setText()

        assertEquals(listOf(RemoteGestureOutcome.BUSY), outcomes)
        assertEquals(0, windowReads)
        assertTrue(node.written.isEmpty())

        running(true)
        assertEquals(RemoteGestureOutcome.COMPLETED, outcomes.last())

        setText()
        assertEquals(listOf("Hola"), node.written)
    }

    @Test
    fun `it leaves nothing running`() {
        setText()

        dispatcher.tap(0.5, 0.5) { outcomes += it }
        report!!(true)

        assertEquals(List(2) { RemoteGestureOutcome.COMPLETED }, outcomes)
    }

    @Test
    fun `only a set_text looks at the window`() {
        val availability = RemoteControlAvailability()
        availability.connected(dispatcher)
        assertEquals("connecting", 0, windowReads)

        dispatcher.tap(0.5, 0.5) { outcomes += it }
        report!!(true)
        dispatcher.swipe(0.5, 0.75, 0.5, 0.25, 300L) { outcomes += it }
        report!!(true)
        dispatcher.back { outcomes += it }
        dispatcher.home { outcomes += it }
        dispatcher.recents { outcomes += it }
        assertEquals("gestures and global actions", 0, windowReads)

        setText()
        assertEquals(1, windowReads)

        availability.disconnected()
        assertEquals("disconnecting", 1, windowReads)
    }

    @Test
    fun `with no service it is unavailable, and nothing looks at any window`() {
        val availability = RemoteControlAvailability()

        availability.setText("Hola") { outcomes += it }
        assertEquals(listOf(RemoteGestureOutcome.UNAVAILABLE), outcomes)
        assertEquals(0, windowReads)

        availability.connected(dispatcher)
        availability.setText("Hola") { outcomes += it }
        assertEquals(RemoteGestureOutcome.COMPLETED, outcomes.last())

        availability.disconnected()
        availability.setText("Hola") { outcomes += it }
        assertEquals(RemoteGestureOutcome.UNAVAILABLE, outcomes.last())
        assertEquals(1, windowReads)
    }

    @Test
    fun `the focus is looked for afresh each time`() {
        val first = FakeNode()
        val second = FakeNode()
        val firstWindow = FakeWindow { first }
        window = firstWindow
        setText("uno")

        val secondWindow = FakeWindow { second }
        window = secondWindow
        setText("dos")

        assertEquals(listOf("uno"), first.written)
        assertEquals(listOf("dos"), second.written)
        assertEquals(1, firstWindow.lookups)
        assertEquals(1, secondWindow.lookups)
    }

    @Test
    fun `no node outlives the command, however it ends`() {
        val nodes = listOf(
            FakeNode(),
            FakeNode(answer = { false }),
            FakeNode(answer = { throw IllegalStateException("window gone") }),
            FakeNode(isEditable = false),
            FakeNode(isEnabled = false),
        )

        for (node in nodes) {
            val each = FakeWindow { node }
            window = each

            setText()

            assertEquals(1, node.released)
            assertEquals(1, each.released)
        }
    }

    @Test
    fun `the window is released when there was nothing to find, or finding it threw`() {
        val empty = FakeWindow { null }
        window = empty
        setText()
        assertEquals(1, empty.released)

        val throwing = FakeWindow { throw IllegalStateException("connection lost") }
        window = throwing
        setText()
        assertEquals(1, throwing.released)
    }

    @Test
    fun `a password field is written to like any other`() {
        val node = focusOn(FakeNode(isPassword = true))

        setText("contraseña-123")

        assertEquals(listOf(RemoteGestureOutcome.COMPLETED), outcomes)
        assertEquals(listOf("contraseña-123"), node.written)
    }

    /**
     * The proof that the path reads no content is that it has nothing to read it with, so that
     * is what is pinned: anything added to these types is a decision this test will ask about.
     */
    @Test
    fun `the node and the window offer nothing to read content with`() {
        assertEquals(
            setOf("isEditable", "isEnabled", "setText", "release"),
            RemoteTextNode::class.java.declaredMethods.map { it.name }.toSet(),
        )
        assertEquals(
            setOf("findInputFocus", "release"),
            RemoteTextWindow::class.java.declaredMethods.map { it.name }.toSet(),
        )
    }

    /** The adapters over real nodes cannot run here, so their source is what can be held still. */
    private val adapter = code("src/main/kotlin/com/example/remote_control_device/RemoteTextInput.kt")

    @Test
    fun `the adapter resolves input focus and writes with ACTION_SET_TEXT`() {
        assertTrue(adapter.contains("findFocus(AccessibilityNodeInfo.FOCUS_INPUT)"))
        assertTrue(adapter.contains("AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text"))
        assertTrue(adapter.contains("performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)"))
    }

    @Test
    fun `the adapter reads no content from a node`() {
        val reads = Regex(
            """\.(text|getText|hintText|getHintText|contentDescription|getContentDescription|""" +
                """isPassword|password|error|tooltipText|paneTitle|stateDescription|viewIdResourceName|""" +
                """className|packageName|extras)\b""",
        )

        assertEquals(emptyList<String>(), reads.findAll(adapter).map { it.value }.toList())
    }

    @Test
    fun `the adapter moves no focus and walks no hierarchy`() {
        for (excluded in listOf(
            "FOCUS_ACCESSIBILITY",
            "ACTION_FOCUS",
            "ACTION_ACCESSIBILITY_FOCUS",
            "getChild",
            "childCount",
            "parent",
            "findAccessibilityNodeInfos",
        )) {
            assertFalse(excluded, adapter.contains(excluded))
        }
    }

    @Test
    fun `no log line can carry the text`() {
        assertFalse(adapter.contains("Log."))

        val channel = code("src/main/kotlin/com/example/remote_control_device/RemoteControlAccessibilityChannel.kt")
        assertFalse(Regex("""\$\{?text\b""").containsMatchIn(channel))
    }

    @Test
    fun `the service keeps nothing and watches nothing`() {
        val service = code("src/main/kotlin/com/example/remote_control_device/RemoteControlAccessibilityService.kt")

        assertTrue(service.contains("override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit"))
        // The window is only read in the function the dispatcher calls for a set_text.
        assertTrue(service.contains("activeWindow = ::activeWindow"))
        assertEquals(1, Regex("""\brootInActiveWindow\b""").findAll(service).count())
        assertEquals(1, Regex("""\bgetRootInActiveWindow\b""").findAll(service).count())
        assertFalse(Regex("""\b(var|val)\s+\w+\s*:\s*AccessibilityNodeInfo""").containsMatchIn(service))
    }

    @Test
    fun `the constants are the ones Android defines`() {
        // Inlined from android.jar. Spelled out so that swapping one for the other has something
        // to disagree with.
        assertEquals(1, AccessibilityNodeInfo.FOCUS_INPUT)
        assertEquals(2, AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
        assertEquals(0x00200000, AccessibilityNodeInfo.ACTION_SET_TEXT)
    }

    /** A Kotlin source without its comments, which may name what the code must not touch. */
    private fun code(path: String): String =
        File(path).readText()
            .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), "")
            .replace(Regex("""//[^\n]*"""), "")
}
