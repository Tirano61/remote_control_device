package com.example.remote_control_device

/** One switch of [ScreenCaptureTransmission], with what happened since the previous one. */
internal data class TransmissionChange(
    /** What the gate is now. */
    val transmitting: Boolean,
    /** Frames let through to WebRTC since the previous switch. */
    val admittedBefore: Long,
    /** Frames the capture produced and the gate kept back since the previous switch. */
    val withheldBefore: Long,
    /**
     * Whether the frame on screen now has to be delivered again: the gate opened on a capture
     * that has produced at least one frame, and a still screen produces no next one.
     */
    val refresh: Boolean,
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
 * A capture starts **closed**. Dart opens it only for a remote session whose authority is
 * confirmed, and closes it the moment that stops being true; see `WebRtcSessionBloc`.
 *
 * Pure bookkeeping, no Android type, so the JVM tests reach it. Not synchronised: every call
 * comes from the `SurfaceTextureHelper`'s thread, which is where [ScreenCapturer] runs it.
 */
internal class ScreenCaptureTransmission {
    var transmitting = false
        private set

    private var stopped = false
    private var frameArrived = false
    private var admitted = 0L
    private var withheld = 0L

    /** A frame arrived from the capture. Returns whether it may go on to WebRTC. */
    fun admit(): Boolean {
        if (stopped) return false
        frameArrived = true
        if (!transmitting) {
            withheld++
            return false
        }
        admitted++
        return true
    }

    /** Closes the gate. Returns the change, or null when it was already closed. */
    fun suspend(): TransmissionChange? = switchTo(false)

    /** Opens the gate. Returns the change, or null when it was already open or is stopped. */
    fun resume(): TransmissionChange? = switchTo(true)

    /** The capture is over: closed for good, nothing reopens it. Idempotent. */
    fun stop() {
        stopped = true
        transmitting = false
    }

    private fun switchTo(open: Boolean): TransmissionChange? {
        if (stopped && open) return null
        if (transmitting == open) return null
        transmitting = open
        val change = TransmissionChange(
            transmitting = open,
            admittedBefore = admitted,
            withheldBefore = withheld,
            refresh = open && frameArrived,
        )
        admitted = 0
        withheld = 0
        return change
    }
}
