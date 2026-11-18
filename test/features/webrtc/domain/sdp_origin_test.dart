import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/sdp_origin.dart';

void main() {
  const chromeOffer =
      'v=0\r\n'
      'o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n'
      's=-\r\n'
      't=0 0\r\n';

  test('reads the identity of the connection and its version apart', () {
    final origin = SdpOrigin.tryParse(chromeOffer)!;

    expect(origin.identity, '- 4611731400430051336 IN IP4 127.0.0.1');
    expect(origin.version, '2');
  });

  test('a renegotiation of the same connection keeps its identity', () {
    final first = SdpOrigin.tryParse(chromeOffer)!;
    final renegotiated = SdpOrigin.tryParse(
      chromeOffer.replaceFirst(' 2 IN', ' 3 IN'),
    )!;

    expect(renegotiated.identity, first.identity);
    expect(renegotiated.version, isNot(first.version));
  });

  test('a new connection has a new identity', () {
    final first = SdpOrigin.tryParse(chromeOffer)!;
    final other = SdpOrigin.tryParse(
      chromeOffer.replaceFirst('4611731400430051336', '8051336461173140043'),
    )!;

    expect(other.identity, isNot(first.identity));
  });

  test('bare \\n line endings are read too', () {
    expect(
      SdpOrigin.tryParse('v=0\no=- 46117 2 IN IP4 127.0.0.1\n')?.identity,
      '- 46117 IN IP4 127.0.0.1',
    );
  });

  test('no origin, or a malformed one, reads as nothing', () {
    expect(SdpOrigin.tryParse(''), isNull);
    expect(SdpOrigin.tryParse('v=0\r\ns=-\r\n'), isNull);
    expect(SdpOrigin.tryParse('v=0\r\no=- 46117 2 IN IP4\r\n'), isNull);
    expect(SdpOrigin.tryParse('v=0\r\no=- abc 2 IN IP4 127.0.0.1\r\n'), isNull);
    expect(
      SdpOrigin.tryParse('v=0\r\no=- 46117 x IN IP4 127.0.0.1\r\n'),
      isNull,
    );
  });

  test('never prints the SDP it was read from', () {
    final origin = SdpOrigin.tryParse(chromeOffer)!;

    expect(origin.toString(), isNot(contains('4611731400430051336')));
    expect(origin.toString(), isNot(contains('127.0.0.1')));
  });
}
