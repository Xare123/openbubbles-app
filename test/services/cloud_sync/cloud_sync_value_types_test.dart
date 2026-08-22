import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_backoff.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  test('operation identity is deterministic, scoped, and revision-aware', () {
    final scope = testScope();
    String identity({CloudSyncScope? requestedScope, int revision = 1}) {
      return CloudOperationIdentity.forMutation(
        scope: requestedScope ?? scope,
        logicalEntityKeyHash: 'logical-key-digest',
        action: CloudOutboxAction.save,
        payloadVersion: 1,
        mutationRevision: revision,
        payloadSha256: 'payload-digest-$revision',
      );
    }

    expect(identity(), identity());
    expect(identity(), startsWith('op1:'));
    expect(identity(revision: 2), isNot(identity()));
    expect(
      identity(requestedScope: testScope(account: testAccountFingerprintB)),
      isNot(identity()),
    );
  });

  test('delete identity and draft do not require an etag or payload', () {
    final scope = testScope();
    final draft = CloudOutboxDraft(
      scope: scope,
      logicalEntityKeyHash: 'deleted-logical-key-digest',
      action: CloudOutboxAction.delete,
      payloadVersion: 1,
      dependencyOperationIds: const [],
      createdAt: testEpoch,
    );
    final identity = CloudOperationIdentity.forMutation(
      scope: scope,
      logicalEntityKeyHash: draft.logicalEntityKeyHash,
      action: draft.action,
      payloadVersion: draft.payloadVersion,
      mutationRevision: 1,
    );

    expect(draft.encryptedPayloadReference, isNull);
    expect(draft.payloadSha256, isNull);
    expect(identity, startsWith('op1:'));
  });

  test('full-jitter exponential backoff honors retry-after', () {
    final policy = CloudSyncBackoffPolicy(
      baseDelay: const Duration(seconds: 2),
      maximumDelay: const Duration(seconds: 20),
      randomUnit: () => 0.5,
    );

    expect(
      policy.delayFor(attempt: 1, category: CloudFailureCategory.network),
      const Duration(seconds: 1),
    );
    expect(
      policy.delayFor(
        attempt: 4,
        category: CloudFailureCategory.throttled,
        retryAfter: const Duration(seconds: 12),
      ),
      const Duration(seconds: 12),
    );
    expect(
      policy.delayFor(attempt: 20, category: CloudFailureCategory.server),
      const Duration(seconds: 10),
    );
  });

  test('PCS pause has conservative floor and remains bounded', () {
    final policy = CloudSyncBackoffPolicy(
      baseDelay: const Duration(seconds: 2),
      maximumDelay: const Duration(minutes: 15),
      randomUnit: () => 0,
    );

    expect(
      policy.delayFor(
        attempt: 1,
        category: CloudFailureCategory.pcsUnavailable,
      ),
      const Duration(seconds: 30),
    );
  });

  test('observer is bounded and its output cannot contain raw values', () {
    final observer = MemoryCloudSyncObserver(maximumEvents: 2);
    for (var index = 0; index < 3; index++) {
      observer.onEvent(
        CloudSyncEvent(
          type: CloudSyncEventType.fetchCompleted,
          scopeDiagnosticKey: testScope().diagnosticKey,
          at: testEpoch,
          count: index,
        ),
      );
    }

    expect(observer.events, hasLength(2));
    final rendered = observer.events.join('\n');
    expect(rendered, isNot(contains('opaque-token')));
    expect(rendered, isNot(contains('protected:payload')));
    expect(rendered, isNot(contains('messages-container')));
    expect(rendered, isNot(contains('message-zone')));
  });

  test('scope diagnostic form exposes only bounded account prefix', () {
    final scope = testScope(
      account: '12345678AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    expect(scope.toString(), contains('12345678'));
    expect(
      scope.toString(),
      isNot(contains('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')),
    );
    expect(scope.toString(), isNot(contains('messages-container')));
  });

  test('message and profile streams never share a storage scope', () {
    final messages = testScope();
    final profiles = testScope(streamKind: CloudSyncStreamKind.profiles);

    expect(messages.storageKey, isNot(profiles.storageKey));
    expect(messages.schemaVersion, 2);
  });

  test('push batch rejects duplicate outcome IDs without overwriting', () {
    final operationId = testOutboxOperation(testScope(), 1).operationId;
    final first = CloudPushOutcome(
      operationId: operationId,
      disposition: CloudPushDisposition.confirmed,
    );
    final second = CloudPushOutcome(
      operationId: operationId,
      disposition: CloudPushDisposition.retryable,
      failureCategory: CloudFailureCategory.network,
    );

    expect(
      () => CloudPushBatchResult(outcomes: [first, second]),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.toString(),
          'redacted message',
          allOf(
            contains('cloud_push_batch_duplicate_outcome_id'),
            isNot(contains(operationId)),
          ),
        ),
      ),
    );
  });

  test('push outcomes reject empty and unsafe operation IDs', () {
    final invalidIds = <String>[
      '',
      'raw/record/secret',
      'op1:${'a' * 63}',
      'op1:${'A' * 64}',
      'op1:${'a' * 64}\nsecret-tail',
    ];

    for (final invalidId in invalidIds) {
      final redactedMessageMatcher = invalidId.isEmpty
          ? contains('cloud_push_outcome_operation_id_invalid')
          : allOf(
              contains('cloud_push_outcome_operation_id_invalid'),
              isNot(contains(invalidId)),
            );
      expect(
        () => CloudPushOutcome(
          operationId: invalidId,
          disposition: CloudPushDisposition.confirmed,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'redacted message',
            redactedMessageMatcher,
          ),
        ),
      );
    }
  });

  test('push batch exposes a stable read-only map and redacted strings', () {
    final operationId = testOutboxOperation(testScope(), 1).operationId;
    final outcome = CloudPushOutcome(
      operationId: operationId,
      disposition: CloudPushDisposition.confirmed,
    );
    final result = CloudPushBatchResult(outcomes: [outcome]);

    expect(result.outcomes, hasLength(1));
    expect(result.toString(), 'CloudPushBatchResult(count: 1)');
    expect(result.toString(), isNot(contains(operationId)));
    expect(outcome.toString(), 'CloudPushOutcome(confirmed, redacted)');
    expect(outcome.toString(), isNot(contains(operationId)));
    expect(
      () => result.outcomes[operationId] = outcome,
      throwsUnsupportedError,
    );
  });
}
