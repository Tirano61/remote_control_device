package com.example.remote_control_device

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.annotation.RequiresApi
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityEvent

/**
 * Puts a touch on the screen, short or held, or a stroke across it, keeps a finger down across
 * several strokes for a remote drag, presses Back, Home or Recents, writes over the content of the
 * focused field, or runs that field's IME action. It holds no policy and asks for nothing else.
 *
 * Only the user can enable it, in Android's accessibility settings, and that says the *service*
 * may exist. It says nothing about any assistance: the service stays connected between sessions,
 * and each command is authorised in Dart against the `ACTIVE` remote session before it gets
 * here. See `docs/webrtc/CONTROL_CHANNEL.md`.
 *
 * It receives no accessibility events. It may retrieve window content
 * (`res/xml/accessibility_service_config.xml`), and uses that for one thing: finding what has input
 * focus while a `set_text` or an `ime_enter` runs. It reads nothing from what it finds beyond
 * whether it is editable and enabled and which actions it lists, and keeps none of it. See
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
                // The user's touch-and-hold delay, as every view on the device reads it.
                longPressTimeoutMs = { ViewConfiguration.getLongPressTimeout().toLong() },
                touchPort = RemoteTouchPort(
                    continuedStrokesSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O,
                    dispatch = ::dispatchTouchSegment,
                    clock = mainThreadClock,
                ),
                onTouchEnded = availability::touchEnded,
                log = { Log.i(TAG, it) },
                cancelGesture = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ::cancelInjectedGesture
                } else {
                    null
                },
            ),
        )
    }

    /** Where every gesture callback already arrives, so a touch's timers never race them. */
    private val mainThreadClock = object : TouchClock {
        private val handler = Handler(Looper.getMainLooper())

        override fun now(): Long = SystemClock.uptimeMillis()

        override fun schedule(delayMs: Long, action: () -> Unit): () -> Unit {
            val runnable = Runnable(action)
            handler.postDelayed(runnable, delayMs)
            return { handler.removeCallbacks(runnable) }
        }
    }

    /**
     * The last stroke of the remote touch that Android accepted. Every stroke after the first is
     * its `continueStroke`, which is what keeps the pointer the same pointer.
     */
    private var touchStroke: GestureDescription.StrokeDescription? = null

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
     * nowhere to go, a tap or, held longer, a long press.
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

    /** Below Android 8.0 there is no continued stroke, and [RemoteTouchPort] says so first. */
    private fun dispatchTouchSegment(segment: TouchSegment, onResult: (Boolean) -> Unit): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return dispatchContinuedStroke(segment, onResult)
    }

    /**
     * One stroke of a remote touch: a new one that keeps the pointer down, or a continuation of the
     * last one. The path is the segment's, at whole pixels, which is how Android compares where a
     * continuation starts with where its stroke ended. A [TouchSegment.Kind.CANCEL_VIA_MISMATCH]
     * starts elsewhere on purpose; see [RemoteTouchController].
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun dispatchContinuedStroke(segment: TouchSegment, onResult: (Boolean) -> Unit): Boolean {
        val path = Path().apply {
            moveTo(segment.from.x.toFloat(), segment.from.y.toFloat())
            if (segment.to != segment.from) lineTo(segment.to.x.toFloat(), segment.to.y.toFloat())
        }
        val stroke = if (segment.kind.continuesPrevious) {
            val previous = touchStroke ?: return false
            previous.continueStroke(path, 0L, segment.durationMs, segment.kind.willContinue)
        } else {
            GestureDescription.StrokeDescription(path, 0L, segment.durationMs, segment.kind.willContinue)
        }
        val accepted = dispatchGesture(
            GestureDescription.Builder().addStroke(stroke).build(),
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) = onResult(true)

                override fun onCancelled(gestureDescription: GestureDescription?) = onResult(false)
            },
            null,
        )
        if (accepted) touchStroke = if (segment.kind.willContinue) stroke else null
        return accepted
    }

    /**
     * Stops the one-shot gesture Android is playing for this service, without touching the screen.
     *
     * **There is no public API that cancels a dispatched gesture.** This dispatches a gesture whose
     * only stroke claims to continue a stroke that was never dispatched. `MotionEventInjector`
     * (`injectEventsMainThread`) sees a gesture that tries to continue an old one, cannot map the
     * continued stroke ("unknown continued stroke id" in `prepareToContinueOldGesture`), and on
     * that refusal runs `cancelAnyPendingInjectedEvents`: the injected events not yet played are
     * removed, one `ACTION_CANCEL` goes to the pointer that gesture holds down, and the gesture
     * running is reported cancelled. Then the new one is reported cancelled too, and returned
     * from before any event of it is built. No `ACTION_DOWN`, `ACTION_MOVE` or `ACTION_UP` is
     * produced, and with no injected gesture running nothing at all reaches an application.
     * Read in `android16-release` and `main` of `frameworks/base`; the same refusal is what
     * [RemoteTouchController.cancelContinuedStrokeViaMismatch] relies on, which CTS
     * (`testContinuedGesture_withLineDisconnect_isCancelled`) requires of every device.
     *
     * The stroke is placed at (0, 0) and never played. Used by [RemoteGestureDispatcher.revoke]
     * and nothing else.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun cancelInjectedGesture(onResult: (Boolean) -> Unit): Boolean {
        val corner = Path().apply { moveTo(0f, 0f) }
        val neverDispatched = GestureDescription.StrokeDescription(corner, 0L, 1L, true)
        val orphan = neverDispatched.continueStroke(corner, 0L, 1L, false)
        return dispatchGesture(
            GestureDescription.Builder().addStroke(orphan).build(),
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
