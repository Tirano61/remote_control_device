package com.example.remote_control_device

/**
 * One stroke of a touch held across several gestures, as `GestureDescription.StrokeDescription`
 * will receive it: a path from [from] to [to] (one point when they are equal), taking [durationMs].
 *
 * Every stroke after the first is `previous.continueStroke(...)` on the Android side; [Kind]
 * says which of them it is and whether it keeps the pointer down when its gesture completes.
 * See "A touch held across strokes" in `docs/webrtc/CONTROL_CHANNEL.md`.
 */
data class TouchSegment(
    val from: GesturePixel,
    val to: GesturePixel,
    val durationMs: Long,
    val kind: Kind,
) {
    enum class Kind(val continuesPrevious: Boolean, val willContinue: Boolean) {
        /** The finger goes down and stays down: a new stroke, `willContinue = true`. */
        DOWN(continuesPrevious = false, willContinue = true),

        /** The finger moves and stays down. */
        MOVE(continuesPrevious = true, willContinue = true),

        /** The finger goes to [to] and is lifted there: Android's `ACTION_UP`. */
        RELEASE(continuesPrevious = true, willContinue = false),

        /**
         * Not a stroke Android will play. A continuation that deliberately does not start where
         * the finger is, so that Android refuses it and cancels the finger. See
         * [RemoteTouchController.cancelContinuedStrokeViaMismatch].
         */
        CANCEL_VIA_MISMATCH(continuesPrevious = true, willContinue = false),
    }
}

/**
 * Time, and things to do later. On the device, `SystemClock.uptimeMillis` and a main-thread
 * `Handler`, which is where every callback of a touch arrives; in tests, a clock the test moves.
 */
interface TouchClock {
    fun now(): Long

    /** Runs [action] on the main thread after [delayMs]. What it returns cancels that. */
    fun schedule(delayMs: Long, action: () -> Unit): () -> Unit
}

/**
 * What a touch needs from Android besides the display: whether continued strokes exist on this
 * version (Android 8.0, API 26), the way to dispatch one, and a clock.
 *
 * [dispatch] answers whether Android accepted the stroke, and reports later, never from inside the
 * call, whether its gesture completed.
 */
class RemoteTouchPort(
    val continuedStrokesSupported: Boolean,
    val dispatch: (TouchSegment, (Boolean) -> Unit) -> Boolean,
    val clock: TouchClock,
)

/** What became of a touch, or of one step of it. [wire] is what crosses the channel to Dart. */
enum class RemoteTouchOutcome(val wire: String) {
    /** The finger is still down and has been down for longer than the long-press timeout. */
    HELD("held"),

    /** The position was taken. Not that the finger is there yet. */
    ACCEPTED("accepted"),

    /** The final stroke completed: Android received the end of the contact. */
    COMPLETED("completed"),

    /** The touch is over: cancelled, or already gone. */
    CANCELLED("cancelled"),

    /** The touch this names cannot go on, or does not exist. */
    ENDED("ended"),

    /** Android refused the first stroke, or something it needed could not be read. */
    REJECTED("rejected"),

    /** Another gesture or another touch is running. */
    BUSY("busy"),

    /** A position that is not normalized. */
    INVALID("invalid"),

    /** Continued strokes do not exist below Android 8.0. */
    UNSUPPORTED("unsupported"),

    /** The accessibility service is not connected. */
    UNAVAILABLE("unavailable"),
}

/** Why a touch ended. For the log, never for the wire. */
enum class TouchEndReason(val log: String) {
    RELEASED("released"),
    CANCELLED("cancel"),
    WATCHDOG("watchdog"),
    LIFETIME("lifetime"),
    GEOMETRY("geometry"),
    ANDROID("android"),
    REJECTED("rejected"),
    SEQUENCE("sequence"),
    INVALID("invalid"),
    ABANDONED("abandoned"),
}

/** Where a moving stroke's duration comes from: the time between the two positions it joins. */
fun touchSegmentDurationMs(elapsedMs: Long): Long =
    elapsedMs.coerceIn(MIN_TOUCH_SEGMENT_MS, MAX_TOUCH_SEGMENT_MS)

/** Never zero, which Android refuses, and about one frame. */
const val MIN_TOUCH_SEGMENT_MS = 16L

/** The furthest the finger is ever behind the latest position it was given. */
const val MAX_TOUCH_SEGMENT_MS = 100L

/**
 * The first stroke, and a release on the spot. The first stroke's duration changes nothing: a
 * point that does not move and continues produces its `ACTION_DOWN` and no other event.
 */
const val STATIONARY_TOUCH_SEGMENT_MS = 16L

/** Without a valid message for this long, the sender is gone and the finger is taken away. */
const val TOUCH_WATCHDOG_MS = 1000L

/** No remote touch lasts longer than this, keepalives or not. */
const val MAX_TOUCH_LIFETIME_MS = 30_000L

/**
 * A pixel one away from [held], on every one of [screens], or `null` if there is none.
 *
 * Right first, then left, then down, then up, so a finger on any edge or corner still has one.
 */
fun mismatchPixelBeside(held: GesturePixel, screens: List<ScreenCaptureGeometry>): GesturePixel? =
    listOf(
        GesturePixel(held.x + 1, held.y),
        GesturePixel(held.x - 1, held.y),
        GesturePixel(held.x, held.y + 1),
        GesturePixel(held.x, held.y - 1),
    ).firstOrNull { pixel ->
        screens.all { pixel.x in 0 until it.width && pixel.y in 0 until it.height }
    }

/**
 * At most one remote touch: one Android pointer kept down across several `dispatchGesture` calls,
 * from `ACTION_DOWN` to `ACTION_UP` or `ACTION_CANCEL`.
 *
 * ```text
 * (none) --start--> PRESSING --hold--> HELD <--> MOVING
 *                       |                 \        |
 *                       +-----------------> RELEASING --> (none)
 *        any of them --cancel--> CANCELLING --> (none)
 * ```
 *
 * The rules that make it one contact and not several:
 * - each continuation starts at [Touch.current], the last pixel actually handed to Android;
 * - at most one stroke is in flight, and at most one position waits for it: the latest;
 * - a continuation that would not move is never dispatched (Android reports it cancelled and
 *   leaves the pointer down);
 * - the hold is a timer started when the first stroke completes, because that stroke completes
 *   as soon as its `ACTION_DOWN` is out.
 *
 * Every Android callback is checked against the stroke it belongs to, so a report about a stroke
 * that has been superseded, or about a touch that has ended, changes nothing.
 *
 * Pure, and main-thread only, like [RemoteGestureDispatcher].
 */
class RemoteTouchController(
    private val port: RemoteTouchPort?,
    private val readDisplay: () -> ScreenCaptureGeometry,
    private val longPressTimeoutMs: () -> Long,
    private val isGestureRunning: () -> Boolean,
    private val onEnded: (Int) -> Unit,
    private val log: (String) -> Unit,
) {
    private enum class Phase { PRESSING, HELD, MOVING, RELEASING, CANCELLING }

    private class PendingRelease(
        val pixel: GesturePixel,
        val arrivedAt: Long,
        val answer: (RemoteTouchOutcome) -> Unit,
    )

    private class Touch(
        val handle: Int,
        val geometry: ScreenCaptureGeometry,
        /** The last pixel handed to Android: where every continuation starts. */
        var current: GesturePixel,
        val holdMs: Long,
        /** When the latest position that became a stroke arrived. */
        var referenceAt: Long,
        var holdAnswer: ((RemoteTouchOutcome) -> Unit)?,
    ) {
        var phase = Phase.PRESSING
        var held = false
        var lastSeq = 0L

        /** Whether the last stroke Android accepted keeps the pointer down. */
        var continuable = false

        var target: GesturePixel? = null
        var targetAt = 0L
        var release: PendingRelease? = null
        var releaseAnswer: ((RemoteTouchOutcome) -> Unit)? = null
        val cancelAnswers = mutableListOf<(RemoteTouchOutcome) -> Unit>()

        var strokes = 0
        var inFlight: Int? = null
        var movingLogged = false

        var holdTimer: (() -> Unit)? = null
        var watchdog: (() -> Unit)? = null
        var lifetime: (() -> Unit)? = null
    }

    private var touch: Touch? = null

    val isActive: Boolean get() = touch != null

    fun start(handle: Int, normalizedX: Double, normalizedY: Double, answer: (RemoteTouchOutcome) -> Unit) {
        val port = port
        if (port == null || !port.continuedStrokesSupported) {
            answer(RemoteTouchOutcome.UNSUPPORTED)
            return
        }
        if (touch != null || isGestureRunning()) {
            answer(RemoteTouchOutcome.BUSY)
            return
        }
        if (!inUnit(normalizedX) || !inUnit(normalizedY)) {
            answer(RemoteTouchOutcome.INVALID)
            return
        }

        val holdMs: Long
        val display: ScreenCaptureGeometry
        val pixel: GesturePixel
        try {
            holdMs = longPressDurationMs(longPressTimeoutMs()) ?: error("long-press timeout out of range")
            display = readDisplay()
            pixel = display.gesturePixel(normalizedX, normalizedY)
        } catch (_: Exception) {
            answer(RemoteTouchOutcome.REJECTED)
            return
        }

        val started = Touch(handle, display, pixel, holdMs, port.clock.now(), answer)
        touch = started
        val accepted = dispatch(
            started,
            TouchSegment(pixel, pixel, STATIONARY_TOUCH_SEGMENT_MS, TouchSegment.Kind.DOWN),
        ) { completed -> onDown(started, completed) }
        if (!accepted) {
            // Nothing went down, so there is nothing to cancel and nobody else to tell.
            touch = null
            started.answerHold(RemoteTouchOutcome.REJECTED)
            return
        }
        started.watchdog = port.clock.schedule(TOUCH_WATCHDOG_MS) { end(started, TouchEndReason.WATCHDOG) }
        started.lifetime = port.clock.schedule(MAX_TOUCH_LIFETIME_MS) { end(started, TouchEndReason.LIFETIME) }
        log("touch $handle started")
    }

    /**
     * Records where the finger should go. It goes there at once if the hold is over and nothing is
     * in flight; otherwise the position waits, replacing any older one.
     */
    fun move(handle: Int, seq: Long, normalizedX: Double, normalizedY: Double): RemoteTouchOutcome {
        val current = touch
        if (current == null || current.handle != handle) return RemoteTouchOutcome.ENDED
        if (current.isFinishing) return RemoteTouchOutcome.ENDED
        val pixel = acceptFollowUp(current, seq, normalizedX, normalizedY) ?: return RemoteTouchOutcome.ENDED
        refreshWatchdog(current)

        current.target = pixel
        current.targetAt = clock().now()
        if (current.isIdle) advance(current)
        return if (touch === current) RemoteTouchOutcome.ACCEPTED else RemoteTouchOutcome.ENDED
    }

    /**
     * Lifts the finger at a position, once the hold is over and nothing is in flight. [answer]
     * gets [RemoteTouchOutcome.COMPLETED] when Android reports the final stroke completed.
     *
     * Nothing else is expected from the sender after this, so the watchdog stops: a release that
     * waits for a long hold to end is not silence.
     */
    fun release(
        handle: Int,
        seq: Long,
        normalizedX: Double,
        normalizedY: Double,
        answer: (RemoteTouchOutcome) -> Unit,
    ) {
        val current = touch
        if (current == null || current.handle != handle || current.isFinishing) {
            answer(RemoteTouchOutcome.ENDED)
            return
        }
        val pixel = acceptFollowUp(current, seq, normalizedX, normalizedY)
        if (pixel == null) {
            answer(RemoteTouchOutcome.ENDED)
            return
        }
        current.watchdog?.invoke()
        current.watchdog = null

        current.release = PendingRelease(pixel, clock().now(), answer)
        if (current.isIdle) advance(current)
    }

    /**
     * Takes the finger away: `ACTION_CANCEL`, never `ACTION_UP`. [answer] gets
     * [RemoteTouchOutcome.CANCELLED] once Android has reported it, or at once if there is no
     * such touch, which is the same outcome: it is not there.
     *
     * A final stroke already in flight cannot be refused: the cancel waits for it.
     */
    fun cancel(handle: Int, answer: (RemoteTouchOutcome) -> Unit) {
        val current = touch
        if (current == null || current.handle != handle) {
            answer(RemoteTouchOutcome.CANCELLED)
            return
        }
        current.cancelAnswers += answer
        when (current.phase) {
            Phase.CANCELLING, Phase.RELEASING -> Unit
            Phase.PRESSING, Phase.HELD, Phase.MOVING -> beginCancel(current)
        }
    }

    /** The touch [handle] ends here, without waiting for anything. Nothing if it is not running. */
    fun abandon(handle: Int) {
        val current = touch ?: return
        if (current.handle == handle) end(current, TouchEndReason.ABANDONED)
    }

    /** Whatever touch is running ends here, without waiting for anything. */
    fun abandon() {
        touch?.let { end(it, TouchEndReason.ABANDONED) }
    }

    // ------------------------------------------------------------------ steps

    private fun onDown(started: Touch, completed: Boolean) {
        if (!completed) {
            end(started, TouchEndReason.ANDROID)
            return
        }
        // The ACTION_DOWN is out and nothing else will come from that stroke: the hold is timed
        // from here.
        started.holdTimer = clock().schedule(started.holdMs) { onHoldElapsed(started) }
    }

    private fun onHoldElapsed(started: Touch) {
        if (touch !== started) return
        started.holdTimer = null
        if (!isSameScreen(started)) {
            end(started, TouchEndReason.GEOMETRY)
            return
        }
        started.held = true
        started.phase = Phase.HELD
        log("touch ${started.handle} held")
        started.answerHold(RemoteTouchOutcome.HELD)
        if (touch === started) advance(started)
    }

    /** Hold over and nothing in flight: the waiting release, the waiting position, or rest. */
    private fun advance(current: Touch) {
        val release = current.release
        if (release != null) {
            dispatchRelease(current, release)
            return
        }
        val target = current.target
        current.target = null
        if (target != null && target != current.current) {
            dispatchMove(current, target)
            return
        }
        current.phase = Phase.HELD
    }

    private fun dispatchMove(current: Touch, target: GesturePixel) {
        val duration = touchSegmentDurationMs(current.targetAt - current.referenceAt)
        current.referenceAt = current.targetAt
        current.phase = Phase.MOVING
        if (!current.movingLogged) {
            current.movingLogged = true
            log("touch ${current.handle} moving seq=${current.lastSeq}")
        }
        val accepted = dispatch(
            current,
            TouchSegment(current.current, target, duration, TouchSegment.Kind.MOVE),
        ) { completed ->
            if (completed) advance(current) else end(current, TouchEndReason.ANDROID)
        }
        if (!accepted) end(current, TouchEndReason.REJECTED)
    }

    private fun dispatchRelease(current: Touch, release: PendingRelease) {
        current.release = null
        current.releaseAnswer = release.answer
        current.phase = Phase.RELEASING
        val duration = if (release.pixel == current.current) {
            // On the spot: one point, willContinue = false, which Android ends with ACTION_UP.
            STATIONARY_TOUCH_SEGMENT_MS
        } else {
            touchSegmentDurationMs(release.arrivedAt - current.referenceAt)
        }
        val accepted = dispatch(
            current,
            TouchSegment(current.current, release.pixel, duration, TouchSegment.Kind.RELEASE),
        ) { completed ->
            if (completed) {
                finish(current, TouchEndReason.RELEASED, RemoteTouchOutcome.COMPLETED)
            } else {
                finish(current, TouchEndReason.ANDROID, RemoteTouchOutcome.ENDED)
            }
        }
        if (!accepted) end(current, TouchEndReason.REJECTED)
    }

    private fun beginCancel(current: Touch) {
        current.phase = Phase.CANCELLING
        current.target = null
        current.cancelTimers(keepLifetime = true)
        current.answerHold(RemoteTouchOutcome.ENDED)
        current.release?.answer?.invoke(RemoteTouchOutcome.ENDED)
        current.release = null
        val dispatched = current.continuable &&
            cancelContinuedStrokeViaMismatch(current) {
                finish(current, TouchEndReason.CANCELLED, RemoteTouchOutcome.ENDED)
            }
        if (!dispatched) finish(current, TouchEndReason.CANCELLED, RemoteTouchOutcome.ENDED)
    }

    /**
     * Cancels the pointer [current] keeps down, by asking Android for something it refuses.
     *
     * **There is no public API that cancels a continued stroke.** This dispatches a continuation of
     * the last stroke that starts one pixel away from where that stroke ended, which breaks the
     * documented precondition of `StrokeDescription.continueStroke` on purpose. Android refuses it,
     * and refusing it sends one `ACTION_CANCEL` for the pointer, drops whatever of its strokes had
     * not been played yet, and reports this gesture cancelled. No `ACTION_DOWN`, no `ACTION_UP`.
     *
     * That behaviour is required of every compatible device by CTS:
     * `AccessibilityGestureDispatchTest#testContinuedGesture_withLineDisconnect_isCancelled`
     * (`cts/tests/accessibilityservice`), which asserts exactly one event, `ACTION_CANCEL`. The
     * code that does it is `MotionEventInjector.prepareToContinueOldGesture` and
     * `cancelAnyPendingInjectedEvents`.
     *
     * Used for cancelling a touch and for nothing else. Provisional until it has been seen on the
     * tablet: what a JVM test can show is which stroke is asked for, not what Android does with it.
     */
    private fun cancelContinuedStrokeViaMismatch(current: Touch, onResult: (Boolean) -> Unit): Boolean {
        val screens = listOfNotNull(current.geometry, readDisplayOrNull())
        val beside = mismatchPixelBeside(current.current, screens) ?: return false
        return dispatch(
            current,
            TouchSegment(beside, beside, STATIONARY_TOUCH_SEGMENT_MS, TouchSegment.Kind.CANCEL_VIA_MISMATCH),
            onResult,
        )
    }

    // ------------------------------------------------------------- endings

    /** The touch ended as it should: released, or cancelled and confirmed by Android. */
    private fun finish(current: Touch, reason: TouchEndReason, releaseOutcome: RemoteTouchOutcome) {
        if (touch !== current) return
        touch = null
        current.cancelTimers(keepLifetime = false)
        current.answerAll(releaseOutcome)
        log("touch ${current.handle} ${if (reason == TouchEndReason.RELEASED) "released" else "cancelled reason=${reason.log}"}")
        onEnded(current.handle)
    }

    /**
     * The touch ends now, without waiting for Android: the session or the channel went away, the
     * sender went quiet, the screen changed, or Android cancelled or refused a stroke. If the
     * pointer may still be down, it is cancelled on the way out, and nobody waits for that.
     */
    private fun end(current: Touch, reason: TouchEndReason) {
        if (touch !== current) return
        touch = null
        current.cancelTimers(keepLifetime = false)
        if (current.continuable) {
            current.inFlight = null
            cancelContinuedStrokeViaMismatch(current) { }
        }
        current.answerAll(RemoteTouchOutcome.ENDED)
        log("touch ${current.handle} cancelled reason=${reason.log}")
        onEnded(current.handle)
    }

    // ------------------------------------------------------------ plumbing

    /**
     * A follow-up from the sender, checked against the touch: its [seq] must be greater than the
     * last one, its position normalized, and the screen the one the touch started on. Anything
     * else ends the touch. The pixel it names, or `null` if it ended.
     */
    private fun acceptFollowUp(current: Touch, seq: Long, normalizedX: Double, normalizedY: Double): GesturePixel? {
        if (seq <= current.lastSeq) {
            end(current, TouchEndReason.SEQUENCE)
            return null
        }
        if (!inUnit(normalizedX) || !inUnit(normalizedY)) {
            end(current, TouchEndReason.INVALID)
            return null
        }
        if (!isSameScreen(current)) {
            end(current, TouchEndReason.GEOMETRY)
            return null
        }
        current.lastSeq = seq
        return current.geometry.gesturePixel(normalizedX, normalizedY)
    }

    /**
     * Hands [segment] to Android. Its report reaches [onResult] only while it is still the stroke
     * in flight of a touch that is still running. [Touch.current] moves only once Android has
     * accepted the stroke, because a continuation has to start where the last accepted one ended.
     */
    private fun dispatch(current: Touch, segment: TouchSegment, onResult: (Boolean) -> Unit): Boolean {
        val port = port ?: return false
        val stroke = ++current.strokes
        current.inFlight = stroke
        val accepted = try {
            port.dispatch(segment) { completed ->
                if (touch === current && current.inFlight == stroke) {
                    current.inFlight = null
                    onResult(completed)
                }
            }
        } catch (_: Exception) {
            false
        }
        if (!accepted) {
            if (current.inFlight == stroke) current.inFlight = null
            return false
        }
        if (segment.kind != TouchSegment.Kind.CANCEL_VIA_MISMATCH) current.current = segment.to
        current.continuable = segment.kind.willContinue
        return true
    }

    private fun refreshWatchdog(current: Touch) {
        current.watchdog?.invoke()
        current.watchdog = clock().schedule(TOUCH_WATCHDOG_MS) { end(current, TouchEndReason.WATCHDOG) }
    }

    private fun isSameScreen(current: Touch): Boolean = readDisplayOrNull() == current.geometry

    private fun readDisplayOrNull(): ScreenCaptureGeometry? = try {
        readDisplay()
    } catch (_: Exception) {
        null
    }

    private fun clock(): TouchClock = port!!.clock

    private val Touch.isFinishing: Boolean
        get() = phase == Phase.RELEASING || phase == Phase.CANCELLING || release != null

    /** Hold over, and nothing in flight: the next step can go at once. */
    private val Touch.isIdle: Boolean
        get() = held && inFlight == null && phase != Phase.RELEASING && phase != Phase.CANCELLING

    private fun Touch.answerHold(outcome: RemoteTouchOutcome) {
        val answer = holdAnswer ?: return
        holdAnswer = null
        answer(outcome)
    }

    /** Every answer still owed, once each: the hold, the release, and the cancels. */
    private fun Touch.answerAll(releaseOutcome: RemoteTouchOutcome) {
        answerHold(RemoteTouchOutcome.ENDED)
        release?.answer?.invoke(RemoteTouchOutcome.ENDED)
        release = null
        releaseAnswer?.let {
            releaseAnswer = null
            it(releaseOutcome)
        }
        val cancels = cancelAnswers.toList()
        cancelAnswers.clear()
        cancels.forEach { it(RemoteTouchOutcome.CANCELLED) }
    }

    private fun Touch.cancelTimers(keepLifetime: Boolean) {
        holdTimer?.invoke()
        holdTimer = null
        watchdog?.invoke()
        watchdog = null
        if (!keepLifetime) {
            lifetime?.invoke()
            lifetime = null
        }
    }

    private fun inUnit(value: Double): Boolean = value in 0.0..1.0
}
