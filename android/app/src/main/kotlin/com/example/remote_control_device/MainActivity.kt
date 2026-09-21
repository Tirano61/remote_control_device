package com.example.remote_control_device

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The Flutter activity, and a place to register channels — nothing more.
 *
 * The one channel it registers is the bridge to the MediaProjection foreground service.
 * It is wired here because this is where a `BinaryMessenger` first exists, and it is
 * unwired again when the engine goes, so a handler never outlives the engine it answers on.
 *
 * `applicationContext` and not `this`: the service outlives any single activity — the user
 * is expected to leave the app while their screen is shared — and starting it from an
 * activity context would tie it to one that may be gone by the time it is stopped.
 */
class MainActivity : FlutterActivity() {

    private var mediaProjectionChannel: MediaProjectionChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        mediaProjectionChannel = MediaProjectionChannel(applicationContext).also {
            it.attachTo(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mediaProjectionChannel?.detach()
        mediaProjectionChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
