package com.example.remote_control_device

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.MethodCallHandlerImpl
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.PeerConnectionFactory
import org.webrtc.VideoTrack

/**
 * The one place this application reaches into `flutter_webrtc`'s Android internals.
 *
 * A track made here has to be usable from Dart exactly like one the plugin made: the
 * peer connection adapter hands its id to `RTCRtpSender.replaceTrack`, and the plugin
 * resolves that id in its own table of local tracks. The plugin offers no public way to
 * add to that table — `MethodCallHandlerImpl.putLocalTrack` is public, but the handler
 * itself is a private field of `FlutterWebRTCPlugin` — so it is read by reflection, here
 * and nowhere else, against `flutter_webrtc 1.6.2+hotfix.2`.
 *
 * If a future plugin version renames that field, registering fails, the capture is torn
 * down, and the assistance carries on without the screen: the failure is a value, never a
 * crash. Everything else used — the factory, `putLocalTrack`, `trackDispose`,
 * `LocalVideoTrack` — is the plugin's public API.
 */
object FlutterWebRtcLocalTracks {

    private const val HANDLER_FIELD = "methodCallHandler"

    /** The plugin's own factory, so the track lives in the same libwebrtc as the peer. */
    fun peerConnectionFactory(): PeerConnectionFactory =
        handler().peerConnectionFactory
            ?: throw IllegalStateException("flutter_webrtc is not initialised")

    /** Makes [track] resolvable by [trackId] from Dart, like any track the plugin made. */
    fun register(trackId: String, track: VideoTrack) {
        handler().putLocalTrack(trackId, LocalVideoTrack(track))
    }

    /**
     * Forgets it: the plugin disables it, detaches it from any renderer and drops it from its
     * table. The native track itself is not disposed — an `RtpSender` may still hold the
     * Java object (`replaceTrack` sets it without taking ownership), and a disposed one there
     * is an `IllegalStateException` the next time the transceivers are read.
     */
    fun unregister(trackId: String) {
        val handler = try {
            handler()
        } catch (_: Exception) {
            return
        }
        handler.trackDispose(trackId)
    }

    private fun handler(): MethodCallHandlerImpl {
        val plugin = FlutterWebRTCPlugin.sharedSingleton
            ?: throw IllegalStateException("flutter_webrtc is not registered")
        val field = FlutterWebRTCPlugin::class.java.getDeclaredField(HANDLER_FIELD)
        field.isAccessible = true
        return field.get(plugin) as? MethodCallHandlerImpl
            ?: throw IllegalStateException("flutter_webrtc is not attached")
    }
}
