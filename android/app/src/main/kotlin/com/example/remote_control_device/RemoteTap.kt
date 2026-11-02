package com.example.remote_control_device

/** A pixel of the screen as it is right now, always inside it. */
data class TapPixel(val x: Int, val y: Int)

/**
 * Where a normalized position lands on this screen.
 *
 * The frame the technician clicks on is the whole display, so `0..1` over the frame is `0..1`
 * over [ScreenCaptureGeometry.width] and [ScreenCaptureGeometry.height]. `1.0` would land one
 * past the last pixel, which is outside the screen, so it is mapped onto the last one.
 */
fun ScreenCaptureGeometry.tapPixel(normalizedX: Double, normalizedY: Double): TapPixel {
    require(isNormalized(normalizedX) && isNormalized(normalizedY)) { "not a normalized position" }
    return TapPixel(pixelOn(normalizedX, width), pixelOn(normalizedY, height))
}

private fun isNormalized(value: Double): Boolean = value in 0.0..1.0

private fun pixelOn(normalized: Double, size: Int): Int =
    (normalized * size).toInt().coerceAtMost(size - 1)

/** What became of a tap. [wire] is what crosses the channel to Dart. */
enum class RemoteTapOutcome(val wire: String) {
    /** Android reported the gesture completed. The only outcome that means it happened. */
    COMPLETED("completed"),

    /** Android cancelled it, or the service went away while it was running. */
    CANCELLED("cancelled"),

    /** `dispatchGesture` refused it, or the display could not be read. */
    REJECTED("rejected"),

    /** A gesture is still running. `dispatchGesture` would cancel it, so this one is refused. */
    BUSY("busy"),

    /** The position is not normalized. Dart already validated it; this is the boundary. */
    INVALID("invalid"),

    /** The accessibility service is not connected. */
    UNAVAILABLE("unavailable"),
}

/**
 * Runs one tap at a time and reports what really happened to it.
 *
 * The display is read afresh for every tap and never kept, so a rotation between two taps needs
 * no signal of its own: [readDisplay] is the same reading the screen capture crops with
 * ([ScreenCapturer.readDisplayGeometry]), which is what makes both describe one screen.
 *
 * [dispatch] answers whether Android accepted the gesture, and later reports through its second
 * argument whether it completed. Queueing is Dart's, because only Dart knows when a session
 * ends; a second tap here is refused, since `dispatchGesture` would otherwise cancel the first.
 *
 * Pure, and main-thread only: the channel handler, the gesture callback and the service
 * lifecycle all run there.
 */
class RemoteTapDispatcher(
    private val readDisplay: () -> ScreenCaptureGeometry,
    private val dispatch: (TapPixel, (Boolean) -> Unit) -> Boolean,
) {
    private var running: Running? = null

    fun tap(normalizedX: Double, normalizedY: Double, answer: (RemoteTapOutcome) -> Unit) {
        if (running != null) {
            answer(RemoteTapOutcome.BUSY)
            return
        }
        if (!isNormalized(normalizedX) || !isNormalized(normalizedY)) {
            answer(RemoteTapOutcome.INVALID)
            return
        }

        val pixel = try {
            readDisplay().tapPixel(normalizedX, normalizedY)
        } catch (_: Exception) {
            answer(RemoteTapOutcome.REJECTED)
            return
        }

        val tap = Running(answer)
        running = tap
        val accepted = try {
            dispatch(pixel) { completed ->
                settle(tap, if (completed) RemoteTapOutcome.COMPLETED else RemoteTapOutcome.CANCELLED)
            }
        } catch (_: Exception) {
            false
        }
        if (!accepted) settle(tap, RemoteTapOutcome.REJECTED)
    }

    /** The service is going away and will not report on the gesture it was running. */
    fun abandon() {
        running?.let { settle(it, RemoteTapOutcome.CANCELLED) }
    }

    /** Answers once: a late report about a tap already answered finds nothing to answer. */
    private fun settle(tap: Running, outcome: RemoteTapOutcome) {
        if (running !== tap) return
        running = null
        tap.answer(outcome)
    }

    private class Running(val answer: (RemoteTapOutcome) -> Unit)
}

/**
 * Whether the accessibility service is connected right now, and the way to it.
 *
 * Available means *connected*, which only Android can make true after the user enabled the
 * service in Settings. It authorises nothing: the service stays connected between assistances,
 * and whether a command may run is decided in Dart, against the remote session.
 */
class RemoteControlAvailability {
    private var dispatcher: RemoteTapDispatcher? = null

    /** Told about every change. Set while a Flutter engine is attached. */
    var onChanged: ((Boolean) -> Unit)? = null

    val isAvailable: Boolean get() = dispatcher != null

    fun connected(next: RemoteTapDispatcher) {
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

    fun tap(normalizedX: Double, normalizedY: Double, answer: (RemoteTapOutcome) -> Unit) {
        val current = dispatcher
        if (current == null) {
            answer(RemoteTapOutcome.UNAVAILABLE)
            return
        }
        current.tap(normalizedX, normalizedY, answer)
    }
}
