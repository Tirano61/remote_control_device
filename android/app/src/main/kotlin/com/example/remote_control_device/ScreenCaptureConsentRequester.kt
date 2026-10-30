package com.example.remote_control_device

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build

/**
 * Android's screen capture consent dialog, and the one grant it produced.
 *
 * It used to be `flutter_webrtc`'s `Helper.requestCapturePermission`, which keeps the grant
 * in a private field of its own for its own capturer. This application now captures with
 * [ScreenCapturer], so it asks for the grant itself and keeps it here, for exactly one
 * capture: [takeGrant] hands it over and forgets it, and a new capture needs a new consent.
 *
 * The grant is an `Intent` carrying a projection token. It is never logged, never put in a
 * MethodChannel reply, and never leaves the Android side.
 */
class ScreenCaptureConsentRequester(private val activity: Activity) {

    private var pendingAnswer: ((Boolean) -> Unit)? = null
    private var grant: Intent? = null

    /**
     * Shows the dialog and answers with what the user chose. Throws when it cannot be shown —
     * the activity is going away, or a dialog is already up.
     *
     * Whole display only, on Android 14 and later: a technician walking someone through
     * their tablet needs the device, and a single-app share goes black the moment the user
     * leaves that app — which reads as a broken session rather than as a choice.
     */
    fun request(onAnswer: (Boolean) -> Unit) {
        check(pendingAnswer == null) { "a consent dialog is already showing" }
        check(!activity.isFinishing && !activity.isDestroyed) { "no activity to show it from" }

        grant = null
        val manager = activity.getSystemService(MediaProjectionManager::class.java)
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            manager.createScreenCaptureIntent()
        }
        activity.startActivityForResult(intent, REQUEST_CODE)
        pendingAnswer = onAnswer
    }

    /** Forwarded from the activity. Answers whether the result was this requester's. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false

        // A dialog nobody is waiting for any more — the session ended while it was up — is
        // not allowed to leave a grant behind for the next one.
        val answer = pendingAnswer ?: return true
        pendingAnswer = null
        val granted = resultCode == Activity.RESULT_OK && data != null
        grant = if (granted) data else null
        answer(granted)
        return true
    }

    /** The grant, once. `null` when there is none, or it was already taken. */
    fun takeGrant(): Intent? {
        val taken = grant
        grant = null
        return taken
    }

    /** Forgets an unused grant, and answers a dialog nobody is waiting for any more. */
    fun reset() {
        grant = null
        val answer = pendingAnswer
        pendingAnswer = null
        answer?.invoke(false)
    }

    companion object {
        // Distinct from anything flutter_webrtc or the Flutter embedding uses.
        private const val REQUEST_CODE = 0x5C4E
    }
}
