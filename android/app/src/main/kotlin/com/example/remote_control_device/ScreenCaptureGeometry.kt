package com.example.remote_control_device

/**
 * The display as it is right now: its size in the orientation it is in right now.
 *
 * [width] and [height] are the *current* ones — 1280×800 on a tablet held sideways whose
 * panel is 800×1280 — never the natural ones with a rotation to apply afterwards. That is
 * the whole bug this type exists to stop: `flutter_webrtc 1.6.2+hotfix.2` reads the current
 * size and then swaps it again in landscape, as if it had been given the natural one.
 *
 * Pure Kotlin, no Android types, so the arithmetic below is unit tested on the JVM.
 */
data class ScreenCaptureGeometry(
    val width: Int,
    val height: Int,
    val densityDpi: Int,
    /** `Surface.ROTATION_0` .. `ROTATION_270`, i.e. 0..3. Diagnostic only. */
    val rotation: Int,
) {
    init {
        require(width > 0 && height > 0) { "a display has a size" }
    }

    val isLandscape: Boolean get() = width > height

    val orientation: String get() = if (isLandscape) "landscape" else "portrait"

    val rotationDegrees: Int get() = rotation * 90

    /**
     * The side of a square virtual display that holds this screen at 1:1 in *either*
     * orientation: the longer of the two sides.
     */
    val squareSide: Int get() = maxOf(width, height)

    /**
     * Where this screen's picture lands inside a square virtual display of [side].
     *
     * Android mirrors a display into a MediaProjection virtual display by scaling it to fit
     * without distortion and centring it — `ContentRecorder.updateMirroredSurface` on
     * Android 14, `LogicalDisplay.configureDisplayLocked` before it. This is that same
     * arithmetic, rounding included, so the rectangle it returns is exactly the picture and
     * not the bars around it.
     */
    fun contentIn(side: Int): CaptureRect {
        require(side > 0) { "a virtual display has a size" }
        val scale = minOf(side.toFloat() / width, side.toFloat() / height)
        val contentWidth = Math.round(width * scale).coerceIn(1, side)
        val contentHeight = Math.round(height * scale).coerceIn(1, side)
        return CaptureRect(
            left = (side - contentWidth) / 2,
            top = (side - contentHeight) / 2,
            width = contentWidth,
            height = contentHeight,
        )
    }

    override fun toString(): String =
        "${width}x$height $orientation rotation=$rotationDegrees dpi=$densityDpi"
}

/** A rectangle in the virtual display's pixels. */
data class CaptureRect(val left: Int, val top: Int, val width: Int, val height: Int) {
    override fun toString(): String = "${width}x$height@($left,$top)"
}

/**
 * How one capture frames the screen, for as long as it runs.
 *
 * The virtual display is square and sized once, from the display as it was when the capture
 * started, and it is never resized: Android 14 allows one virtual display per projection, and
 * resizing that one was what produced the deformed landscape frames — the platform kept
 * mirroring for the old size. A square holds the screen at 1:1 whichever way it is turned, so
 * a rotation only moves the picture inside it. What moves with it is [content], the part of
 * each frame that is sent; nothing about the peer connection, the transceiver or the track.
 */
class ScreenCaptureFraming(initial: ScreenCaptureGeometry) {

    /** Fixed for the life of the capture. */
    val virtualDisplaySide: Int = initial.squareSide

    var geometry: ScreenCaptureGeometry = initial
        private set

    var content: CaptureRect = initial.contentIn(virtualDisplaySide)
        private set

    /**
     * Takes the display as it is now. Answers whether anything changed, so that a rotation is
     * logged once and not once per frame.
     */
    fun update(next: ScreenCaptureGeometry): Boolean {
        if (next == geometry) return false
        geometry = next
        content = next.contentIn(virtualDisplaySide)
        return true
    }
}

/**
 * When to read the display again, and what to do with what it says.
 *
 * Found on the tablet: `DisplayManager.DisplayListener.onDisplayChanged` arrives *before* the
 * application's `Configuration` is updated, and `Display.getRealMetrics` / `getRotation` read
 * from an application context are adjusted by that configuration. So the reading taken on
 * `onDisplayChanged` is the display as it was before the rotation, and the crop stayed one
 * rotation behind:
 *
 * ```text
 * 14:28:05  rotated to portrait     onDisplayChanged reads 1280x800 -> "no change"
 * 14:30:07  rotated to landscape    onDisplayChanged reads 800x1280 -> portrait crop
 * ```
 *
 * The configuration change is the moment the reading is right, so it is a signal of its own,
 * and the display change stays as a second one. Neither is trusted to be the last: every
 * signal reads the display afresh and the crop follows the reading. A stale reading is
 * therefore never final — it is the same as the current state, nothing moves, and the next
 * signal corrects it — and a duplicate one changes nothing either. No timers: what ends the
 * wait is Android saying the configuration changed.
 *
 * Pure, so the sequence that broke on the tablet is replayed on the JVM.
 */
class ScreenCaptureGeometryRefresh(
    val framing: ScreenCaptureFraming,
    private val readDisplay: () -> ScreenCaptureGeometry,
) {
    /**
     * Reads the display, on any signal that it may have changed. Returns the geometry the crop
     * moved to, or `null` when the reading is the state the crop is already in.
     */
    fun refresh(): ScreenCaptureGeometry? {
        val reading = readDisplay()
        return if (framing.update(reading)) reading else null
    }
}
