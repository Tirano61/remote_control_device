package com.example.remote_control_device

/**
 * The native mirror of whether a remote command may start right now.
 *
 * It is not a second authority. Dart decides, in `WebRtcSessionBloc`, from the C2 authority of the
 * remote session (`ACTIVE` and confirmed, the negotiation of that session, the screen not taken
 * away by Android), and tells this gate every time that answer changes: [open] with a numbered
 * grant when control becomes authorised, [close] the moment it stops being. Every command crosses
 * the channel stamped with the grant Dart sent it under, and is let through only while that very
 * grant is open ([admits]).
 *
 * What it adds to Dart's own check is what Dart cannot do from the other side of the channel:
 * - a command that reaches Android after the close, under any grant, is refused here;
 * - closing the gate is what cancels the gesture Android is playing (see
 *   [RemoteGestureDispatcher.revoke]), and what makes its late report say "revoked";
 * - a grant is never reused: an open with a grant not newer than the last one is refused, so a
 *   command of an older opening cannot run under a newer one;
 * - a session Dart reported as ended ([close] with `ended`) can never be opened again while this
 *   process lives, whatever Dart sends later.
 *
 * Unlike the screen's transmission lease ([ScreenCaptureTransmission]) it carries no expiry. A
 * frame is a continuous stream that must stop by itself if Dart stops vouching for it; a command
 * only exists because Dart sent it, so a Dart that has stopped (paused, stalled) sends none, and
 * what it sent before is bounded on this side: a gesture by its own duration (at most 4 s), a
 * remote touch by its 1 s watchdog. See "Native control gate" in `docs/remote_session/LIFECYCLE.md`.
 *
 * Pure, and main-thread only, like the dispatcher: the channel handler is its only caller.
 */
class RemoteControlGate {
    /** The grant in force, or `null` when the gate is closed. */
    var openGrant: Long? = null
        private set

    /** The session [openGrant] was given for. For the log, never for a decision. */
    var openSession: String? = null
        private set

    /** The newest grant ever opened since the last [reset]. */
    private var lastGrant = 0L

    /** Sessions Dart said are over. Only ever added to while the process lives. */
    private val ended = LinkedHashSet<String>()

    val isOpen: Boolean get() = openGrant != null

    /** Whether a command stamped with [grant] may start now. A missing grant never may. */
    fun admits(grant: Long?): Boolean = grant != null && grant == openGrant

    /**
     * Opens [grant] for [session]. Whatever was open before is closed first: its commands no longer
     * pass. The caller revokes what the old grant left running.
     */
    fun open(grant: Long, session: String): RemoteControlOpenOutcome {
        if (session in ended) return RemoteControlOpenOutcome.ENDED
        if (grant <= lastGrant) return RemoteControlOpenOutcome.STALE
        lastGrant = grant
        openGrant = grant
        openSession = session
        return RemoteControlOpenOutcome.OPENED
    }

    /**
     * Closes the gate and, with [endedSession], records that session as over for good. Answers the
     * grant that was open, or `null` if it was already closed. Idempotent.
     */
    fun close(endedSession: String? = null): Long? {
        if (endedSession != null) remember(endedSession)
        val was = openGrant
        openGrant = null
        openSession = null
        return was
    }

    /**
     * A new Flutter engine: its Dart numbers its grants from the start again. The gate closes and
     * forgets the numbering, never the sessions that ended.
     */
    fun reset(): Long? {
        val was = close()
        lastGrant = 0L
        return was
    }

    fun hasEnded(session: String): Boolean = session in ended

    private fun remember(session: String) {
        ended += session
        // A tablet has one assistance at a time; a long-lived process keeps the newest ones.
        while (ended.size > MAX_ENDED_REMEMBERED) ended.remove(ended.first())
    }

    private companion object {
        const val MAX_ENDED_REMEMBERED = 64
    }
}

/** What became of an opening. [wire] is what crosses the channel to Dart. */
enum class RemoteControlOpenOutcome(val wire: String) {
    OPENED("opened"),

    /** Not newer than a grant already opened: a message that was overtaken, or a bug. */
    STALE("stale"),

    /** The session was reported ended: it is never opened again in this process. */
    ENDED("ended"),
}

/**
 * What the dispatcher found when the gate closed. For the log and the tests: Dart has already been
 * told everything it needs ("revoked") by then.
 */
data class RemoteControlRevocation(
    /** A one-shot gesture (tap, long press, swipe) was being played by Android. */
    val gestureRunning: Boolean,
    /** Whether Android was asked to cancel it. `false` below Android 8.0, or if it refused. */
    val cancelRequested: Boolean,
    /** A remote touch was down, and has been let go. */
    val touchAbandoned: Boolean,
)
