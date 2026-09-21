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

/**
 * Keeps a MediaProjection screen capture alive, and tells the user it is running.
 *
 * Android 14 made this mandatory rather than polite: a capture may only start while a
 * foreground service declared `foregroundServiceType="mediaProjection"` is running, and
 * that service may only start once the user has granted the projection. So the order is
 * fixed, and it is enforced on the Flutter side, in `MediaProjectionScreenCaptureClient`:
 *
 * ```text
 * consent dialog  ->  this service  ->  getDisplayMedia
 * ```
 *
 * What this class does *not* do is as deliberate as what it does. There is no WebRTC here,
 * no Socket.IO, no session, no identity, no state that anything else reads: it starts
 * foreground, holds a notification, and stops. Everything that is a decision lives in Dart,
 * where it can be tested without a tablet.
 *
 * The notification is not decoration. It is the only thing that tells someone their screen
 * is being shared while they are using another app, so it is ongoing, it cannot be swiped
 * away, and it goes down with the service.
 */
class MediaProjectionForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
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

    companion object {
        private const val CHANNEL_ID = "remote_assistance_screen_share"
        private const val CHANNEL_NAME = "Asistencia remota"
        private const val NOTIFICATION_ID = 1001

        /**
         * Starts it, or does nothing if it is already running.
         *
         * Throws whatever the platform throws — `ForegroundServiceStartNotAllowedException`
         * and `SecurityException` above all — so that the Flutter side can report a screen
         * that could not be shared instead of a session that could not be answered.
         */
        fun start(context: Context) {
            val intent = Intent(context, MediaProjectionForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Stops it. A no-op when it is not running, which is what makes it idempotent. */
        fun stop(context: Context) {
            context.stopService(Intent(context, MediaProjectionForegroundService::class.java))
        }
    }
}
