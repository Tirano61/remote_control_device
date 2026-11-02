package com.example.remote_control_device

import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Android half of the bridge to [RemoteControlAccessibilityService].
 *
 * Transport and nothing else. Whether a gesture may run is decided in Dart, in
 * `WebRtcSessionBloc`, against the remote session; by the time [TAP_METHOD] or [SWIPE_METHOD]
 * arrives the decision is made. Failures are answered as outcomes, never thrown across the
 * boundary.
 *
 * It also pushes [AVAILABILITY_CHANGED_METHOD] the other way, because the user enables the
 * service from Settings while the application is in the background and has to find it enabled
 * on the way back.
 */
class RemoteControlAccessibilityChannel(
    private val context: Context,
    private val availability: RemoteControlAvailability,
) : MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null

    fun attachTo(messenger: BinaryMessenger) {
        detach()
        channel = MethodChannel(messenger, CHANNEL_NAME).also { it.setMethodCallHandler(this) }
        availability.onChanged = { available ->
            channel?.invokeMethod(AVAILABILITY_CHANGED_METHOD, available)
        }
    }

    /** The service is left alone: it belongs to Android, and only the user can turn it off. */
    fun detach() {
        availability.onChanged = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            AVAILABLE_METHOD -> result.success(availability.isAvailable)

            TAP_METHOD -> {
                val x = call.argument<Double>(X)
                val y = call.argument<Double>(Y)
                if (x == null || y == null) {
                    result.success(RemoteGestureOutcome.INVALID.wire)
                    return
                }
                availability.tap(x, y) { outcome ->
                    Log.i(TAG, "tap ${outcome.wire}")
                    result.success(outcome.wire)
                }
            }

            SWIPE_METHOD -> {
                val startX = call.argument<Double>(START_X)
                val startY = call.argument<Double>(START_Y)
                val endX = call.argument<Double>(END_X)
                val endY = call.argument<Double>(END_Y)
                val durationMs = call.argument<Int>(DURATION_MS)
                if (startX == null || startY == null || endX == null || endY == null || durationMs == null) {
                    result.success(RemoteGestureOutcome.INVALID.wire)
                    return
                }
                availability.swipe(startX, startY, endX, endY, durationMs.toLong()) { outcome ->
                    Log.i(TAG, "swipe ${outcome.wire}")
                    result.success(outcome.wire)
                }
            }

            SETTINGS_METHOD -> try {
                // Only opens the screen. Enabling the service is the user's, in Android's own UI.
                context.startActivity(
                    Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success(null)
            } catch (error: Exception) {
                result.error(SETTINGS_FAILED, error.javaClass.simpleName, null)
            }

            else -> result.notImplemented()
        }
    }

    companion object {
        private const val TAG = "RemoteControlInput"

        const val CHANNEL_NAME = "remote_control/accessibility"
        const val AVAILABLE_METHOD = "isAccessibilityServiceAvailable"
        const val TAP_METHOD = "performTap"
        const val SWIPE_METHOD = "performSwipe"
        const val SETTINGS_METHOD = "openAccessibilitySettings"
        const val AVAILABILITY_CHANGED_METHOD = "accessibilityServiceAvailabilityChanged"

        private const val X = "x"
        private const val Y = "y"
        private const val START_X = "startX"
        private const val START_Y = "startY"
        private const val END_X = "endX"
        private const val END_Y = "endY"
        private const val DURATION_MS = "durationMs"

        private const val SETTINGS_FAILED = "ACCESSIBILITY_SETTINGS_FAILED"
    }
}
