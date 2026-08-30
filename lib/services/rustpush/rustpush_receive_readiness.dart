import 'dart:async';

Future<T> waitForRustPushReceiveReadiness<T>({
  required Future<void> nativeStateReady,
  required Future<void> databaseReady,
  required T? Function() currentState,
  Duration timeout = const Duration(seconds: 25),
}) async {
  await Future.wait<void>([
    nativeStateReady,
    databaseReady,
  ]).timeout(timeout);

  final state = currentState();
  if (state == null) {
    throw StateError('RustPush receive state is unavailable');
  }
  return state;
}
