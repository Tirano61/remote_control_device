package com.example.remote_control_device

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Android half of the bridge to [MediaProjectionForegroundService].
 *
 * Two messages and nothing else. It holds no state of its own — the one start waiting for
 * the service to come up is held by the service's companion, next to the code that answers
 * it — takes no decision and knows nothing
 * about remote sessions, WebRTC or device identity — those live in Dart, where they are
 * tested. What is here is the part Dart cannot reach: an Android `Service`.
 *
 * Failures are answered, never swallowed and never thrown across the boundary. Starting a
 * foreground service can be refused by the platform — `ForegroundServiceStartNotAllowedException`
 * when the app is not in the foreground, `SecurityException` when it has no projection — and a
 * refusal has to reach Dart as an error so the negotiation can continue without the screen
 * rather than die with it.
 */
class MediaProjectionChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null

    fun attachTo(messenger: BinaryMessenger) {
        detach()
        channel = MethodChannel(messenger, CHANNEL_NAME).also { it.setMethodCallHandler(this) }
    }

    fun detach() {
        // A start still waiting is answered now, so no Result outlives the engine it was
        // meant for.
        MediaProjectionForegroundService.abandonPendingStart(MediaProjectionForegroundService.STOPPED)
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
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

            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL_NAME = "remote_control_device/media_projection"
        const val START_METHOD = "startMediaProjectionForegroundService"
        const val STOP_METHOD = "stopMediaProjectionForegroundService"

        private const val START_FAILED = "FOREGROUND_SERVICE_START_FAILED"
        private const val STOP_FAILED = "FOREGROUND_SERVICE_STOP_FAILED"
    }
}
