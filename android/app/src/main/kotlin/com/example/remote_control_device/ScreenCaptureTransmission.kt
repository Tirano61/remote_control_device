package com.example.remote_control_device

/** One switch of [ScreenCaptureTransmission], with what happened since the previous one. */
internal data class TransmissionChange(
    /** What the gate is now. */
    val transmitting: Boolean,
    /** Frames let through to WebRTC since the previous switch. */
    val admittedBefore: Long,
    /** Frames the capture produced and the closed gate kept back since the previous switch. */
    val withheldBefore: Long,
    /**
     * Whether the frame on screen now has to be delivered again: the gate opened on a capture
     * that has produced at least one frame, and a still screen produces no next one.
     */
    val refresh: Boolean,
    /** Frames kept back because the gate was open but its lease had run out. */
    val expiredBefore: Long = 0,
)

/**
 * How long the frames of an open gate may go on reaching WebRTC: until [deadlineNanos], on the
 * elapsed-realtime clock (`SystemClock.elapsedRealtimeNanos`, `CLOCK_BOOTTIME`).
 *
 * [evidenceAtNanos] is when Dart observed the newest heartbeat evidence of the `/devices`
 * connection — a `PING`, or the connection coming up — read by Dart from the same clock, not
 * when the message carrying it reached this side. So a message that arrives late carries an old
 * instant and buys no time; see [ScreenCaptureTransmission.renew].
 */
internal data class TransmissionLease(
    /** The opening this lease belongs to. Dart numbers them; never reused. */
    val grant: Long,
    val evidenceAtNanos: Long,
    val validForNanos: Long,
) {
    val deadlineNanos: Long = evidenceAtNanos + validForNanos
}

/** What became of one frame at the gate. */
internal enum class FrameAdmission {
    /** It goes on to WebRTC. */
    ADMITTED,

    /** The gate is closed. */
    WITHHELD_CLOSED,

    /** The gate is open, and the first frame since its lease ran out. Logged, once per lease. */
    WITHHELD_LEASE_RAN_OUT,

    /** The gate is open and its lease has run out. */
    WITHHELD_EXPIRED,

    /** The capture is over. */
    STOPPED,
}

/** The answer to an opening. */
internal enum class LeaseVerdict {
    /** Open, and its lease has time left. */
    LIVE,

    /** Open, but the evidence it was opened with is already too old: nothing goes through. */
    EXPIRED,

    /**
     * Not opened at all: the lease made no sense here — evidence from this clock's future, a
     * validity outside [ScreenCaptureTransmission.MAX_VALIDITY_NANOS]. The gate is closed.
     */
    REJECTED,
}

internal data class TransmissionOpening(
    /** The switch, or null when the gate was already open (a new grant replaced the lease). */
    val change: TransmissionChange?,
    val verdict: LeaseVerdict,
    /** How old the evidence was when the opening arrived. Negative for one from the future. */
    val evidenceAgeNanos: Long,
)

internal enum class RenewalOutcome {
    /** The lease now runs from this evidence. */
    RENEWED,

    /**
     * The evidence came after the lease had already run out: there was a gap of at least its
     * validity with no evidence at all. Nothing is renewed, and nothing can renew this grant
     * any more — every later evidence is later still. Only a new opening, which Dart makes only
     * after the authority was confirmed again, lets frames through again.
     */
    LAPSED,

    /**
     * Not about the lease that holds: the gate is closed, the capture is over, the grant is an
     * older one, or the evidence is not newer than what the lease already runs from. A late or
     * repeated message, with nothing to report.
     */
    IGNORED,

    /** Evidence from this clock's future, or a validity that is not the grant's. Not applied. */
    REJECTED,
}

internal data class TransmissionRenewal(
    val outcome: RenewalOutcome,
    /** Whether frames go through right now, after this renewal. */
    val live: Boolean,
    /**
     * The lease had run out and this renewal revived it — the evidence came in time, its
     * message did not — so frames were kept back meanwhile and the screen as it is now has to
     * be delivered again.
     */
    val refresh: Boolean = false,
    val evidenceAgeNanos: Long = 0,
    /** Time left on the lease that holds after this call; negative once it has run out. */
    val remainingNanos: Long = 0,
)

/**
 * Whether the frames a running capture produces may reach WebRTC at all.
 *
 * The capture and its transmission are two different things, and this is where they part:
 *
 * ```text
 * MediaProjection -> virtual display -> SurfaceTexture -> onFrame -> [gate] -> encoder -> peer
 * ```
 *
 * Closed, the capture keeps running — the projection, the user's consent and the notification
 * are all still there — and nothing it produces leaves the device: no frame reaches the video
 * source, so no encoder, sender or peer connection has anything to send, whichever peer the
 * track is attached to. Not a black frame either, which is what disabling the `VideoTrack`
 * would give (libwebrtc's `VideoBroadcaster` turns every frame of a disabled track into a black
 * one of the same size, so the technician would still see when the screen changes).
 *
 * ## Two conditions
 *
 * A frame goes through only when both hold at the moment it arrives:
 *
 * ```text
 * open      Dart opened the gate for the remote session whose authority it has confirmed
 * lease     the heartbeat evidence that opening was given, or a renewal of it, is younger
 *           than its validity — read here, from this side's own clock, for every frame
 * ```
 *
 * The first one is Dart's decision, as it has been since Prompt 40. The second one is what
 * Prompt 43 adds: it does not need Dart to run. If the isolate is blocked, suspended or behind
 * on its timers, the heartbeat watchdog cannot close the gate — but the lease runs out on its
 * own, here, and every frame after that is kept back without any message from Dart.
 *
 * The lease grants nothing. It can only take away what the opening gave: a renewal never opens
 * a closed gate, never revives a lease that ran out because the evidence stopped, and never
 * reaches a newer opening (see [renew]).
 *
 * ## Clock
 *
 * [clock] is `SystemClock.elapsedRealtimeNanos()` in the application: `CLOCK_BOOTTIME`, which
 * the user cannot set and which keeps counting in deep sleep. Dart stamps its evidence from the
 * same kernel clock, so an instant crosses the channel as it was read, and the channel's delay
 * does not move it. An instant from this clock's future means the two do not agree, and is
 * refused: the gate stays shut, the safe direction.
 *
 * ## Threads
 *
 * [admit] runs on the `SurfaceTextureHelper`'s thread for every frame and takes no lock: it reads
 * one volatile snapshot and the clock. Every change — [open], [close], [renew], [stop] — replaces
 * the snapshot under one lock, so changes made from different threads apply one after another
 * and a frame sees either the old snapshot or the new one, whole. Openings and closings are made
 * on the helper's thread ([ScreenCapturer.openTransmission] waits for that), so a frame already
 * being processed there finishes before they apply; renewals may arrive from any thread.
 *
 * Pure bookkeeping, no Android type, so the JVM tests reach it.
 */
internal class ScreenCaptureTransmission(private val clock: () -> Long) {

    private class Gate(
        val stopped: Boolean,
        /** The newest grant ever opened here. An opening must be newer still. */
        val highestGrant: Long,
        /** Null while closed. */
        val lease: TransmissionLease?,
    )

    @Volatile private var gate = Gate(stopped = false, highestGrant = 0, lease = null)
    private val lock = Any()

    // Counters for the log only; never a decision. Volatile is enough for them: a count read
    // a frame late is still a count.
    @Volatile private var frameArrived = false
    @Volatile private var admitted = 0L
    @Volatile private var withheld = 0L
    @Volatile private var expired = 0L

    /** The lease whose running out was already reported by [admit]. */
    @Volatile private var expiryReported: TransmissionLease? = null

    /** Whether the gate is open. Says nothing about its lease; see [isLive]. */
    val transmitting: Boolean
        get() = gate.let { !it.stopped && it.lease != null }

    /** The lease that holds, or null while closed. */
    val lease: TransmissionLease?
        get() = gate.let { if (it.stopped) null else it.lease }

    /** Whether a frame arriving now would go through. */
    fun isLive(): Boolean {
        val lease = lease ?: return false
        return clock() - lease.deadlineNanos < 0
    }

    /**
     * A frame arrived from the capture. Lock-free: one volatile read and the clock.
     *
     * Only ever called from the helper's thread, so the counters it bumps have one writer.
     */
    fun admit(): FrameAdmission {
        val gate = gate
        if (gate.stopped) return FrameAdmission.STOPPED
        frameArrived = true
        val lease = gate.lease
        if (lease == null) {
            withheld++
            return FrameAdmission.WITHHELD_CLOSED
        }
        // Compared as a difference, not as two instants: correct across an overflow.
        if (clock() - lease.deadlineNanos >= 0) {
            expired++
            if (expiryReported !== lease) {
                expiryReported = lease
                return FrameAdmission.WITHHELD_LEASE_RAN_OUT
            }
            return FrameAdmission.WITHHELD_EXPIRED
        }
        admitted++
        return FrameAdmission.ADMITTED
    }

    /**
     * Opens the gate for [grant], with a lease from [evidenceAtNanos] for [validForNanos].
     *
     * Returns null — nothing applied — when the capture is stopped or [grant] is not newer than
     * every grant opened before: a late or repeated opening must never undo a later closing.
     * An opening that makes no sense ([LeaseVerdict.REJECTED]) leaves the gate closed.
     */
    fun open(grant: Long, evidenceAtNanos: Long, validForNanos: Long): TransmissionOpening? =
        synchronized(lock) {
            val current = gate
            if (current.stopped || grant <= current.highestGrant) return null
            val now = clock()
            val age = now - evidenceAtNanos
            if (age < 0 || !isValidity(validForNanos)) {
                val change = switchTo(current, null, grant)
                return TransmissionOpening(change, LeaseVerdict.REJECTED, age)
            }
            val lease = TransmissionLease(grant, evidenceAtNanos, validForNanos)
            val change = switchTo(current, lease, grant)
            val verdict = if (now - lease.deadlineNanos < 0) LeaseVerdict.LIVE else LeaseVerdict.EXPIRED
            TransmissionOpening(change, verdict, age)
        }

    /** Closes the gate. Returns the change, or null when it was already closed or is stopped. */
    fun close(): TransmissionChange? = synchronized(lock) {
        val current = gate
        if (current.stopped || current.lease == null) return null
        switchTo(current, null, current.highestGrant)
    }

    /**
     * Fresh evidence for the opening [grant]: the lease runs from [evidenceAtNanos] from now on.
     *
     * The rule is about the evidence, never about when its message arrived:
     *
     * ```text
     * evidence before the lease ran out    RENEWED   the heartbeat never stopped for as long as
     *                                                its validity; frames go on, or resume if the
     *                                                message itself was late
     * evidence at or after it ran out      LAPSED    there was a gap with no evidence at all; the
     *                                                grant is over, Dart has to confirm again
     * ```
     *
     * A late message carries an old instant, so the deadline it gives is old too: it cannot buy
     * a moment the evidence does not cover. A renewal never opens a closed gate and never reaches
     * a newer opening, so revoking always wins over any renewal still on its way.
     */
    fun renew(grant: Long, evidenceAtNanos: Long, validForNanos: Long): TransmissionRenewal =
        synchronized(lock) {
            val current = gate
            val lease = current.lease
            val now = clock()
            if (current.stopped || lease == null || lease.grant != grant) {
                return TransmissionRenewal(RenewalOutcome.IGNORED, live = false)
            }
            val age = now - evidenceAtNanos
            val remaining = lease.deadlineNanos - now
            if (age < 0 || validForNanos != lease.validForNanos) {
                return TransmissionRenewal(RenewalOutcome.REJECTED, remaining > 0, false, age, remaining)
            }
            if (evidenceAtNanos - lease.evidenceAtNanos <= 0) {
                // Not newer than what the lease already runs from: nothing moves back.
                return TransmissionRenewal(RenewalOutcome.IGNORED, remaining > 0, false, age, remaining)
            }
            if (evidenceAtNanos - lease.deadlineNanos >= 0) {
                return TransmissionRenewal(RenewalOutcome.LAPSED, remaining > 0, false, age, remaining)
            }
            val renewed = TransmissionLease(grant, evidenceAtNanos, validForNanos)
            gate = Gate(current.stopped, current.highestGrant, renewed)
            val left = renewed.deadlineNanos - now
            val wasExpired = remaining <= 0
            TransmissionRenewal(
                RenewalOutcome.RENEWED,
                live = left > 0,
                refresh = wasExpired && left > 0 && frameArrived,
                evidenceAgeNanos = age,
                remainingNanos = left,
            )
        }

    /** The capture is over: closed for good, nothing reopens or renews it. Idempotent. */
    fun stop() = synchronized(lock) {
        val current = gate
        gate = Gate(stopped = true, highestGrant = current.highestGrant, lease = null)
    }

    /** Counters since the last switch, for the log. */
    fun admittedSinceSwitch(): Long = admitted

    private fun switchTo(current: Gate, lease: TransmissionLease?, grant: Long): TransmissionChange? {
        gate = Gate(current.stopped, maxOf(current.highestGrant, grant), lease)
        val wasOpen = current.lease != null
        val open = lease != null
        if (wasOpen == open) return null
        val change = TransmissionChange(
            transmitting = open,
            admittedBefore = admitted,
            withheldBefore = withheld,
            refresh = open && frameArrived,
            expiredBefore = expired,
        )
        admitted = 0
        withheld = 0
        expired = 0
        return change
    }

    private fun isValidity(validForNanos: Long) = validForNanos in 1..MAX_VALIDITY_NANOS

    companion object {
        /**
         * The longest lease accepted. Dart asks for `pingInterval + min(3 s, pingTimeout)`, 13 s
         * with the backend's 10/10; anything past this is not a heartbeat and is refused.
         */
        const val MAX_VALIDITY_NANOS = 120_000_000_000L
    }
}
