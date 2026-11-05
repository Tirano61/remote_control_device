import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/webrtc/data/flutter_webrtc_peer_connection_factory.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginChannel = MethodChannel('FlutterWebRTC.Method');
  const eventChannel = MethodChannel('FlutterWebRTC/peerConnectionEventpc-1');

  group('peerConnectionConfigurationOf', () {
    test('turns off CPU overuse detection', () {
      final configuration = peerConnectionConfigurationOf(
        const WebRtcIceConfiguration.none(),
      );

      expect(configuration['enableCpuOveruseDetection'], isFalse);
    });

    test('keeps the semantics and the ICE servers it was already sending', () {
      final configuration = peerConnectionConfigurationOf(
        const WebRtcIceConfiguration([
          WebRtcIceServer(['stun:stun.example.org:3478']),
        ]),
      );

      expect(configuration['sdpSemantics'], 'unified-plan');
      expect(configuration['iceServers'], [
        {
          'urls': ['stun:stun.example.org:3478'],
        },
      ]);
    });

    test('adds nothing else the plugin would act on', () {
      final configuration = peerConnectionConfigurationOf(
        const WebRtcIceConfiguration.none(),
      );

      expect(configuration.keys, {
        'iceServers',
        'sdpSemantics',
        'enableCpuOveruseDetection',
      });
    });
  });

  group('FlutterWebRtcPeerConnectionFactory', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(pluginChannel, null);
      messenger.setMockMethodCallHandler(eventChannel, null);
    });

    test('hands that configuration to the plugin', () async {
      Map<Object?, Object?>? sent;
      messenger.setMockMethodCallHandler(pluginChannel, (call) async {
        if (call.method != 'createPeerConnection') return null;
        final arguments = call.arguments as Map<Object?, Object?>;
        sent = arguments['configuration'] as Map<Object?, Object?>;
        return <String, Object?>{'peerConnectionId': 'pc-1'};
      });
      messenger.setMockMethodCallHandler(eventChannel, (_) async => null);

      await const FlutterWebRtcPeerConnectionFactory().create(
        const WebRtcIceConfiguration.none(),
      );

      expect(sent, isNotNull);
      expect(sent!['enableCpuOveruseDetection'], isFalse);
    });
  });
}
