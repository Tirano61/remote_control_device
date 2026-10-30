import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
// The plugin's native track type. It is what `getDisplayMedia` itself builds
// from a track id, and it is not exported by name; a track this application
// creates natively is wrapped the same way, so the peer connection adapter
// cannot tell the two apart.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/media_stream_track_impl.dart'
    show MediaStreamTrackNative;
import 'package:remote_control_device/features/screen_capture/data/method_channel_media_projection_service.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_video_track.dart';
import 'package:remote_control_device/features/screen_capture/domain/screen_capture_platform.dart';

/// The part of screen capture that only a tablet can verify.
///
/// The capture is not `navigator.mediaDevices.getDisplayMedia` any more. What
/// `flutter_webrtc 1.6.2+hotfix.2` does with it on Android, read from the
/// installed package:
///
/// ```text
/// getDisplayMedia   OrientationAwareScreenCapturer.startCapture(
///                       Display.getRealSize())     <- the CURRENT size
/// startCapture      in landscape: swaps width and height AGAIN
///                   -> VirtualDisplay 800x1280 on a 1280x800 screen
/// first frame       changeCaptureFormat -> VirtualDisplay.resize(1280x800)
/// ```
///
/// On the tablet that resize left the platform mirroring for the old size, and
/// landscape frames came out as the left 62.5 % of the screen stretched 1.6×.
/// Android 14 allows one virtual display per projection, so the same resize is
/// also every rotation. None of it is reachable from Dart, and none of it can
/// be fixed on the receiving side without inventing pixels.
///
/// So the capture is `ScreenCapturer.kt`: a square virtual display, never
/// resized, cropped per frame to the screen as it is right now. It produces an
/// ordinary libwebrtc video track, registered with the plugin under its id, and
/// this adapter wraps that id in the plugin's own track type — which is all
/// `RTCRtpSender.replaceTrack` needs.
///
/// Video only, by construction: the Android side creates a video source and
/// nothing else.
class FlutterWebRtcScreenMediaSource implements ScreenMediaSource {
  const FlutterWebRtcScreenMediaSource();

  static const String startCaptureMethod = 'startScreenCapture';
  static const String stopCaptureMethod = 'stopScreenCapture';

  static const String _loggerName = 'screen';

  static MethodChannel get _channel =>
      MethodChannelMediaProjectionForegroundService.channel;

  @override
  Future<ScreenMediaCapture> open() async {
    final reply = await _channel.invokeMapMethod<String, Object?>(
      startCaptureMethod,
    );
    final trackId = reply?['trackId'];
    if (trackId is! String || trackId.isEmpty) {
      // A capture this side cannot name is one it cannot send or stop. Ask
      // the Android side to release whatever it is, and fail.
      await _stop(null);
      throw StateError('screen capture started without a track');
    }

    // Diagnostics for the tablet: how big the display is now and how big the
    // frames leaving it are. Never a frame, never a token.
    if (kDebugMode) {
      developer.log(
        'capture geometry ${reply!['displayWidth']}x${reply['displayHeight']} '
        '${reply['orientation']} rotation=${reply['rotation']} '
        'dpi=${reply['densityDpi']} '
        'virtualDisplay=${reply['virtualDisplaySide']} '
        'sending=${reply['captureWidth']}x${reply['captureHeight']}',
        name: _loggerName,
      );
    }

    return FlutterWebRtcScreenMediaCapture(
      MediaStreamTrackNative(trackId, 'screen', 'video', true, 'local'),
    );
  }

  static Future<void> _stop(String? trackId) async {
    try {
      await _channel.invokeMethod<void>(stopCaptureMethod, <String, Object?>{
        'trackId': ?trackId,
      });
    } catch (_) {
      // Releasing must never throw: every teardown path calls it.
    }
  }
}

/// A capture in progress, and the one place the real track is held.
class FlutterWebRtcScreenMediaCapture implements ScreenMediaCapture {
  FlutterWebRtcScreenMediaCapture(rtc.MediaStreamTrack track)
    : _videoTrack = FlutterWebRtcScreenVideoTrack(track);

  final FlutterWebRtcScreenVideoTrack _videoTrack;

  bool _disposed = false;

  @override
  List<ScreenVideoTrack> get videoTracks => [_videoTrack];

  /// Kept on the track for the day it fires. Today it does not: the Android
  /// capturer releases itself when the user presses *Stop sharing* in the
  /// system controls, but nothing tells Dart, so what they see is the capture
  /// ending, the assistance carrying on, and the notification going away with
  /// the session.
  @override
  set onEnded(void Function()? listener) {
    _videoTrack.track.onEnded = listener;
  }

  /// Stops this capture natively — the virtual display, the projection and
  /// the track's registration go with it. Idempotent, and keyed by track id,
  /// so a late release can never stop a capture that replaced this one.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _videoTrack.track.onEnded = null;
    await FlutterWebRtcScreenMediaSource._stop(_videoTrack.id);
  }
}

/// The screen's video track, with the `flutter_webrtc` object still attached.
///
/// The one type that crosses from this adapter to the WebRTC one, and the
/// reason it is public: attaching a track to a transceiver has to happen
/// inside `flutter_webrtc`, so the peer connection adapter needs to get the
/// real object back out. It gets it by asking for this type and nothing else —
/// a [ScreenVideoTrack] from anywhere but here is refused rather than guessed
/// at.
class FlutterWebRtcScreenVideoTrack implements ScreenVideoTrack {
  const FlutterWebRtcScreenVideoTrack(this.track);

  final rtc.MediaStreamTrack track;

  /// libwebrtc types it as nullable; a track without an id cannot be looked up
  /// natively and is refused by the same check that refuses a foreign handle.
  @override
  String get id => track.id ?? '';
}
