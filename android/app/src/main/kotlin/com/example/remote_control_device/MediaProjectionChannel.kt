package com.example.remote_control_device

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
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
 * In between, `setScreenCaptureTransmission` opens or closes the running capture's
 * transmission gate (a new capture starts closed); see [ScreenCaptureTransmission].
 * Which state it should be in is Dart's decision.
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
    private val capture = RunningScreenCapture<ScreenCaptureSession>(
        trackIdOf = { it.trackId },
        release = { it.stop() },
    )
    private val mainThread = Handler(Looper.getMainLooper())

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

            SET_TRANSMISSION_METHOD -> {
                val trackId = call.argument<String>(TRACK_ID)
                val transmitting = call.argument<Boolean>(TRANSMITTING)
                if (trackId == null || transmitting == null) {
                    result.error(TRANSMISSION_FAILED, BAD_ARGUMENTS, null)
                } else {
                    try {
                        // false: no such capture any more, or it is stopping. Either way it
                        // transmits nothing, which is not a failure.
                        val applied = capture.ifRunning(trackId) {
                            it.setTransmitting(transmitting)
                        }
                        result.success(applied ?: false)
                    } catch (error: Exception) {
                        result.error(TRANSMISSION_FAILED, error.javaClass.simpleName, null)
                    }
                }
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
            ScreenCaptureSession.start(context, grant) { trackId ->
                // The projection's thread. Bookkeeping and the channel live on the main one.
                mainThread.post { onStoppedByPlatform(trackId) }
            }
        } catch (error: Exception) {
            Log.w(TAG, "capture could not be started: ${error.javaClass.simpleName}")
            result.error(CAPTURE_FAILED, error.javaClass.simpleName, null)
            return
        }
        capture.started(started)

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
    private fun stopCapture(trackId: String? = null) = capture.stop(trackId)

    /**
     * MediaProjection's `onStop` for [trackId]. The capture is released here, and Dart is told
     * only if it was still the running one: Dart decides what the assistance loses with it, and
     * it never restarts the capture without a new consent dialog. The foreground service is
     * Dart's to stop, as for every other stop.
     */
    private fun onStoppedByPlatform(trackId: String) {
        if (!capture.stoppedByPlatform(trackId)) return
        Log.i(TAG, "capture stopped by the platform: reported to Dart")
        channel?.invokeMethod(STOPPED_BY_PLATFORM_METHOD, mapOf(TRACK_ID to trackId))
    }

    companion object {
        private const val TAG = "RemoteControlScreen"

        const val CHANNEL_NAME = "remote_control_device/media_projection"
        const val CONSENT_METHOD = "requestScreenCaptureConsent"
        const val START_METHOD = "startMediaProjectionForegroundService"
        const val STOP_METHOD = "stopMediaProjectionForegroundService"
        const val START_CAPTURE_METHOD = "startScreenCapture"
        const val STOP_CAPTURE_METHOD = "stopScreenCapture"

        /** `{ "trackId": "<id>", "transmitting": <bool> }`. Answers whether it was applied. */
        const val SET_TRANSMISSION_METHOD = "setScreenCaptureTransmission"

        /** Android -> Dart. `{ "trackId": "<id>" }`, after the capture was released. */
        const val STOPPED_BY_PLATFORM_METHOD = "screenCaptureStoppedByPlatform"

        private const val TRACK_ID = "trackId"
        private const val TRANSMITTING = "transmitting"
        private const val NO_GRANT = "NO_GRANT"
        private const val BAD_ARGUMENTS = "BAD_ARGUMENTS"

        private const val CONSENT_FAILED = "SCREEN_CAPTURE_CONSENT_FAILED"
        private const val START_FAILED = "FOREGROUND_SERVICE_START_FAILED"
        private const val STOP_FAILED = "FOREGROUND_SERVICE_STOP_FAILED"
        private const val CAPTURE_FAILED = "SCREEN_CAPTURE_FAILED"
        private const val TRANSMISSION_FAILED = "SCREEN_CAPTURE_TRANSMISSION_FAILED"
    }
}
