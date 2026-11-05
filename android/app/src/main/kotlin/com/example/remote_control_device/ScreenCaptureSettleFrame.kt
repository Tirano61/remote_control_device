package com.example.remote_control_device

/** The one thing [ScreenCaptureSettleFrame] needs from a clock that can call back. */
internal interface SettleFrameTimer {
    fun schedule(action: Runnable, delayMs: Long)

    fun cancel(action: Runnable)
}

/** A frame to hand to WebRTC: the crop to apply, the timestamp to give it, and what it is. */
internal data class SettleFrameOutgoing(
    val crop: CaptureRect?,
    val timestampNs: Long,
    val isSettle: Boolean,
)

/**
 * Sends the last captured frame once more when the screen goes quiet, and then nothing.
 *
 * A mirrored display only produces a frame when something changes, so the last frame of a
 * transition is the one thing the pipeline gets no second chance at. libvpx may discard it
 * after encoding (`vp8_drop_encodedframe_overshoot`) and rely on a next frame, and WebRTC's
 * adapter may discard it under a frame rate limit. With a still screen no next frame comes.
 *
 * ```text
 * real  real  real (final)
 *                  └── settleDelayMs with no real frame ──> one more delivery, then nothing
 * ```
 *
 * Each real frame starts the wait again. When it runs out, [requestRedelivery] asks the
 * `SurfaceTextureHelper` to deliver its current texture again (`forceFrame`). Nothing is kept
 * for this but the crop and the timestamp: the image stays where it already is, latched in the
 * `SurfaceTexture`, and it reaches the encoder as a texture like every other frame. An I420 copy
 * was tried first and rejected on the tablet: 27 ms per real frame on the capture thread, and
 * WebRTC reconfigures its encoder whenever a frame's `is_texture` differs from the last one's.
 *
 * Redelivery is not a call that returns a frame. It comes back later through [onFrame], so
 * that is where a delivery is told apart:
 *
 * ```text
 * a new timestamp                      a real frame, even if a redelivery was requested:
 *                                      a new image got there first
 * the last timestamp, requested        the settle frame
 * the last timestamp, not requested    a redelivery that lost to a real frame; discarded
 * ```
 *
 * The settle frame does not start another wait, so this is not a keepalive.
 *
 * Not synchronised. Every call and [timer] callback must come from the same thread, which in
 * [ScreenCapturer] is the `SurfaceTextureHelper`'s.
 */
internal class ScreenCaptureSettleFrame(
    private val timer: SettleFrameTimer,
    private val nanoTime: () -> Long,
    private val requestRedelivery: () -> Unit,
    private val settleDelayMs: Long = DEFAULT_SETTLE_DELAY_MS,
) {
    private var lastTimestampNs: Long? = null
    private var lastArrivedAtNs = 0L
    private var lastCrop: CaptureRect? = null
    private var redeliveryRequested = false
    private var stopped = false

    private val fire = Runnable {
        if (!stopped && lastTimestampNs != null) {
            redeliveryRequested = true
            requestRedelivery()
        }
    }

    /**
     * A frame arrived from the helper. [currentCrop] is what a real frame would be cropped with
     * now. Returns what to send, or null to send nothing.
     *
     * A settle frame goes out with the crop of the real frame it repeats, never with the current
     * one: the image was taken with that crop, and the display may have rotated since.
     */
    fun onFrame(timestampNs: Long, currentCrop: CaptureRect?): SettleFrameOutgoing? {
        if (stopped) return null

        if (timestampNs != lastTimestampNs) {
            redeliveryRequested = false
            lastTimestampNs = timestampNs
            lastArrivedAtNs = nanoTime()
            lastCrop = currentCrop
            timer.cancel(fire)
            timer.schedule(fire, settleDelayMs)
            return SettleFrameOutgoing(currentCrop, timestampNs, isSettle = false)
        }

        if (!redeliveryRequested) return null
        redeliveryRequested = false
        return SettleFrameOutgoing(
            lastCrop,
            settleTimestampNs(timestampNs, lastArrivedAtNs, nanoTime()),
            isSettle = true,
        )
    }

    /** Cancels the wait. Nothing is sent afterwards, whatever is still on its way. Idempotent. */
    fun stop() {
        stopped = true
        redeliveryRequested = false
        timer.cancel(fire)
    }

    companion object {
        /**
         * Chosen above the 500 ms a frame took to get through WebRTC's adapter at `max_fps=2`,
         * the lowest limit seen on the tablet while CPU adaptation could still impose one, and
         * kept because it is the value validated there.
         */
        const val DEFAULT_SETTLE_DELAY_MS = 700L

        /**
         * A timestamp for the repeat, on the original's clock and as far after it as the repeat
         * is being sent after the original arrived.
         *
         * The original's own timestamp would not do: WebRTC drops a frame that is not newer than
         * the last one. `System.nanoTime` is not used directly because a frame's timestamp comes
         * from the `SurfaceTexture`, and the two are not documented to share a clock.
         */
        fun settleTimestampNs(originalNs: Long, arrivedAtNs: Long, nowNs: Long): Long =
            originalNs + maxOf(nowNs - arrivedAtNs, 1L)
    }
}
