package com.example.remote_control_device

import android.content.Context
import android.content.Intent
import android.util.Log
import com.cloudwebrtc.webrtc.utils.EglUtils
import java.util.UUID
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource

/**
 * One screen capture, from the projection to the track Dart sends, and back down again.
 *
 * Video only, by construction: a [VideoSource] and nothing else is created here. There is no
 * audio source to forget to leave out.
 *
 * Built only after the `mediaProjection` foreground service has reported READY — that order
 * is enforced in Dart, and [start] relies on it: `getMediaProjection` is where Android 14
 * throws when the service is not up.
 */
class ScreenCaptureSession private constructor(
    val trackId: String,
    val geometry: ScreenCaptureGeometry,
    val virtualDisplaySide: Int,
    private val capturer: ScreenCapturer,
    private val helper: SurfaceTextureHelper,
    private val source: VideoSource,
) {
    private var stopped = false

    /**
     * Releases everything, in the order the pieces depend on each other. Idempotent.
     *
     * The track is forgotten by the plugin first, so nothing on the Dart side can resolve it
     * while its capture is going away; then the capturer stops — the virtual display and the
     * projection go with it — and only then the source and the texture thread it fed.
     */
    fun stop() {
        if (stopped) return
        stopped = true

        FlutterWebRtcLocalTracks.unregister(trackId)
        capturer.stopCapture()
        capturer.dispose()
        source.dispose()
        helper.dispose()
        Log.i(TAG, "capture session released")
    }

    companion object {
        private const val TAG = "RemoteControlScreen"
        private const val TEXTURE_THREAD = "RemoteControlScreenCapture"

        /**
         * Starts capturing with a projection [grant] the user has just given, and makes the
         * resulting track available to Dart.
         *
         * The grant is used here once and not kept: Android 14 refuses a second projection
         * from the same consent, and this application would not ask it to.
         */
        fun start(context: Context, grant: Intent): ScreenCaptureSession {
            val factory = FlutterWebRtcLocalTracks.peerConnectionFactory()

            Log.i(TAG, "capture starting")
            val helper = SurfaceTextureHelper.create(TEXTURE_THREAD, EglUtils.getRootEglBaseContext())
                ?: throw IllegalStateException("no texture thread")
            val source = factory.createVideoSource(/* isScreencast = */ true)
            val capturer = ScreenCapturer(grant)
            try {
                capturer.initialize(helper, context, source.capturerObserver)
                capturer.startCapture(0, 0, 0)

                val trackId = UUID.randomUUID().toString()
                val track = factory.createVideoTrack(trackId, source)
                try {
                    FlutterWebRtcLocalTracks.register(trackId, track)
                } catch (error: Exception) {
                    // Never reached Dart, so nothing else holds it.
                    track.dispose()
                    throw error
                }

                val geometry = checkNotNull(capturer.initialGeometry)
                Log.i(TAG, "capture started")
                return ScreenCaptureSession(
                    trackId = trackId,
                    geometry = geometry,
                    virtualDisplaySide = capturer.virtualDisplaySide,
                    capturer = capturer,
                    helper = helper,
                    source = source,
                )
            } catch (error: Exception) {
                capturer.stopCapture()
                capturer.dispose()
                source.dispose()
                helper.dispose()
                throw error
            }
        }
    }
}
