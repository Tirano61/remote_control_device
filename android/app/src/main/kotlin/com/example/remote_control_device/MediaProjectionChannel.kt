package com.example.remote_control_device

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Android half of the bridge for screen capture: the consent dialog, the
 * [MediaProjectionForegroundService], and the [ScreenCaptureSession] itself.
 *
 * Transport and nothing else. It takes no decision and knows nothing about remote sessions,
 * WebRTC negotiation or device identity — those live in Dart, in
 * `MediaProjectionScreenCaptureClient`, where they are tested, and that client is what puts
 * these messages in their only valid order:
 *
 * ```text
 * requestScreenCaptureConsent -> startMediaProjectionForegroundService (READY)
 *     -> startScreenCapture ... stopScreenCapture -> stopMediaProjectionForegroundService
 * ```
 *
 * What it does hold is what cannot cross the boundary: the projection grant (between the
 * dialog and the capture, never longer) and the one running capture.
 *
 * Failures are answered, never swallowed and never thrown across the boundary, and only by
 * exception class name: a platform message here can quote the grant intent. A refusal has to
 * reach Dart as an error so the negotiation can continue without the screen rather than die
 * with it.
 */
class MediaProjectionChannel(
    private val context: Context,
    private val consent: ScreenCaptureConsentRequester,
) : MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var session: ScreenCaptureSession? = null

    fun attachTo(messenger: BinaryMessenger) {
        detach()
        channel = MethodChannel(messenger, CHANNEL_NAME).also { it.setMethodCallHandler(this) }
    }

    /**
     * The engine is going away, and with it the Dart side that owns the capture. Nothing is
     * left running for nobody: the capture stops, the grant is dropped, every waiting answer
     * is given now, and the notification comes down.
     */
    fun detach() {
        if (channel == null) return
        stopCapture()
        consent.reset()
        MediaProjectionForegroundService.stop(context)
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /** Forwarded from the activity. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        consent.onActivityResult(requestCode, resultCode, data)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            CONSENT_METHOD -> try {
                consent.request { granted ->
                    Log.i(TAG, if (granted) "screen capture permission granted" else "screen capture permission denied")
                    result.success(granted)
                }
            } catch (error: Exception) {
                result.error(CONSENT_FAILED, error.javaClass.simpleName, null)
            }

            // Answered when the service is foreground as mediaProjection, not when it was
            // asked to start: Dart opens the capture the moment this returns, and Android 14
            // refuses a capture whose service is still on its way up.
            START_METHOD -> MediaProjectionForegroundService.start(
                context,
                onReady = { result.success(null) },
                onFailed = { reason -> result.error(START_FAILED, reason, null) },
            )

            STOP_METHOD -> try {
                MediaProjectionForegroundService.stop(context)
                result.success(null)
            } catch (error: Exception) {
                result.error(STOP_FAILED, error.javaClass.simpleName, null)
            }

            START_CAPTURE_METHOD -> startCapture(result)

            STOP_CAPTURE_METHOD -> {
                stopCapture(call.argument<String>(TRACK_ID))
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun startCapture(result: MethodChannel.Result) {
        // One capture at a time. Dart stops the previous one before it asks again; this only
        // makes sure a mistake there cannot leave two projections running.
        stopCapture()

        val grant = consent.takeGrant()
        if (grant == null) {
            result.error(CAPTURE_FAILED, NO_GRANT, null)
            return
        }

        val started = try {
            ScreenCaptureSession.start(context, grant)
        } catch (error: Exception) {
            Log.w(TAG, "capture could not be started: ${error.javaClass.simpleName}")
            result.error(CAPTURE_FAILED, error.javaClass.simpleName, null)
            return
        }
        session = started

        val geometry = started.geometry
        val content = geometry.contentIn(started.virtualDisplaySide)
        result.success(
            mapOf(
                TRACK_ID to started.trackId,
                "displayWidth" to geometry.width,
                "displayHeight" to geometry.height,
                "densityDpi" to geometry.densityDpi,
                "orientation" to geometry.orientation,
                "rotation" to geometry.rotationDegrees,
                "virtualDisplaySide" to started.virtualDisplaySide,
                "captureWidth" to content.width,
                "captureHeight" to content.height,
            ),
        )
    }

    /**
     * Stops the running capture. With a [trackId], only if it is that capture: a late stop
     * for a capture that was already replaced must not take down its replacement.
     */
    private fun stopCapture(trackId: String? = null) {
        val running = session ?: return
        if (trackId != null && running.trackId != trackId) return
        session = null
        running.stop()
    }

    companion object {
        private const val TAG = "RemoteControlScreen"

        const val CHANNEL_NAME = "remote_control_device/media_projection"
        const val CONSENT_METHOD = "requestScreenCaptureConsent"
        const val START_METHOD = "startMediaProjectionForegroundService"
        const val STOP_METHOD = "stopMediaProjectionForegroundService"
        const val START_CAPTURE_METHOD = "startScreenCapture"
        const val STOP_CAPTURE_METHOD = "stopScreenCapture"

        private const val TRACK_ID = "trackId"
        private const val NO_GRANT = "NO_GRANT"

        private const val CONSENT_FAILED = "SCREEN_CAPTURE_CONSENT_FAILED"
        private const val START_FAILED = "FOREGROUND_SERVICE_START_FAILED"
        private const val STOP_FAILED = "FOREGROUND_SERVICE_STOP_FAILED"
        private const val CAPTURE_FAILED = "SCREEN_CAPTURE_FAILED"
    }
}
