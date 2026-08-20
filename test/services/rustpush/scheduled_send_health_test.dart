import 'package:bluebubbles/services/rustpush/scheduled_send_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 19, 12);

  test('future scheduled sends remain in flight on the active service', () {
    expect(
      shouldFailInterruptedSend(
        recordedServiceId: 'active',
        activeServiceId: 'active',
        scheduledFor: now.add(const Duration(hours: 1)),
        now: now,
      ),
      isFalse,
    );
  });

  test('delivered messages are no longer pending schedules', () {
    expect(
      isPendingScheduledSend(
        scheduledFor: now.subtract(const Duration(minutes: 1)),
        isDelivered: true,
      ),
      isFalse,
    );
    expect(
      isPendingScheduledSend(
        scheduledFor: now.add(const Duration(minutes: 1)),
        isDelivered: false,
      ),
      isTrue,
    );
    expect(
      isPendingScheduledSend(
        scheduledFor: null,
        isDelivered: false,
      ),
      isFalse,
    );
  });

  test('scheduled sends get a confirmation grace period', () {
    expect(
      isScheduledSendOverdue(
        now.subtract(const Duration(minutes: 4)),
        now: now,
      ),
      isFalse,
    );
    expect(
      isScheduledSendOverdue(
        now.subtract(const Duration(minutes: 5)),
        now: now,
      ),
      isTrue,
    );
  });

  test('overdue scheduled sends do not remain in flight forever', () {
    expect(
      shouldFailInterruptedSend(
        recordedServiceId: 'active',
        activeServiceId: 'active',
        scheduledFor: now.subtract(const Duration(days: 2)),
        now: now,
      ),
      isTrue,
    );
  });

  test('work owned by a replaced native service is interrupted', () {
    expect(
      shouldFailInterruptedSend(
        recordedServiceId: 'old',
        activeServiceId: 'active',
        scheduledFor: now.add(const Duration(hours: 1)),
        now: now,
      ),
      isTrue,
    );
  });

  test('rows without a sending owner are ignored', () {
    expect(
      shouldFailInterruptedSend(
        recordedServiceId: null,
        activeServiceId: 'active',
        scheduledFor: now.subtract(const Duration(days: 2)),
        now: now,
      ),
      isFalse,
    );
  });

  test('empty native handles still recover only when overdue', () {
    expect(
      shouldFailInterruptedSend(
        recordedServiceId: '',
        activeServiceId: '',
        scheduledFor: now.add(const Duration(minutes: 1)),
        now: now,
      ),
      isFalse,
    );
    expect(
      shouldFailInterruptedSend(
        recordedServiceId: '',
        activeServiceId: '',
        scheduledFor: now.subtract(const Duration(minutes: 5)),
        now: now,
      ),
      isTrue,
    );
  });

  test('late confirmation errors do not override delivery', () {
    expect(
      shouldMarkSendConfirmationFailed(
        error: 'late error',
        isDelivered: true,
      ),
      isFalse,
    );
    expect(
      shouldMarkSendConfirmationFailed(
        error: 'rejected',
        isDelivered: false,
      ),
      isTrue,
    );
    expect(
      shouldMarkSendConfirmationFailed(
        error: null,
        isDelivered: false,
      ),
      isFalse,
    );
  });

  test('delivery clears a stale in-flight owner', () {
    expect(
      shouldClearCompletedSendOwner(
        recordedServiceId: 'active',
        isDelivered: true,
      ),
      isTrue,
    );
    expect(
      shouldClearCompletedSendOwner(
        recordedServiceId: null,
        isDelivered: true,
      ),
      isFalse,
    );
    expect(
      shouldClearCompletedSendOwner(
        recordedServiceId: 'active',
        isDelivered: false,
      ),
      isFalse,
    );
  });
}
