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
 * Transport, and a gate. Whether a gesture may run is decided in Dart, in
 * `WebRtcSessionBloc`, against the remote session; by the time [TAP_METHOD], [LONG_PRESS_METHOD],
 * [SWIPE_METHOD], [BACK_METHOD], [HOME_METHOD], [RECENTS_METHOD], [SET_TEXT_METHOD],
 * [IME_ENTER_METHOD] or one of the remote touch methods arrives the decision is made. A remote
 * touch is named by a handle Dart chooses, never by the sender's own name for it.
 *
 * That decision is mirrored here, and enforced on this side too: Dart opens a numbered grant with
 * [OPEN_CONTROL_METHOD] when control becomes authorised and closes it with [CLOSE_CONTROL_METHOD]
 * the moment it is not, and every command carries the grant it was sent under. A command whose
 * grant is not the one open answers [REVOKED_WIRE] without reaching the service, and closing the
 * gate cancels what is running. See [RemoteControlGate].
 * Failures are answered as outcomes, never thrown across the boundary.
 *
 * The text of a [SET_TEXT_METHOD] may be a password. It goes to the service and nowhere else, and
 * no log line here names it.
 *
 * It also pushes [AVAILABILITY_CHANGED_METHOD] the other way, because the user enables the
 * service from Settings while the application is in the background and has to find it enabled
 * on the way back, and [TOUCH_ENDED_METHOD], because a touch can end here (its watchdog, its
 * lifetime, the display changing) while Dart is waiting for it.
 */
class RemoteControlAccessibilityChannel(
    private val context: Context,
    private val availability: RemoteControlAvailability,
) : MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null

    fun attachTo(messenger: BinaryMessenger) {
        detach()
        // A new Dart numbers its grants from the start, and has authorised nothing yet.
        availability.resetControl()
        channel = MethodChannel(messenger, CHANNEL_NAME).also { it.setMethodCallHandler(this) }
        availability.onChanged = { available ->
            channel?.invokeMethod(AVAILABILITY_CHANGED_METHOD, available)
        }
        availability.onTouchEnded = { handle ->
            channel?.invokeMethod(TOUCH_ENDED_METHOD, handle)
        }
    }

    /**
     * The service is left alone: it belongs to Android, and only the user can turn it off. The
     * control gate is not: the Dart that opened it is gone, so nothing it authorised goes on.
     */
    fun detach() {
        if (channel != null) availability.resetControl()
        availability.onChanged = null
        availability.onTouchEnded = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method in GATED_METHODS && !availability.admits(integerArgument(call, GRANT))) {
            // Not logged per call: a touch's moves may keep arriving for a moment after the close.
            if (call.method != MOVE_TOUCH_METHOD) Log.i(TAG, "${call.method} refused: control not authorised")
            result.success(REVOKED_WIRE)
            return
        }
        when (call.method) {
            AVAILABLE_METHOD -> result.success(availability.isAvailable)

            // The authority Dart decided, mirrored: a numbered grant for one session.
            OPEN_CONTROL_METHOD -> {
                val grant = integerArgument(call, GRANT)
                val session = call.argument<Any?>(SESSION) as? String
                if (grant == null || session == null) {
                    result.success(RemoteControlOpenOutcome.STALE.wire)
                    return
                }
                val outcome = availability.openControl(grant, session)
                Log.i(TAG, "control grant $grant for $session ${outcome.wire}")
                result.success(outcome.wire)
            }

            // Waits for nothing, and refuses nothing: withdrawing never needs permission.
            CLOSE_CONTROL_METHOD -> {
                val ended = call.argument<Any?>(ENDED) as? String
                val grant = availability.gate.openGrant
                val revocation = availability.closeControl(ended)
                if (revocation != null) {
                    Log.i(
                        TAG,
                        "control grant $grant revoked" +
                            (if (revocation.gestureRunning) " (gesture running, cancel ${if (revocation.cancelRequested) "requested" else "unavailable"})" else "") +
                            (if (revocation.touchAbandoned) " (touch let go)" else ""),
                    )
                }
                if (ended != null) Log.i(TAG, "control for $ended ended for good")
                result.success(null)
            }

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

            // A position and nothing else: how long to hold is the device's to decide.
            LONG_PRESS_METHOD -> {
                val x = call.argument<Double>(X)
                val y = call.argument<Double>(Y)
                if (x == null || y == null) {
                    result.success(RemoteGestureOutcome.INVALID.wire)
                    return
                }
                availability.longPress(x, y) { outcome ->
                    Log.i(TAG, "long_press ${outcome.wire}")
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

            BACK_METHOD -> availability.back(answerAction("back", result))

            HOME_METHOD -> availability.home(answerAction("home", result))

            RECENTS_METHOD -> availability.recents(answerAction("recents", result))

            SET_TEXT_METHOD -> {
                val text = call.argument<Any?>(TEXT) as? String
                if (text == null) {
                    result.success(RemoteGestureOutcome.INVALID.wire)
                    return
                }
                availability.setText(text, answerAction("set_text", result))
            }

            // No arguments: which field and which action are the device's to find, not the call's.
            IME_ENTER_METHOD -> availability.imeEnter(answerAction("ime_enter", result))

            // A handle Dart chose, and a position: how long the hold lasts is the device's.
            START_TOUCH_METHOD -> {
                val handle = call.argument<Any?>(TOUCH) as? Int
                val x = call.argument<Any?>(X) as? Double
                val y = call.argument<Any?>(Y) as? Double
                if (handle == null || x == null || y == null) {
                    result.success(RemoteTouchOutcome.INVALID.wire)
                    return
                }
                availability.startTouch(handle, x, y) { outcome ->
                    Log.i(TAG, "touch $handle hold ${outcome.wire}")
                    result.success(outcome.wire)
                }
            }

            // Answered at once, and not logged: there may be thirty of these a second.
            MOVE_TOUCH_METHOD -> {
                val handle = call.argument<Any?>(TOUCH) as? Int
                val seq = integerArgument(call, SEQ)
                val x = call.argument<Any?>(X) as? Double
                val y = call.argument<Any?>(Y) as? Double
                if (handle == null || seq == null || x == null || y == null) {
                    result.success(RemoteTouchOutcome.INVALID.wire)
                    return
                }
                result.success(availability.moveTouch(handle, seq, x, y).wire)
            }

            RELEASE_TOUCH_METHOD -> {
                val handle = call.argument<Any?>(TOUCH) as? Int
                val seq = integerArgument(call, SEQ)
                val x = call.argument<Any?>(X) as? Double
                val y = call.argument<Any?>(Y) as? Double
                if (handle == null || seq == null || x == null || y == null) {
                    result.success(RemoteTouchOutcome.INVALID.wire)
                    return
                }
                availability.releaseTouch(handle, seq, x, y) { outcome ->
                    Log.i(TAG, "touch $handle release ${outcome.wire}")
                    result.success(outcome.wire)
                }
            }

            CANCEL_TOUCH_METHOD -> {
                val handle = call.argument<Any?>(TOUCH) as? Int
                if (handle == null) {
                    result.success(RemoteTouchOutcome.INVALID.wire)
                    return
                }
                availability.cancelTouch(handle) { outcome ->
                    Log.i(TAG, "touch $handle cancel ${outcome.wire}")
                    result.success(outcome.wire)
                }
            }

            // Waits for nothing: whatever ended the session must not wait for a finger.
            ABANDON_TOUCH_METHOD -> {
                (call.argument<Any?>(TOUCH) as? Int)?.let(availability::abandonTouch)
                result.success(null)
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

    /** An integer, as the codec sends one: 32 bits when it fits, 64 when not. Never a double. */
    private fun integerArgument(call: MethodCall, name: String): Long? =
        when (val value = call.argument<Any?>(name)) {
            is Int -> value.toLong()
            is Long -> value
            else -> null
        }

    /** Android only says it took the action, so that is what the log says. */
    private fun answerAction(
        name: String,
        result: MethodChannel.Result,
    ): (RemoteGestureOutcome) -> Unit = { outcome ->
        val said = if (outcome == RemoteGestureOutcome.COMPLETED) "accepted" else outcome.wire
        Log.i(TAG, "$name $said")
        result.success(outcome.wire)
    }

    companion object {
        private const val TAG = "RemoteControlInput"

        const val CHANNEL_NAME = "remote_control/accessibility"
        const val AVAILABLE_METHOD = "isAccessibilityServiceAvailable"
        const val TAP_METHOD = "performTap"
        const val LONG_PRESS_METHOD = "performLongPress"
        const val SWIPE_METHOD = "performSwipe"
        const val BACK_METHOD = "performBack"
        const val HOME_METHOD = "performHome"
        const val RECENTS_METHOD = "performRecents"
        const val SET_TEXT_METHOD = "performSetText"
        const val IME_ENTER_METHOD = "performImeEnter"
        const val SETTINGS_METHOD = "openAccessibilitySettings"
        const val AVAILABILITY_CHANGED_METHOD = "accessibilityServiceAvailabilityChanged"
        const val START_TOUCH_METHOD = "startRemoteTouch"
        const val MOVE_TOUCH_METHOD = "moveRemoteTouch"
        const val RELEASE_TOUCH_METHOD = "releaseRemoteTouch"
        const val CANCEL_TOUCH_METHOD = "cancelRemoteTouch"
        const val ABANDON_TOUCH_METHOD = "abandonRemoteTouch"
        const val TOUCH_ENDED_METHOD = "remoteTouchEnded"
        const val OPEN_CONTROL_METHOD = "openRemoteControl"
        const val CLOSE_CONTROL_METHOD = "closeRemoteControl"

        /** What a command refused by the gate answers: the same word for gestures and touches. */
        const val REVOKED_WIRE = "revoked"

        /**
         * Every method that acts on the screen. Each must carry the [GRANT] it was sent under.
         * Cancelling or abandoning a touch only withdraws, so neither needs one.
         */
        private val GATED_METHODS = setOf(
            TAP_METHOD,
            LONG_PRESS_METHOD,
            SWIPE_METHOD,
            BACK_METHOD,
            HOME_METHOD,
            RECENTS_METHOD,
            SET_TEXT_METHOD,
            IME_ENTER_METHOD,
            START_TOUCH_METHOD,
            MOVE_TOUCH_METHOD,
            RELEASE_TOUCH_METHOD,
        )

        private const val X = "x"
        private const val Y = "y"
        private const val START_X = "startX"
        private const val START_Y = "startY"
        private const val END_X = "endX"
        private const val END_Y = "endY"
        private const val DURATION_MS = "durationMs"
        private const val TEXT = "text"
        private const val TOUCH = "touch"
        private const val SEQ = "seq"
        private const val GRANT = "grant"
        private const val SESSION = "session"
        private const val ENDED = "ended"

        private const val SETTINGS_FAILED = "ACCESSIBILITY_SETTINGS_FAILED"
    }
}
