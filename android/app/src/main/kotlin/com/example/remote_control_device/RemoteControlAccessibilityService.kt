package com.example.remote_control_device

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * Puts a touch on the screen, presses Back, Home or Recents, or writes over the content of the
 * focused field. It holds no policy and asks for nothing else.
 *
 * Only the user can enable it, in Android's accessibility settings, and that says the *service*
 * may exist. It says nothing about any assistance: the service stays connected between sessions,
 * and each command is authorised in Dart against the `ACTIVE` remote session before it gets
 * here. See `docs/webrtc/CONTROL_CHANNEL.md`.
 *
 * It receives no accessibility events. It may retrieve window content
 * (`res/xml/accessibility_service_config.xml`), and uses that for one thing: finding what has input
 * focus while a `set_text` runs. It reads nothing from what it finds and keeps none of it. See
 * "Text-input privacy boundary" in the document above.
 */
class RemoteControlAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.i(TAG, "accessibility service connected")
        availability.connected(
            RemoteGestureDispatcher(
                // The application context, as the capture reads it: the two must agree on
                // what the current screen is.
                readDisplay = { ScreenCapturer.readDisplayGeometry(applicationContext) },
                dispatch = ::dispatchStroke,
                performGlobalAction = ::performGlobalAction,
                activeWindow = ::activeWindow,
            ),
        )
    }

    /**
     * Without being told otherwise, Android fetches part of the hierarchy along with the root, into
     * this process's cache. Finding the focus needs none of it, so from Android 13, where it can be
     * asked, it fetches only the root.
     */
    private fun activeWindow(): RemoteTextWindow? {
        val root = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getRootInActiveWindow(NO_PREFETCHING)
        } else {
            rootInActiveWindow
        }
        return root?.let(::AccessibilityTextWindow)
    }

    /**
     * One stroke at screen coordinates, not on any view: a straight line for a swipe, and with
     * nowhere to go, a tap.
     */
    private fun dispatchStroke(stroke: GestureStroke, onResult: (Boolean) -> Unit): Boolean {
        val path = Path().apply {
            moveTo(stroke.start.x.toFloat(), stroke.start.y.toFloat())
            stroke.end?.let { lineTo(it.x.toFloat(), it.y.toFloat()) }
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, stroke.durationMs))
            .build()

        return dispatchGesture(
            gesture,
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) = onResult(true)

                override fun onCancelled(gestureDescription: GestureDescription?) = onResult(false)
            },
            null,
        )
    }

    /** No event types are requested, so none arrive. */
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: Intent?): Boolean {
        disconnect()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        disconnect()
        super.onDestroy()
    }

    private fun disconnect() {
        if (availability.isAvailable) Log.i(TAG, "accessibility service disconnected")
        availability.disconnected()
    }

    companion object {
        private const val TAG = "RemoteControlInput"

        private const val NO_PREFETCHING = 0

        /** One per process, because Android binds at most one instance of the service. */
        val availability = RemoteControlAvailability()
    }
}
