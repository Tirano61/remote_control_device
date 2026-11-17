import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/data/remote_control_channel_codec.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_inbound_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';

/// The four messages of a touch session on the wire. Like every other message
/// they are untrusted, refused rather than clamped, and answered only when they
/// carry an id.
void main() {
  RemoteControlInboundMessage? decodeText(String text) =>
      RemoteControlChannelCodec.decode(WebRtcDataChannelMessage.text(text));

  RemoteControlInboundMessage invalid(String id) =>
      RemoteControlMessageRejected(id, RemoteControlError.invalidCommand);

  const touchTypes = [
    'touch_hold',
    'touch_move',
    'touch_release',
    'touch_cancel',
  ];

  group('the four documented messages decode exactly', () {
    test('touch_hold', () {
      expect(
        decodeText(
          '{"v":1,"type":"touch_hold","id":"hold-7","touch":"t-7",'
          '"x":0.41,"y":0.52}',
        ),
        const RemoteControlCommandReceived(
          RemoteTouchHoldCommand(id: 'hold-7', touch: 't-7', x: 0.41, y: 0.52),
        ),
      );
    });

    test('touch_move', () {
      expect(
        decodeText(
          '{"v":1,"type":"touch_move","id":"mv-7-12","touch":"t-7","seq":12,'
          '"x":0.43,"y":0.55}',
        ),
        const RemoteControlCommandReceived(
          RemoteTouchMoveCommand(
            id: 'mv-7-12',
            touch: 't-7',
            seq: 12,
            x: 0.43,
            y: 0.55,
          ),
        ),
      );
    });

    test('touch_release', () {
      expect(
        decodeText(
          '{"v":1,"type":"touch_release","id":"rel-7","touch":"t-7","seq":40,'
          '"x":0.60,"y":0.70}',
        ),
        const RemoteControlCommandReceived(
          RemoteTouchReleaseCommand(
            id: 'rel-7',
            touch: 't-7',
            seq: 40,
            x: 0.6,
            y: 0.7,
          ),
        ),
      );
    });

    test('touch_cancel', () {
      expect(
        decodeText(
          '{"v":1,"type":"touch_cancel","id":"cxl-7","touch":"t-7","seq":41}',
        ),
        const RemoteControlCommandReceived(
          RemoteTouchCancelCommand(id: 'cxl-7', touch: 't-7', seq: 41),
        ),
      );
    });
  });

  group('extra fields are ignored', () {
    test('a seq on a touch_hold changes nothing', () {
      expect(
        decodeText(
          '{"v":1,"type":"touch_hold","id":"h","touch":"t","seq":9,'
          '"x":0,"y":1}',
        ),
        const RemoteControlCommandReceived(
          RemoteTouchHoldCommand(id: 'h', touch: 't', x: 0, y: 1),
        ),
      );
    });

    test('a position on a touch_cancel changes nothing', () {
      expect(
        decodeText(
          '{"v":1,"type":"touch_cancel","id":"c","touch":"t","seq":2,'
          '"x":0.5,"y":0.5,"durationMs":300}',
        ),
        const RemoteControlCommandReceived(
          RemoteTouchCancelCommand(id: 'c', touch: 't', seq: 2),
        ),
      );
    });
  });

  group('touch', () {
    String hold(String touchJson) =>
        '{"v":1,"type":"touch_hold","id":"h","touch":$touchJson,'
        '"x":0.5,"y":0.5}';

    test('is kept exactly as it arrived', () {
      final decoded = decodeText(hold('"  ¿t?"'));
      final command = (decoded! as RemoteControlCommandReceived).command;
      expect((command as RemoteTouchHoldCommand).touch, '  ¿t?');
    });

    test('of exactly 64 code units is accepted', () {
      final touch = 'a' * RemoteTouchCommand.maxTouchLength;
      expect(decodeText(hold('"$touch"')), isA<RemoteControlCommandReceived>());
    });

    final wrongTouches = <(String, String?)>[
      ('missing', null),
      ('null', 'null'),
      ('empty', '""'),
      ('a number', '7'),
      ('a bool', 'true'),
      ('an object', '{}'),
      ('an array', '["t"]'),
      ('65 code units', '"${'a' * 65}"'),
      ('33 emoji, which are 66 code units', '"${'\u{1F44B}' * 33}"'),
    ];
    for (final (name, touchJson) in wrongTouches) {
      for (final type in touchTypes) {
        test('$name is invalid in a $type', () {
          final field = touchJson == null ? '' : '"touch":$touchJson,';
          expect(
            decodeText(
              '{"v":1,"type":"$type","id":"m",$field"seq":1,"x":0,"y":0}',
            ),
            invalid('m'),
          );
        });
      }
    }
  });

  group('seq', () {
    for (final type in ['touch_move', 'touch_release', 'touch_cancel']) {
      group('in a $type', () {
        String message(String? seqJson) {
          final field = seqJson == null ? '' : '"seq":$seqJson,';
          return '{"v":1,"type":"$type","id":"m","touch":"t",$field'
              '"x":0.5,"y":0.5}';
        }

        test('1 is the smallest accepted', () {
          expect(decodeText(message('1')), isA<RemoteControlCommandReceived>());
        });

        test('2147483647 is the largest accepted', () {
          final decoded = decodeText(message('2147483647'));
          final command = (decoded! as RemoteControlCommandReceived).command;
          expect((command as RemoteTouchFollowUpCommand).seq, 2147483647);
        });

        final wrongSeqs = <(String, String?)>[
          ('missing', null),
          ('null', 'null'),
          ('0', '0'),
          ('negative', '-1'),
          ('above 2147483647', '2147483648'),
          ('a double', '3.0'),
          ('a fraction', '3.5'),
          ('a string', '"3"'),
          ('a bool', 'true'),
          ('infinite', '1e999'),
        ];
        for (final (name, seqJson) in wrongSeqs) {
          test('$name is invalid', () {
            expect(decodeText(message(seqJson)), invalid('m'));
          });
        }
      });
    }
  });

  group("positions are a tap's", () {
    for (final type in ['touch_hold', 'touch_move', 'touch_release']) {
      group('in a $type', () {
        String message(String? x, String? y) {
          final fields = [
            if (x != null) '"x":$x',
            if (y != null) '"y":$y',
          ].join(',');
          return '{"v":1,"type":"$type","id":"m","touch":"t","seq":3'
              '${fields.isEmpty ? '' : ',$fields'}}';
        }

        test('both ends of the range are accepted', () {
          expect(
            decodeText(message('0', '1')),
            isA<RemoteControlCommandReceived>(),
          );
          expect(
            decodeText(message('1.0', '0.0')),
            isA<RemoteControlCommandReceived>(),
          );
        });

        final wrongPositions = <(String, String?, String?)>[
          ('x missing', null, '0.5'),
          ('y missing', '0.5', null),
          ('x null', 'null', '0.5'),
          ('x a numeric string', '"0.5"', '0.5'),
          ('y a bool', '0.5', 'true'),
          ('x infinite', '1e999', '0.5'),
          ('y negative infinite', '0.5', '-1e999'),
          ('x below the range', '-0.0001', '0.5'),
          ('y above the range', '0.5', '1.0001'),
        ];
        for (final (name, x, y) in wrongPositions) {
          test('$name is invalid, never clamped', () {
            expect(decodeText(message(x, y)), invalid('m'));
          });
        }
      });
    }

    test('a literal NaN is broken JSON, and ignored', () {
      expect(
        decodeText(
          '{"v":1,"type":"touch_move","id":"m","touch":"t","seq":1,'
          '"x":NaN,"y":0}',
        ),
        isNull,
      );
    });
  });

  group('like every message', () {
    test('with no id there is nothing to answer, so it is ignored', () {
      for (final type in touchTypes) {
        expect(
          decodeText('{"v":1,"type":"$type","touch":"t","seq":1,"x":0,"y":0}'),
          isNull,
        );
      }
    });

    test('another version is not read as a version 1 touch', () {
      expect(
        decodeText(
          '{"v":2,"type":"touch_hold","id":"h","touch":"t","x":0,"y":0}',
        ),
        const RemoteControlMessageRejected(
          'h',
          RemoteControlError.unsupportedCommand,
        ),
      );
    });

    test('a type that only looks like one is unknown', () {
      for (final type in ['touch_down', 'TOUCH_HOLD', 'touch', 'drag_start']) {
        expect(
          decodeText(
            '{"v":1,"type":"$type","id":"x","touch":"t","seq":1,'
            '"x":0,"y":0}',
          ),
          const RemoteControlMessageRejected(
            'x',
            RemoteControlError.unsupportedCommand,
          ),
        );
      }
    });

    test('v missing is invalid', () {
      expect(
        decodeText('{"type":"touch_hold","id":"h","touch":"t","x":0,"y":0}'),
        invalid('h'),
      );
    });
  });
}
