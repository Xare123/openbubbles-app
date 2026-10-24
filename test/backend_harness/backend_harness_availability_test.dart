import 'package:bluebubbles/backend_harness/backend_harness_controller.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'client presence during unfinished setup reports registration, not ready',
    () {
      final state = backendHarnessAccountAvailability(
        setupFinished: false,
        nativeClientPresent: true,
      );
      expect(state.phase, BackendHarnessPhase.registering);
      expect(state.flags, {
        'setup_finished': false,
        'native_client_present': true,
      });
      expect(state.flags.containsKey('auth_ready'), false);
    },
  );
  test(
    'stored setup without a native client still needs session restoration',
    () {
      final state = backendHarnessAccountAvailability(
        setupFinished: true,
        nativeClientPresent: false,
      );
      expect(state.phase, BackendHarnessPhase.configuring);
      expect(state.flags.containsKey('auth_ready'), false);
    },
  );
  test(
    'a completed setup and loaded client alone do not assert authentication',
    () {
      final state = backendHarnessAccountAvailability(
        setupFinished: true,
        nativeClientPresent: true,
      );
      expect(state.phase, BackendHarnessPhase.idle);
      expect(state.flags.containsKey('auth_ready'), false);
    },
  );
  test('a fresh empty profile needs credentials', () {
    final state = backendHarnessAccountAvailability(
      setupFinished: false,
      nativeClientPresent: false,
    );
    expect(state.phase, BackendHarnessPhase.needs_credentials);
  });
}
