import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// Something arrived on the `control` channel.
///
/// Raw on purpose. This stage establishes the channel and stops there: there is
/// no control protocol yet, nothing is parsed, and above all nothing is
/// *executed* — no tap, no swipe, no Back, no text. Interpreting these bytes is
/// the next prompt's work, and it will need an Android side that does not exist
/// in this build.
///
/// Exposed all the same, because a channel whose messages go nowhere cannot be
/// told apart from one that is silently broken.
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

  /// Never the contents: until there is a control protocol, an unparsed frame
  /// from the other end is untrusted input and is not worth printing.
  @override
  String toString() => 'WebRtcDataChannelMessage(binary: $isBinary)';
}
