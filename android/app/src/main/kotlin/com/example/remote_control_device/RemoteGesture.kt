package com.example.remote_control_device

import android.accessibilityservice.AccessibilityService

/** A pixel of the screen as it is right now, always inside it. */
data class GesturePixel(val x: Int, val y: Int)

/**
 * Where a normalized position lands on this screen.
 *
 * The frame the technician clicks on is the whole display, so `0..1` over the frame is `0..1`
 * over [ScreenCaptureGeometry.width] and [ScreenCaptureGeometry.height]. `1.0` would land one
 * past the last pixel, which is outside the screen, so it is mapped onto the last one.
 */
fun ScreenCaptureGeometry.gesturePixel(normalizedX: Double, normalizedY: Double): GesturePixel {
    require(isNormalized(normalizedX) && isNormalized(normalizedY)) { "not a normalized position" }
    return GesturePixel(pixelOn(normalizedX, width), pixelOn(normalizedY, height))
}

private fun isNormalized(value: Double): Boolean = value in 0.0..1.0

private fun pixelOn(normalized: Double, size: Int): Int =
    (normalized * size).toInt().coerceAtMost(size - 1)

/**
 * The one stroke of a gesture, as `GestureDescription.StrokeDescription` will receive it.
 *
 * With no [end] it stays where it started, which is a tap. It always starts at time zero.
 */
data class GestureStroke(val start: GesturePixel, val end: GesturePixel?, val durationMs: Long)

/**
 * The stroke of a swipe on this screen, or `null` if both ends land on the same pixel.
 *
 * Two positions can differ and still name one pixel. Android treats a stroke with no length as
 * a touch held in place, which for up to two seconds would be a long press nobody asked for.
 */
fun ScreenCaptureGeometry.swipeStroke(
    startX: Double,
    startY: Double,
    endX: Double,
    endY: Double,
    durationMs: Long,
): GestureStroke? {
    val start = gesturePixel(startX, startY)
    val end = gesturePixel(endX, endY)
    return if (start == end) null else GestureStroke(start, end, durationMs)
}

/** What became of a gesture or a global action. [wire] is what crosses the channel to Dart. */
enum class RemoteGestureOutcome(val wire: String) {
    /**
     * Android reported the gesture completed. The only outcome that means it happened.
     *
     * For a global action it means Android took it: `performGlobalAction` answers at once and
     * nothing reports when the action has finished.
     */
    COMPLETED("completed"),

    /** Android cancelled it, or the service went away while it was running. */
    CANCELLED("cancelled"),

    /** `dispatchGesture` or `performGlobalAction` refused it, or the display could not be read. */
    REJECTED("rejected"),

    /** A gesture is still running. `dispatchGesture` would cancel it, so this one is refused. */
    BUSY("busy"),

    /**
     * A position is not normalized, a duration is out of range, or a swipe goes nowhere on this
     * screen. Dart already validated what it could; this is the boundary.
     */
    INVALID("invalid"),

    /** The accessibility service is not connected. */
    UNAVAILABLE("unavailable"),
}

/**
 * Runs one gesture at a time, of any kind, and reports what really happened to it.
 *
 * The display is read afresh for every gesture and never kept, so a rotation between two needs
 * no signal of its own: [readDisplay] is the same reading the screen capture crops with
 * ([ScreenCapturer.readDisplayGeometry]), which is what makes both describe one screen. A
 * rotation during a swipe changes nothing here: its stroke is already Android's, which finishes
 * or cancels it.
 *
 * [dispatch] answers whether Android accepted the gesture, and later reports through its second
 * argument whether it completed. Queueing is Dart's, because only Dart knows when a session
 * ends; a second gesture here is refused, since `dispatchGesture` would otherwise cancel the
 * first.
 *
 * [performGlobalAction] is `AccessibilityService.performGlobalAction`. A global action names no
 * position, so it reads no display. It answers at once and leaves nothing running, but it still
 * waits its turn: Home must not start under a swipe that has not finished.
 *
 * Pure, and main-thread only: the channel handler, the gesture callback and the service
 * lifecycle all run there.
 */
class RemoteGestureDispatcher(
    private val readDisplay: () -> ScreenCaptureGeometry,
    private val dispatch: (GestureStroke, (Boolean) -> Unit) -> Boolean,
    private val performGlobalAction: (Int) -> Boolean,
) {
    private var running: Running? = null

    fun tap(normalizedX: Double, normalizedY: Double, answer: (RemoteGestureOutcome) -> Unit) {
        perform(
            isValid = isNormalized(normalizedX) && isNormalized(normalizedY),
            answer = answer,
        ) { display ->
            GestureStroke(display.gesturePixel(normalizedX, normalizedY), null, TAP_DURATION_MS)
        }
    }

    fun swipe(
        startX: Double,
        startY: Double,
        endX: Double,
        endY: Double,
        durationMs: Long,
        answer: (RemoteGestureOutcome) -> Unit,
    ) {
        perform(
            isValid = isNormalized(startX) && isNormalized(startY) &&
                isNormalized(endX) && isNormalized(endY) &&
                durationMs in MIN_SWIPE_DURATION_MS..MAX_SWIPE_DURATION_MS,
            answer = answer,
        ) { display ->
            display.swipeStroke(startX, startY, endX, endY, durationMs)
        }
    }

    fun back(answer: (RemoteGestureOutcome) -> Unit) =
        globalAction(AccessibilityService.GLOBAL_ACTION_BACK, answer)

    fun home(answer: (RemoteGestureOutcome) -> Unit) =
        globalAction(AccessibilityService.GLOBAL_ACTION_HOME, answer)

    fun recents(answer: (RemoteGestureOutcome) -> Unit) =
        globalAction(AccessibilityService.GLOBAL_ACTION_RECENTS, answer)

    private fun globalAction(action: Int, answer: (RemoteGestureOutcome) -> Unit) {
        if (running != null) {
            answer(RemoteGestureOutcome.BUSY)
            return
        }
        val accepted = try {
            performGlobalAction(action)
        } catch (_: Exception) {
            false
        }
        answer(if (accepted) RemoteGestureOutcome.COMPLETED else RemoteGestureOutcome.REJECTED)
    }

    /** [strokeOn] answering `null` means the gesture makes no sense on the screen as it is. */
    private fun perform(
        isValid: Boolean,
        answer: (RemoteGestureOutcome) -> Unit,
        strokeOn: (ScreenCaptureGeometry) -> GestureStroke?,
    ) {
        if (running != null) {
            answer(RemoteGestureOutcome.BUSY)
            return
        }
        if (!isValid) {
            answer(RemoteGestureOutcome.INVALID)
            return
        }

        val stroke = try {
            strokeOn(readDisplay())
        } catch (_: Exception) {
            answer(RemoteGestureOutcome.REJECTED)
            return
        }
        if (stroke == null) {
            answer(RemoteGestureOutcome.INVALID)
            return
        }

        val gesture = Running(answer)
        running = gesture
        val accepted = try {
            dispatch(stroke) { completed ->
                settle(gesture, if (completed) RemoteGestureOutcome.COMPLETED else RemoteGestureOutcome.CANCELLED)
            }
        } catch (_: Exception) {
            false
        }
        if (!accepted) settle(gesture, RemoteGestureOutcome.REJECTED)
    }

    /** The service is going away and will not report on the gesture it was running. */
    fun abandon() {
        running?.let { settle(it, RemoteGestureOutcome.CANCELLED) }
    }

    /** Answers once: a late report about a gesture already answered finds nothing to answer. */
    private fun settle(gesture: Running, outcome: RemoteGestureOutcome) {
        if (running !== gesture) return
        running = null
        gesture.answer(outcome)
    }

    private class Running(val answer: (RemoteGestureOutcome) -> Unit)

    private companion object {
        /** Long enough to register as a touch, far short of a long press. */
        const val TAP_DURATION_MS = 50L

        /** The range of the protocol, in `docs/webrtc/CONTROL_CHANNEL.md`. */
        const val MIN_SWIPE_DURATION_MS = 50L
        const val MAX_SWIPE_DURATION_MS = 2000L
    }
}

/**
 * Whether the accessibility service is connected right now, and the way to it.
 *
 * Available means *connected*, which only Android can make true after the user enabled the
 * service in Settings. It authorises nothing: the service stays connected between assistances,
 * and whether a command may run is decided in Dart, against the remote session.
 */
class RemoteControlAvailability {
    private var dispatcher: RemoteGestureDispatcher? = null

    /** Told about every change. Set while a Flutter engine is attached. */
    var onChanged: ((Boolean) -> Unit)? = null

    val isAvailable: Boolean get() = dispatcher != null

    fun connected(next: RemoteGestureDispatcher) {
        dispatcher?.abandon()
        dispatcher = next
        onChanged?.invoke(true)
    }

    /** Idempotent: Android may report both `onUnbind` and `onDestroy`. */
    fun disconnected() {
        val gone = dispatcher ?: return
        dispatcher = null
        gone.abandon()
        onChanged?.invoke(false)
    }

    fun tap(normalizedX: Double, normalizedY: Double, answer: (RemoteGestureOutcome) -> Unit) {
        val current = dispatcher
        if (current == null) {
            answer(RemoteGestureOutcome.UNAVAILABLE)
            return
        }
        current.tap(normalizedX, normalizedY, answer)
    }

    fun swipe(
        startX: Double,
        startY: Double,
        endX: Double,
        endY: Double,
        durationMs: Long,
        answer: (RemoteGestureOutcome) -> Unit,
    ) {
        val current = dispatcher
        if (current == null) {
            answer(RemoteGestureOutcome.UNAVAILABLE)
            return
        }
        current.swipe(startX, startY, endX, endY, durationMs, answer)
    }

    fun back(answer: (RemoteGestureOutcome) -> Unit) {
        val current = dispatcher
        if (current == null) {
            answer(RemoteGestureOutcome.UNAVAILABLE)
            return
        }
        current.back(answer)
    }

    fun home(answer: (RemoteGestureOutcome) -> Unit) {
        val current = dispatcher
        if (current == null) {
            answer(RemoteGestureOutcome.UNAVAILABLE)
            return
        }
        current.home(answer)
    }

    fun recents(answer: (RemoteGestureOutcome) -> Unit) {
        val current = dispatcher
        if (current == null) {
            answer(RemoteGestureOutcome.UNAVAILABLE)
            return
        }
        current.recents(answer)
    }
}
