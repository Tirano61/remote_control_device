package com.example.remote_control_device

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The Flutter activity, and a place to register channels — nothing more.
 *
 * The one channel it registers is the bridge for screen capture. It is wired here because
 * this is where a `BinaryMessenger` first exists, and it is unwired again when the engine
 * goes, so a handler never outlives the engine it answers on.
 *
 * Two contexts, on purpose. The consent dialog needs *this* activity — it is shown with
 * `startActivityForResult`, and its answer comes back through [onActivityResult]. Everything
 * else gets `applicationContext`: the service and the capture outlive any single activity —
 * the user is expected to leave the app while their screen is shared — and tying them to one
 * that may be gone by the time they are stopped would be a leak at best.
 */
class MainActivity : FlutterActivity() {

    private var mediaProjectionChannel: MediaProjectionChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        mediaProjectionChannel = MediaProjectionChannel(
            applicationContext,
            ScreenCaptureConsentRequester(this),
        ).also {
            it.attachTo(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mediaProjectionChannel?.detach()
        mediaProjectionChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // The consent dialog's answer is ours; everything else is the plugins'.
        if (mediaProjectionChannel?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
