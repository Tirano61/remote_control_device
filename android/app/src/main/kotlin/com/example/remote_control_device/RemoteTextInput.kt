package com.example.remote_control_device

import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The node that has input focus, offering only what writing to it, or running its IME action,
 * needs.
 *
 * There is deliberately nothing here to read a node's content with, so the path of a `set_text` or
 * an `ime_enter` cannot read a field, a hint or a description, password or not: it would not
 * compile.
 */
interface RemoteTextNode {
    val isEditable: Boolean
    val isEnabled: Boolean

    /**
     * Whether the node lists `ACTION_IME_ENTER` among its actions. Only the ids of those actions
     * are looked at, never their labels.
     */
    val exposesImeEnter: Boolean

    /** `ACTION_SET_TEXT`, answering what Android answers. */
    fun setText(text: String): Boolean

    /** `ACTION_IME_ENTER`, answering what Android answers. */
    fun imeEnter(): Boolean

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
 * [activeWindow] is only ever called from here and from [imeEnterOnInputFocus], so authorising the
 * command, which Dart does before it reaches this side, is also what authorises looking at the
 * window.
 */
fun writeToInputFocus(activeWindow: () -> RemoteTextWindow?, text: String): RemoteGestureOutcome =
    onEditableInputFocus(activeWindow) { node ->
        if (node.setText(text)) RemoteGestureOutcome.COMPLETED else RemoteGestureOutcome.REJECTED
    }

/**
 * Runs the IME action of whatever has input focus right now: what its keyboard would show as
 * Search, Done, Go, Next or Send, or an unspecified action. Which one it is, is the field's to
 * decide, and nothing here asks.
 *
 * The target is resolved exactly as for [writeToInputFocus]. A valid target that does not list
 * `ACTION_IME_ENTER` is [RemoteGestureOutcome.ACTION_UNAVAILABLE]: nothing stands in for it, no
 * key event and no newline.
 */
fun imeEnterOnInputFocus(activeWindow: () -> RemoteTextWindow?): RemoteGestureOutcome =
    onEditableInputFocus(activeWindow) { node ->
        when {
            !node.exposesImeEnter -> RemoteGestureOutcome.ACTION_UNAVAILABLE
            node.imeEnter() -> RemoteGestureOutcome.COMPLETED
            else -> RemoteGestureOutcome.REJECTED
        }
    }

/**
 * Resolves the input focus of the active window and hands it to [act] if it is editable and
 * enabled. Anything thrown on the way is [RemoteGestureOutcome.REJECTED], and the window and the
 * node are released however it ends.
 */
private fun onEditableInputFocus(
    activeWindow: () -> RemoteTextWindow?,
    act: (RemoteTextNode) -> RemoteGestureOutcome,
): RemoteGestureOutcome =
    try {
        val window = activeWindow()
        if (window == null) {
            RemoteGestureOutcome.TARGET_UNAVAILABLE
        } else {
            try {
                onEditableInputFocusOf(window, act)
            } finally {
                window.release()
            }
        }
    } catch (_: Exception) {
        RemoteGestureOutcome.REJECTED
    }

private fun onEditableInputFocusOf(
    window: RemoteTextWindow,
    act: (RemoteTextNode) -> RemoteGestureOutcome,
): RemoteGestureOutcome {
    val node = window.findInputFocus() ?: return RemoteGestureOutcome.TARGET_UNAVAILABLE
    try {
        if (!node.isEditable || !node.isEnabled) return RemoteGestureOutcome.TARGET_UNAVAILABLE
        return act(node)
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

    /** `ACTION_IME_ENTER` exists from Android 11. Below it, no node can list it. */
    override val exposesImeEnter: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            node.actionList.any { it.id == AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id }

    override fun setText(text: String): Boolean {
        val arguments = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
    }

    override fun imeEnter(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)

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
