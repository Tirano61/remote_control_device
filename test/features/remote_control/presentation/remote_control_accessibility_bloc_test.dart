import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/presentation/bloc/remote_control_accessibility/remote_control_accessibility_bloc.dart';

import '../../../fakes/remote_control_fakes.dart';

void main() {
  late FakeRemoteControlAccessibilityClient client;
  late RemoteControlAccessibilityBloc bloc;

  setUp(() {
    client = FakeRemoteControlAccessibilityClient();
    bloc = RemoteControlAccessibilityBloc(client: client);
  });

  tearDown(() async => bloc.close());

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('says nothing until the first read answers', () {
    expect(bloc.state, const RemoteControlAccessibilityState());
  });

  test('reads the service when started', () async {
    client.status = RemoteControlAccessibilityStatus.unavailable;

    bloc.add(const RemoteControlAccessibilityStarted());
    await settle();

    expect(bloc.state.status, RemoteControlAccessibilityStatus.unavailable);
  });

  test('follows the service as Android reports it', () async {
    client.status = RemoteControlAccessibilityStatus.unavailable;
    bloc.add(const RemoteControlAccessibilityStarted());
    await settle();

    client.pushStatus(RemoteControlAccessibilityStatus.available);
    await settle();
    expect(bloc.state.status, RemoteControlAccessibilityStatus.available);

    client.pushStatus(RemoteControlAccessibilityStatus.unavailable);
    await settle();
    expect(bloc.state.status, RemoteControlAccessibilityStatus.unavailable);

    // Enabled a second time: nothing depends on it being the first bind.
    client.pushStatus(RemoteControlAccessibilityStatus.available);
    await settle();
    expect(bloc.state.status, RemoteControlAccessibilityStatus.available);
  });

  test('opening settings changes nothing by itself', () async {
    client.status = RemoteControlAccessibilityStatus.unavailable;
    bloc.add(const RemoteControlAccessibilityStarted());
    await settle();

    bloc.add(const RemoteControlAccessibilitySettingsRequested());
    await settle();

    expect(client.settingsOpened, 1);
    expect(bloc.state.status, RemoteControlAccessibilityStatus.unavailable);
  });
}
