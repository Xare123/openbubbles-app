const Duration scheduledSendConfirmationGrace = Duration(minutes: 5);

bool isPendingScheduledSend({
  required DateTime? scheduledFor,
  required bool isDelivered,
}) =>
    scheduledFor != null && !isDelivered;

bool shouldMarkSendConfirmationFailed({
  required String? error,
  required bool isDelivered,
}) =>
    error != null && !isDelivered;

bool shouldClearCompletedSendOwner({
  required String? recordedServiceId,
  required bool isDelivered,
}) =>
    recordedServiceId != null && isDelivered;

bool isScheduledSendOverdue(
  DateTime? scheduledFor, {
  required DateTime now,
  Duration grace = scheduledSendConfirmationGrace,
}) {
  if (scheduledFor == null) return false;
  return !now.isBefore(scheduledFor.add(grace));
}

bool shouldFailInterruptedSend({
  required String? recordedServiceId,
  required String activeServiceId,
  required DateTime? scheduledFor,
  required DateTime now,
  Duration grace = scheduledSendConfirmationGrace,
}) {
  if (recordedServiceId == null) return false;
  if (recordedServiceId != activeServiceId) return true;
  return isScheduledSendOverdue(
    scheduledFor,
    now: now,
    grace: grace,
  );
}
