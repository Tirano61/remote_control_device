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
        decodeText('{"v":1,"type":"pinch","id":"p-1","x":0,"y":0}'),
        const RemoteControlMessageRejected(
          'p-1',
          RemoteControlError.unsupportedCommand,
        ),
      );
    });

    test('another version is not read as a version 1 swipe', () {
      expect(
        decodeText(
          '{"v":2,"type":"swipe","id":"later","startX":0.5,"startY":0.8,'
          '"endX":0.5,"endY":0.2,"durationMs":300}',
        ),
        const RemoteControlMessageRejected(
          'later',
          RemoteControlError.unsupportedCommand,
        ),
      );
    });
  });

  group('a swipe', () {
    /// A valid swipe with one field replaced, or removed when [value] is null.
    RemoteControlInboundMessage? decodeSwipeWith(String field, String? value) {
      final fields = <String, String>{
        'startX': '0.2',
        'startY': '0.8',
        'endX': '0.2',
        'endY': '0.3',
        'durationMs': '300',
      };
      if (value == null) {
        fields.remove(field);
      } else {
        fields[field] = value;
      }
      final body = fields.entries.map((e) => '"${e.key}":${e.value}').join(',');
      return decodeText('{"v":1,"type":"swipe","id":"s-1",$body}');
    }

    const invalid = RemoteControlMessageRejected(
      's-1',
      RemoteControlError.invalidCommand,
    );

    test('decodes to exactly the typed command', () {
      expect(
        decodeText(
          '{"v":1,"type":"swipe","id":"swipe-1","startX":0.2,"startY":0.8,'
          '"endX":0.2,"endY":0.3,"durationMs":300}',
        ),
        const RemoteControlCommandReceived(
          RemoteSwipeCommand(
            id: 'swipe-1',
            startX: 0.2,
            startY: 0.8,
            endX: 0.2,
            endY: 0.3,
            durationMs: 300,
          ),
        ),
      );
    });

    test('ignores unknown extra fields, as a tap does', () {
      expect(
        decodeSwipeWith('extra', '"ignored"'),
        isA<RemoteControlCommandReceived>(),
      );
    });

    group('durationMs', () {
      for (final valid in const [50, 300, 2000]) {
        test('$valid is valid', () {
          final decoded = decodeSwipeWith('durationMs', '$valid');

          expect(decoded, isA<RemoteControlCommandReceived>());
          final command =
              (decoded! as RemoteControlCommandReceived).command
                  as RemoteSwipeCommand;
          expect(command.durationMs, valid);
        });
      }

      for (final (name, value) in const [
        ('49, just below the range', '49'),
        ('2001, just above the range', '2001'),
        ('zero', '0'),
        ('negative', '-300'),
        ('300.0, which decodes to a double', '300.0'),
        ('3e2, which decodes to a double', '3e2'),
        ('a numeric string', '"300"'),
        ('null', 'null'),
        ('a bool', 'true'),
        ('infinite', '1e999'),
        ('missing', null),
      ]) {
        test('$name is invalid', () {
          expect(decodeSwipeWith('durationMs', value), invalid);
        });
      }
    });

    for (final field in const ['startX', 'startY', 'endX', 'endY']) {
      group(field, () {
        for (final value in const ['0.0', '0.5', '1.0', '0', '1']) {
          test('$value is valid', () {
            expect(
              decodeSwipeWith(field, value),
              isA<RemoteControlCommandReceived>(),
            );
          });
        }

        for (final (name, value) in const [
          ('below the range', '-0.1'),
          ('above the range', '1.1'),
          ('infinite', '1e999'),
          ('negative infinite', '-1e999'),
          ('a numeric string', '"0.5"'),
          ('null', 'null'),
          ('a bool', 'true'),
          ('missing', null),
        ]) {
          test('$name is invalid, not clamped', () {
            expect(decodeSwipeWith(field, value), invalid);
          });
        }
      });
    }

    group('that goes nowhere', () {
      test('is invalid, and does not become a tap', () {
        expect(
          decodeText(
            '{"v":1,"type":"swipe","id":"s-1","startX":0.5,"startY":0.5,'
            '"endX":0.5,"endY":0.5,"durationMs":300}',
          ),
          invalid,
        );
      });

      test('is still nowhere when written differently', () {
        expect(
          decodeText(
            '{"v":1,"type":"swipe","id":"s-1","startX":1,"startY":0,'
            '"endX":1.0,"endY":-0.0,"durationMs":300}',
          ),
          invalid,
        );
      });

      test('moving along one axis only is not nowhere', () {
        expect(
          decodeText(
            '{"v":1,"type":"swipe","id":"s-1","startX":0.5,"startY":0.5,'
            '"endX":0.51,"endY":0.5,"durationMs":300}',
          ),
          isA<RemoteControlCommandReceived>(),
        );
      });
    });

    test('a tap\'s x and y do not make a swipe', () {
      expect(
        decodeText('{"v":1,"type":"swipe","id":"s-1","x":0.5,"y":0.5}'),
        invalid,
      );
    });

    test('a swipe\'s fields do not make a tap', () {
      expect(
        decodeText(
          '{"v":1,"type":"tap","id":"s-1","startX":0.5,"startY":0.8,'
          '"endX":0.5,"endY":0.2,"durationMs":300}',
        ),
        invalid,
      );
    });
  });

  for (final (type, otherType, command) in const [
    ('back', 'home', RemoteBackCommand(id: 'nav-1')),
    ('home', 'back', RemoteHomeCommand(id: 'nav-1')),
  ]) {
    group('a $type', () {
      test('decodes to exactly the typed command', () {
        expect(
          decodeText('{"v":1,"type":"$type","id":"nav-1"}'),
          RemoteControlCommandReceived(command),
        );
      });

      test('is not the same command as a $otherType with that id', () {
        expect(
          decodeText('{"v":1,"type":"$otherType","id":"nav-1"}'),
          isNot(RemoteControlCommandReceived(command)),
        );
      });

      test('ignores unknown extra fields, as a tap does', () {
        expect(
          decodeText(
            '{"v":1,"type":"$type","id":"nav-1","x":0.5,"durationMs":"no"}',
          ),
          RemoteControlCommandReceived(command),
        );
      });

      group('with nothing to answer to is ignored', () {
        for (final (name, text) in [
          ('a missing id', '{"v":1,"type":"$type"}'),
          ('a null id', '{"v":1,"type":"$type","id":null}'),
          ('a numeric id', '{"v":1,"type":"$type","id":7}'),
          ('an empty id', '{"v":1,"type":"$type","id":""}'),
          ('a payload that is a list', '[{"v":1,"type":"$type","id":"a"}]'),
          ('a payload that is a string', '"$type"'),
          ('broken JSON', '{"v":1,"type":"$type",'),
        ]) {
          test(name, () => expect(decodeText(text), isNull));
        }
      });

      for (final (name, fields) in [
        ('v missing', '"type":"$type"'),
        ('v as a string', '"v":"1","type":"$type"'),
        ('v as a double', '"v":1.0,"type":"$type"'),
        ('v null', '"v":null,"type":"$type"'),
      ]) {
        test('$name is invalid', () {
          expect(
            decodeText('{"id":"bad",$fields}'),
            const RemoteControlMessageRejected(
              'bad',
              RemoteControlError.invalidCommand,
            ),
          );
        });
      }

      test('another version is not read as version 1', () {
        expect(
          decodeText('{"v":2,"type":"$type","id":"later"}'),
          const RemoteControlMessageRejected(
            'later',
            RemoteControlError.unsupportedCommand,
          ),
        );
      });

      test('in another case is another type', () {
        expect(
          decodeText('{"v":1,"type":"${type.toUpperCase()}","id":"nav-1"}'),
          const RemoteControlMessageRejected(
            'nav-1',
            RemoteControlError.unsupportedCommand,
          ),
        );
      });
    });
  }

  test('a type that is not a string is invalid, whatever else is there', () {
    expect(
      decodeText('{"v":1,"type":["back"],"id":"nav-1"}'),
      const RemoteControlMessageRejected(
        'nav-1',
        RemoteControlError.invalidCommand,
      ),
    );
  });

  test('recents is not a command yet', () {
    expect(
      decodeText('{"v":1,"type":"recents","id":"nav-1"}'),
      const RemoteControlMessageRejected(
        'nav-1',
        RemoteControlError.unsupportedCommand,
      ),
    );
  });

  group('acks', () {
    test('a back and a home are answered like any command', () {
      expect(
        jsonDecode(
          RemoteControlChannelCodec.encodeAck(
            const RemoteControlAck.success('home-123'),
          ),
        ),
        {'v': 1, 'type': 'ack', 'id': 'home-123', 'ok': true},
      );
      expect(
        jsonDecode(
          RemoteControlChannelCodec.encodeAck(
            const RemoteControlAck.failure(
              'back-123',
              RemoteControlError.gestureRejected,
            ),
          ),
        ),
        {
          'v': 1,
          'type': 'ack',
          'id': 'back-123',
          'ok': false,
          'error': 'gesture_rejected',
        },
      );
    });

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
