package com.example.remote_control_device

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps a MediaProjection screen capture alive, and tells the user it is running.
 *
 * Android 14 made this mandatory rather than polite: a capture may only start while a
 * foreground service declared `foregroundServiceType="mediaProjection"` is running, and
 * that service may only start once the user has granted the projection. So the order is
 * fixed, and it is enforced on the Flutter side, in `MediaProjectionScreenCaptureClient`:
 *
 * ```text
 * consent dialog  ->  this service, READY  ->  capture
 * ```
 *
 * "Running" means `startForeground(..., MEDIA_PROJECTION)` has returned, not that
 * `startForegroundService` has. The second only queues the service: `onStartCommand` runs
 * later, on the main thread, and a capture started in between is refused with
 * `SecurityException: Media projections require a foreground service of type
 * FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION`. That race was seen on a tablet, intermittently,
 * on a second consecutive session. So [start] takes a callback, and the callback is answered
 * from [onStartCommand] once the platform has accepted the foreground type — never before,
 * and never by a timer.
 *
 * What this class does *not* do is as deliberate as what it does. There is no WebRTC here,
 * no Socket.IO, no session, no identity: it starts foreground, says so, holds a notification,
 * and stops. Everything that is a decision lives in Dart, where it can be tested without a
 * tablet.
 *
 * The notification is not decoration. It is the only thing that tells someone their screen
 * is being shared while they are using another app, so it is ongoing, it cannot be swiped
 * away, and it goes down with the service.
 */
class MediaProjectionForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val token = intent?.getLongExtra(EXTRA_START_TOKEN, NO_TOKEN) ?: NO_TOKEN

        try {
            createNotificationChannel()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // The type has to be named here as well as in the manifest. Naming only one of
                // the two is the mistake that throws on Android 14.
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
        } catch (error: Exception) {
            // SecurityException or InvalidForegroundServiceTypeException, above all. Only the
            // class name: a platform message here can quote the intent that started us.
            Log.w(TAG, "media projection service refused: ${error.javaClass.simpleName}")
            settle(token, error.javaClass.simpleName)
            stopSelf(startId)
            return START_NOT_STICKY
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            (foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION) == 0
        ) {
            // Foreground, but not as the one type a capture accepts. Reporting READY here would
            // be the same SecurityException, one step later.
            Log.w(TAG, "media projection service is foreground without the mediaProjection type")
            settle(token, NOT_MEDIA_PROJECTION)
            stopSelf(startId)
            return START_NOT_STICKY
        }

        Log.i(TAG, "media projection service ready")
        settle(token, null)

        // Not sticky: a capture cannot outlive the process that was granted it. If Android
        // kills us, the projection is gone too, and a service restarted without one would
        // be a notification about a share that is not happening.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            // Low: it must be present and unmissable in the shade, not something that
            // makes a sound or covers what the technician is walking the user through.
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(CHANNEL_NAME)
            .setContentText("Compartiendo pantalla")
            .setSmallIcon(R.drawable.ic_screen_share)
            .setOngoing(true)
            .build()
    }

    /** One [start] waiting to hear from [onStartCommand]. */
    private class PendingStart(
        val token: Long,
        val onReady: () -> Unit,
        val onFailed: (String) -> Unit,
    )

    companion object {
        private const val TAG = "RemoteControlScreen"
        private const val CHANNEL_ID = "remote_assistance_screen_share"
        private const val CHANNEL_NAME = "Asistencia remota"
        private const val NOTIFICATION_ID = 1001

        private const val EXTRA_START_TOKEN = "remote_control_device.media_projection.start_token"
        private const val NO_TOKEN = 0L

        const val NOT_MEDIA_PROJECTION = "NOT_MEDIA_PROJECTION"
        const val SUPERSEDED = "SUPERSEDED"
        const val STOPPED = "STOPPED"

        // Main thread only: `start`/`stop` are called from the MethodChannel handler and
        // `onStartCommand` runs on the main thread, so there is nothing to synchronise.
        private var lastStartToken = NO_TOKEN
        private var pendingStart: PendingStart? = null

        /**
         * Starts the service and answers once it is foreground as `mediaProjection`.
         *
         * Exactly one of [onReady] and [onFailed] is called, exactly once: [onReady] from
         * [onStartCommand] after `startForeground` returned with the right type; [onFailed]
         * if the platform refused to start the service, refused the foreground type, or the
         * start was overtaken by a [stop] or by another [start] before it was answered.
         *
         * Every start carries a token of its own, so a late answer for an earlier start — a
         * previous session's service coming up after it was already abandoned — can never be
         * mistaken for this one.
         */
        fun start(context: Context, onReady: () -> Unit, onFailed: (String) -> Unit) {
            abandonPendingStart(SUPERSEDED)

            val token = ++lastStartToken
            pendingStart = PendingStart(token, onReady, onFailed)
            Log.i(TAG, "media projection service starting")

            val intent = Intent(context, MediaProjectionForegroundService::class.java)
                .putExtra(EXTRA_START_TOKEN, token)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                // ForegroundServiceStartNotAllowedException when the app is not in the
                // foreground, above all.
                Log.w(TAG, "media projection service not started: ${error.javaClass.simpleName}")
                settle(token, error.javaClass.simpleName)
            }
        }

        /**
         * Stops it. A no-op when it is not running, which is what makes it idempotent. A start
         * still waiting for its answer is failed first, so nothing about this service can reach
         * the next one.
         */
        fun stop(context: Context) {
            abandonPendingStart(STOPPED)
            context.stopService(Intent(context, MediaProjectionForegroundService::class.java))
        }

        /** Fails the start that is waiting, if any. For a bridge that is going away. */
        fun abandonPendingStart(reason: String) {
            val pending = pendingStart ?: return
            pendingStart = null
            pending.onFailed(reason)
        }

        private fun settle(token: Long, failure: String?) {
            val pending = pendingStart ?: return
            if (pending.token != token) return
            pendingStart = null
            if (failure == null) pending.onReady() else pending.onFailed(failure)
        }
    }
}
