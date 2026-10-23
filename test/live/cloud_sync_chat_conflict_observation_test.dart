import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_chat_conflict_observation.dart';

void main() {
  test(
    'observation ignores only its exact fence lease, not user or sync rows',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'chat-observation-state-test-',
      );
      final store = await openStore(directory: scratch.path);
      try {
        final empty = quarantinedChatObservationPreservedState(store);
        final sentinel = CloudSyncLeaseEntity(
          leaseKey: 'synthetic-operation-fence',
          scopeKey: CloudKitOperationInterlock.fenceScopeKey,
          accountFingerprint: 'synthetic',
          ownerIdHash: 'synthetic',
          generation: 1,
          acquiredAtMs: 1,
          expiresAtMs: 2,
        );
        final leases = store.box<CloudSyncLeaseEntity>();
        sentinel.id = leases.put(sentinel);
        expect(quarantinedChatObservationPreservedState(store), empty);
        sentinel.expiresAtMs = 3;
        leases.put(sentinel);
        expect(quarantinedChatObservationPreservedState(store), empty);

        final unrelated = CloudSyncLeaseEntity(
          leaseKey: 'synthetic-unrelated-lease',
          scopeKey: 'synthetic-other-scope',
          accountFingerprint: 'synthetic',
          ownerIdHash: 'synthetic',
          generation: 1,
          acquiredAtMs: 1,
          expiresAtMs: 2,
        );
        unrelated.id = leases.put(unrelated);
        final withLease = quarantinedChatObservationPreservedState(store);
        expect(withLease, isNot(empty));
        unrelated.expiresAtMs = 3;
        leases.put(unrelated);
        expect(
          quarantinedChatObservationPreservedState(store),
          isNot(withLease),
        );

        final message = Message(
          guid: 'synthetic-observation-message',
          text: 'original',
        );
        final messages = store.box<Message>();
        message.id = messages.put(message);
        final withMessage = quarantinedChatObservationPreservedState(store);
        message.text = 'changed';
        messages.put(message);
        expect(
          quarantinedChatObservationPreservedState(store),
          isNot(withMessage),
        );

        final originalIds = <String, Set<int>>{};
        final originalRows = quarantinedChatObservationPreservedState(store,
          collectIds: originalIds);
        final added = Message(guid: 'synthetic-new-observation-message');
        added.id = messages.put(added);
        expect(quarantinedChatObservationPreservedState(store,
          restrictIds: originalIds), originalRows);
        message.text = 'changed again';
        messages.put(message);
        expect(quarantinedChatObservationPreservedState(store,
          restrictIds: originalIds), isNot(originalRows));
        expect(quarantinedChatObservationPreservedState(store,
          ignoredRows: {'Message:${added.id}'}),
          quarantinedChatObservationPreservedState(store,
            restrictIds: originalIds));
      } finally {
        store.close();
        await scratch.delete(recursive: true);
      }
    },
  );
}
