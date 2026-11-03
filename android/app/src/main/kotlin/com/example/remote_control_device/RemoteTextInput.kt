package com.example.remote_control_device

import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The node that has input focus, offering only what writing to it needs.
 *
 * There is deliberately nothing here to read a node's content with, so the path of a `set_text`
 * cannot read a field, a hint or a description, password or not: it would not compile.
 */
interface RemoteTextNode {
    val isEditable: Boolean
    val isEnabled: Boolean

    /** `ACTION_SET_TEXT`, answering what Android answers. */
    fun setText(text: String): Boolean

    fun release()
}

/** The active window, from which the one thing to ask for is what has input focus. */
interface RemoteTextWindow {
    fun findInputFocus(): RemoteTextNode?

    fun release()
}

/**
 * Writes [text] over the content of whatever has input focus right now.
 *
 * The focus is resolved here, for this command, and no node outlives it. Nothing moves the focus
 * and nothing looks for another field: with no valid target the answer is
 * [RemoteGestureOutcome.TARGET_UNAVAILABLE], and the technician taps on the right one.
 *
 * [activeWindow] is only ever called from here, so authorising the command, which Dart does before
 * it reaches this side, is also what authorises looking at the window.
 */
fun writeToInputFocus(activeWindow: () -> RemoteTextWindow?, text: String): RemoteGestureOutcome =
    try {
        val window = activeWindow()
        if (window == null) {
            RemoteGestureOutcome.TARGET_UNAVAILABLE
        } else {
            try {
                writeToInputFocusOf(window, text)
            } finally {
                window.release()
            }
        }
    } catch (_: Exception) {
        RemoteGestureOutcome.REJECTED
    }

private fun writeToInputFocusOf(window: RemoteTextWindow, text: String): RemoteGestureOutcome {
    val node = window.findInputFocus() ?: return RemoteGestureOutcome.TARGET_UNAVAILABLE
    try {
        if (!node.isEditable || !node.isEnabled) return RemoteGestureOutcome.TARGET_UNAVAILABLE
        return if (node.setText(text)) RemoteGestureOutcome.COMPLETED else RemoteGestureOutcome.REJECTED
    } finally {
        node.release()
    }
}

/** [RemoteTextWindow] over the root of the active window. */
class AccessibilityTextWindow(private val root: AccessibilityNodeInfo) : RemoteTextWindow {
    override fun findInputFocus(): RemoteTextNode? =
        root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.let(::AccessibilityTextNode)

    override fun release() = root.releaseQuietly()
}

/** [RemoteTextNode] over a real node. */
private class AccessibilityTextNode(private val node: AccessibilityNodeInfo) : RemoteTextNode {
    override val isEditable: Boolean get() = node.isEditable

    override val isEnabled: Boolean get() = node.isEnabled

    override fun setText(text: String): Boolean {
        val arguments = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
    }

    override fun release() = node.releaseQuietly()
}

/**
 * Nodes are pooled below Android 13, where this hands one back, and it does nothing from there on.
 * A failure here says nothing about the action, which has already been answered for.
 */
private fun AccessibilityNodeInfo.releaseQuietly() {
    try {
        @Suppress("DEPRECATION")
        recycle()
    } catch (_: IllegalStateException) {
        // Already back in the pool.
    }
}
