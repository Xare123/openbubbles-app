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

  test('applied-floor event exposes only bounded enum and counter fields', () {
    final event = CloudSyncEvent(
      type: CloudSyncEventType.inboxAppliedFloorStalled,
      scopeDiagnosticKey: testScope().diagnosticKey,
      at: testEpoch,
      appliedFloorBlockReason: CloudSyncAppliedFloorBlockReason.quarantined,
      failureCategory: CloudFailureCategory.malformedRecord,
      count: 1,
      attempt: 3,
    );

    expect(event.toString(), contains('inboxAppliedFloorStalled'));
    expect(event.toString(), contains('floorBlock=quarantined'));
    expect(event.toString(), isNot(contains('record')));
    expect(event.toString(), isNot(contains('token')));
    expect(event.toString(), isNot(contains('payload')));
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
}
