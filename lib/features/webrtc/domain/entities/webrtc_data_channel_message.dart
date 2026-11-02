import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// A raw frame as the `control` channel delivered it, before decoding.
///
/// Only the peer connection adapter and the codec see this. What crosses the
/// port is the decoded `RemoteControlInboundMessage`.
class WebRtcDataChannelMessage extends Equatable {
  const WebRtcDataChannelMessage.text(String value)
    : text = value,
      binary = null;

  const WebRtcDataChannelMessage.binary(Uint8List value)
    : text = null,
      binary = value;

  /// Set when the peer sent a text frame.
  final String? text;

  /// Set when the peer sent a binary frame.
  final Uint8List? binary;

  bool get isBinary => binary != null;

  @override
  List<Object?> get props => [text, binary];

  /// Never the contents: an unparsed frame from the other end is untrusted
  /// input and is not worth printing.
  @override
  String toString() => 'WebRtcDataChannelMessage(binary: $isBinary)';
}
