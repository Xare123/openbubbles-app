import 'package:synchronized/synchronized.dart';

class CloudKitOperationCoordinator {
  final Lock _lock = Lock();

  Future<T> run<T>(Future<T> Function() operation) => _lock.synchronized(operation);
}

class CloudMessageSaveOutcome {
  final Set<String> confirmedRecordIds;
  final Set<String> retryableRecordIds;

  const CloudMessageSaveOutcome({
    required this.confirmedRecordIds,
    required this.retryableRecordIds,
  });

  factory CloudMessageSaveOutcome.fromResponse({
    required Iterable<String> attemptedRecordIds,
    required Map<String, bool> response,
  }) {
    final attempted = attemptedRecordIds.toSet();
    final confirmed = attempted.where((recordId) => response[recordId] == true).toSet();

    return CloudMessageSaveOutcome(
      confirmedRecordIds: confirmed,
      // A missing result is not confirmation. Keep it retryable just like an
      // explicit failure so transient or partial CloudKit responses cannot
      // silently strand a local message.
      retryableRecordIds: attempted.difference(confirmed),
    );
  }
}

class CloudAttachmentSaveOutcome {
  final Set<String> confirmedRecordIds;
  final Set<String> retryableRecordIds;
  final Set<String> retryableMessageRecordIds;

  const CloudAttachmentSaveOutcome({
    required this.confirmedRecordIds,
    required this.retryableRecordIds,
    required this.retryableMessageRecordIds,
  });

  factory CloudAttachmentSaveOutcome.fromResponse({
    required Iterable<String> attemptedRecordIds,
    required Map<String, bool> response,
    required Map<String, String> messageRecordIdByAttachmentRecordId,
  }) {
    final recordOutcome = CloudMessageSaveOutcome.fromResponse(
      attemptedRecordIds: attemptedRecordIds,
      response: response,
    );

    return CloudAttachmentSaveOutcome(
      confirmedRecordIds: recordOutcome.confirmedRecordIds,
      retryableRecordIds: recordOutcome.retryableRecordIds,
      retryableMessageRecordIds: recordOutcome.retryableRecordIds
          .map((recordId) => messageRecordIdByAttachmentRecordId[recordId])
          .whereType<String>()
          .toSet(),
    );
  }
}

class CloudMessageUploadBatchResult {
  final int confirmedCount;
  final int retryableCount;

  const CloudMessageUploadBatchResult({
    required this.confirmedCount,
    required this.retryableCount,
  });

  bool get madeProgress => confirmedCount > 0;
}
