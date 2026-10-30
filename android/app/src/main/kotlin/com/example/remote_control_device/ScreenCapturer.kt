package com.example.remote_control_device

import android.app.Activity
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.Surface
import java.util.concurrent.atomic.AtomicBoolean
import org.webrtc.CapturerObserver
import org.webrtc.SurfaceTextureHelper
import org.webrtc.ThreadUtils
import org.webrtc.VideoCapturer
import org.webrtc.VideoFrame
import org.webrtc.VideoSink

/**
 * The screen, as a WebRTC video source, the right way up in either orientation.
 *
 * It replaces `flutter_webrtc`'s `OrientationAwareScreenCapturer` for this application, and
 * the reason is in that class, read from the installed `1.6.2+hotfix.2`:
 *
 * ```text
 * getDisplayMedia     startCapture(Display.getRealSize())   <- already the CURRENT size
 * startCapture        if landscape: width = height; height = width   <- swapped AGAIN
 *                     createVirtualDisplay(800x1280) on a 1280x800 screen
 * onFrame (1st)       changeCaptureFormat(1280, 800) -> VirtualDisplay.resize()
 * ```
 *
 * The tablet's own logs show the virtual display created 800×1280 and resized to 1280×800 a
 * frame later, and what reached the web was the left 62.5 % of the screen stretched 1.6×:
 * the platform kept mirroring for the size the display was created with. Android 14 allows
 * one virtual display per projection, so every rotation goes through that same resize.
 *
 * So this capturer never resizes anything. Its virtual display is a square whose side is the
 * screen's longer side, created once; Android mirrors the screen into it at 1:1, centred, in
 * whichever orientation it is in. Each frame is then cropped — `cropAndScale` on the texture,
 * no copy — to the rectangle the picture occupies right now. Portrait goes out 800×1280,
 * landscape 1280×800, and a rotation changes the frames' size in the same track: no new
 * track, no new transceiver, no renegotiation.
 *
 * A rotation is noticed twice, on purpose: by a `DisplayListener` and by the application's
 * `onConfigurationChanged`. The first arrives before the configuration the display reading
 * depends on is updated, so on its own it read the previous orientation and left the crop one
 * rotation behind (seen on the tablet). Each signal reads the display again and the crop
 * follows the reading — see [ScreenCaptureGeometryRefresh].
 *
 * Threads: [startCapture] and [stopCapture] are called from the main thread; frames, the
 * display listener and the projection callback all run on the [SurfaceTextureHelper]'s
 * thread, which is the only thread that reads or moves [framing]. A configuration change
 * arrives on the main thread and is handed to that thread as it is.
 */
class ScreenCapturer(private val projectionGrant: Intent) : VideoCapturer, VideoSink {

    private lateinit var helper: SurfaceTextureHelper
    private lateinit var observer: CapturerObserver
    private lateinit var context: Context
    private lateinit var displayManager: DisplayManager

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var surface: Surface? = null
    private var framing: ScreenCaptureFraming? = null
    private var geometryRefresh: ScreenCaptureGeometryRefresh? = null

    private val stopped = AtomicBoolean(false)
    private var mismatchLogged = false

    /** The display as the capture started with it. */
    var initialGeometry: ScreenCaptureGeometry? = null
        private set

    /** The virtual display's side, or 0 before [startCapture]. */
    var virtualDisplaySide: Int = 0
        private set

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // The user pressed "Stop sharing" in Android's own controls, or another
            // projection took over. The projection is gone either way; what it was drawing
            // into goes with it.
            Log.i(TAG, "capture stopped by the platform")
            stopCapture()
        }
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == Display.DEFAULT_DISPLAY) refreshGeometry(SIGNAL_DISPLAY)
        }

        override fun onDisplayAdded(displayId: Int) = Unit

        override fun onDisplayRemoved(displayId: Int) = Unit
    }

    private val configurationCallbacks = object : ComponentCallbacks2 {
        override fun onConfigurationChanged(newConfig: Configuration) {
            // Main thread. Handed to the helper's thread, which owns the crop; not delayed.
            helper.handler.post { refreshGeometry(SIGNAL_CONFIGURATION) }
        }

        @Deprecated("Required by ComponentCallbacks; nothing to release here.")
        override fun onLowMemory() = Unit

        override fun onTrimMemory(level: Int) = Unit
    }

    override fun initialize(
        surfaceTextureHelper: SurfaceTextureHelper,
        applicationContext: Context,
        capturerObserver: CapturerObserver,
    ) {
        helper = surfaceTextureHelper
        context = applicationContext
        observer = capturerObserver
        displayManager = applicationContext.getSystemService(DisplayManager::class.java)
    }

    /**
     * Starts capturing. The arguments are ignored: the size comes from the display itself,
     * and a frame rate is not something a mirrored display can be asked for.
     *
     * Throws what the platform throws — `SecurityException` above all, when the
     * `mediaProjection` foreground service is not running — after releasing whatever it had
     * already acquired.
     */
    override fun startCapture(width: Int, height: Int, framerate: Int) {
        check(!stopped.get()) { "capturer was stopped" }

        val geometry = readDisplayGeometry(context)
        val framing = ScreenCaptureFraming(geometry)
        val side = framing.virtualDisplaySide

        try {
            val manager = context.getSystemService(MediaProjectionManager::class.java)
            val projection = manager.getMediaProjection(Activity.RESULT_OK, projectionGrant)
                ?: throw IllegalStateException("no media projection for this grant")
            this.projection = projection
            // Android 14 refuses createVirtualDisplay on a projection with no callback.
            projection.registerCallback(projectionCallback, helper.handler)

            helper.setTextureSize(side, side)
            helper.surfaceTexture.setDefaultBufferSize(side, side)
            val surface = Surface(helper.surfaceTexture)
            this.surface = surface

            this.framing = framing
            geometryRefresh = ScreenCaptureGeometryRefresh(framing) { readDisplayGeometry(context) }
            virtualDisplay = projection.createVirtualDisplay(
                VIRTUAL_DISPLAY_NAME,
                side,
                side,
                geometry.densityDpi,
                VIRTUAL_DISPLAY_FLAGS,
                surface,
                null,
                null,
            )
        } catch (error: Exception) {
            release()
            throw error
        }

        initialGeometry = geometry
        virtualDisplaySide = side
        Log.i(TAG, "capture geometry $geometry, virtual display ${side}x$side, sending ${framing.content}")

        displayManager.registerDisplayListener(displayListener, helper.handler)
        context.registerComponentCallbacks(configurationCallbacks)
        observer.onCapturerStarted(true)
        helper.startListening(this)
        // A rotation between reading the display above and the listeners being registered
        // would otherwise go unnoticed until the next one.
        helper.handler.post { refreshGeometry(SIGNAL_STARTED) }
    }

    override fun onFrame(frame: VideoFrame) {
        if (stopped.get()) return
        val framing = framing ?: return

        val buffer = frame.buffer
        val side = framing.virtualDisplaySide
        if (buffer.width != side || buffer.height != side) {
            // Not the square this capturer asked for. Sent as it came rather than cropped
            // with a rectangle that belongs to another size.
            if (!mismatchLogged) {
                mismatchLogged = true
                Log.w(TAG, "capture frame is ${buffer.width}x${buffer.height}, expected ${side}x$side")
            }
            observer.onFrameCaptured(frame)
            return
        }

        val content = framing.content
        val cropped = buffer.cropAndScale(
            content.left,
            content.top,
            content.width,
            content.height,
            content.width,
            content.height,
        )
        val framed = VideoFrame(cropped, frame.rotation, frame.timestampNs)
        try {
            observer.onFrameCaptured(framed)
        } finally {
            framed.release()
        }
    }

    /** Idempotent, and safe from any thread, including the projection's own callback. */
    override fun stopCapture() {
        if (!stopped.compareAndSet(false, true)) return
        if (!::helper.isInitialized) return

        // Inline when already on the helper's thread — the projection callback is.
        ThreadUtils.invokeAtFrontUninterruptibly(
            helper.handler,
            Runnable {
                helper.stopListening()
                displayManager.unregisterDisplayListener(displayListener)
                context.unregisterComponentCallbacks(configurationCallbacks)
                observer.onCapturerStopped()
                release()
                Log.i(TAG, "capture stopped")
            },
        )
    }

    /** The size follows the display; there is nothing to change from outside. */
    override fun changeCaptureFormat(width: Int, height: Int, framerate: Int) = Unit

    override fun dispose() {
        stopCapture()
    }

    override fun isScreencast(): Boolean = true

    /**
     * Reads the display again after [signal] and moves the crop if the reading moved. A reading
     * that matches the current crop — a duplicate signal, or one that came before the
     * configuration caught up — changes nothing, and is logged at debug level only so that the
     * tablet's log shows which signal finally carried the rotation.
     */
    private fun refreshGeometry(signal: String) {
        if (stopped.get()) return
        val refresh = geometryRefresh ?: return
        val moved = try {
            refresh.refresh()
        } catch (error: Exception) {
            Log.w(TAG, "display could not be read: ${error.javaClass.simpleName}")
            return
        }
        if (moved != null) {
            Log.i(TAG, "capture geometry $moved, sending ${refresh.framing.content} ($signal)")
        } else {
            Log.d(TAG, "geometry unchanged ($signal)")
        }
    }

    private fun release() {
        virtualDisplay?.release()
        virtualDisplay = null
        surface?.release()
        surface = null
        projection?.let {
            // Unregistered first, or stopping it calls back into stopCapture.
            it.unregisterCallback(projectionCallback)
            it.stop()
        }
        projection = null
    }

    companion object {
        private const val TAG = "RemoteControlScreen"
        private const val VIRTUAL_DISPLAY_NAME = "RemoteControl_ScreenCapture"

        private const val SIGNAL_STARTED = "started"
        private const val SIGNAL_DISPLAY = "display changed"
        private const val SIGNAL_CONFIGURATION = "configuration changed"

        // The flags flutter_webrtc uses, which are known to mirror on the tablets this runs
        // on: a public display with no content of its own mirrors the default one.
        private const val VIRTUAL_DISPLAY_FLAGS =
            DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC or
                DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION

        /**
         * The default display's real size in its current orientation, its density and its
         * rotation.
         *
         * `Display.getRealMetrics` is deprecated in favour of `WindowMetrics`, and for sizing
         * an app's window that advice is right. It is not what this needs: `WindowMetrics`
         * requires a visual context and describes a window, and this runs from the
         * application context — the user is expected to be in another app — and needs the
         * whole display, which is precisely what the platform mirrors into a projection.
         */
        @Suppress("DEPRECATION")
        fun readDisplayGeometry(context: Context): ScreenCaptureGeometry {
            val display = context.getSystemService(DisplayManager::class.java)
                .getDisplay(Display.DEFAULT_DISPLAY)
                ?: throw IllegalStateException("no default display")
            val metrics = DisplayMetrics()
            display.getRealMetrics(metrics)
            return ScreenCaptureGeometry(
                width = metrics.widthPixels,
                height = metrics.heightPixels,
                densityDpi = metrics.densityDpi,
                rotation = display.rotation,
            )
        }
    }
}
