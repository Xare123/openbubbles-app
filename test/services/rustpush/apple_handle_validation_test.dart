import 'package:bluebubbles/services/rustpush/apple_handle_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts the selected handle while it is live', () {
    expect(
      validateLiveAppleHandle(
        selectedHandle: 'mailto:rami@example.com',
        liveHandles: const ['mailto:rami@example.com', 'tel:+15551234567'],
      ),
      'mailto:rami@example.com',
    );
  });

  test('rejects a stale selected handle without changing it', () {
    expect(
      () => validateLiveAppleHandle(
        selectedHandle: 'tel:+15551234567',
        liveHandles: const ['mailto:rami@example.com'],
      ),
      throwsA(
        isA<AppleHandleUnavailableException>().having(
          (error) => error.selectedHandle,
          'selectedHandle',
          'tel:+15551234567',
        ),
      ),
    );
  });

  test('terminal handle text is user-visible without exposing the handle', () {
    const error = AppleHandleUnavailableException(
      selectedHandle: 'tel:+15551234567',
    );

    expect(error.userMessage, contains('no longer registered'));
    expect(error.toString(), error.userMessage);
    expect(error.toString(), isNot(contains('+15551234567')));
  });

  test('reports an account with no active handles as terminal', () {
    const error = AppleHandleUnavailableException(noRegisteredHandles: true);

    expect(error.userMessage, contains('No active Apple messaging handle'));
  });
}
