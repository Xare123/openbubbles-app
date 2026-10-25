import 'dart:async';

/// A retained host must join the actual receive and certification operations.
/// The ordinary UI keeps its existing processing deadline and receipt behavior.
Future<void> completeRustPushReceive({
  required Future<void> Function() process,
  required Future<void> Function() certify,
  required bool retainEnteredWork,
  Duration processingTimeout = const Duration(minutes: 3),
}) async {
  final processing = process();
  if (retainEnteredWork) {
    await processing;
    await certify();
  } else {
    await processing.timeout(processingTimeout);
    unawaited(certify());
  }
}

Future<T> waitForRustPushReceiveReadiness<T>({
  required Future<void> nativeStateReady,
  required Future<void> databaseReady,
  required T? Function() currentState,
  Duration timeout = const Duration(seconds: 25),
}) async {
  await Future.wait<void>([nativeStateReady, databaseReady]).timeout(timeout);

  final state = currentState();
  if (state == null) {
    throw StateError('RustPush receive state is unavailable');
  }
  return state;
}
