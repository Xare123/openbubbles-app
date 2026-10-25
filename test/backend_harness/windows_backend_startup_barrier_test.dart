import 'dart:async';

import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ObservedStartup extends RustPushService {
  final completion = Completer<void>();
  var calls = 0;

  @override
  Future<void> initializeStartup() {
    calls++;
    return completion.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'full startup barrier waits for the same once-only startup body',
    () async {
      final service = _ObservedStartup();
      expect(() => service.startupFuture, throwsStateError);
      final first = service.onInit();
      final second = service.onInit();
      expect(identical(first, second), isTrue);
      expect(identical(first, service.startupFuture), isTrue);
      expect(service.calls, 1);
      var finished = false;
      first.then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      service.completion.complete();
      await service.startupFuture;
      expect(finished, isTrue);
      expect(service.calls, 1);
      expect(service.nativeCloseFuture, isNull);
    },
  );

  test(
    'startup failure remains observable without retrying initialization',
    () async {
      final service = _ObservedStartup();
      final startup = service.onInit();
      final failure = expectLater(startup, throwsStateError);
      service.completion.completeError(StateError('synthetic_startup_failure'));
      await failure;
      expect(identical(service.onInit(), startup), isTrue);
      expect(service.calls, 1);
    },
  );
}
