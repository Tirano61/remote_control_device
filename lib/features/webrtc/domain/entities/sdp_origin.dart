import 'package:equatable/equatable.dart';

/// The `o=` line of an SDP offer, read for one purpose: telling which
/// `RTCPeerConnection` on the web produced it.
///
/// ```text
/// o=<username> <sess-id> <sess-version> <nettype> <addrtype> <unicast-address>
/// ```
///
/// RFC 8866 §5.2 makes every field but `sess-version` a globally unique
/// identifier of the session, and every browser and libwebrtc picks a fresh
/// random `sess-id` for each `RTCPeerConnection`. `sess-version` grows on each
/// renegotiation of that same connection. So:
///
/// ```text
/// same identity, same SDP          a repeat of the offer being negotiated
/// same identity, other version     a renegotiation of a connection already
///                                  answered (not something this build does)
/// identity seen before             an offer from a connection already given
///                                  up on: stale
/// identity never seen              a new connection on the web: a first offer,
///                                  or a recovery after the old one failed
/// ```
///
/// The signaling contract carries no negotiation id — the backend forwards
/// `remoteSessionId` and `sdp` only — so this is the only marker an offer has.
///
/// Never logged, and [toString] says nothing: an `o=` line is SDP content.
class SdpOrigin extends Equatable {
  const SdpOrigin._(this.identity, this.version);

  /// Everything in the `o=` line except `sess-version`, joined by single
  /// spaces. Equal for every offer of one `RTCPeerConnection`.
  final String identity;

  /// `sess-version`, as written.
  final String version;

  /// Reads the first `o=` line of [sdp], or returns `null` when there is none
  /// or it does not have the six fields RFC 8866 requires.
  ///
  /// An SDP with no readable origin is not something any browser produces,
  /// and an offer that cannot be told apart from the last one is never allowed
  /// to replace a peer connection.
  static SdpOrigin? tryParse(String sdp) {
    for (final rawLine in sdp.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      if (!line.startsWith('o=')) continue;

      final fields = line
          .substring(2)
          .split(' ')
          .where((field) => field.isNotEmpty)
          .toList(growable: false);
      if (fields.length != 6) return null;
      final sessionId = fields[1];
      final version = fields[2];
      if (!_isDigits(sessionId) || !_isDigits(version)) return null;

      return SdpOrigin._(
        [fields[0], sessionId, fields[3], fields[4], fields[5]].join(' '),
        version,
      );
    }
    return null;
  }

  static bool _isDigits(String value) =>
      value.isNotEmpty && value.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

  @override
  List<Object?> get props => [identity, version];

  @override
  String toString() => 'SdpOrigin(<redacted>)';
}
