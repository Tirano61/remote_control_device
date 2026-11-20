package com.example.remote_control_device

/**
 * The one running screen capture, and the rule for what happens when Android ends it by itself.
 *
 * MediaProjection's `onStop` is the platform taking the screen away: the user pressed *Stop
 * sharing* in the system controls, or another projection took over. Dart owns the decision
 * about what that means for the assistance (control withdrawn, peer closed) and has to hear
 * about it. Before this class it did not: the capturer released itself and Dart went on
 * believing the screen was shared.
 *
 * What it guarantees:
 *
 * ```text
 * a platform stop of the capture that is running   -> released, reported once
 * a platform stop of a capture already replaced    -> nothing (a late callback)
 * a platform stop after the app stopped it itself  -> nothing (not news to Dart)
 * a second platform stop of the same capture       -> nothing
 * ```
 *
 * Pure bookkeeping, with no Android type in it, so the JVM tests can reach it. Every method is
 * called on the main thread: the projection's callback is posted there before it gets here.
 */
class RunningScreenCapture<S : Any>(
    private val trackIdOf: (S) -> String,
    private val release: (S) -> Unit,
) {
    private var running: S? = null

    val current: S?
        get() = running

    /** A new capture is running. One at a time: a previous one is released first. */
    fun started(session: S) {
        stop()
        running = session
    }

    /**
     * The application stops the capture. With a [trackId], only if it is that capture: a late
     * stop for a capture that was already replaced must not take down its replacement.
     */
    fun stop(trackId: String? = null) {
        val session = running ?: return
        if (trackId != null && trackIdOf(session) != trackId) return
        running = null
        release(session)
    }

    /**
     * Runs [action] on the running capture if it is the one with [trackId], and returns its
     * result; null when there is no capture or it is another one. A late message about a capture
     * that was already replaced must never reach its replacement.
     */
    fun <R> ifRunning(trackId: String, action: (S) -> R): R? {
        val session = running ?: return null
        if (trackIdOf(session) != trackId) return null
        return action(session)
    }

    /**
     * Android ended the capture with [trackId] by itself. Returns `true` when that is the
     * running capture — it has been released now, and Dart must be told — and `false` for
     * anything Dart already knows about.
     */
    fun stoppedByPlatform(trackId: String): Boolean {
        val session = running ?: return false
        if (trackIdOf(session) != trackId) return false
        running = null
        release(session)
        return true
    }
}
