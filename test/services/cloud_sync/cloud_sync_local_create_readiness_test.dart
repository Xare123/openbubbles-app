import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';
import 'cloud_sync_restored_chat_test_fixture.dart';

void main() {
  test(
    'proven local create crosses unrelated terminal save and deletion debt',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount(
          terminalByZone: const {
            'chatManateeZone': _Terminal.retained,
            'attachmentManateeZone': _Terminal.retained,
          },
          tombstoneByZone: const {'attachmentManateeZone': true},
        );
        fixture.transport.stages.add(_stage());

        final admitted = await fixture.admitLocal();
        final leased = await fixture.store.leaseEligibleOutbox(
          fixture.scope(),
          now: testEpoch,
          limit: 1,
          leaseId: 'proven-local-create',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        );
        final submitted = await fixture.store.markOutboxSubmissionStarted(
          fixture.scope(),
          leaseId: 'proven-local-create',
          submissionIdentity: testSubmissionIdentity([admitted.operationId]),
          now: testEpoch,
        );

        expect(leased.single.operationId, admitted.operationId);
        expect(submitted.single.operationId, admitted.operationId);
        expect(submitted.single.status, CloudOutboxStatus.unknownOutcome);
        expect(submitted.single.appleRequestUuid, isNotNull);
        expect(submitted.single.appleOperationUuid, isNotNull);
        expect(fixture.intent.state, 2);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'exact target tombstone blocks admission whether applied or retained',
    () async {
      for (final terminal in _Terminal.values) {
        final fixture = await _Fixture.create();
        try {
          await fixture.seedAccount(
            terminalByZone: {'messageManateeZone': terminal},
            tombstoneByZone: const {'messageManateeZone': true},
            serverHashByZone: const {
              'messageManateeZone': _targetServerRecordIdHash,
            },
          );
          fixture.transport.stages.add(_stage());

          await expectLater(
            fixture.admitLocal(),
            throwsA(isA<CloudSyncFailure>()),
            reason: terminal.name,
          );

          expect(fixture.encodes, 1, reason: terminal.name);
          expect(fixture.transport.stageCalls, 1, reason: terminal.name);
          expect(fixture.transport.rolledBack, [
            testProtectedLeaseReference('a'),
          ], reason: terminal.name);
          expect(fixture.intent.state, 1, reason: terminal.name);
          expect(
            fixture.objectBox.box<CloudOutboxOperationEntity>().count(),
            0,
            reason: terminal.name,
          );
        } finally {
          await fixture.close();
        }
      }
    },
  );

  test(
    'exact target tombstone added after lease blocks submission atomically',
    () async {
      for (final terminal in _Terminal.values) {
        final fixture = await _Fixture.create();
        try {
          await fixture.seedAccount();
          fixture.transport.stages.add(_stage());
          final admitted = await fixture.admitLocal();
          await fixture.store.leaseEligibleOutbox(
            fixture.scope(),
            now: testEpoch,
            limit: 1,
            leaseId: 'target-tombstone-${terminal.name}',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save},
          );
          await fixture.addPage(
            zone: 'messageManateeZone',
            terminal: terminal,
            tombstone: true,
            serverRecordIdHash: _targetServerRecordIdHash,
          );

          await expectLater(
            fixture.store.markOutboxSubmissionStarted(
              fixture.scope(),
              leaseId: 'target-tombstone-${terminal.name}',
              submissionIdentity: testSubmissionIdentity([
                admitted.operationId,
              ]),
              now: testEpoch,
            ),
            throwsA(isA<CloudSyncFailure>()),
            reason: terminal.name,
          );

          final row = fixture.outboxRow;
          expect(row.state, CloudOutboxStatus.leased.index);
          expect(row.appleRequestUuid, isNull);
          expect(row.appleOperationUuid, isNull);
        } finally {
          await fixture.close();
        }
      }
    },
  );

  test(
    'known incomplete history fails before local encoding or native staging',
    () async {
      for (final defect in const [
        'missing',
        'hole',
        'nonterminal',
        'error',
        'backoff',
      ]) {
        final fixture = await _Fixture.create();
        try {
          await fixture.installHistoryDefect(defect);
          fixture.transport.stages.add(_stage());

          await expectLater(
            fixture.admitLocal(),
            throwsA(isA<CloudSyncFailure>()),
            reason: defect,
          );

          expect(fixture.encodes, 0, reason: defect);
          expect(fixture.transport.stageCalls, 0, reason: defect);
          expect(fixture.transport.rolledBack, isEmpty, reason: defect);
          expect(fixture.intent.state, 1, reason: defect);
          expect(
            fixture.objectBox.box<CloudOutboxOperationEntity>().count(),
            0,
            reason: defect,
          );
        } finally {
          await fixture.close();
        }
      }
    },
  );

  test(
    'missing restored-chat proof fails before encoding or native staging',
    () async {
      for (final missing in const ['snapshot', 'alias', 'record map']) {
        final fixture = await _Fixture.create();
        try {
          await fixture.seedAccount();
          fixture.removeRestoredChatProof(missing);
          fixture.transport.stages.add(_stage());

          await expectLater(
            fixture.admitLocal(),
            throwsA(_chatNotReady()),
            reason: missing,
          );

          expect(fixture.encodes, 0, reason: missing);
          expect(fixture.transport.stageCalls, 0, reason: missing);
          expect(fixture.transport.rolledBack, isEmpty, reason: missing);
          expect(fixture.intent.state, 1, reason: missing);
          expect(
            fixture.objectBox.box<CloudOutboxOperationEntity>().count(),
            0,
            reason: missing,
          );
          expect(fixture.messageRecordMapCount, 0, reason: missing);
        } finally {
          await fixture.close();
        }
      }
    },
  );

  test('stale restored-chat generation fails closed before encoding', () async {
    final fixture = await _Fixture.create();
    try {
      await fixture.seedAccount();
      fixture.makeRestoredChatProofStale();
      fixture.transport.stages.add(_stage());

      await expectLater(fixture.admitLocal(), throwsA(_chatNotReady()));

      expect(fixture.encodes, 0);
      expect(fixture.transport.stageCalls, 0);
      expect(fixture.intent.state, 1);
      expect(fixture.objectBox.box<CloudOutboxOperationEntity>().count(), 0);
      expect(fixture.messageRecordMapCount, 0);
    } finally {
      await fixture.close();
    }
  });

  test(
    'conflicting restored-chat owner fails closed before encoding',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount();
        fixture.addConflictingRestoredChatOwner();
        fixture.transport.stages.add(_stage());

        await expectLater(fixture.admitLocal(), throwsA(_chatNotReady()));

        expect(fixture.encodes, 0);
        expect(fixture.transport.stageCalls, 0);
        expect(fixture.intent.state, 1);
        expect(fixture.objectBox.box<CloudOutboxOperationEntity>().count(), 0);
        expect(fixture.messageRecordMapCount, 0);
      } finally {
        await fixture.close();
      }
    },
  );

  test('altered restored-chat alias fails closed before encoding', () async {
    final fixture = await _Fixture.create();
    try {
      await fixture.seedAccount();
      fixture.alterRestoredChatAlias();
      fixture.transport.stages.add(_stage());

      await expectLater(fixture.admitLocal(), throwsA(_chatNotReady()));

      expect(fixture.encodes, 0);
      expect(fixture.transport.stageCalls, 0);
      expect(fixture.intent.state, 1);
      expect(fixture.objectBox.box<CloudOutboxOperationEntity>().count(), 0);
      expect(fixture.messageRecordMapCount, 0);
    } finally {
      await fixture.close();
    }
  });

  test(
    'restored chat now tombstoned or unprojected fails closed before encoding',
    () async {
      for (final defect in const ['tombstoned', 'unprojected']) {
        final fixture = await _Fixture.create();
        try {
          await fixture.seedAccount();
          await fixture.addPage(
            zone: 'chatManateeZone',
            terminal: defect == 'tombstoned'
                ? _Terminal.applied
                : _Terminal.retained,
            tombstone: defect == 'tombstoned',
            serverRecordIdHash: _restoredChatServerRecordIdHash,
          );
          fixture.transport.stages.add(_stage());

          await expectLater(
            fixture.admitLocal(),
            throwsA(_chatNotReady()),
            reason: defect,
          );

          expect(fixture.encodes, 0, reason: defect);
          expect(fixture.transport.stageCalls, 0, reason: defect);
          expect(fixture.intent.state, 1, reason: defect);
          expect(
            fixture.objectBox.box<CloudOutboxOperationEntity>().count(),
            0,
            reason: defect,
          );
          expect(fixture.messageRecordMapCount, 0, reason: defect);
        } finally {
          await fixture.close();
        }
      }
    },
  );

  test(
    'restored-chat proof is rechecked during adoption and staging rolls back',
    () async {
      for (final defect in const ['proof removed', 'proof identity changed']) {
        final fixture = await _Fixture.create();
        try {
          await fixture.seedAccount();
          final entered = Completer<void>();
          final release = Completer<void>();
          fixture.transport
            ..stages.add(_stage())
            ..stageEntered = entered
            ..releaseStage = release;

          final admission = fixture.admitLocal();
          final rejected = expectLater(admission, throwsA(_chatNotReady()));
          await entered.future;
          if (defect == 'proof removed') {
            fixture.removeRestoredChatProof('snapshot');
          } else {
            fixture.changeRestoredChatProofIdentity();
          }
          release.complete();
          await rejected;

          expect(fixture.encodes, 1, reason: defect);
          expect(fixture.transport.stageCalls, 1, reason: defect);
          expect(fixture.transport.rolledBack, [
            testProtectedLeaseReference('a'),
          ], reason: defect);
          expect(fixture.intent.state, 1, reason: defect);
          expect(
            fixture.objectBox.box<CloudOutboxOperationEntity>().count(),
            0,
            reason: defect,
          );
          expect(fixture.messageRecordMapCount, 0, reason: defect);
        } finally {
          await fixture.close();
        }
      }
    },
  );

  test(
    'local-only new chat remains a ready intent with no staged state',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount(seedRestoredChatProof: false);
        fixture.transport.stages.add(_stage());

        await expectLater(fixture.admitLocal(), throwsA(_chatNotReady()));

        expect(fixture.encodes, 0);
        expect(fixture.transport.stageCalls, 0);
        expect(fixture.transport.rolledBack, isEmpty);
        expect(fixture.intent.state, 1);
        expect(fixture.objectBox.box<CloudOutboxOperationEntity>().count(), 0);
        expect(fixture.objectBox.box<CloudRecordMapEntity>().count(), 0);
      } finally {
        await fixture.close();
      }
    },
  );

  test('history is rechecked inside adoption after native staging', () async {
    final fixture = await _Fixture.create();
    try {
      await fixture.seedAccount();
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.transport
        ..stages.add(_stage())
        ..stageEntered = entered
        ..releaseStage = release;

      final admission = fixture.admitLocal();
      final rejected = expectLater(admission, throwsA(isA<CloudSyncFailure>()));
      await entered.future;
      await fixture.addPendingPage(zone: 'attachmentManateeZone');
      release.complete();
      await rejected;

      expect(fixture.encodes, 1);
      expect(fixture.transport.stageCalls, 1);
      expect(fixture.transport.rolledBack, [testProtectedLeaseReference('a')]);
      expect(fixture.intent.state, 1);
      expect(fixture.objectBox.box<CloudOutboxOperationEntity>().count(), 0);
      expect(fixture.messageRecordMapCount, 0);
    } finally {
      await fixture.close();
    }
  });

  test(
    'lease independently rejects origin binding authority source or map drift',
    () async {
      for (final defect in const [
        'origin',
        'adopted binding',
        'epoch',
        'missing source',
        'missing map',
      ]) {
        final fixture = await _Fixture.create();
        try {
          await fixture.seedAccount(
            terminalByZone: const {'attachmentManateeZone': _Terminal.retained},
          );
          fixture.transport.stages.add(_stage());
          await fixture.admitLocal();
          fixture.installLeaseDefect(defect);

          await expectLater(
            fixture.store.leaseEligibleOutbox(
              fixture.scope(),
              now: testEpoch,
              limit: 1,
              leaseId: 'lease-defect-${defect.replaceAll(' ', '-')}',
              leaseDuration: const Duration(minutes: 1),
              allowedActions: const {CloudOutboxAction.save},
            ),
            throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())),
            reason: defect,
          );

          final row = fixture.outboxRow;
          expect(row.state, CloudOutboxStatus.pending.index, reason: defect);
          expect(row.leaseIdHash, isNull, reason: defect);
        } finally {
          await fixture.close();
        }
      }
    },
  );

  test(
    'adopted chat proof is rechecked after restart before leasing',
    () async {
      for (final missing in ['snapshot', 'alias', 'record map']) {
        final fixture = await _Fixture.create();
        try {
          await fixture.seedAccount();
          fixture.transport.stages.add(_stage());
          await fixture.admitLocal();
          await fixture.reopenConfigured();
          fixture.removeRestoredChatProof(missing);

          await expectLater(
            fixture.store.leaseEligibleOutbox(
              fixture.scope(),
              now: testEpoch,
              limit: 1,
              leaseId: 'missing-chat-proof',
              leaseDuration: const Duration(minutes: 1),
              allowedActions: const {CloudOutboxAction.save},
            ),
            throwsA(_chatNotReady()),
            reason: missing,
          );
          expect(fixture.outboxRow.state, CloudOutboxStatus.pending.index);
          expect(fixture.outboxRow.leaseIdHash, isNull);
          expect(fixture.transport.stageCalls, 1);
        } finally {
          await fixture.close();
        }
      }
    },
  );

  test(
    'adopted chat deletion after lease blocks submission atomically',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount();
        fixture.transport.stages.add(_stage());
        final admitted = await fixture.admitLocal();
        await fixture.store.leaseEligibleOutbox(
          fixture.scope(),
          now: testEpoch,
          limit: 1,
          leaseId: 'deleted-chat',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        );
        await fixture.addPage(
          zone: 'chatManateeZone',
          terminal: _Terminal.applied,
          tombstone: true,
          serverRecordIdHash: _restoredChatServerRecordIdHash,
        );
        await expectLater(
          fixture.store.markOutboxSubmissionStarted(
            fixture.scope(),
            leaseId: 'deleted-chat',
            submissionIdentity: testSubmissionIdentity([admitted.operationId]),
            now: testEpoch,
          ),
          throwsA(_chatNotReady()),
        );
        expect(fixture.outboxRow.state, CloudOutboxStatus.leased.index);
        expect(fixture.outboxRow.appleRequestUuid, isNull);
        expect(fixture.outboxRow.appleOperationUuid, isNull);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'adopted chat binding permits a newer applied save without Message',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount();
        fixture.transport.stages.add(_stage());
        final admitted = await fixture.admitLocal();
        final binding = fixture.intent.admittedChatBinding!;
        expect(binding, isNot(contains(_chatIdentifier)));
        expect(binding, isNot(contains(_localGuid)));
        expect(binding, isNot(contains(fixture.local.text!)));
        final updatedEtag = 'U' * 43;
        await fixture.seedZone(
          zone: 'chatManateeZone',
          terminal: _Terminal.applied,
          serverRecordIdHash: _restoredChatServerRecordIdHash,
          etagHash: updatedEtag,
        );
        final mapping = fixture.objectBox
            .box<CloudRecordMapEntity>()
            .getAll()
            .singleWhere((row) => row.zone == 'chatManateeZone');
        fixture.objectBox.box<CloudRecordMapEntity>().put(
          mapping..etagHash = updatedEtag,
        );
        final snapshot = fixture.objectBox
            .box<CloudSemanticSnapshotEntity>()
            .getAll()
            .single;
        fixture.objectBox.box<CloudSemanticSnapshotEntity>().put(
          snapshot..etagHash = updatedEtag,
        );
        fixture.objectBox.box<Message>().remove(fixture.local.id!);
        await fixture.reopenConfigured();
        final recovered = await fixture.admitLocal(
          encoder: (_) =>
              throw StateError('must not read or re-encode Message'),
        );
        final leased = await fixture.store.leaseEligibleOutbox(
          fixture.scope(),
          now: testEpoch,
          limit: 1,
          leaseId: 'current-chat',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        );
        expect(leased.single.operationId, admitted.operationId);
        expect(
          recovered.encryptedPayloadReference,
          admitted.encryptedPayloadReference,
        );
        expect(fixture.intent.admittedChatBinding, binding);
        expect(fixture.transport.stageCalls, 1);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'adopted chat cannot follow a locally consistent remote remap',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount();
        fixture.transport.stages.add(_stage());
        await fixture.admitLocal();
        final mapping = fixture.objectBox
            .box<CloudRecordMapEntity>()
            .getAll()
            .singleWhere((row) => row.zone == 'chatManateeZone');
        final source = fixture.objectBox
            .box<CloudInboxChangeEntity>()
            .getAll()
            .singleWhere((row) => row.zone == 'chatManateeZone');
        fixture.objectBox.box<CloudRecordMapEntity>().put(
          mapping..serverRecordIdHash = 'W' * 43,
        );
        fixture.objectBox.box<CloudInboxChangeEntity>().put(
          source..serverRecordIdHash = 'W' * 43,
        );
        await fixture.reopenConfigured();
        await expectLater(
          fixture.store.leaseEligibleOutbox(
            fixture.scope(),
            now: testEpoch,
            limit: 1,
            leaseId: 'remapped-chat',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save},
          ),
          throwsA(_chatNotReady()),
        );
        expect(fixture.outboxRow.state, CloudOutboxStatus.pending.index);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'legacy adopted envelope is recoverable but cannot fabricate chat proof',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount();
        fixture.transport.stages.add(_stage());
        final admitted = await fixture.admitLocal();
        // Exact predecessor format, before the dependency column existed.
        final legacyDigest = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  'cloud-sync-local-send-adoption-v1',
                  admitted.scope.storageKey,
                  admitted.operationId,
                  admitted.logicalEntityKeyHash,
                  admitted.action.name,
                  admitted.payloadVersion,
                  admitted.mutationRevision,
                  admitted.checkpointGeneration,
                  admitted.encryptedPayloadReference,
                  admitted.payloadSha256,
                  admitted.serverRecordIdHash,
                  admitted.dependencyOperationIds.toList()..sort(),
                  admitted.createdAt.millisecondsSinceEpoch,
                ]),
              ),
            )
            .toString();
        fixture.objectBox.box<CloudSyncLocalSendIntentEntity>().put(
          fixture.intent
            ..admittedChatBinding = null
            ..admittedBindingSha256 = legacyDigest,
        );
        await fixture.reopenConfigured();
        final recovered = await fixture.admitLocal(
          encoder: (_) => throw StateError('must not re-encode'),
        );
        expect(
          recovered.encryptedPayloadReference,
          admitted.encryptedPayloadReference,
        );
        await expectLater(
          fixture.store.leaseEligibleOutbox(
            fixture.scope(),
            now: testEpoch,
            limit: 1,
            leaseId: 'old-no-proof',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save},
          ),
          throwsA(_chatNotReady()),
        );
        expect(fixture.intent.admittedChatBinding, isNull);
        expect(fixture.transport.stageCalls, 1);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'adopted chat binding is part of the immutable envelope digest',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount();
        fixture.transport.stages.add(_stage());
        await fixture.admitLocal();
        fixture.objectBox.box<CloudSyncLocalSendIntentEntity>().put(
          fixture.intent..admittedChatBinding = '[1, "changed"]',
        );
        await expectLater(fixture.admitLocal(), throwsA(isA<StateError>()));
        expect(fixture.outboxRow.state, CloudOutboxStatus.pending.index);
        expect(fixture.transport.stageCalls, 1);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'default store and generic admissions retain the fully applied guard',
    () async {
      final fallback = await _Fixture.create();
      try {
        await fallback.seedAccount();
        fallback.transport.stages.add(_stage());
        await fallback.admitLocal();
        await fallback.addPage(
          zone: 'attachmentManateeZone',
          terminal: _Terminal.retained,
        );
        final strictStore = ObjectBoxCloudSyncStore(
          store: fallback.objectBox,
          protector: fallback.protector,
          clock: () => testEpoch,
        );

        await expectLater(
          strictStore.leaseEligibleOutbox(
            fallback.scope(),
            now: testEpoch,
            limit: 1,
            leaseId: 'strict-fallback',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save},
          ),
          throwsA(isA<CloudSyncFailure>()),
        );
      } finally {
        await fallback.close();
      }

      final generic = await _Fixture.create();
      try {
        await generic.seedAccount();
        generic.transport.stages.add(_stage());
        final unproven = await generic.coordinator.admitMessage(
          generic.scope(),
          message: _FakeCloudMessage(),
          createdAt: testEpoch,
        );
        await generic.addPage(
          zone: 'chatManateeZone',
          terminal: _Terminal.retained,
        );

        await expectLater(
          generic.store.leaseEligibleOutbox(
            generic.scope(),
            now: testEpoch,
            limit: 1,
            leaseId: 'unproven-generic',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save},
          ),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(generic.outboxRow.operationId, unproven.operationId);
        expect(generic.outboxRow.state, CloudOutboxStatus.pending.index);

        generic.transport.stages.add(
          _stage(
            leaseCharacter: 'b',
            referenceCharacter: 'Q',
            logicalCharacter: 'M',
            serverCharacter: 'T',
          ),
        );
        await expectLater(
          generic.coordinator.admitMessage(
            generic.scope(),
            message: _FakeCloudMessage(),
            createdAt: testEpoch.add(const Duration(seconds: 1)),
          ),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(
          generic.transport.rolledBack,
          contains(testProtectedLeaseReference('b')),
        );
      } finally {
        await generic.close();
      }
    },
  );

  test('local-send exception requires the exact V2 message scope', () async {
    for (final invalid in const ['schema', 'stream', 'zone', 'lane']) {
      final fixture = await _Fixture.create();
      try {
        final scope = switch (invalid) {
          'schema' => fixture.scope(schemaVersion: 1),
          'stream' => fixture.scope(streamKind: CloudSyncStreamKind.profiles),
          'zone' => fixture.scope(zone: 'chatManateeZone'),
          _ => fixture.scope(persistenceLane: CloudSyncPersistenceLane.legacy),
        };
        fixture.transport.stages.add(_stage());

        await expectLater(
          fixture.admitLocal(scope: scope),
          throwsA(isA<StateError>()),
          reason: invalid,
        );

        expect(fixture.encodes, 0, reason: invalid);
        expect(fixture.transport.stageCalls, 0, reason: invalid);
        expect(fixture.objectBox.box<CloudOutboxOperationEntity>().count(), 0);
      } finally {
        await fixture.close();
      }
    }
  });

  test(
    'restart recovers the original adopted envelope without re-encoding',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount();
        final staged = _stage();
        fixture.transport
          ..stages.add(staged)
          ..commitFailure = StateError('synthetic commit uncertainty');
        await expectLater(fixture.admitLocal(), throwsStateError);
        final originalOperationId = fixture.intent.admittedOperationId!;
        expect(fixture.intent.state, 2);

        await fixture.addPage(
          zone: 'attachmentManateeZone',
          terminal: _Terminal.retained,
          tombstone: true,
        );
        fixture.objectBox.box<Message>().remove(fixture.local.id!);
        await fixture.reopenConfigured();
        fixture.transport.commitFailure = null;

        final recovered = await fixture.admitLocal(
          encoder: (_) => throw StateError('must not re-encode'),
        );

        expect(recovered.operationId, originalOperationId);
        expect(
          recovered.encryptedPayloadReference,
          staged.protectedEnvelopeReference,
        );
        expect(recovered.protectedLeaseReference, staged.leaseReference);
        expect(fixture.encodes, 1);
        expect(fixture.transport.stageCalls, 1);
        expect(fixture.objectBox.box<CloudOutboxOperationEntity>().count(), 1);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'unknown outcome reconciliation remains independent of readiness',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.seedAccount();
        fixture.transport.stages.add(_stage());
        final admitted = await fixture.admitLocal();
        await fixture.store.leaseEligibleOutbox(
          fixture.scope(),
          now: testEpoch,
          limit: 1,
          leaseId: 'unknown-seed',
          leaseDuration: const Duration(seconds: 1),
          allowedActions: const {CloudOutboxAction.save},
        );
        await fixture.store.markOutboxSubmissionStarted(
          fixture.scope(),
          leaseId: 'unknown-seed',
          submissionIdentity: testSubmissionIdentity([admitted.operationId]),
          now: testEpoch,
        );
        await fixture.addPage(
          zone: 'messageManateeZone',
          terminal: _Terminal.retained,
          tombstone: true,
          serverRecordIdHash: _targetServerRecordIdHash,
        );

        fixture.removeRestoredChatProof('snapshot');
        final reconciliation = await fixture.store.leaseUnknownOutcomes(
          fixture.scope(),
          now: testEpoch.add(const Duration(seconds: 2)),
          limit: 1,
          leaseId: 'unknown-reconcile',
          leaseDuration: const Duration(minutes: 1),
        );

        expect(reconciliation.single.operationId, admitted.operationId);
        expect(reconciliation.single.status, CloudOutboxStatus.unknownOutcome);
        expect(reconciliation.single.appleRequestUuid, isNotNull);
        expect(reconciliation.single.appleOperationUuid, isNotNull);
      } finally {
        await fixture.close();
      }
    },
  );
}

enum _Terminal { applied, retained }

const _localGuid = '11111111-1111-4111-8111-111111111111';
const _chatGuid = 'iMessage;-;recipient@example.com';
const _chatIdentifier = 'recipient@example.com';
final _restoredChatServerRecordIdHash = syntheticRestoredChatServerRecordIdHash;
final _restoredChatEtagHash = syntheticRestoredChatEtagHash;
const _targetServerRecordIdHash = 'SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS';
const _zones = <String>[
  'chatManateeZone',
  'messageManateeZone',
  'attachmentManateeZone',
];

final class _Fixture {
  _Fixture._(this.directory, this.protector, this.objectBox, this.transport);

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'openbubbles-local-create-readiness-',
    );
    final objectBox = await openStore(directory: directory.path);
    final fixture = _Fixture._(
      directory,
      _Protector(),
      objectBox,
      _StagingTransport(),
    );
    fixture._bindRuntime();
    fixture._createConfirmedIntent();
    return fixture;
  }

  final Directory directory;
  final _Protector protector;
  Store objectBox;
  final _StagingTransport transport;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudSyncLocalSendJournal journal;
  late ObjectBoxCloudSyncStore store;
  late CloudSyncOutboundAdmissionCoordinator coordinator;
  late CloudSyncLocalSendAuthFence authFence;
  late Message local;
  late int intentId;
  int encodes = 0;
  final Map<String, CloudCoordinatorLeaseFence> _fences = {};
  int _batch = 0;

  CloudSyncScope scope({
    String zone = 'messageManateeZone',
    int schemaVersion = cloudSyncSchemaVersion,
    CloudSyncStreamKind streamKind = CloudSyncStreamKind.messages,
    CloudSyncPersistenceLane persistenceLane =
        CloudSyncPersistenceLane.semantic,
  }) => CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: zone,
    streamKind: streamKind,
    schemaVersion: schemaVersion,
    persistenceLane: persistenceLane,
  );

  CloudKitWriterScope get writerScope =>
      CloudKitWriterScope(accountFingerprint: testAccountFingerprintA);

  CloudSyncLocalSendIntentEntity get intent =>
      objectBox.box<CloudSyncLocalSendIntentEntity>().get(intentId)!;

  CloudOutboxOperationEntity get outboxRow =>
      objectBox.box<CloudOutboxOperationEntity>().getAll().single;

  int get messageRecordMapCount =>
      recordMapCountForZone(objectBox, 'messageManateeZone');

  void _bindRuntime() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: objectBox,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    if (authority.read(writerScope) == null) {
      final disabled = authority.initializeDisabled(
        writerScope,
        now: testEpoch,
      );
      authority.provisionInitialOwner(
        writerScope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: testEpoch,
      );
    }
    journal = CloudSyncLocalSendJournal(
      store: objectBox,
      authority: authority,
      authoritySnapshot: authority.read(writerScope)!,
    );
    store = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: protector,
      clock: () => testEpoch,
      localSendJournal: journal,
    );
    coordinator = CloudSyncOutboundAdmissionCoordinator(
      store: store,
      transport: transport,
      ensureProtectedStoreRecovered: () async {
        transport.timeline.add('recover');
      },
    );
    final auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic-session',
      accountFingerprint: testAccountFingerprintA,
      protectedStoreIdentity: 'obcs2.store.$testAccountFingerprintA',
      cloudMessagesClient: Object(),
    );
    authFence = CloudSyncLocalSendAuthFence(
      expected: auth,
      capture: () async => auth,
      stillCurrent: () => true,
    );
  }

  void _createConfirmedIntent() {
    final handle = Handle(
      address: 'recipient@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'recipient@example.com/iMessage',
    );
    objectBox.box<Handle>().put(handle);
    final chat = Chat(
      guid: _chatGuid,
      chatIdentifier: _chatIdentifier,
      usingHandle: 'mailto:sender@example.com',
      style: 45,
      participants: [handle],
    )..handles.add(handle);
    objectBox.box<Chat>().put(chat);
    local = Message(
      guid: 'temp-Abc12345',
      stagingGuid: _localGuid,
      text: 'synthetic local message',
      isFromMe: true,
      dateCreated: testEpoch,
      attributedBody: [AttributedBody.raw('synthetic local message')],
    )..chat.target = chat;
    final identity = CloudSyncLocalSendIdentity.capture(
      local,
      chat,
      _localGuid,
    )!;
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => objectBox.box<Message>().put(local),
      now: testEpoch,
    );
    intentId = objectBox
        .box<CloudSyncLocalSendIntentEntity>()
        .getAll()
        .single
        .id;
    local
      ..guid = _localGuid
      ..stagingGuid = null;
    journal.saveConfirmedSubmission(
      identity: identity,
      persistMessage: () => objectBox.box<Message>().put(local),
      now: testEpoch,
    );
  }

  Future<CloudOutboxOperation> admitLocal({
    CloudSyncScope? scope,
    frb_api.CloudMessage Function(Message)? encoder,
  }) => coordinator.admitLocalSend(
    scope ?? this.scope(),
    intentId: intentId,
    journal: journal,
    authFence: authFence,
    encodeMessage:
        encoder ??
        (message) {
          encodes++;
          return _LocalCloudMessage(message);
        },
  );

  Future<void> seedAccount({
    Map<String, _Terminal> terminalByZone = const {},
    Map<String, bool> tombstoneByZone = const {},
    Map<String, String> serverHashByZone = const {},
    Map<String, int> rowCountByZone = const {},
    bool seedRestoredChatProof = true,
  }) async {
    for (final zone in _zones) {
      final terminal = terminalByZone[zone] ?? _Terminal.applied;
      final tombstone = tombstoneByZone[zone] ?? false;
      final isRestoredChatSource =
          zone == 'chatManateeZone' &&
          seedRestoredChatProof &&
          terminal == _Terminal.applied &&
          !tombstone;
      await seedZone(
        zone: zone,
        terminal: terminal,
        tombstone: tombstone,
        serverRecordIdHash:
            serverHashByZone[zone] ??
            (isRestoredChatSource ? _restoredChatServerRecordIdHash : null),
        etagHash: isRestoredChatSource ? _restoredChatEtagHash : null,
        rowCount: rowCountByZone[zone] ?? 1,
      );
    }
    if (seedRestoredChatProof) {
      final hasRestoredSource = objectBox
          .box<CloudInboxChangeEntity>()
          .getAll()
          .any(
            (row) =>
                row.zone == 'chatManateeZone' &&
                row.serverRecordIdHash == _restoredChatServerRecordIdHash &&
                row.status == CloudInboxStatus.applied.index &&
                !row.isTombstone,
          );
      if (!hasRestoredSource) {
        await seedZone(
          zone: 'chatManateeZone',
          terminal: _Terminal.applied,
          serverRecordIdHash: _restoredChatServerRecordIdHash,
          etagHash: _restoredChatEtagHash,
        );
      }
      await _seedRestoredChatProof();
    }
  }

  Future<void> _seedRestoredChatProof() async {
    final chatScope = scope(zone: 'chatManateeZone');
    final checkpoint = await store.readCheckpoint(chatScope);
    final source = objectBox
        .box<CloudInboxChangeEntity>()
        .getAll()
        .where(
          (row) =>
              row.accountFingerprint == chatScope.accountFingerprint &&
              row.zone == chatScope.zone &&
              row.generation == checkpoint.generation &&
              row.serverRecordIdHash == _restoredChatServerRecordIdHash,
        )
        .reduce(
          (latest, candidate) => candidate.fetchSequence > latest.fetchSequence
              ? candidate
              : latest,
        );
    await seedSyntheticRestoredChatProof(
      objectBox: objectBox,
      store: store,
      chatScope: chatScope,
      chat: local.chat.target!,
      appliedSource: source,
      now: testEpoch,
    );
  }

  void removeRestoredChatProof(String missing) {
    switch (missing) {
      case 'snapshot':
        objectBox.box<CloudSemanticSnapshotEntity>().removeAll();
      case 'alias':
        objectBox.box<CloudSemanticChatAliasEntity>().removeAll();
      case 'record map':
        final box = objectBox.box<CloudRecordMapEntity>();
        for (final row in box.getAll().where(
          (row) => row.zone == 'chatManateeZone',
        )) {
          box.remove(row.id);
        }
      default:
        throw ArgumentError.value(missing, 'missing');
    }
  }

  void makeRestoredChatProofStale() {
    final snapshot =
        objectBox.box<CloudSemanticSnapshotEntity>().getAll().single
          ..generation = 0
          ..scopeGenerationKey = 'semantic-generation4:${testSha256('0')}';
    objectBox.box<CloudSemanticSnapshotEntity>().put(snapshot);
    final alias = objectBox.box<CloudSemanticChatAliasEntity>().getAll().single
      ..generation = 0
      ..scopeGenerationKey = snapshot.scopeGenerationKey;
    objectBox.box<CloudSemanticChatAliasEntity>().put(alias);
  }

  void addConflictingRestoredChatOwner() {
    final chatScope = scope(zone: 'chatManateeZone');
    final existing = objectBox
        .box<CloudSemanticSnapshotEntity>()
        .getAll()
        .single;
    final conflictingLogicalOwner = syntheticRestoredChatLogicalEntityKeyHash(
      'iMessage;-;conflicting-synthetic-owner',
    );
    objectBox.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        snapshotKey:
            'semantic-snapshot4:${existing.scopeGenerationKey}:${CloudEntityKind.chat.name}:$conflictingLogicalOwner',
        scopeGenerationKey: existing.scopeGenerationKey,
        scopeKey: existing.scopeKey,
        accountFingerprint: existing.accountFingerprint,
        container: existing.container,
        database: existing.database,
        zone: existing.zone,
        streamKind: existing.streamKind,
        schemaVersion: existing.schemaVersion,
        generation: existing.generation,
        entityKind: CloudEntityKind.chat.name,
        logicalEntityKeyHash: conflictingLogicalOwner,
        canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
          scope: chatScope,
          generation: existing.generation,
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: conflictingLogicalOwner,
          canonicalGuid: local.chat.target!.guid,
        ),
        canonicalGuidLookupHash: existing.canonicalGuidLookupHash,
        updatedAtMs: testEpoch.millisecondsSinceEpoch,
      ),
    );
  }

  void alterRestoredChatAlias() {
    final alias = objectBox.box<CloudSemanticChatAliasEntity>().getAll().single
      ..aliasKeyHash = syntheticRestoredChatAliasKeyHash(
        'altered-synthetic-alias',
      );
    objectBox.box<CloudSemanticChatAliasEntity>().put(alias);
  }

  void changeRestoredChatProofIdentity() {
    final snapshot =
        objectBox.box<CloudSemanticSnapshotEntity>().getAll().single
          ..canonicalGuidHash = testSha256('c');
    objectBox.box<CloudSemanticSnapshotEntity>().put(snapshot);
  }

  Future<void> seedZone({
    required String zone,
    required _Terminal terminal,
    bool tombstone = false,
    String? serverRecordIdHash,
    String? etagHash,
    int rowCount = 1,
  }) async {
    final targetScope = scope(zone: zone);
    final checkpoint = await store.readCheckpoint(targetScope);
    final fence = await _fence(targetScope);
    final firstSequence = checkpoint.fetchedSequence + 1;
    final batchNumber = ++_batch;
    await store.journalFetchedBatch(
      CloudFetchBatch(
        scope: targetScope,
        changes: [
          for (var offset = 0; offset < rowCount; offset++)
            _change(
              batchNumber * 10 + offset,
              tombstone: tombstone,
              serverRecordIdHash: serverRecordIdHash,
              etagHash: etagHash,
            ),
        ],
        batchId: 'readiness-batch-$batchNumber-$zone',
        generation: checkpoint.generation,
        nextToken: 'readiness-token-$batchNumber-$zone',
        hasMore: false,
      ),
      now: testEpoch,
      leaseFence: fence,
      expectedGeneration: checkpoint.generation,
      expectedFetchedToken: checkpoint.fetchedToken,
    );
    for (var offset = 0; offset < rowCount; offset++) {
      final sequence = firstSequence + offset;
      switch (terminal) {
        case _Terminal.applied:
          await store.markInboxApplied(
            targetScope,
            sequence: sequence,
            now: testEpoch,
            leaseFence: fence,
          );
        case _Terminal.retained:
          await store.markInboxRetainedUnprojected(
            targetScope,
            sequence: sequence,
            category: CloudFailureCategory.unsupportedService,
            now: testEpoch,
            maximumDeferredAttempts: 8,
            maximumDeferredAge: const Duration(days: 3),
            leaseFence: fence,
          );
      }
    }
    await store.recordPullSuccess(targetScope, now: testEpoch);
  }

  Future<void> addPage({
    required String zone,
    required _Terminal terminal,
    bool tombstone = false,
    String? serverRecordIdHash,
  }) => seedZone(
    zone: zone,
    terminal: terminal,
    tombstone: tombstone,
    serverRecordIdHash: serverRecordIdHash,
  );

  Future<void> addPendingPage({required String zone}) async {
    final targetScope = scope(zone: zone);
    final checkpoint = await store.readCheckpoint(targetScope);
    final batchNumber = ++_batch;
    await store.journalFetchedBatch(
      CloudFetchBatch(
        scope: targetScope,
        changes: [_change(batchNumber * 10)],
        batchId: 'pending-batch-$batchNumber-$zone',
        generation: checkpoint.generation,
        nextToken: 'pending-token-$batchNumber-$zone',
        hasMore: false,
      ),
      now: testEpoch,
      leaseFence: await _fence(targetScope),
      expectedGeneration: checkpoint.generation,
      expectedFetchedToken: checkpoint.fetchedToken,
    );
  }

  Future<void> installHistoryDefect(String defect) async {
    switch (defect) {
      case 'hole':
        await seedAccount(rowCountByZone: const {'chatManateeZone': 2});
        final row = objectBox
            .box<CloudInboxChangeEntity>()
            .getAll()
            .singleWhere(
              (value) =>
                  value.zone == 'chatManateeZone' && value.fetchSequence == 1,
            );
        objectBox.box<CloudInboxChangeEntity>().remove(row.id);
      case 'nonterminal':
        for (final zone in _zones.where(
          (value) => value != 'chatManateeZone',
        )) {
          await seedZone(zone: zone, terminal: _Terminal.applied);
        }
        await addPendingPage(zone: 'chatManateeZone');
      case 'missing':
        await seedAccount();
        final checkpoint = objectBox
            .box<CloudSyncCheckpointEntity>()
            .getAll()
            .singleWhere((value) => value.zone == 'chatManateeZone');
        objectBox.box<CloudSyncCheckpointEntity>().remove(checkpoint.id);
      case 'error':
        await seedAccount();
        final checkpoint =
            objectBox.box<CloudSyncCheckpointEntity>().getAll().singleWhere(
              (value) => value.zone == 'chatManateeZone',
            )..lastErrorCategory = CloudFailureCategory.network.name;
        objectBox.box<CloudSyncCheckpointEntity>().put(checkpoint);
      case 'backoff':
        await seedAccount();
        final checkpoint =
            objectBox.box<CloudSyncCheckpointEntity>().getAll().singleWhere(
                (value) => value.zone == 'chatManateeZone',
              )
              ..backoffAttempt = 1
              ..nextEligibleAtMs = testEpoch
                  .add(const Duration(minutes: 1))
                  .millisecondsSinceEpoch;
        objectBox.box<CloudSyncCheckpointEntity>().put(checkpoint);
      default:
        throw ArgumentError.value(defect, 'defect');
    }
  }

  void installLeaseDefect(String defect) {
    switch (defect) {
      case 'origin':
        objectBox.box<CloudSyncLocalSendIntentEntity>().put(
          intent..intentKey = testSha256('e'),
        );
      case 'adopted binding':
        objectBox.box<CloudSyncLocalSendIntentEntity>().put(
          intent..admittedBindingSha256 = testSha256('f'),
        );
      case 'epoch':
        final row = objectBox
            .box<CloudKitWriterAuthorityEntity>()
            .getAll()
            .single;
        row.epoch++;
        objectBox.box<CloudKitWriterAuthorityEntity>().put(row);
      case 'missing source':
        objectBox.box<CloudSyncLocalSendIntentEntity>().remove(intentId);
      case 'missing map':
        final row = objectBox.box<CloudRecordMapEntity>().getAll().singleWhere(
          (row) => row.zone == 'messageManateeZone',
        );
        objectBox.box<CloudRecordMapEntity>().remove(row.id);
      default:
        throw ArgumentError.value(defect, 'defect');
    }
  }

  Future<CloudCoordinatorLeaseFence> _fence(CloudSyncScope targetScope) async {
    return _fences[targetScope.storageKey] ??= (await store
        .tryAcquireCoordinatorLease(
          targetScope,
          ownerId: 'local-create-readiness-${targetScope.zone}',
          now: testEpoch,
          leaseDuration: const Duration(days: 1),
        ))!;
  }

  Future<void> reopenConfigured() async {
    objectBox.close();
    objectBox = await openStore(directory: directory.path);
    _fences.clear();
    _bindRuntime();
  }

  Future<void> close() async {
    objectBox.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  }
}

Matcher _chatNotReady() => isA<CloudSyncFailure>().having(
  (failure) => failure.safeCode,
  'safeCode',
  'cloud_sync_local_send_chat_not_ready',
);

CloudFetchedChange _change(
  int index, {
  bool tombstone = false,
  String? serverRecordIdHash,
  String? etagHash,
}) => CloudFetchedChange(
  changeId: 'C${index.toString().padLeft(42, '0')}',
  recordIdHash: serverRecordIdHash ?? 'record-digest-$index',
  etagHash: tombstone ? null : etagHash ?? 'etag-digest-$index',
  type: tombstone ? CloudChangeType.delete : CloudChangeType.save,
  encryptedServerRecordId: 'protected:server-record-$index',
  protectedSystemFieldsReference: 'protected:system-fields-$index',
  encryptedPayloadReference: tombstone ? null : 'protected:payload-$index',
  payloadSha256: tombstone ? null : 'payload-digest-$index',
  isTombstone: tombstone,
);

CloudSyncProtectedOutboundStageData _stage({
  String leaseCharacter = 'a',
  String referenceCharacter = 'P',
  String logicalCharacter = 'L',
  String serverCharacter = 'S',
}) => CloudSyncProtectedOutboundStageData(
  logicalEntityKeyHash: List.filled(43, logicalCharacter).join(),
  protectedEnvelopeReference: testProtectedReference(referenceCharacter),
  payloadSha256: testSha256('a'),
  serverRecordIdHash: List.filled(43, serverCharacter).join(),
  leaseReference: testProtectedLeaseReference(leaseCharacter),
);

final class _LocalCloudMessage implements frb_api.CloudMessage {
  _LocalCloudMessage(Message message)
    : guid = message.guid!,
      chatId = message.chat.target!.guid,
      destinationCallerId = message.chat.target!.usingHandle!
          .replaceFirst('mailto:', '')
          .replaceFirst('tel:', '');

  @override
  final String guid;
  @override
  final String chatId;
  @override
  final String destinationCallerId;
  @override
  int get type => 1;
  @override
  String get service => 'iMessage';
  @override
  String get sender => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeCloudMessage implements frb_api.CloudMessage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StagingTransport implements CloudSyncOutboundStagingTransport {
  final List<CloudSyncProtectedOutboundStageData> stages = [];
  final List<String> timeline = [];
  final List<String> committed = [];
  final List<String> rolledBack = [];
  Object? commitFailure;
  Completer<void>? stageEntered;
  Completer<void>? releaseStage;
  Future<void> _exclusiveTail = Future<void>.value();
  int stageCalls = 0;

  @override
  Future<T> runOutboundAdmissionExclusive<T>(
    Future<T> Function() action,
  ) async {
    final previous = _exclusiveTail;
    final released = Completer<void>();
    _exclusiveTail = previous.then((_) => released.future);
    await previous;
    try {
      return await action();
    } finally {
      released.complete();
    }
  }

  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
  }) async {
    stageCalls++;
    timeline.add('stage');
    stageEntered?.complete();
    await releaseStage?.future;
    return stages.removeAt(0);
  }

  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  ) async {
    timeline.add('commit:$leaseReference');
    if (commitFailure case final failure?) throw failure;
    committed.add(leaseReference);
  }

  @override
  Future<void> rollbackOutboundLease(String leaseReference) async {
    timeline.add('rollback:$leaseReference');
    rolledBack.add(leaseReference);
  }
}

final class _Protector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      sha256.convert(utf8.encode(rawAccountIdentifier)).toString();

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => 'protected:$plaintext';

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => ciphertext.substring('protected:'.length);
}
