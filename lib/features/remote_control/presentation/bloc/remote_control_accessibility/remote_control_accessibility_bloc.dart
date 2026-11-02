import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';

part 'remote_control_accessibility_event.dart';
part 'remote_control_accessibility_state.dart';

/// Whether the accessibility service is connected, for the one line on screen
/// that tells the user.
///
/// That is all it is for. No command consults it: a command that finds the
/// service gone is told so by the service itself, and an enabled service does
/// not make any command acceptable.
class RemoteControlAccessibilityBloc
    extends
        Bloc<RemoteControlAccessibilityEvent, RemoteControlAccessibilityState> {
  RemoteControlAccessibilityBloc({
    required RemoteControlAccessibilityClient client,
  }) : _client = client,
       super(const RemoteControlAccessibilityState()) {
    on<RemoteControlAccessibilityStarted>(_onStarted);
    on<RemoteControlAccessibilityStatusChanged>(_onStatusChanged);
    on<RemoteControlAccessibilitySettingsRequested>(_onSettingsRequested);
  }

  final RemoteControlAccessibilityClient _client;

  StreamSubscription<RemoteControlAccessibilityStatus>? _subscription;

  Future<void> _onStarted(
    RemoteControlAccessibilityStarted event,
    Emitter<RemoteControlAccessibilityState> emit,
  ) async {
    // Listening first, so a change during the read below is not missed. The
    // user is expected to enable the service from Settings with the application
    // in the background, and that change is what brings them back to this line.
    _subscription ??= _client.statusChanges.listen(
      (status) => add(RemoteControlAccessibilityStatusChanged(status)),
    );
    final status = await _client.currentStatus();
    if (state.status == null) {
      emit(RemoteControlAccessibilityState(status));
    }
  }

  void _onStatusChanged(
    RemoteControlAccessibilityStatusChanged event,
    Emitter<RemoteControlAccessibilityState> emit,
  ) {
    emit(RemoteControlAccessibilityState(event.status));
  }

  Future<void> _onSettingsRequested(
    RemoteControlAccessibilitySettingsRequested event,
    Emitter<RemoteControlAccessibilityState> emit,
  ) => _client.openAccessibilitySettings();

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    return super.close();
  }
}
