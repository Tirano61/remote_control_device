package com.example.remote_control_device

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * Puts a touch on the screen. It holds no policy, reads nothing and asks for nothing else.
 *
 * Only the user can enable it, in Android's accessibility settings, and that says the *service*
 * may exist. It says nothing about any assistance: the service stays connected between sessions,
 * and each command is authorised in Dart against the `ACTIVE` remote session before it gets
 * here. See `docs/webrtc/CONTROL_CHANNEL.md`.
 *
 * It receives no accessibility events and cannot read window content
 * (`res/xml/accessibility_service_config.xml`), so the only thing it can do is the gesture.
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
                dispatch = ::dispatchTap,
            ),
        )
    }

    /** A short stroke with no movement: a tap at screen coordinates, not on any view. */
    private fun dispatchTap(pixel: GesturePixel, onResult: (Boolean) -> Unit): Boolean {
        val path = Path().apply { moveTo(pixel.x.toFloat(), pixel.y.toFloat()) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, TAP_DURATION_MS))
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

        /** Long enough to register as a touch, far short of a long press. */
        private const val TAP_DURATION_MS = 50L

        /** One per process, because Android binds at most one instance of the service. */
        val availability = RemoteControlAvailability()
    }
}
