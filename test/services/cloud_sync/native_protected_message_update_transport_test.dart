import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_projection.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_update_executor.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_update_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_message_dependency.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _targetGuid = '22222222-2222-4222-8222-222222222222';
const _mutationGuid = '11111111-1111-4111-8111-111111111111';
const _requestUuid = '11111111-2222-4ABC-8DEF-555555555555';
const _operationUuid = 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001';

void main() {
  late _Fixture fixture;

  setUp(() async => fixture = await _Fixture.create());
  tearDown(() async => fixture.close());

  test('missing update binding fails read-only before native work', () async {
    final transport = fixture.buildTransport(bindings: _ReadOnlyBindings());

    await expectLater(
      fixture.runV2(
        () => transport.stageMessageUpdate(
          fixture.scope,
          source: fixture.source,
          predecessor: fixture.predecessor,
          currentAuth: fixture.auth,
          receipt: fixture.receipt,
        ),
      ),
      throwsA(_cloudFailure('cloud_sync_protected_read_only')),
    );
  });

  test(
    'cold receipt replay binds update preparation to the current native session',
    () async {
      final transport = fixture.buildTransport();
      final currentAuth = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: _token('C'),
        accountFingerprint: fixture.auth.accountFingerprint,
        protectedStoreIdentity: fixture.auth.protectedStoreIdentity,
        cloudMessagesClient: fixture.activeClient,
      );

      await fixture.runV2(
        () => transport.stageMessageUpdate(
          fixture.scope,
          source: fixture.source,
          predecessor: fixture.predecessor,
          currentAuth: currentAuth,
          receipt: fixture.receipt,
        ),
      );

      final input = fixture.bindings.stagedUpdateInput!;
      expect(
        input.mutationContext.nativeSessionId,
        currentAuth.nativeSessionId,
      );
      expect(
        input.mutationReceipt.nativeSessionId,
        fixture.receipt.nativeSessionId,
      );
      expect(
        input.mutationContext.nativeSessionId,
        isNot(input.mutationReceipt.nativeSessionId),
      );
    },
  );

  test('create prepared submission cannot enter update consume', () async {
    final transport = fixture.buildTransport();
    final create = fixture.createOperation();
    final createProtected = fixture.protectedOperation(
      create,
      serverReference: create.encryptedPayloadReference!,
    );
    final createIdentity = _identity(create.operationId);
    final update = fixture.updateOperation(
      status: CloudOutboxStatus.unknownOutcome,
      withSubmissionIdentity: true,
    );

    await fixture.runV2(() async {
      final prepared = await transport.prepareSubmission(
        fixture.scope,
        submissionIdentity: createIdentity,
        operations: [createProtected],
      );

      await expectLater(
        transport.consumePreparedMessageUpdate(
          fixture.scope,
          preparedSubmission: prepared,
          persistedIdentity: _identity(update.operationId),
          operation: update,
          protectedOperation: fixture.protectedOperation(update),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_native_prepared_update_required',
          ),
        ),
      );
    });

    expect(fixture.bindings.createPrepareCalls, 1);
    expect(fixture.bindings.updateConsumeCalls, 0);
  });

  test(
    'update prepared submission cannot enter generic create consume',
    () async {
      final transport = fixture.buildTransport();
      final update = fixture.updateOperation();
      final updateProtected = fixture.protectedOperation(update);

      await fixture.runV2(() async {
        final prepared = await transport.prepareMessageUpdateSubmission(
          fixture.scope,
          submissionIdentity: _identity(update.operationId),
          operation: update,
          protectedOperation: updateProtected,
          source: fixture.source,
          predecessor: fixture.predecessor,
        );

        await expectLater(
          transport.consumePreparedSubmission(
            fixture.scope,
            preparedSubmission: prepared,
            persistedIdentity: _identity(update.operationId),
            protectedOperations: [updateProtected],
            operations: [update],
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              'cloud_sync_native_prepared_submission_required',
            ),
          ),
        );
      });

      expect(fixture.bindings.updatePrepareCalls, 1);
      expect(fixture.bindings.createConsumeCalls, 0);
      expect(fixture.bindings.updateConsumeCalls, 0);
    },
  );

  test(
    'malformed source predecessor and operation correlations fail before native mutation',
    () async {
      final transport = fixture.buildTransport();
      final foreignScope = CloudSyncScope(
        accountFingerprint: _token('Z'),
        container: fixture.scope.container,
        database: fixture.scope.database,
        zone: fixture.scope.zone,
        streamKind: fixture.scope.streamKind,
        schemaVersion: fixture.scope.schemaVersion,
        persistenceLane: fixture.scope.persistenceLane,
      );

      await expectLater(
        fixture.runV2(
          () => transport.stageMessageUpdate(
            foreignScope,
            source: fixture.source,
            predecessor: fixture.predecessor,
            currentAuth: fixture.auth,
            receipt: fixture.receipt,
          ),
        ),
        throwsA(_cloudFailure('cloud_sync_message_update_source_invalid')),
      );

      final predecessorMismatch = fixture.updateOperation(
        serverRecordIdHash: _token('Z'),
      );
      await expectLater(
        fixture.runV2(
          () => transport.prepareMessageUpdateSubmission(
            fixture.scope,
            submissionIdentity: _identity(predecessorMismatch.operationId),
            operation: predecessorMismatch,
            protectedOperation: fixture.protectedOperation(
              predecessorMismatch,
              serverReference:
                  fixture.predecessor.recordMapping.encryptedServerRecordId,
            ),
            source: fixture.source,
            predecessor: fixture.predecessor,
          ),
        ),
        throwsA(_cloudFailure('cloud_sync_message_update_predecessor_changed')),
      );

      final update = fixture.updateOperation();
      await expectLater(
        fixture.runV2(
          () => transport.prepareMessageUpdateSubmission(
            fixture.scope,
            submissionIdentity: _identity(update.operationId),
            operation: update,
            protectedOperation: fixture.protectedOperation(
              update,
              serverReference: _reference('Z'),
            ),
            source: fixture.source,
            predecessor: fixture.predecessor,
          ),
        ),
        throwsA(_cloudFailure('cloud_sync_message_update_binding_mismatch')),
      );

      expect(fixture.bindings.updateStageCalls, 0);
      expect(fixture.bindings.updatePrepareCalls, 0);
      expect(fixture.bindings.updateConsumeCalls, 0);
    },
  );

  test(
    'successful update consume remains durably fenced outcome-unknown',
    () async {
      final transport = fixture.buildTransport();
      final leased = fixture.updateOperation();
      final unknown = leased.copyWith(
        status: CloudOutboxStatus.unknownOutcome,
        appleRequestUuid: _requestUuid,
        appleOperationUuid: _operationUuid,
      );
      final protected = fixture.protectedOperation(leased);

      await fixture.runV2(() async {
        final prepared = await transport.prepareMessageUpdateSubmission(
          fixture.scope,
          submissionIdentity: _identity(leased.operationId),
          operation: leased,
          protectedOperation: protected,
          source: fixture.source,
          predecessor: fixture.predecessor,
        );
        await transport.consumePreparedMessageUpdate(
          fixture.scope,
          preparedSubmission: prepared,
          persistedIdentity: _identity(unknown.operationId),
          operation: unknown,
          protectedOperation: protected,
        );
      });

      expect(fixture.bindings.updateConsumeCalls, 1);
      expect(
        fixture.writerAuthority.read(fixture.writerScope)!.state,
        CloudKitWriterAuthorityState.mutationUnknown,
      );
      expect(fixture.mutationFence.existsSync(), isTrue);
    },
  );

  test(
    'generic create reconciliation explicitly rejects update payload v3',
    () async {
      final transport = fixture.buildTransport();
      final leased = fixture.updateOperation();
      final unknown = leased.copyWith(
        status: CloudOutboxStatus.unknownOutcome,
        appleRequestUuid: _requestUuid,
        appleOperationUuid: _operationUuid,
      );
      final protected = fixture.protectedOperation(leased);

      await fixture.runV2(() async {
        final prepared = await transport.prepareMessageUpdateSubmission(
          fixture.scope,
          submissionIdentity: _identity(leased.operationId),
          operation: leased,
          protectedOperation: protected,
          source: fixture.source,
          predecessor: fixture.predecessor,
        );
        await transport.consumePreparedMessageUpdate(
          fixture.scope,
          preparedSubmission: prepared,
          persistedIdentity: _identity(unknown.operationId),
          operation: unknown,
          protectedOperation: protected,
        );
      });

      await expectLater(
        fixture.runV2(
          () => transport.reconcileUnknownOutcome(
            fixture.scope,
            operation: unknown,
          ),
        ),
        throwsA(
          isA<CloudKitWriterAuthorityFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloudkit_writer_create_reconciliation_update_forbidden',
          ),
        ),
      );

      expect(fixture.bindings.createReconcileCalls, 0);
      expect(fixture.bindings.updateReconcileCalls, 0);
      expect(fixture.mutationFence.existsSync(), isTrue);
    },
  );

  test(
    'update executor commits exact readback and finalizes both leases',
    () async {
      final transport = _ExecutorTransport(
        CloudSyncMessageUpdateReconciliationDisposition.committed,
      );
      final executor = fixture.buildExecutor(transport);

      final admitted = await executor.admitReflectedUpdate(
        fixture.scope,
        source: fixture.source,
        predecessor: fixture.predecessor,
        currentAuth: fixture.auth,
        stillCurrent: () => true,
        receipt: fixture.receipt,
      );
      final result = await executor.runOnce(
        fixture.scope,
        currentAuth: fixture.auth,
        stillCurrent: () => true,
      );

      expect(result.submitted, 1);
      expect(result.confirmed, 1);
      expect(transport.committedLeases, [_lease('c'), _lease('e')]);
      expect(transport.acknowledgedLeases, [_lease('c'), _lease('e')]);
      expect(transport.completedStatuses, [CloudOutboxStatus.confirmed]);
      expect(transport.releaseCalls, 1);
      final stored = (await fixture.cloudStore.readOutboxEntries(
        fixture.scope,
      )).singleWhere((entry) => entry.operationId == admitted.operationId);
      expect(stored.status, CloudOutboxStatus.confirmed);
      expect(stored.protectedLeaseReference, isNull);
      final mapping = await fixture.cloudStore.readRecordMap(
        fixture.scope,
        logicalEntityKeyHash: admitted.logicalEntityKeyHash,
        generation: admitted.checkpointGeneration,
        serverRecordIdHash: admitted.serverRecordIdHash,
      );
      expect(mapping!.etagHash, _token('T'));
      expect(mapping.encryptedRawRecordReference, _reference('V'));
      expect(mapping.protectedReadbackLeaseReference, isNull);
    },
  );

  test(
    'update executor ignores an unrelated retained sibling tombstone',
    () async {
      fixture.retainSeededTombstone('attachmentManateeZone');
      final transport = _ExecutorTransport(
        CloudSyncMessageUpdateReconciliationDisposition.committed,
      );
      final executor = fixture.buildExecutor(transport);

      final admitted = await executor.admitReflectedUpdate(
        fixture.scope,
        source: fixture.source,
        predecessor: fixture.predecessor,
        currentAuth: fixture.auth,
        stillCurrent: () => true,
        receipt: fixture.receipt,
      );
      final result = await executor.runOnce(
        fixture.scope,
        currentAuth: fixture.auth,
        stillCurrent: () => true,
      );

      expect(result.submitted, 1);
      expect(result.confirmed, 1);
      expect(
        (await fixture.cloudStore.readOutboxEntries(fixture.scope))
            .singleWhere((entry) => entry.operationId == admitted.operationId)
            .status,
        CloudOutboxStatus.confirmed,
      );
    },
  );

  test('update executor rejects a retained tombstone for its record', () async {
    fixture.retainSeededTombstone('messageManateeZone');
    final transport = _ExecutorTransport(
      CloudSyncMessageUpdateReconciliationDisposition.committed,
    );
    final executor = fixture.buildExecutor(transport);

    final admitted = await executor.admitReflectedUpdate(
      fixture.scope,
      source: fixture.source,
      predecessor: fixture.predecessor,
      currentAuth: fixture.auth,
      stillCurrent: () => true,
      receipt: fixture.receipt,
    );
    await expectLater(
      executor.runOnce(
        fixture.scope,
        currentAuth: fixture.auth,
        stillCurrent: () => true,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'messages_cloud_tombstone_projection_unavailable',
        ),
      ),
    );
    expect(transport.stageCalls, 1);
    expect(
      (await fixture.cloudStore.readOutboxEntries(fixture.scope))
          .singleWhere((entry) => entry.operationId == admitted.operationId)
          .status,
      CloudOutboxStatus.pending,
    );
  });

  test(
    'acknowledgement failure happens after durable update finalization',
    () async {
      final transport = _ExecutorTransport(
        CloudSyncMessageUpdateReconciliationDisposition.committed,
        failAcknowledgement: true,
      );
      final executor = fixture.buildExecutor(transport);
      final admitted = await executor.admitReflectedUpdate(
        fixture.scope,
        source: fixture.source,
        predecessor: fixture.predecessor,
        currentAuth: fixture.auth,
        stillCurrent: () => true,
        receipt: fixture.receipt,
      );

      await expectLater(
        executor.runOnce(
          fixture.scope,
          currentAuth: fixture.auth,
          stillCurrent: () => true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(transport.completedStatuses, <CloudOutboxStatus>[
        CloudOutboxStatus.confirmed,
      ]);
      final stored = (await fixture.cloudStore.readOutboxEntries(
        fixture.scope,
      )).singleWhere((entry) => entry.operationId == admitted.operationId);
      expect(stored.status, CloudOutboxStatus.confirmed);
      expect(stored.protectedLeaseReference, isNull);
      final mapping = await fixture.cloudStore.readRecordMap(
        fixture.scope,
        logicalEntityKeyHash: admitted.logicalEntityKeyHash,
        generation: admitted.checkpointGeneration,
        serverRecordIdHash: admitted.serverRecordIdHash,
      );
      expect(mapping!.encryptedRawRecordReference, _reference('V'));
      expect(mapping.protectedReadbackLeaseReference, isNull);
      expect(transport.acknowledgedLeases, <String>[_lease('c')]);

      final restartTransport = _ExecutorTransport(
        CloudSyncMessageUpdateReconciliationDisposition.committed,
      );
      final restart = await fixture
          .buildExecutor(restartTransport)
          .runOnce(
            fixture.scope,
            currentAuth: fixture.auth,
            stillCurrent: () => true,
          );
      expect(restart.submitted, 0);
      expect(restartTransport.committedLeases, isEmpty);
      expect(restartTransport.acknowledgedLeases, isEmpty);
    },
  );

  for (final kind in CloudSyncLocalMutationKind.values) {
    test(
      '${kind.name} exact readback stays terminal across executor restart',
      () async {
        final variant = kind == CloudSyncLocalMutationKind.edit
            ? fixture
            : await _Fixture.create(kind: kind);
        try {
          final firstTransport = _ExecutorTransport(
            CloudSyncMessageUpdateReconciliationDisposition.committed,
          );
          final firstExecutor = variant.buildExecutor(firstTransport);
          final admitted = await firstExecutor.admitReflectedUpdate(
            variant.scope,
            source: variant.source,
            predecessor: variant.predecessor,
            currentAuth: variant.auth,
            stillCurrent: () => true,
            receipt: variant.receipt,
          );
          final first = await firstExecutor.runOnce(
            variant.scope,
            currentAuth: variant.auth,
            stillCurrent: () => true,
          );

          expect(first.submitted, 1);
          expect(first.confirmed, 1);
          expect(firstTransport.stageCalls, 1);
          final exactOperation =
              (await variant.cloudStore.readOutboxEntries(
                variant.scope,
              )).singleWhere(
                (operation) => operation.operationId == admitted.operationId,
              );
          final confirmedSource = variant.journal.markExactReadbackConfirmed(
            intentId: variant.source.intentId,
            operation: exactOperation,
            currentAuth: variant.auth,
            stillCurrent: () => true,
            now: _time(21),
          );
          await firstTransport.acknowledgeCommittedPageLease(
            confirmedSource.leaseReference,
          );
          final journalRow = variant.store
              .box<CloudSyncLocalMutationIntentEntity>()
              .getAll()
              .single;
          expect(journalRow.state, 5);
          expect(journalRow.admittedOperationId, admitted.operationId);
          expect(
            await variant.cloudStore.readLiveProtectedOutboundLeaseReferences(
              maximumCount: 100,
            ),
            isNot(
              contains(
                variant.source.decodeProtectedSourceBinding().leaseReference,
              ),
            ),
          );

          final restartTransport = _ExecutorTransport(
            CloudSyncMessageUpdateReconciliationDisposition.committed,
          );
          final restartExecutor = variant.buildExecutor(restartTransport);
          final replay = await restartExecutor.runOnce(
            variant.scope,
            currentAuth: variant.auth,
            stillCurrent: () => true,
          );

          expect(replay.submitted, 0);
          expect(replay.confirmed, 0);
          expect(restartTransport.stageCalls, 0);
          expect(restartTransport.committedLeases, isEmpty);
          expect(restartTransport.acknowledgedLeases, isEmpty);
          expect(restartTransport.completedStatuses, isEmpty);
          expect(restartTransport.releaseCalls, 0);
        } finally {
          if (!identical(variant, fixture)) await variant.close();
        }
      },
    );
  }

  test(
    'update executor proves not-applied before returning work to pending',
    () async {
      final transport = _ExecutorTransport(
        CloudSyncMessageUpdateReconciliationDisposition.notApplied,
      );
      final executor = fixture.buildExecutor(transport);
      final admitted = await executor.admitReflectedUpdate(
        fixture.scope,
        source: fixture.source,
        predecessor: fixture.predecessor,
        currentAuth: fixture.auth,
        stillCurrent: () => true,
        receipt: fixture.receipt,
      );

      final result = await executor.runOnce(
        fixture.scope,
        currentAuth: fixture.auth,
        stillCurrent: () => true,
      );

      expect(result.notApplied, 1);
      expect(transport.completedStatuses, [CloudOutboxStatus.unknownOutcome]);
      expect(transport.acknowledgedLeases, isEmpty);
      final stored = (await fixture.cloudStore.readOutboxEntries(
        fixture.scope,
      )).singleWhere((entry) => entry.operationId == admitted.operationId);
      expect(stored.status, CloudOutboxStatus.pending);
      expect(stored.protectedLeaseReference, _lease('c'));
    },
  );

  test('stale admission source cannot restage an adopted update', () async {
    final transport = _ExecutorTransport(
      CloudSyncMessageUpdateReconciliationDisposition.unresolved,
    );
    final executor = fixture.buildExecutor(transport);
    final first = await executor.admitReflectedUpdate(
      fixture.scope,
      source: fixture.source,
      predecessor: fixture.predecessor,
      currentAuth: fixture.auth,
      stillCurrent: () => true,
      receipt: fixture.receipt,
    );
    final second = await executor.admitReflectedUpdate(
      fixture.scope,
      source: fixture.source,
      predecessor: fixture.predecessor,
      currentAuth: fixture.auth,
      stillCurrent: () => true,
      receipt: fixture.receipt,
    );

    expect(second.operationId, first.operationId);
    expect(transport.stageCalls, 1);
    expect(transport.committedLeases, [_lease('c')]);
  });
}

final class _Fixture {
  _Fixture._({
    required this.directory,
    required this.store,
    required this.cloudStore,
    required this.scope,
    required this.activeClient,
    required this.writerAuthority,
    required this.writerScope,
    required this.source,
    required this.predecessor,
    required this.receipt,
    required this.auth,
    required this.journal,
    required this.bindings,
  });

  final Directory directory;
  final Store store;
  final ObjectBoxCloudSyncStore cloudStore;
  final CloudSyncScope scope;
  final Object activeClient;
  final ObjectBoxCloudKitWriterAuthority writerAuthority;
  final CloudKitWriterScope writerScope;
  final CloudSyncLocalMutationAdmissionSource source;
  final CloudSyncMessageMutationPredecessor predecessor;
  final api.CloudSyncNativeSendReceipt receipt;
  final CloudSyncNativeAuthSnapshot auth;
  final CloudSyncLocalMutationJournal journal;
  final _Bindings bindings;

  File get mutationFence => File(
    '${directory.path}${Platform.pathSeparator}'
    '.openbubbles-cloudkit-writer-mutation-v1.fence',
  );

  static Future<_Fixture> create({
    CloudSyncLocalMutationKind kind = CloudSyncLocalMutationKind.edit,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'openbubbles-message-update-transport-',
    );
    final store = await openStore(directory: directory.path);
    final activeClient = Object();
    final scope = CloudSyncScope(
      accountFingerprint: _token('A'),
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'messageManateeZone',
      streamKind: CloudSyncStreamKind.messages,
      schemaVersion: 2,
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final writerScope = CloudKitWriterScope(
      accountFingerprint: scope.accountFingerprint,
    );
    final writerAuthority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: const CloudKitWriterOwnershipDecision(
        owner: CloudKitWriterOwner.v2,
        configurationValid: true,
      ),
    );
    final disabled = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: const CloudKitWriterOwnershipDecision(
        owner: CloudKitWriterOwner.none,
        configurationValid: true,
      ),
    ).initializeDisabled(writerScope, now: _time(0));
    writerAuthority.provisionInitialOwner(
      writerScope,
      owner: CloudKitWriterOwner.v2,
      expectedEpoch: disabled.epoch,
      evidence: const CloudKitWriterTransitionEvidence.forTest(
        operationsQuiesced: true,
        activeIdentityRevalidated: true,
        legacyMutationQueues: LegacyMutationQueueDisposition.empty,
      ),
      now: _time(1),
    );

    final handle = Handle(
      address: 'peer@example.invalid',
      service: 'iMessage',
      uniqueAddressAndService: 'peer@example.invalid/iMessage',
    );
    store.box<Handle>().put(handle);
    final chat = Chat(
      guid: 'iMessage;-;peer@example.invalid',
      style: 45,
      chatIdentifier: 'peer@example.invalid',
      usingHandle: 'mailto:me@example.invalid',
      participants: [handle],
    );
    chat.handles.add(handle);
    store.box<Chat>().put(chat);
    final target = Message(
      guid: _targetGuid,
      isFromMe: true,
      text: 'original',
      dateCreated: _time(1),
      attributedBody: [AttributedBody.raw('original')],
    )..chat.target = chat;
    store.box<Message>().put(target);

    final wire = _mutationWire(kind);
    final identity = CloudSyncLocalMutationIdentity.captureWire(wire)!;
    final sourceBinding = CloudSyncLocalMutationSourceBinding(
      accountFingerprint: scope.accountFingerprint,
      protectedStoreIdentity: _storeIdentity,
      mutationGuidHash: identity.guidHash,
      targetGuidHash: identity.targetGuidHash,
      targetPart: identity.targetPart,
      sourceSha256: identity.sourceSha256,
      protectedReference: _reference('M'),
      leaseReference: _lease('b'),
      payloadSha256: _sha('a'),
      payloadLength: 512,
    );
    final auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: _token('N'),
      accountFingerprint: scope.accountFingerprint,
      protectedStoreIdentity: _storeIdentity,
      cloudMessagesClient: activeClient,
    );
    final journal = CloudSyncLocalMutationJournal(
      store: store,
      authority: writerAuthority,
      authoritySnapshot: writerAuthority.read(writerScope)!,
    );
    final before = journal.captureTargetSnapshot(
      localMessageId: target.id!,
      identity: identity,
    );
    final intentId = journal.adoptSource(
      localMessageId: target.id!,
      identity: identity,
      targetSnapshotSha256: before,
      source: sourceBinding,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(2),
    );
    journal.beginSubmission(
      intentId: intentId,
      committedSource: sourceBinding,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(3),
    );
    final receipt = api.CloudSyncNativeSendReceipt(
      receiptId: 'obcs2.ids.${_token('I')}',
      guidHash: identity.guidHash,
      nativeSessionId: auth.nativeSessionId,
      preparedSentTimestampMs: BigInt.from(_time(4).millisecondsSinceEpoch),
      sourceBinding: api.CloudSyncNativeSendSourceBinding(
        kind: api.CloudSyncNativeSendSourceKind.mutation,
        sourceSha256: sourceBinding.sourceSha256,
        protectedReference: sourceBinding.protectedReference,
        leaseReference: sourceBinding.leaseReference,
        payloadSha256: sourceBinding.payloadSha256,
        payloadLength: BigInt.from(sourceBinding.payloadLength),
      ),
    );
    journal.recordNativeReceipt(
      intentId: intentId,
      receipt: receipt,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(4),
    );
    final projection = CloudSyncLocalMutationProjection.projectFirst(
      target: store.box<Message>().get(target.id!)!,
      wire: wire,
      source: sourceBinding,
      preparedSentTimestampMs: receipt.preparedSentTimestampMs!.toInt(),
    );
    journal.reflectConfirmed(
      intentId: intentId,
      receipt: receipt,
      currentAuth: auth,
      stillCurrent: () => true,
      project: (message, timestamp) => message
        ..text = projection.text
        ..attributedBody = projection.attributedBody
        ..messageSummaryInfo = projection.messageSummaryInfo
        ..dateEdited = projection.dateEdited,
      now: _time(5),
    );
    final source = journal.readReflectedForUpdate(
      intentId: intentId,
      currentAuth: auth,
      stillCurrent: () => true,
    );

    final cloudStore = ObjectBoxCloudSyncStore(
      store: store,
      protector: _NoProtector(),
      localMutationJournal: journal,
      clock: () => _time(6),
    );
    await _seedCompletedCloudAccount(cloudStore, scope);
    final checkpoint = await cloudStore.readCheckpoint(scope);
    final scopeKey = cloudSyncPersistentScopeKey(scope);
    final generationKey =
        'semantic-generation4:${sha256.convert(utf8.encode('$scopeKey\u001f${checkpoint.generation}'))}';
    final lookupHash = CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
      scope: scope,
      generation: checkpoint.generation,
      canonicalGuid: _targetGuid,
    );
    final canonicalHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
      scope: scope,
      generation: checkpoint.generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: _logicalEntityKeyHash,
      canonicalGuid: _targetGuid,
    );
    store.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        snapshotKey:
            'semantic-snapshot4:$generationKey:message:$_logicalEntityKeyHash',
        scopeGenerationKey: generationKey,
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        generation: checkpoint.generation,
        entityKind: CloudEntityKind.message.name,
        logicalEntityKeyHash: _logicalEntityKeyHash,
        canonicalGuidHash: canonicalHash,
        canonicalGuidLookupHash: lookupHash,
        etagHash: _etagHash,
        updatedAtMs: _time(7).millisecondsSinceEpoch,
      ),
    );
    store.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: cloudSyncCanonicalRecordMapKey(scope, _logicalEntityKeyHash),
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        logicalEntityKeyHash: _logicalEntityKeyHash,
        serverRecordIdHash: _serverRecordIdHash,
        generation: checkpoint.generation,
        encryptedServerRecordId: _reference('R'),
        etagHash: _etagHash,
        encryptedRawRecordRef: _reference('W'),
        rawRecordGeneration: checkpoint.generation,
        updatedAtMs: _time(7).millisecondsSinceEpoch,
      ),
    );
    final predecessor = source.requirePredecessor(
      store: store,
      messageScope: scope,
    );

    return _Fixture._(
      directory: directory,
      store: store,
      cloudStore: cloudStore,
      scope: scope,
      activeClient: activeClient,
      writerAuthority: writerAuthority,
      writerScope: writerScope,
      source: source,
      predecessor: predecessor,
      receipt: receipt,
      auth: auth,
      journal: journal,
      bindings: _Bindings(),
    );
  }

  CloudSyncMessageUpdateExecutor buildExecutor(_ExecutorTransport transport) =>
      CloudSyncMessageUpdateExecutor(
        objectBoxStore: store,
        cloudStore: cloudStore,
        journal: journal,
        transport: transport,
        preparedSubmissionReleaser: transport,
        leaseTransport: transport,
        clock: () => _time(20),
        uuidFactory: _UuidSequence().next,
      );

  void retainSeededTombstone(String zone) {
    final rows = store
        .box<CloudInboxChangeEntity>()
        .getAll()
        .where(
          (row) =>
              row.accountFingerprint == scope.accountFingerprint &&
              row.zone == zone,
        )
        .toList(growable: false);
    if (rows.length != 1) {
      throw StateError('fixture_seeded_inbox_row_missing');
    }
    final row = rows.single
      ..status = CloudInboxStatus.retainedUnprojected.index
      ..changeType = CloudChangeType.delete.name
      ..isTombstone = true
      ..etagHash = null
      ..encryptedPayloadRef = null
      ..payloadSha256 = null;
    store.box<CloudInboxChangeEntity>().put(row);
  }

  NativeProtectedCloudSyncTransport buildTransport({
    NativeProtectedCloudSyncBindings? bindings,
  }) => NativeProtectedCloudSyncTransport(
    cloudMessagesClient: activeClient,
    storageDirectory: directory.path,
    protectedStoreIdentity: _storeIdentity,
    bindings: bindings ?? this.bindings,
    readCheckpointGeneration: (_) async => predecessor.generation,
    writerMutationGuard: CloudKitWriterMutationGuard.forTest(
      store: store,
      readActiveClient: () => activeClient,
      privateStorageDirectory: directory.path,
      nativeAuthBinding: _AuthBinding(
        accountFingerprint: scope.accountFingerprint,
        protectedStoreIdentity: _storeIdentity,
      ),
      reconciliationBinding: this.bindings,
      buildDecision: const CloudKitWriterOwnershipDecision(
        owner: CloudKitWriterOwner.v2,
        configurationValid: true,
      ),
    ),
  );

  Future<T> runV2<T>(Future<T> Function() action) => CloudKitOperationInterlock(
    privateStorageDirectory: directory.path,
    fenceStore: InMemoryCloudSyncStore(),
  ).runExclusive(kind: CloudKitOperationKind.v2ReadWrite, action: action);

  CloudOutboxOperation updateOperation({
    CloudOutboxStatus status = CloudOutboxStatus.leased,
    bool withSubmissionIdentity = false,
    String? serverRecordIdHash,
  }) {
    const payloadSha256 =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final operationId = CloudOperationIdentity.forMutation(
      scope: scope,
      logicalEntityKeyHash: _logicalEntityKeyHash,
      action: CloudOutboxAction.save,
      payloadVersion: cloudSyncMessageUpdatePayloadVersion,
      mutationRevision: 1,
      payloadSha256: payloadSha256,
    );
    return CloudOutboxOperation(
      scope: scope,
      operationId: operationId,
      logicalEntityKeyHash: _logicalEntityKeyHash,
      action: CloudOutboxAction.save,
      payloadVersion: cloudSyncMessageUpdatePayloadVersion,
      mutationRevision: 1,
      checkpointGeneration: predecessor.generation,
      dependencyOperationIds: const {},
      createdAt: _time(8),
      encryptedPayloadReference: _reference('U'),
      payloadSha256: payloadSha256,
      serverRecordIdHash: serverRecordIdHash ?? _serverRecordIdHash,
      protectedLeaseReference: _lease('c'),
      appleRequestUuid: withSubmissionIdentity ? _requestUuid : null,
      appleOperationUuid: withSubmissionIdentity ? _operationUuid : null,
      status: status,
    );
  }

  CloudOutboxOperation createOperation() {
    const logical = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
    final operationId = CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: logical,
      payloadVersion: cloudSyncOutboundPayloadVersion,
    );
    return CloudOutboxOperation(
      scope: scope,
      operationId: operationId,
      logicalEntityKeyHash: logical,
      action: CloudOutboxAction.save,
      payloadVersion: cloudSyncOutboundPayloadVersion,
      mutationRevision: 1,
      checkpointGeneration: predecessor.generation,
      dependencyOperationIds: const {},
      createdAt: _time(8),
      encryptedPayloadReference: _reference('C'),
      payloadSha256: _sha('e'),
      serverRecordIdHash: _token('C'),
      protectedLeaseReference: _lease('d'),
      status: CloudOutboxStatus.leased,
    );
  }

  CloudSyncProtectedWriteOperation protectedOperation(
    CloudOutboxOperation operation, {
    String? serverReference,
  }) => CloudSyncProtectedWriteOperation(
    operationId: operation.operationId,
    logicalEntityKeyHash: operation.logicalEntityKeyHash,
    action: operation.action,
    protectedLeaseReference: operation.protectedLeaseReference,
    protectedServerRecordIdReference:
        serverReference ?? predecessor.recordMapping.encryptedServerRecordId,
    serverRecordIdHash: operation.serverRecordIdHash!,
    protectedPayloadReference: operation.encryptedPayloadReference,
    payloadSha256: operation.payloadSha256,
  );

  Future<void> close() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  }
}

Future<void> _seedCompletedCloudAccount(
  ObjectBoxCloudSyncStore store,
  CloudSyncScope messageScope,
) async {
  for (final (index, zone) in const <(int, String)>[
    (0, 'chatManateeZone'),
    (1, 'messageManateeZone'),
    (2, 'attachmentManateeZone'),
  ]) {
    final scope = CloudSyncScope(
      accountFingerprint: messageScope.accountFingerprint,
      container: messageScope.container,
      database: messageScope.database,
      zone: zone,
      streamKind: messageScope.streamKind,
      schemaVersion: messageScope.schemaVersion,
      persistenceLane: messageScope.persistenceLane,
    );
    final checkpoint = await store.readCheckpoint(scope);
    final lease = await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'message-update-fixture-$zone',
      now: _time(6),
      leaseDuration: const Duration(minutes: 10),
    );
    if (lease == null) throw StateError('fixture_coordinator_lease_missing');
    final marker = String.fromCharCode(65 + index);
    final messageZone = zone == 'messageManateeZone';
    await store.journalFetchedBatch(
      CloudFetchBatch(
        scope: scope,
        changes: <CloudFetchedChange>[
          CloudFetchedChange(
            changeId: _token(marker),
            recordIdHash: messageZone ? _serverRecordIdHash : _token(marker),
            type: CloudChangeType.save,
            etagHash: messageZone ? _etagHash : _token(marker),
            encryptedServerRecordId: messageZone
                ? _reference('R')
                : _reference(marker),
            protectedSystemFieldsReference: _reference('X'),
            encryptedPayloadReference: messageZone
                ? _reference('W')
                : _reference(marker),
            payloadSha256: _sha(marker.toLowerCase()),
          ),
        ],
        batchId: 'message-update-fixture-$zone',
        generation: checkpoint.generation,
        nextToken: 'message-update-token-$zone',
        hasMore: false,
      ),
      now: _time(6),
      leaseFence: lease,
      expectedGeneration: checkpoint.generation,
      expectedFetchedToken: checkpoint.fetchedToken,
    );
    await store.markInboxApplied(
      scope,
      sequence: 1,
      now: _time(7),
      leaseFence: lease,
    );
    await store.recordPullSuccess(scope, now: _time(7));
  }
}

final class _ExecutorTransport
    implements
        CloudSyncMessageUpdateTransport,
        CloudSyncPreparedSubmissionReleaser,
        CloudProtectedPageLeaseTransport {
  _ExecutorTransport(this.disposition, {this.failAcknowledgement = false});

  final CloudSyncMessageUpdateReconciliationDisposition disposition;
  final bool failAcknowledgement;
  int stageCalls = 0;
  int releaseCalls = 0;
  final List<String> committedLeases = <String>[];
  final List<String> acknowledgedLeases = <String>[];
  final List<String> rolledBackLeases = <String>[];
  final List<CloudOutboxStatus> completedStatuses = <CloudOutboxStatus>[];

  @override
  String get protectedPageLeaseRecoveryIdentity => _storeIdentity;

  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      action();

  @override
  Future<CloudSyncProtectedMessageUpdateStage> stageMessageUpdate(
    CloudSyncScope scope, {
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required api.CloudSyncNativeSendReceipt receipt,
  }) async {
    stageCalls++;
    return CloudSyncProtectedMessageUpdateStage(
      protectedReference: _reference('U'),
      leaseReference: _lease('c'),
      payloadSha256: _sha('c'),
      logicalEntityKeyHash: predecessor.recordMapping.logicalEntityKeyHash,
      serverRecordIdHash: predecessor.recordMapping.serverRecordIdHash,
    );
  }

  @override
  Future<CloudSyncPreparedSubmission> prepareMessageUpdateSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required CloudOutboxOperation operation,
    required CloudSyncProtectedWriteOperation protectedOperation,
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  }) async => CloudSyncPreparedSubmission.fromProtectedPreflight(
    scope: scope,
    identity: submissionIdentity,
    operations: <CloudSyncProtectedWriteOperation>[protectedOperation],
  );

  @override
  Future<void> consumePreparedMessageUpdate(
    CloudSyncScope scope, {
    required CloudSyncPreparedSubmission preparedSubmission,
    required CloudOutboxSubmissionIdentity persistedIdentity,
    required CloudOutboxOperation operation,
    required CloudSyncProtectedWriteOperation protectedOperation,
  }) async => preparedSubmission.claimForConsumption(
    scope,
    persistedIdentity: persistedIdentity,
    protectedOperations: <CloudSyncProtectedWriteOperation>[protectedOperation],
  );

  @override
  Future<CloudSyncMessageUpdateReconciliation> reconcileMessageUpdate(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  }) async => switch (disposition) {
    CloudSyncMessageUpdateReconciliationDisposition.committed =>
      CloudSyncMessageUpdateReconciliation.committed(
        CloudMessageUpdateReadbackReceipt(
          operationId: operation.operationId,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          serverRecordIdHash: operation.serverRecordIdHash!,
          predecessorEtagHash: predecessor.recordMapping.etagHash!,
          resultingEtagHash: _token('T'),
          protectedCurrentRawRecordReference: _reference('V'),
          protectedCurrentRawRecordLeaseReference: _lease('e'),
          rawGeneration: predecessor.generation,
          appleRequestUuid: operation.appleRequestUuid!,
          appleOperationUuid: operation.appleOperationUuid!,
        ),
      ),
    CloudSyncMessageUpdateReconciliationDisposition.notApplied =>
      const CloudSyncMessageUpdateReconciliation.notApplied(),
    CloudSyncMessageUpdateReconciliationDisposition.diverged =>
      const CloudSyncMessageUpdateReconciliation.diverged(),
    CloudSyncMessageUpdateReconciliationDisposition.unresolved =>
      const CloudSyncMessageUpdateReconciliation.unresolved(
        failureCategory: CloudFailureCategory.network,
      ),
  };

  @override
  Future<void> completeMessageUpdateReconciliation(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) async => completedStatuses.add(operation.status);

  @override
  Future<bool> releasePreparedSubmission(
    CloudSyncPreparedSubmission preparedSubmission,
  ) async {
    releaseCalls++;
    return true;
  }

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> retainedReferences,
  ) async => committedLeases.add(leaseReference);

  @override
  Future<void> acknowledgeCommittedPageLease(String leaseReference) async {
    acknowledgedLeases.add(leaseReference);
    if (failAcknowledgement) {
      throw StateError('simulated_acknowledgement_failure');
    }
  }

  @override
  Future<void> rollbackProtectedPageLease(String leaseReference) async =>
      rolledBackLeases.add(leaseReference);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected executor transport operation');
}

final class _UuidSequence {
  var _next = 0;

  String next() {
    _next++;
    return '00000000-0000-4000-8000-${_next.toString().padLeft(12, '0')}';
  }
}

final class _Bindings
    implements
        NativeProtectedCloudSyncBindings,
        NativeProtectedCloudSyncWriteBindings,
        NativeProtectedCloudSyncMessageUpdateBindings,
        CloudKitWriterReconciliationBinding {
  int createPrepareCalls = 0;
  int createConsumeCalls = 0;
  int createReconcileCalls = 0;
  int updateStageCalls = 0;
  int updatePrepareCalls = 0;
  int updateConsumeCalls = 0;
  int updateReconcileCalls = 0;
  api.CloudSyncMessageUpdatePrepareInput? stagedUpdateInput;
  api.CloudSyncMessageUpdateSubmissionInput? preparedUpdateInput;

  @override
  Future<api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    createReconcileCalls++;
    return api.CloudSyncOutboundReconcileResult(
      disposition: api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: input.protectedPayloadReference,
    );
  }

  @override
  Future<api.CloudSyncPreparedMessageCreateResult> prepareMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<api.CloudSyncPreparedMessageCreateInput> inputs,
  }) async {
    createPrepareCalls++;
    return api.CloudSyncPreparedMessageCreateResult(
      handle: _PreparedHandle(),
      handleBindingSha256: _sha('a'),
    );
  }

  @override
  Future<api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({
    required api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  }) async {
    createConsumeCalls++;
    throw StateError('unexpected create consume');
  }

  @override
  Future<api.CloudSyncPrepareMessageUpdateResult> prepareMessageUpdate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required api.CloudSyncMessageUpdatePrepareInput input,
  }) async {
    updateStageCalls++;
    stagedUpdateInput = input;
    return api.CloudSyncPrepareMessageUpdateResult(
      prepared: api.CloudSyncPreparedMessageUpdate(
        protectedReference: _reference('U'),
        leaseReference: _lease('c'),
        payloadSha256: _sha('c'),
        logicalEntityKeyHash: _logicalEntityKeyHash,
        serverRecordIdHash: _serverRecordIdHash,
      ),
    );
  }

  @override
  Future<api.CloudSyncPreparedMessageCreateResult>
  prepareMessageUpdateSubmission({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required api.CloudSyncMessageUpdateSubmissionInput input,
  }) async {
    updatePrepareCalls++;
    preparedUpdateInput = input;
    return api.CloudSyncPreparedMessageCreateResult(
      handle: _PreparedHandle(),
      handleBindingSha256: _sha('a'),
    );
  }

  @override
  Future<api.CloudSyncOutboundConsumeResult> consumePreparedMessageUpdate({
    required api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  }) async {
    updateConsumeCalls++;
    final input = preparedUpdateInput!;
    return api.CloudSyncOutboundConsumeResult(
      outcomes: [
        api.CloudSyncOutboundSaveOutcome(
          localOperationId: input.localOperationId,
          appleOperationUuid: input.appleOperationUuid,
          disposition: api.CloudSyncOutboundSaveDisposition.succeeded,
          serverRecordIdHash: input.serverRecordIdHash,
          etagHash: _token('T'),
        ),
      ],
    );
  }

  @override
  Future<api.CloudSyncMessageUpdateReconcileResult> reconcileMessageUpdate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required api.CloudSyncMessageUpdateSubmissionInput input,
  }) async {
    updateReconcileCalls++;
    throw StateError('unexpected update reconcile');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReadOnlyBindings implements NativeProtectedCloudSyncBindings {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _AuthBinding implements CloudSyncNativeAuthBinding {
  const _AuthBinding({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
  });

  final String accountFingerprint;
  final String protectedStoreIdentity;

  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async => CloudSyncNativeAuthMetadata(
    nativeSessionId: _token('N'),
    accountFingerprint: accountFingerprint,
    protectedStoreIdentity: protectedStoreIdentity,
  );

  @override
  Future<void> ensureReadAuthentication({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async {}

  @override
  Future<void> warmReadAuthentication({
    required Object cloudMessagesClient,
  }) async {}

  @override
  Future<void> warmReadAuthenticationUnderWriterPause({
    required Object cloudMessagesClient,
    required BigInt pauseToken,
  }) async {}
}

final class _PreparedHandle
    implements api.CloudSyncPreparedMessageCreateHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _NoProtector implements CloudSyncProtector {
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async =>
      'test-v1:${base64UrlEncode(utf8.encode('${scope.storageKey}\u001f${kind.name}\u001f$plaintext'))}';

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    final decoded = utf8.decode(
      base64Url.decode(ciphertext.substring('test-v1:'.length)),
    );
    final prefix = '${scope.storageKey}\u001f${kind.name}\u001f';
    if (!decoded.startsWith(prefix)) throw const FormatException();
    return decoded.substring(prefix.length);
  }

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      sha256.convert(utf8.encode(rawAccountIdentifier)).toString();
}

api.MessageInst _mutationWire(CloudSyncLocalMutationKind kind) =>
    api.MessageInst(
      id: _mutationGuid,
      sender: 'mailto:me@example.invalid',
      conversation: api.ConversationData(
        participants: [
          'mailto:me@example.invalid',
          'mailto:peer@example.invalid',
        ],
        senderGuid: 'iMessage;-;peer@example.invalid',
      ),
      message: kind == CloudSyncLocalMutationKind.edit
          ? const api.Message.edit(
              api.EditMessage(
                tuuid: _targetGuid,
                editPart: 0,
                newParts: api.MessageParts(
                  field0: [
                    api.IndexedMessagePart(
                      part_: api.MessagePart.text(
                        'replacement',
                        api.TextFormat.flags(
                          api.TextFlags(
                            bold: false,
                            italic: false,
                            underline: false,
                            strikethrough: false,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const api.Message.unsend(
              api.UnsendMessage(tuuid: _targetGuid, editPart: 0),
            ),
      sentTimestamp: 0,
      sendDelivered: true,
      verificationFailed: false,
    );

CloudOutboxSubmissionIdentity _identity(String operationId) =>
    CloudOutboxSubmissionIdentity(
      requestUuid: _requestUuid,
      operationUuids: {operationId: _operationUuid},
    );

Matcher _cloudFailure(String safeCode) => isA<CloudSyncFailure>().having(
  (failure) => failure.safeCode,
  'safeCode',
  safeCode,
);

DateTime _time(int seconds) => DateTime.utc(2026, 9, 12, 12, 0, seconds);
String _token(String character) => List.filled(43, character).join();
String _sha(String character) => List.filled(64, character).join();
String _reference(String character) => 'obcs2.ref.${_token(character)}';
String _lease(String character) =>
    'obcs2.lease.${List.filled(32, character).join()}';

final String _storeIdentity = 'obcs2.store.${_token('S')}';
final String _logicalEntityKeyHash = _token('L');
final String _serverRecordIdHash = _token('R');
final String _etagHash = _token('E');
