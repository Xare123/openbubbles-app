import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_plan_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart'
    as production;
import 'package:bluebubbles/src/rust/api/api.dart' as frb;
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Historical-owner coverage for the shared byte-upload journal.
///
/// NOTE: authored, not executed here. The host blocks the native ObjectBox
/// DLL (Application Control 4551), so no database test can run locally.
/// Parent runs qualification after regenerating ObjectBox bindings for the
/// additive owner columns.
final _now = DateTime.utc(2026, 9, 28);
final _account = 'A' * 43;
final _storeId = 'obcs2.store.${'S' * 43}';
final _snapshot = 'a' * 64;
const _ownerChanged = 'cloud_sync_attachment_owner_changed';

CloudSyncScope _uploadScope() => CloudSyncScope(
  accountFingerprint: _account,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'attachmentManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
CloudKitWriterScope _writerScope() =>
    CloudKitWriterScope(accountFingerprint: _account);

CloudSyncNativeAuthSnapshot _auth() => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: 'synthetic-session',
  accountFingerprint: _account,
  protectedStoreIdentity: _storeId,
  cloudMessagesClient: Object(),
);

void _expectOwnerChanged(void Function() run) {
  try {
    run();
  } on StateError catch (error) {
    expect(error.message, _ownerChanged);
    return;
  }
  fail('expected StateError($_ownerChanged)');
}

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudSyncLocalSendJournal localSends;
  late CloudSyncHistoricalArchiveJournal historicalJournal;
  late CloudSyncAttachmentUploadJournal uploads;
  late int historicalIntentId;

  CloudSyncHistoricalProtectedSourceBinding _source() =>
      CloudSyncHistoricalProtectedSourceBinding(
        accountFingerprint: _account,
        protectedStoreIdentity: _storeId,
        snapshotSha256: _snapshot,
        messageGuidHash: 'b' * 64,
        sourceSha256: 'c' * 64,
        protectedReference: 'obcs2.ref.${'H' * 43}',
        leaseReference: 'obcs2.lease.${'a' * 32}',
        payloadSha256: 'd' * 64,
        payloadLength: 128,
      );

  CloudSyncHistoricalArchiveJournal _historicalJournal() =>
      CloudSyncHistoricalArchiveJournal(
        store: store,
        accountFingerprint: _account,
        protectedStoreIdentity: _storeId,
        snapshotSha256: _snapshot,
        clock: () => _now,
      );

  CloudSyncProtectedOutboundStageData _plan(String logical) =>
      CloudSyncProtectedOutboundStageData(
        logicalEntityKeyHash: logical,
        protectedEnvelopeReference: 'obcs2.ref.${'P' * 43}',
        payloadSha256: 'e' * 64,
        serverRecordIdHash: 'M' * 43,
        leaseReference: 'obcs2.lease.${'f' * 32}',
      );

  void _seedCheckpoint() {
    store.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: cloudSyncPersistentScopeKey(_uploadScope()),
        accountFingerprint: _account,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'attachmentManateeZone',
        streamKind: 'messages',
        schemaVersion: 2,
        persistenceLane: 'semantic',
        generation: 1,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'historical-attachment-upload-journal-',
    );
    store = await openStore(directory: directory.path);
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final existing = authority.read(_writerScope());
    if (existing == null) {
      final disabled = authority.initializeDisabled(_writerScope(), now: _now);
      authority.provisionInitialOwner(
        _writerScope(),
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: _now,
      );
    }
    localSends = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authority.read(_writerScope())!,
    );
    historicalJournal = _historicalJournal();
    final source = _source();
    historicalIntentId = historicalJournal.adopt(source).id;
    historicalJournal.markSourceLeaseCommitted(
      intentId: historicalIntentId,
      expectedSource: source,
    );
    _seedCheckpoint();
    uploads = CloudSyncAttachmentUploadJournal(
      store: store,
      localSends: localSends,
      scope: _uploadScope(),
      checkpointGeneration: 1,
      currentAuth: _auth(),
      writerAuthority: authority,
    );
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  group('historical plan integration', () {
    late _HistoricalPlanStaging staging;
    late CloudSyncNativeAuthSnapshot live;
    late List<CloudSyncAttachmentPlanInventoryItem> inventory;
    var stages = 0;
    void Function()? afterStage;

    CloudSyncAttachmentPlanInventoryItem item(String key) =>
        CloudSyncAttachmentPlanInventoryItem(
          originalAttachmentGuid: 'original-$key',
          reflectedAttachmentGuid: 'reflected-$key',
          logicalEntityKeyHash: key * 43,
        );
    CloudSyncAttachmentPlanCoordinator coordinator() =>
        CloudSyncAttachmentPlanCoordinator(
          store: store,
          localSends: localSends,
          uploads: uploads,
          readLiveAuth: () async => live,
          staging: staging,
          readInventory: (_, __) =>
              throw StateError('unexpected_IDS_inventory'),
          stagePlan: (_, __, ___) => throw StateError('unexpected_IDS_plan'),
        );
    Future<List<CloudAttachmentUploadSnapshot>> run() =>
        coordinator().ensureHistoricalPlans(
          historicalIntentId: historicalIntentId,
          historicalJournal: historicalJournal,
          readInventory: (source, auth) async {
            expect(source.encode(), _source().encode());
            expect(auth.sameIdentity(live), isTrue);
            return inventory;
          },
          stagePlan: (entry, source, auth) async {
            stages++;
            expect(source.encode(), _source().encode());
            expect(auth.sameIdentity(live), isTrue);
            final key = entry.logicalEntityKeyHash;
            final digit = key.startsWith('L') ? '1' : '2';
            final plan = CloudSyncProtectedOutboundStageData(
              logicalEntityKeyHash: key,
              serverRecordIdHash: key,
              protectedEnvelopeReference: 'obcs2.ref.$key',
              payloadSha256: digit * 64,
              leaseReference: 'obcs2.lease.${digit * 32}',
            );
            afterStage?.call();
            return plan;
          },
        );

    setUp(() {
      staging = _HistoricalPlanStaging();
      live = _auth();
      inventory = [item('L'), item('K')];
      stages = 0;
      afterStage = null;
    });

    test('full inventory reuses exact plans after database reopen', () async {
      final original = await run();
      expect(stages, 2);
      expect(
        original.map((row) => row.ownerIntentId),
        everyElement(historicalIntentId),
      );
      store.close();
      store = await openStore(directory: directory.path);
      authority = ObjectBoxCloudKitWriterAuthority.forTest(
        store: store,
        buildDecision: CloudKitWriterOwnership.resolve('v2'),
      );
      localSends = CloudSyncLocalSendJournal(
        store: store,
        authority: authority,
        authoritySnapshot: authority.read(_writerScope())!,
      );
      historicalJournal = _historicalJournal();
      uploads = CloudSyncAttachmentUploadJournal(
        store: store,
        localSends: localSends,
        scope: _uploadScope(),
        checkpointGeneration: 1,
        currentAuth: live,
        writerAuthority: authority,
      );
      final resumed = await run();
      expect(resumed.map((row) => row.id), original.map((row) => row.id));
      expect(
        resumed.map((row) => row.plan.protectedEnvelopeReference),
        original.map((row) => row.plan.protectedEnvelopeReference),
      );
      expect(stages, 2);
      expect(staging.commits, hasLength(4));
      expect(staging.rollbacks, isEmpty);
    });

    test(
      'commit failure retains adopted plan and retries without restaging',
      () async {
        inventory = [item('L')];
        staging.failCommit = true;
        await expectLater(run(), throwsA(isA<StateError>()));
        final id = store.box<CloudAttachmentUploadEntity>().getAll().single.id;
        expect(stages, 1);
        expect(staging.rollbacks, isEmpty);
        staging.failCommit = false;
        expect((await run()).single.id, id);
        expect(stages, 1);
        expect(staging.commits, hasLength(2));
      },
    );

    test('duplicate native inventory stages and commits nothing', () async {
      inventory = [item('L'), item('L')];
      await expectLater(run(), throwsA(isA<StateError>()));
      expect(stages, 0);
      expect(staging.commits, isEmpty);
      expect(store.box<CloudAttachmentUploadEntity>().count(), 0);
    });

    test('shrunk inventory cannot strand retained children', () async {
      await run();
      inventory = [item('L')];
      final commits = staging.commits.length;
      await expectLater(run(), throwsA(isA<StateError>()));
      expect(stages, 2);
      expect(staging.commits, hasLength(commits));
      expect(store.box<CloudAttachmentUploadEntity>().count(), 2);
    });

    test(
      'auth drift before adoption rolls back only the unowned stage',
      () async {
        afterStage = () => live = _auth(); // New client identity, same account.
        await expectLater(run(), throwsA(isA<StateError>()));
        expect(stages, 1);
        expect(staging.rollbacks, hasLength(1));
        expect(staging.commits, isEmpty);
        expect(store.box<CloudAttachmentUploadEntity>().count(), 0);
      },
    );

    test('reconciled writer epoch retains original plans unchanged', () async {
      final original = await run();
      final epoch = authority.read(_writerScope())!.epoch;
      final permit = authority.issuePermit(
        _writerScope(),
        expectedOwner: CloudKitWriterOwner.v2,
      );
      authority.markMutationUnknown(permit, now: _now);
      authority.reconcileMutationFence(
        _writerScope(),
        owner: CloudKitWriterOwner.v2,
        fencedEpoch: epoch,
        now: _now,
      );
      expect((await run()).map((row) => row.id), original.map((row) => row.id));
      expect(stages, 2);
      expect(
        store.box<CloudAttachmentUploadEntity>().getAll().map(
          (row) => row.writerEpoch,
        ),
        everyElement(epoch),
      );
    });
  });

  test('historical adopt and find round-trip; legacy entrypoints reject', () {
    final plan = _plan('L' * 43);
    final adopted = uploads.adoptHistoricalPlan(
      historicalIntentId: historicalIntentId,
      plan: plan,
      now: _now,
      historicalJournal: historicalJournal,
    );
    expect(adopted.plan.logicalEntityKeyHash, 'L' * 43);
    expect(adopted.ownerKind, 1);
    expect(adopted.ownerIntentId, historicalIntentId);
    expect(adopted.localSendIntentId, 0);
    final row = store.box<CloudAttachmentUploadEntity>().get(adopted.id)!;
    expect(row.ownerKind, 1);
    expect(row.ownerIntentId, historicalIntentId);
    expect(row.localSendIntentId, 0);
    final found = uploads.findHistoricalForAttachment(
      historicalIntentId: historicalIntentId,
      logicalEntityKeyHash: 'L' * 43,
      sourceAttachmentKeys: {'L' * 43},
      historicalJournal: historicalJournal,
    );
    expect(found?.id, adopted.id);
    final source = uploads.readHistoricalOriginalSource(
      adopted.id,
      historicalJournal,
    );
    expect(source.messageGuidHash, 'b' * 64);
    expect(source.sourceSha256, 'c' * 64);
    _expectOwnerChanged(() => uploads.readOriginalSource(adopted.id));
    _expectOwnerChanged(
      () => uploads.beginAttempt(
        id: adopted.id,
        attemptId: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
        now: _now,
      ),
    );
  });

  test('equal numeric intent ids do not collide across owners', () {
    final epoch = authority.read(_writerScope())!.epoch;
    final localKey = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-attachment-upload-v1',
              cloudSyncPersistentScopeKey(_uploadScope()),
              'e' * 64,
              'f' * 64,
              'K' * 43,
            ]),
          ),
        )
        .toString();
    store.box<CloudAttachmentUploadEntity>().put(
      CloudAttachmentUploadEntity(
        uploadKey: localKey,
        accountFingerprint: _account,
        writerEpoch: epoch,
        checkpointGeneration: 1,
        localSendIntentId: historicalIntentId,
        messageGuidHash: 'e' * 64,
        sourceSha256: 'f' * 64,
        protectedStoreIdentity: _storeId,
        attachmentKeyHash: 'K' * 43,
        serverRecordIdHash: 'N' * 43,
        planReference: 'obcs2.ref.${'Q' * 43}',
        planLeaseReference: 'obcs2.lease.${'1' * 32}',
        planPayloadSha256: '2' * 64,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    final historical = uploads.adoptHistoricalPlan(
      historicalIntentId: historicalIntentId,
      plan: _plan('L' * 43),
      now: _now,
      historicalJournal: historicalJournal,
    );
    expect(
      uploads
          .findHistoricalForAttachment(
            historicalIntentId: historicalIntentId,
            logicalEntityKeyHash: 'L' * 43,
            sourceAttachmentKeys: {'L' * 43},
            historicalJournal: historicalJournal,
          )
          ?.id,
      historical.id,
    );
    final localId = store
        .box<CloudAttachmentUploadEntity>()
        .query(CloudAttachmentUploadEntity_.attachmentKeyHash.equals('K' * 43))
        .build()
        .findUnique()!
        .id;
    _expectOwnerChanged(
      () => uploads.readHistoricalOriginalSource(localId, historicalJournal),
    );
  });

  test('source and snapshot drift fail closed', () {
    final plan = _plan('L' * 43);
    uploads.adoptHistoricalPlan(
      historicalIntentId: historicalIntentId,
      plan: plan,
      now: _now,
      historicalJournal: historicalJournal,
    );
    final rows = store.box<CloudSyncHistoricalArchiveIntentEntity>();
    final row = rows.get(historicalIntentId)!;
    row.protectedSourceBinding = row.protectedSourceBinding.replaceFirst(
      'c' * 64,
      'd' * 64,
    );
    rows.put(row);
    expect(
      () => uploads.findHistoricalForAttachment(
        historicalIntentId: historicalIntentId,
        logicalEntityKeyHash: 'L' * 43,
        sourceAttachmentKeys: {'L' * 43},
        historicalJournal: historicalJournal,
      ),
      throwsA(isA<StateError>()),
    );
    final foreign = CloudSyncHistoricalArchiveJournal(
      store: store,
      accountFingerprint: _account,
      protectedStoreIdentity: _storeId,
      snapshotSha256: 'f' * 64,
      clock: () => _now,
    );
    expect(
      () => uploads.adoptHistoricalPlan(
        historicalIntentId: historicalIntentId,
        plan: _plan('L' * 43),
        now: _now,
        historicalJournal: foreign,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('reopen attempt record adopt and dispatch revalidation', () async {
    const attemptId = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
    final prepared = uploads.adoptHistoricalPlan(
      historicalIntentId: historicalIntentId,
      plan: _plan('L' * 43),
      now: _now,
      historicalJournal: historicalJournal,
    );
    store.close();
    store = await openStore(directory: directory.path);
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    historicalJournal = _historicalJournal();
    uploads = CloudSyncAttachmentUploadJournal(
      store: store,
      localSends: CloudSyncLocalSendJournal(
        store: store,
        authority: authority,
        authoritySnapshot: authority.read(_writerScope())!,
      ),
      scope: _uploadScope(),
      checkpointGeneration: 1,
      currentAuth: _auth(),
      writerAuthority: authority,
    );
    localSends = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authority.read(_writerScope())!,
    );
    final found = uploads.findHistoricalForAttachment(
      historicalIntentId: historicalIntentId,
      logicalEntityKeyHash: 'L' * 43,
      sourceAttachmentKeys: {'L' * 43},
      historicalJournal: historicalJournal,
    );
    expect(found?.id, prepared.id);
    final started = uploads.beginHistoricalAttempt(
      id: prepared.id,
      attemptId: attemptId,
      now: _now,
      historicalJournal: historicalJournal,
    );
    expect(started.attemptId, attemptId);
    expect(
      uploads.readHistoricalAttemptedForReconciliation(
        historicalJournal: historicalJournal,
      ),
      contains(prepared.id),
    );
    expect(
      uploads.readHistoricalAttemptedForReconciliation(
        historicalIntentId: historicalIntentId + 1000,
        historicalJournal: historicalJournal,
      ),
      isEmpty,
    );
    final uploaded = uploads.recordHistoricalUploaded(
      id: prepared.id,
      attemptId: attemptId,
      result: _plan('L' * 43),
      now: _now,
      historicalJournal: historicalJournal,
    );
    expect(uploaded.result?.payloadSha256, 'e' * 64);
    final operationId = CloudOperationIdentity.forInitialCreate(
      scope: _uploadScope(),
      logicalEntityKeyHash: 'L' * 43,
      payloadVersion: 1,
    );
    store.box<CloudOutboxOperationEntity>().put(
      CloudOutboxOperationEntity(
        operationId: operationId,
        scopeKey: cloudSyncPersistentScopeKey(_uploadScope()),
        accountFingerprint: _account,
        zone: 'attachmentManateeZone',
        logicalEntityKeyHash: 'L' * 43,
        action: CloudOutboxAction.save.index,
        mutationRevision: 1,
        checkpointGeneration: 1,
        encryptedPayloadRef: 'obcs2.ref.${'P' * 43}',
        payloadSha256: 'e' * 64,
        protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
        serverRecordIdHash: 'M' * 43,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    final admitted = uploads.adoptHistoricalRecordCreate(
      id: prepared.id,
      now: _now,
      historicalJournal: historicalJournal,
      admit: (transactionStore, result) => CloudOutboxOperation(
        scope: _uploadScope(),
        operationId: operationId,
        logicalEntityKeyHash: 'L' * 43,
        action: CloudOutboxAction.save,
        payloadVersion: 1,
        mutationRevision: 1,
        checkpointGeneration: 1,
        dependencyOperationIds: const {},
        createdAt: _now,
        encryptedPayloadReference: 'obcs2.ref.${'P' * 43}',
        payloadSha256: 'e' * 64,
        serverRecordIdHash: 'M' * 43,
        protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
      ),
    );
    expect(admitted.admittedOperationId, operationId);
    uploads.requireHistoricalAdoptedOperation(
      CloudOutboxOperation(
        scope: _uploadScope(),
        operationId: operationId,
        logicalEntityKeyHash: 'L' * 43,
        action: CloudOutboxAction.save,
        payloadVersion: 1,
        mutationRevision: 1,
        checkpointGeneration: 1,
        dependencyOperationIds: const {},
        createdAt: _now,
        encryptedPayloadReference: 'obcs2.ref.${'P' * 43}',
        payloadSha256: 'e' * 64,
        serverRecordIdHash: 'M' * 43,
        protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
      ),
      historicalJournal,
    );
  });

  test(
    'historical child proof retains mixed original epochs and rejects unreleased receipts',
    () async {
      const attempt = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      final keys = {'L' * 43, 'K' * 43};
      final rows = store.box<CloudAttachmentUploadEntity>();
      final outbox = store.box<CloudOutboxOperationEntity>();
      final durable = ObjectBoxCloudSyncStore(
        store: store,
        protector: _NoCryptoProtector(),
        attachmentUploadJournal: uploads,
        historicalAttachmentJournal: historicalJournal,
        localSendJournal: localSends,
      );
      final ids = <int>[];
      for (final key in keys) {
        final stage = _plan(key);
        final plan = uploads.adoptHistoricalPlan(
          historicalIntentId: historicalIntentId,
          plan: stage,
          now: _now,
          historicalJournal: historicalJournal,
        );
        uploads.beginHistoricalAttempt(
          id: plan.id,
          attemptId: attempt,
          now: _now,
          historicalJournal: historicalJournal,
        );
        uploads.recordHistoricalUploaded(
          id: plan.id,
          attemptId: attempt,
          result: stage,
          now: _now,
          historicalJournal: historicalJournal,
        );
        final operationId = CloudOperationIdentity.forInitialCreate(
          scope: _uploadScope(),
          logicalEntityKeyHash: key,
          payloadVersion: 1,
        );
        final operation = CloudOutboxOperation(
          scope: _uploadScope(),
          operationId: operationId,
          logicalEntityKeyHash: key,
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          mutationRevision: 1,
          checkpointGeneration: 1,
          dependencyOperationIds: const {},
          createdAt: _now,
          encryptedPayloadReference: stage.protectedEnvelopeReference,
          payloadSha256: stage.payloadSha256,
          serverRecordIdHash: stage.serverRecordIdHash,
          protectedLeaseReference: stage.leaseReference,
        );
        final id = outbox.put(
          CloudOutboxOperationEntity(
            operationId: operationId,
            scopeKey: cloudSyncPersistentScopeKey(_uploadScope()),
            accountFingerprint: _account,
            zone: 'attachmentManateeZone',
            logicalEntityKeyHash: key,
            action: CloudOutboxAction.save.index,
            mutationRevision: 1,
            checkpointGeneration: 1,
            encryptedPayloadRef: stage.protectedEnvelopeReference,
            payloadSha256: stage.payloadSha256,
            serverRecordIdHash: stage.serverRecordIdHash,
            protectedLeaseReference: stage.leaseReference,
            createdAtMs: _now.millisecondsSinceEpoch,
            updatedAtMs: _now.millisecondsSinceEpoch,
          ),
        );
        uploads.adoptHistoricalRecordCreate(
          id: plan.id,
          now: _now,
          historicalJournal: historicalJournal,
          admit: (_, _) => operation,
        );
        final confirmed = outbox.get(id)!
          ..state = CloudOutboxStatus.confirmed.index
          ..confirmedAtMs = _now.millisecondsSinceEpoch
          ..appleRequestUuid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
          ..appleOperationUuid = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
        outbox.put(confirmed);
        final exact = durable.readHistoricalAttachmentOperation(
          _uploadScope(),
          operationId,
          historicalJournal,
        );
        await expectLater(
          durable.clearConfirmedProtectedOutboundLeaseReference(
            expectedOperation: exact,
          ),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(outbox.get(id)!.protectedLeaseReference, stage.leaseReference);
        await durable.clearConfirmedProtectedOutboundLeaseReference(
          expectedOperation: exact,
          recordVerifiedLocalSendReadback: true,
        );
        expect(outbox.get(id)!.protectedLeaseReference, isNull);
        expect(
          durable
              .readHistoricalAttachmentOperation(
                _uploadScope(),
                operationId,
                historicalJournal,
              )
              .status,
          CloudOutboxStatus.confirmed,
        );
        ids.add(plan.id);
        final epoch = authority.read(_writerScope())!.epoch;
        authority.markMutationUnknown(
          authority.issuePermit(
            _writerScope(),
            expectedOwner: CloudKitWriterOwner.v2,
          ),
          now: _now,
        );
        authority.reconcileMutationFence(
          _writerScope(),
          owner: CloudKitWriterOwner.v2,
          fencedEpoch: epoch,
          now: _now,
        );
      }
      expect(
        rows.get(ids.first)!.writerEpoch,
        isNot(rows.get(ids.last)!.writerEpoch),
      );
      final proof = uploads.captureHistoricalParentReadbackProof(
        historicalIntentId: historicalIntentId,
        sourceAttachmentKeys: keys,
        historicalJournal: historicalJournal,
      );
      uploads.requireHistoricalParentReadbackProof(
        historicalIntentId: historicalIntentId,
        proof: proof,
        historicalJournal: historicalJournal,
      );
      expect(
        () => uploads.requireParentReadbackProof(
          localSendIntentId: historicalIntentId,
          proof: proof,
        ),
        throwsA(isA<StateError>()),
      );
      final second = outbox.getAll().last
        ..protectedLeaseReference = 'obcs2.lease.${'f' * 32}';
      outbox.put(second);
      expect(
        () => uploads.requireHistoricalParentReadbackProof(
          historicalIntentId: historicalIntentId,
          proof: proof,
          historicalJournal: historicalJournal,
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('lane guards reject cross-owner and foreign use', () {
    final prepared = uploads.adoptHistoricalPlan(
      historicalIntentId: historicalIntentId,
      plan: _plan('L' * 43),
      now: _now,
      historicalJournal: historicalJournal,
    );
    _expectOwnerChanged(
      () => uploads.beginRetainedAttempt(
        id: prepared.id,
        attemptId: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
        sourceAttachmentKeys: {'L' * 43},
        now: _now,
      ),
    );
    expect(
      () => uploads.requireParentReadbackProof(
        localSendIntentId: historicalIntentId,
        proof: jsonEncode([2, 'scope', 1, 1, historicalIntentId]),
      ),
      throwsA(isA<StateError>()),
    );
    final foreignJournal = CloudSyncHistoricalArchiveJournal(
      store: store,
      accountFingerprint: 'B' * 43,
      protectedStoreIdentity: 'obcs2.store.${'T' * 43}',
      snapshotSha256: _snapshot,
      clock: () => _now,
    );
    expect(
      () => uploads.adoptHistoricalPlan(
        historicalIntentId: historicalIntentId,
        plan: _plan('L' * 43),
        now: _now,
        historicalJournal: foreignJournal,
      ),
      throwsA(isA<StateError>()),
    );
  });

  for (final scenario in [
    'exact',
    'missing',
    'wrongAttempt',
    'sourceDrift',
    'accountDrift',
  ]) {
    test('historical exact receipt guard: $scenario', () async {
      final auth = _auth();
      final plan = uploads.adoptHistoricalPlan(
        historicalIntentId: historicalIntentId,
        plan: _plan('L' * 43),
        now: _now,
        historicalJournal: historicalJournal,
      );
      const attempt = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      uploads.beginHistoricalAttempt(
        id: plan.id,
        attemptId: attempt,
        now: _now,
        historicalJournal: historicalJournal,
      );
      final epoch = authority.read(_writerScope())!.epoch;
      final binding = _HistoricalReceiptBinding();
      final guard = CloudKitWriterMutationGuard.forTest(
        store: store,
        readActiveClient: () => auth.cloudMessagesClient,
        privateStorageDirectory: directory.path,
        nativeAuthBinding: binding,
        reconciliationBinding: binding,
        buildDecision: CloudKitWriterOwnership.resolve('v2'),
      );
      final interlock = CloudKitOperationInterlock(
        privateStorageDirectory: directory.path,
        fenceStore: InMemoryCloudSyncStore(),
      );
      Future<T> run<T>(Future<T> Function() action) => interlock.runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: action,
      );
      await expectLater(
        run(
          () => guard.runAuthorized<void>(
            owner: CloudKitWriterOwner.v2,
            expectedClient: auth.cloudMessagesClient,
            expectedAccountFingerprint: _account,
            preparedHandleBindingSha256: 'f' * 64,
            reconciliationBindingSha256: uploads
                .reconciliationHistoricalBindingSha256(
                  plan.id,
                  historicalJournal,
                ),
            requireAdmission: () {},
            requireDurableAdmission: () async {},
            action: (capability) async {
              capability.consumeForNative();
              throw StateError('synthetic_lost_response');
            },
          ),
        ),
        throwsA(isA<CloudKitWriterAuthorityFailure>()),
      );
      expect(
        await run(
          () => guard.canSchedulePendingAttachmentUploadRecovery(
            expectedClient: auth.cloudMessagesClient,
            uploads: uploads,
            uploadId: plan.id,
            expectedEpoch: epoch,
            historicalJournal: historicalJournal,
          ),
        ),
        isTrue,
      );
      final fence = File(
        '${directory.path}/.openbubbles-cloudkit-writer-mutation-v1.fence',
      );
      final retainedFence = fence.readAsStringSync();
      binding.missing = scenario == 'missing';
      binding.wrongAttempt = scenario == 'wrongAttempt';
      binding.onVerify = () {
        if (scenario == 'accountDrift') binding.account = 'B' * 43;
        if (scenario == 'sourceDrift') {
          final box = store.box<CloudSyncHistoricalArchiveIntentEntity>();
          final row = box.get(historicalIntentId)!;
          final value = jsonDecode(row.protectedSourceBinding) as List<dynamic>;
          value[7] = 'obcs2.ref.${'Y' * 43}';
          row.protectedSourceBinding = jsonEncode(value);
          box.put(row);
        }
      };
      final recovery = run(
        () => guard.reconcilePendingAttachmentUpload(
          expectedClient: auth.cloudMessagesClient,
          uploads: uploads,
          onlyIntentId: historicalIntentId,
          historicalJournal: historicalJournal,
        ),
      );
      if (scenario == 'exact') {
        expect(await recovery, isTrue);
        expect(fence.existsSync(), isFalse);
        expect(
          authority.read(_writerScope())!.state,
          CloudKitWriterAuthorityState.stable,
        );
        expect(authority.read(_writerScope())!.epoch, epoch + 2);
      } else {
        if (scenario == 'missing') {
          expect(await recovery, isFalse);
        } else {
          await expectLater(
            recovery,
            throwsA(
              anyOf(isA<StateError>(), isA<CloudKitWriterAuthorityFailure>()),
            ),
          );
        }
        expect(fence.readAsStringSync(), retainedFence);
        expect(
          authority.read(_writerScope())!.state,
          CloudKitWriterAuthorityState.mutationUnknown,
        );
      }
      expect(binding.calls, 1);
      expect(
        store.box<CloudAttachmentUploadEntity>().get(plan.id)!.attemptId,
        attempt,
      );
      expect(
        store.box<CloudAttachmentUploadEntity>().get(plan.id)!.writerEpoch,
        epoch,
      );
      expect(
        store.box<CloudAttachmentUploadEntity>().get(plan.id)!.resultReference,
        isNull,
      );
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    });
  }

  test('old-epoch evidence stays readable; new attempts stay pinned', () async {
    const attemptId = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
    final prepared = uploads.adoptHistoricalPlan(
      historicalIntentId: historicalIntentId,
      plan: _plan('L' * 43),
      now: _now,
      historicalJournal: historicalJournal,
    );
    uploads.beginHistoricalAttempt(
      id: prepared.id,
      attemptId: attemptId,
      now: _now,
      historicalJournal: historicalJournal,
    );
    uploads.markHistoricalUnknown(
      id: prepared.id,
      attemptId: attemptId,
      now: _now,
      historicalJournal: historicalJournal,
    );
    final staleEpoch = authority.read(_writerScope())!.epoch;
    await CloudKitOperationInterlock(
      privateStorageDirectory: directory.path,
      fenceStore: InMemoryCloudSyncStore(),
    ).runExclusive(
      kind: CloudKitOperationKind.v2ReadWrite,
      action: () async {
        final permit = authority.issuePermit(
          _writerScope(),
          expectedOwner: CloudKitWriterOwner.v2,
        );
        authority.markMutationUnknown(permit, now: _now);
      },
    );
    expect(authority.read(_writerScope())!.epoch, staleEpoch + 1);
    expect(
      uploads
          .findHistoricalForAttachment(
            historicalIntentId: historicalIntentId,
            logicalEntityKeyHash: 'L' * 43,
            sourceAttachmentKeys: {'L' * 43},
            historicalJournal: historicalJournal,
          )
          ?.id,
      prepared.id,
    );
    expect(
      uploads
          .readHistoricalOriginalSource(prepared.id, historicalJournal)
          .sourceSha256,
      'c' * 64,
    );
    expect(
      uploads.readHistoricalAttemptedForReconciliation(
        historicalJournal: historicalJournal,
      ),
      contains(prepared.id),
    );
    final recovered = uploads.recordHistoricalUploaded(
      id: prepared.id,
      attemptId: attemptId,
      result: _plan('L' * 43),
      now: _now,
      historicalJournal: historicalJournal,
    );
    expect(recovered.result?.payloadSha256, 'e' * 64);
    final staleKey = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-attachment-upload-v1',
              cloudSyncPersistentScopeKey(_uploadScope()),
              1,
              _snapshot,
              historicalIntentId,
              'b' * 64,
              'c' * 64,
              'K' * 43,
            ]),
          ),
        )
        .toString();
    store.box<CloudAttachmentUploadEntity>().put(
      CloudAttachmentUploadEntity(
        uploadKey: staleKey,
        accountFingerprint: _account,
        writerEpoch: staleEpoch,
        checkpointGeneration: 1,
        localSendIntentId: 0,
        ownerKind: 1,
        ownerIntentId: historicalIntentId,
        messageGuidHash: 'b' * 64,
        sourceSha256: 'c' * 64,
        protectedStoreIdentity: _storeId,
        attachmentKeyHash: 'K' * 43,
        serverRecordIdHash: 'M' * 43,
        planReference: 'obcs2.ref.${'P' * 43}',
        planLeaseReference: 'obcs2.lease.${'f' * 32}',
        planPayloadSha256: 'e' * 64,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    final staleId = store
        .box<CloudAttachmentUploadEntity>()
        .query(CloudAttachmentUploadEntity_.attachmentKeyHash.equals('K' * 43))
        .build()
        .findUnique()!
        .id;
    expect(
      () => uploads.beginHistoricalAttempt(
        id: staleId,
        attemptId: 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',
        now: _now,
        historicalJournal: historicalJournal,
      ),
      throwsA(isA<StateError>()),
    );
  });
}

final class _HistoricalReceiptBinding
    implements
        production.CloudSyncNativeAuthBinding,
        CloudKitWriterHistoricalUploadReconciliationBinding {
  String account = _account;
  bool missing = false;
  bool wrongAttempt = false;
  int calls = 0;
  void Function()? onVerify;

  @override
  Future<production.CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async => production.CloudSyncNativeAuthMetadata(
    accountFingerprint: account,
    protectedStoreIdentity: _storeId,
    nativeSessionId: 'synthetic-session',
  );

  @override
  Future<frb.CloudSyncAttachmentUploadReceiptEvidence?>
  verifyHistoricalAttachmentUploadReceipt({
    required Object cloudMessagesClient,
    required frb.CloudSyncHistoricalAttachmentContext context,
    required frb.CloudSyncAttachmentUploadPlanReference planStage,
    required String expectedAttemptId,
  }) async {
    expect(context.source.snapshotSha256, _snapshot);
    expect(context.source.sourceSha256, 'c' * 64);
    expect(context.source.protectedReference, 'obcs2.ref.${'H' * 43}');
    expect(context.expectedAuth.nativeSessionId, 'synthetic-session');
    calls++;
    onVerify?.call();
    if (missing) return null;
    return frb.CloudSyncAttachmentUploadReceiptEvidence(
      uploadAttemptId: wrongAttempt
          ? 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
          : expectedAttemptId,
      planPayloadSha256: planStage.payloadSha256,
      logicalEntityKeyHash: planStage.logicalEntityKeyHash,
      serverRecordIdHash: planStage.serverRecordIdHash,
      completedPayloadSha256: 'e' * 64,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_native_operation');
}

final class _HistoricalPlanStaging
    implements CloudSyncOutboundStagingTransport {
  final commits = <String>[];
  final rollbacks = <String>[];
  bool failCommit = false;

  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedReference,
  ) async {
    commits.add(leaseReference);
    if (failCommit) throw StateError('synthetic_commit_interrupted');
  }

  @override
  Future<void> rollbackOutboundLease(String leaseReference) async {
    rollbacks.add(leaseReference);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_staging_operation');
}

final class _NoCryptoProtector implements CloudSyncProtector {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_crypto_operation');
}
