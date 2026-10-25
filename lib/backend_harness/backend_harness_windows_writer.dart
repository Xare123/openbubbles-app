import 'package:bluebubbles/database/models.dart';

/// Explicit Windows writer admission is separate from the read-only host.
/// This policy grants no native permit or archive consent.
bool backendHarnessWindowsWriterModeAllowed({
  required bool writerCompiled,
  required bool writerEnvironment,
  required String recoveryOwner,
  required bool legacyWriter,
  required bool v2Writer,
  required bool outbound,
  required bool automaticUploads,
}) {
  if (legacyWriter) return false;
  if (!writerCompiled) {
    return !writerEnvironment &&
        recoveryOwner.isEmpty &&
        !v2Writer &&
        !outbound &&
        !automaticUploads;
  }
  return writerEnvironment &&
      v2Writer &&
      outbound &&
      automaticUploads &&
      backendHarnessRecoveryOwnerValid(recoveryOwner);
}

bool backendHarnessRecoveryOwnerValid(String value) => RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
).hasMatch(value);

bool backendHarnessValidFreshGroupRecovery(Map<String, Object?> args) =>
    args.length == 4 && args.keys.every(const {
      'operationId', 'chatId', 'intentId', 'retainedRecoveryOwner',
    }.contains) &&
    args['operationId'] is String &&
    RegExp(r'^op1:[a-f0-9]{64}$').hasMatch(args['operationId'] as String) &&
    args['chatId'] is int && (args['chatId'] as int) > 0 &&
    args['intentId'] is int && (args['intentId'] as int) > 0 &&
    args['retainedRecoveryOwner'] is String &&
    backendHarnessRecoveryOwnerValid(args['retainedRecoveryOwner'] as String);

bool backendHarnessRetainedFixtureAllowed({
  required bool isWindows,
  required String? admittedOwner,
  required Object? requestedOwner,
  required bool archiveSessionReady,
}) =>
    !isWindows ||
    (admittedOwner != null &&
        backendHarnessRecoveryOwnerValid(admittedOwner) &&
        requestedOwner == admittedOwner &&
        archiveSessionReady);

/// Account-scoped inventory only. Counts are conservative and can overlap;
/// they authorize neither draining old work nor changing a journal row.
Map<String, int> backendHarnessArchiveQueueCounts(
  Store store,
  String account,
) => store.runInTransaction(TxMode.read, () {
  int count<T>(QueryBuilder<T> builder) {
    final query = builder.build();
    try {
      return query.count();
    } finally {
      query.close();
    }
  }

  final sends = store.box<CloudSyncLocalSendIntentEntity>();
  final mutations = store.box<CloudSyncLocalMutationIntentEntity>();
  final outbox = store.box<CloudOutboxOperationEntity>();
  final ready =
      count(
        sends.query(
          CloudSyncLocalSendIntentEntity_.accountFingerprint
              .equals(account)
              .and(CloudSyncLocalSendIntentEntity_.state.oneOf([1, 3])),
        ),
      ) +
      count(
        mutations.query(
          CloudSyncLocalMutationIntentEntity_.accountFingerprint
              .equals(account)
              .and(CloudSyncLocalMutationIntentEntity_.state.oneOf([2, 3])),
        ),
      );
  final held =
      count(
        sends.query(
          CloudSyncLocalSendIntentEntity_.accountFingerprint
              .equals(account)
              .and(CloudSyncLocalSendIntentEntity_.state.equals(0)),
        ),
      ) +
      count(
        mutations.query(
          CloudSyncLocalMutationIntentEntity_.accountFingerprint
              .equals(account)
              .and(CloudSyncLocalMutationIntentEntity_.state.oneOf([0, 1])),
        ),
      );
  final unresolved =
      count(
        outbox.query(
          CloudOutboxOperationEntity_.accountFingerprint
              .equals(account)
              .and(
                CloudOutboxOperationEntity_.state
                    .notEquals(2)
                    .or(
                      CloudOutboxOperationEntity_.protectedLeaseReference
                          .notNull(),
                    ),
              ),
        ),
      ) +
      count(
        sends.query(
          CloudSyncLocalSendIntentEntity_.accountFingerprint
              .equals(account)
              .and(
                CloudSyncLocalSendIntentEntity_.state
                    .equals(2)
                    .and(
                      CloudSyncLocalSendIntentEntity_
                          .confirmedReadbackBindingSha256
                          .isNull(),
                    ),
              ),
        ),
      ) +
      count(
        mutations.query(
          CloudSyncLocalMutationIntentEntity_.accountFingerprint
              .equals(account)
              .and(CloudSyncLocalMutationIntentEntity_.state.equals(4)),
        ),
      );
  return {
    'ready_intents': ready,
    'held_intents': held,
    'unresolved_operations': unresolved,
  };
});
