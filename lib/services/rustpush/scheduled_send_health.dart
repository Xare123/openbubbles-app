const Duration scheduledSendConfirmationGrace = Duration(minutes: 5);
const String sendOwnerAttemptSeparator = '::attempt::';

String encodeSendOwner({
  required String serviceId,
  required String attemptId,
}) =>
    '$serviceId$sendOwnerAttemptSeparator$attemptId';

String sendOwnerServiceId(String recordedOwner) =>
    recordedOwner.split(sendOwnerAttemptSeparator).first;

String? sendOwnerAttemptId(String? recordedOwner) {
  if (recordedOwner == null) return null;
  final separatorIndex = recordedOwner.indexOf(sendOwnerAttemptSeparator);
  if (separatorIndex == -1) return null;
  return recordedOwner.substring(
    separatorIndex + sendOwnerAttemptSeparator.length,
  );
}

bool isCurrentSendConfirmation({
  required String? recordedOwner,
  required String attemptId,
}) {
  if (recordedOwner == null) return false;
  final recordedAttemptId = sendOwnerAttemptId(recordedOwner);
  return recordedAttemptId != null && recordedAttemptId == attemptId;
}

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
  if (sendOwnerServiceId(recordedServiceId) != activeServiceId) return true;
  return isScheduledSendOverdue(
    scheduledFor,
    now: now,
    grace: grace,
  );
}
