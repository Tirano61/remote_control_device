import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/data/remote_control_channel_codec.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_inbound_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';

/// The wire format, byte by byte where it matters. Everything arriving here is
/// untrusted, so most of this file is the ways a message can be wrong.
void main() {
  RemoteControlInboundMessage? decodeText(String text) =>
      RemoteControlChannelCodec.decode(WebRtcDataChannelMessage.text(text));

  group('a valid tap', () {
    test('decodes to a typed command', () {
      expect(
        decodeText('{"v":1,"type":"tap","id":"tap-123","x":0.5,"y":0.25}'),
        const RemoteControlCommandReceived(
          RemoteTapCommand(id: 'tap-123', x: 0.5, y: 0.25),
        ),
      );
    });

    test('accepts both ends of the range, written as integers', () {
      expect(
        decodeText('{"v":1,"type":"tap","id":"a","x":0,"y":1}'),
        const RemoteControlCommandReceived(
          RemoteTapCommand(id: 'a', x: 0, y: 1),
        ),
      );
    });

    test('does not assume the id is a UUID', () {
      final decoded = decodeText(
        '{"v":1,"type":"tap","id":"  ¿7?","x":0,"y":0}',
      );

      expect(decoded, isA<RemoteControlCommandReceived>());
      final command = (decoded! as RemoteControlCommandReceived).command;
      expect(command.id, '  ¿7?');
    });
  });

  group('nothing to answer to is ignored', () {
    test('a binary frame', () {
      expect(
        RemoteControlChannelCodec.decode(
          WebRtcDataChannelMessage.binary(
            Uint8List.fromList(
              utf8.encode('{"v":1,"type":"tap","id":"a","x":0,"y":0}'),
            ),
          ),
        ),
        isNull,
      );
    });

    for (final (name, text) in const [
      ('broken JSON', '{"v":1,"type":"tap",'),
      ('an empty frame', ''),
      ('a literal NaN, which is not JSON', '{"v":1,"id":"a","x":NaN,"y":0}'),
      ('a payload that is a list', '[{"v":1,"type":"tap","id":"a"}]'),
      ('a payload that is a number', '1'),
      ('a payload that is null', 'null'),
      ('a missing id', '{"v":1,"type":"tap","x":0,"y":0}'),
      ('an empty id', '{"v":1,"type":"tap","id":"","x":0,"y":0}'),
      ('a numeric id', '{"v":1,"type":"tap","id":7,"x":0,"y":0}'),
      ('a null id', '{"v":1,"type":"tap","id":null,"x":0,"y":0}'),
    ]) {
      test(name, () => expect(decodeText(text), isNull));
    }
  });

  group('malformed, with an id, is invalid_command', () {
    for (final (name, fields) in const [
      ('v missing', '"type":"tap","x":0,"y":0'),
      ('v as a string', '"v":"1","type":"tap","x":0,"y":0'),
      ('v as a double', '"v":1.0,"type":"tap","x":0,"y":0'),
      ('v null', '"v":null,"type":"tap","x":0,"y":0'),
      ('type missing', '"v":1,"x":0,"y":0'),
      ('type not a string', '"v":1,"type":3,"x":0,"y":0'),
      ('x missing', '"v":1,"type":"tap","y":0'),
      ('y missing', '"v":1,"type":"tap","x":0'),
      ('x null', '"v":1,"type":"tap","x":null,"y":0'),
      ('y null', '"v":1,"type":"tap","x":0,"y":null'),
      ('x as a numeric string', '"v":1,"type":"tap","x":"0.5","y":0'),
      ('y as a numeric string', '"v":1,"type":"tap","x":0,"y":"0.5"'),
      ('x as a bool', '"v":1,"type":"tap","x":true,"y":0'),
      ('x infinite', '"v":1,"type":"tap","x":1e999,"y":0'),
      ('x negative infinite', '"v":1,"type":"tap","x":-1e999,"y":0'),
      ('y infinite', '"v":1,"type":"tap","x":0,"y":1e999'),
      ('x below the range', '"v":1,"type":"tap","x":-0.1,"y":0'),
      ('x above the range', '"v":1,"type":"tap","x":1.1,"y":0'),
      ('y below the range', '"v":1,"type":"tap","x":0,"y":-0.1'),
      ('y above the range', '"v":1,"type":"tap","x":0,"y":1.1'),
    ]) {
      test(name, () {
        expect(
          decodeText('{"id":"bad",$fields}'),
          const RemoteControlMessageRejected(
            'bad',
            RemoteControlError.invalidCommand,
          ),
        );
      });
    }
  });

  group('well formed, but not something this build knows', () {
    test('another version is not read as version 1', () {
      // Fields that would make a perfectly good v1 tap, and it still is not.
      expect(
        decodeText('{"v":2,"type":"tap","id":"later","x":0.5,"y":0.5}'),
        const RemoteControlMessageRejected(
          'later',
          RemoteControlError.unsupportedCommand,
        ),
      );
    });

    test('another version needs nothing else to be well formed', () {
      expect(
        decodeText('{"v":0,"id":"old"}'),
        const RemoteControlMessageRejected(
          'old',
          RemoteControlError.unsupportedCommand,
        ),
      );
    });

    test('an unknown type', () {
      expect(
        decodeText('{"v":1,"type":"swipe","id":"s-1","x":0,"y":0}'),
        const RemoteControlMessageRejected(
          's-1',
          RemoteControlError.unsupportedCommand,
        ),
      );
    });
  });

  group('acks', () {
    test('success is exactly the documented object', () {
      expect(
        jsonDecode(
          RemoteControlChannelCodec.encodeAck(
            const RemoteControlAck.success('tap-1'),
          ),
        ),
        {'v': 1, 'type': 'ack', 'id': 'tap-1', 'ok': true},
      );
    });

    for (final (error, wire) in const [
      (
        RemoteControlError.accessibilityUnavailable,
        'accessibility_unavailable',
      ),
      (RemoteControlError.sessionNotActive, 'session_not_active'),
      (RemoteControlError.gestureRejected, 'gesture_rejected'),
      (RemoteControlError.invalidCommand, 'invalid_command'),
      (RemoteControlError.unsupportedCommand, 'unsupported_command'),
    ]) {
      test('failure carries $wire', () {
        expect(
          jsonDecode(
            RemoteControlChannelCodec.encodeAck(
              RemoteControlAck.failure('tap-1', error),
            ),
          ),
          {'v': 1, 'type': 'ack', 'id': 'tap-1', 'ok': false, 'error': wire},
        );
      });
    }
  });
}
