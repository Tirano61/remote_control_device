import 'package:equatable/equatable.dart';

/// One ICE server.
///
/// [urls] is a list because the standard makes it one. There are deliberately
/// no credentials: TURN is not configured in this build, and a `username` /
/// `credential` pair would be a shared secret compiled into an APK.
class WebRtcIceServer extends Equatable {
  const WebRtcIceServer(this.urls);

  final List<String> urls;

  @override
  List<Object?> get props => [urls];
}

/// The ICE servers a peer connection is built with.
///
/// Configured centrally and injected at compile time, exactly as
/// `remote_control_web` does it:
///
/// ```text
/// --dart-define=WEBRTC_STUN_URL=stun:stun.l.google.com:19302
/// ```
///
/// With no value the list is empty, which is the right default for the LAN test
/// this stage is aimed at: host candidates alone connect two devices on the
/// same network, and a STUN server that cannot be reached only adds latency to
/// gathering.
///
/// Both ends must be configured the same way for a real test. STUN discovers a
/// public address; it does not relay, so two peers behind symmetric NATs will
/// not connect whatever is set here. That is a TURN problem and TURN is not in
/// this prompt.
class WebRtcIceConfiguration extends Equatable {
  const WebRtcIceConfiguration(this.iceServers);

  /// No ICE servers: host candidates only.
  const WebRtcIceConfiguration.none() : iceServers = const [];

  /// Reads the single configured STUN URL, treating an empty or blank value as
  /// "not configured" — `String.fromEnvironment` yields `''` when the define is
  /// absent, and an empty `urls` entry would be a malformed server rather than
  /// no server.
  factory WebRtcIceConfiguration.fromStunUrl(String? stunUrl) {
    final url = stunUrl?.trim() ?? '';
    if (url.isEmpty) return const WebRtcIceConfiguration.none();
    return WebRtcIceConfiguration([
      WebRtcIceServer([url]),
    ]);
  }

  final List<WebRtcIceServer> iceServers;

  @override
  List<Object?> get props => [iceServers];
}
