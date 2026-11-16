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
 * How long a long press holds its touch, given the device's long-press timeout
 * (`ViewConfiguration.getLongPressTimeout()`), or `null` if that timeout cannot be used.
 *
 * Android reads a touch as a long press once it has been held for the timeout, so the stroke
 * outlasts it by [LONG_PRESS_MARGIN_MS] rather than ending on the boundary. A timeout that is not
 * positive is not one Android gives; one so long that the stroke would exceed
 * [MAX_LONG_PRESS_DURATION_MS] is refused, because Dart would stop waiting for the answer while
 * the touch is still held.
 */
fun longPressDurationMs(longPressTimeoutMs: Long): Long? {
    if (longPressTimeoutMs <= 0) return null
    val duration = longPressTimeoutMs + LONG_PRESS_MARGIN_MS
    return if (duration <= MAX_LONG_PRESS_DURATION_MS) duration else null
}

/** Past the timeout, so that the touch is not released exactly as Android decides. */
const val LONG_PRESS_MARGIN_MS = 100L

/**
 * Well above the longest touch-and-hold delay Android's settings offer (1.5 s), and well below
 * the 5 s `MethodChannelRemoteControlAccessibilityClient` waits for any gesture's answer.
 */
const val MAX_LONG_PRESS_DURATION_MS = 4000L

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

    /**
     * `dispatchGesture`, `performGlobalAction`, `ACTION_SET_TEXT` or `ACTION_IME_ENTER` refused it,
     * or something it needed from Android could not be read.
     */
    REJECTED("rejected"),

    /**
     * A `set_text` or an `ime_enter` found no active window, no input focus, or a node that is not
     * editable and enabled.
     */
    TARGET_UNAVAILABLE("targetUnavailable"),

    /** An `ime_enter` found a valid target that does not list `ACTION_IME_ENTER`. */
    ACTION_UNAVAILABLE("actionUnavailable"),

    /** A gesture is still running. `dispatchGesture` would cancel it, so this one is refused. */
    BUSY("busy"),

    /**
     * A position is not normalized, a duration is out of range, a swipe goes nowhere on this
     * screen, or a text is too long or missing. Dart already validated what it could; this is the
     * boundary.
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
 * [activeWindow] is consulted for a `set_text` or an `ime_enter` and for nothing else: not when the
 * service connects, and not for a gesture or a global action.
 *
 * [longPressTimeoutMs] is `ViewConfiguration.getLongPressTimeout()`, read afresh for every long
 * press like the display, so a change in the user's touch-and-hold setting needs no signal
 * either. It is read for a long press and for nothing else. See [writeToInputFocus] and
 * [imeEnterOnInputFocus].
 *
 * Pure, and main-thread only: the channel handler, the gesture callback and the service
 * lifecycle all run there.
 */
class RemoteGestureDispatcher(
    private val readDisplay: () -> ScreenCaptureGeometry,
    private val dispatch: (GestureStroke, (Boolean) -> Unit) -> Boolean,
    private val performGlobalAction: (Int) -> Boolean,
    private val activeWindow: () -> RemoteTextWindow?,
    private val longPressTimeoutMs: () -> Long,
) {
    private var running: Running? = null

    fun tap(normalizedX: Double, normalizedY: Double, answer: (RemoteGestureOutcome) -> Unit) =
        press(normalizedX, normalizedY, answer) { TAP_DURATION_MS }

    /**
     * A tap held for as long as this device takes to read it as a long press. The stroke is the
     * tap's, on the same pixel; only its duration differs. A timeout that cannot be used rejects
     * it before any gesture starts.
     */
    fun longPress(normalizedX: Double, normalizedY: Double, answer: (RemoteGestureOutcome) -> Unit) =
        press(normalizedX, normalizedY, answer) {
            longPressDurationMs(longPressTimeoutMs()) ?: error("long-press timeout out of range")
        }

    /**
     * One touch that stays where it lands. [durationMs] is asked only once the position is valid,
     * the screen has been read and nothing is running.
     */
    private fun press(
        normalizedX: Double,
        normalizedY: Double,
        answer: (RemoteGestureOutcome) -> Unit,
        durationMs: () -> Long,
    ) {
        perform(
            isValid = isNormalized(normalizedX) && isNormalized(normalizedY),
            answer = answer,
        ) { display ->
            GestureStroke(display.gesturePixel(normalizedX, normalizedY), null, durationMs())
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

    fun setText(text: String, answer: (RemoteGestureOutcome) -> Unit) {
        if (running != null) {
            answer(RemoteGestureOutcome.BUSY)
            return
        }
        if (text.length > MAX_TEXT_LENGTH) {
            answer(RemoteGestureOutcome.INVALID)
            return
        }
        answer(writeToInputFocus(activeWindow, text))
    }

    /** Like [setText], it waits for no gesture: one still running makes it [RemoteGestureOutcome.BUSY]. */
    fun imeEnter(answer: (RemoteGestureOutcome) -> Unit) {
        if (running != null) {
            answer(RemoteGestureOutcome.BUSY)
            return
        }
        answer(imeEnterOnInputFocus(activeWindow))
    }

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

        /** In UTF-16 code units, which is what both Kotlin and Dart count as a String's length. */
        const val MAX_TEXT_LENGTH = 4096
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

    fun longPress(normalizedX: Double, normalizedY: Double, answer: (RemoteGestureOutcome) -> Unit) {
        val current = dispatcher
        if (current == null) {
            answer(RemoteGestureOutcome.UNAVAILABLE)
            return
        }
        current.longPress(normalizedX, normalizedY, answer)
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

    fun setText(text: String, answer: (RemoteGestureOutcome) -> Unit) {
        val current = dispatcher
        if (current == null) {
            answer(RemoteGestureOutcome.UNAVAILABLE)
            return
        }
        current.setText(text, answer)
    }

    fun imeEnter(answer: (RemoteGestureOutcome) -> Unit) {
        val current = dispatcher
        if (current == null) {
            answer(RemoteGestureOutcome.UNAVAILABLE)
            return
        }
        current.imeEnter(answer)
    }
}
