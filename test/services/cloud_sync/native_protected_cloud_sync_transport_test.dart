import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_transport.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeBindings bindings;
  late NativeProtectedCloudSyncTransport transport;
  late CloudSyncScope scope;

  setUp(() {
    bindings = _FakeBindings();
    transport = NativeProtectedCloudSyncTransport(
      cloudMessagesClient: Object(),
      storageDirectory: 'private-storage',
      protectedStoreIdentity: _storeIdentity,
      bindings: bindings,
    );
    scope = CloudSyncScope(
      accountFingerprint: _hash('A'),
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'messageManateeZone',
      streamKind: CloudSyncStreamKind.messages,
      schemaVersion: 2,
    );
  });

  test(
    'maps only native hashes and protected references into one batch',
    () async {
      bindings.fetchResult = NativeProtectedFetchResult(
        page: NativeProtectedPage(
          changes: [
            NativeProtectedChange(
              changeId: _hash('C'),
              recordIdHash: _hash('R'),
              etagHash: _hash('E'),
              kind: NativeProtectedChangeKind.save,
              payloadSha256: _sha('a'),
              payloadLength: 4,
              protectedRecordIdentityReference: _reference('I'),
              protectedRawEnvelopeReference: _reference('P'),
              serverModifiedAtMillis: 1234,
              isTombstone: false,
            ),
          ],
          batchId: _hash('B'),
          generation: 7,
          pageLeaseReference: _lease('1'),
          protectedNextCheckpointReference: _reference('N'),
          complete: false,
          admittedRawBytes: 512,
        ),
      );

      final batch = await transport.fetchChanges(
        scope,
        previousToken: _reference('O'),
        generation: 7,
        limit: 500,
      );

      expect(bindings.maximumChanges, 200);
      expect(bindings.expectedAccountFingerprint, _hash('A'));
      expect(bindings.previousCheckpointReference, _reference('O'));
      expect(batch.batchId, _hash('B'));
      expect(batch.nextToken, _reference('N'));
      expect(batch.protectedPageLeaseReference, _lease('1'));
      expect(batch.hasMore, isTrue);
      final change = batch.changes.single;
      expect(change.changeId, _hash('C'));
      expect(change.recordIdHash, _hash('R'));
      expect(change.encryptedServerRecordId, _reference('I'));
      expect(change.encryptedPayloadReference, _reference('P'));
      expect(change.protectedSystemFieldsReference, isNull);
      expect(
        change.serverModifiedAt,
        DateTime.fromMillisecondsSinceEpoch(1234, isUtc: true),
      );
      expect(change.preflightFailure, isNull);
    },
  );

  test(
    'accepts the expanded protected-zone allowlist without remapping',
    () async {
      bindings.fetchResult = _validEmptyFetchResult();
      final cases = <(String zone, String stream)>[
        ('chatManateeZone', 'chats'),
        ('messageManateeZone', 'messages'),
        ('attachmentManateeZone', 'attachments'),
        ('messageUpdateZone', 'messageUpdateZone'),
        ('recoverableMessageDeleteZone', 'recoverableMessageDeleteZone'),
        ('scheduledMessageZone', 'scheduledMessageZone'),
        ('chat1ManateeZone', 'chat1ManateeZone'),
      ];

      for (final (zone, stream) in cases) {
        final batch = await transport.fetchChanges(
          CloudSyncScope(
            accountFingerprint: _hash('A'),
            container: 'com.apple.messages.cloud',
            database: 'private',
            zone: zone,
            streamKind: CloudSyncStreamKind.messages,
            schemaVersion: 2,
          ),
          previousToken: null,
          generation: 1,
          limit: 1,
        );
        expect(batch.changes, isEmpty);
        expect(bindings.stream, stream);
      }
    },
  );

  test(
    'quarantined tombstone preserves delete shape without raw material',
    () async {
      bindings.fetchResult = NativeProtectedFetchResult(
        page: NativeProtectedPage(
          changes: [
            NativeProtectedChange(
              changeId: _hash('C'),
              recordIdHash: _hash('R'),
              kind: NativeProtectedChangeKind.quarantined,
              payloadSha256: _sha('b'),
              payloadLength: 9 * 1024 * 1024,
              protectedRecordIdentityReference: _reference('I'),
              protectedRawEnvelopeReference: _reference('P'),
              preflightCode: NativeProtectedPreflightCode.oversizedRecord,
              isTombstone: true,
            ),
          ],
          batchId: _hash('B'),
          generation: 1,
          pageLeaseReference: _lease('2'),
          complete: true,
          admittedRawBytes: 9 * 1024 * 1024,
        ),
      );

      final batch = await transport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 20,
      );

      final change = batch.changes.single;
      expect(change.type, CloudChangeType.delete);
      expect(change.isTombstone, isTrue);
      expect(change.preflightFailure, CloudFailureCategory.malformedRecord);
      expect(change.preflightCode, CloudPreflightCode.oversizedRecord);
    },
  );

  test('preserves every content-free native preflight reason', () async {
    const cases =
        <(NativeProtectedPreflightCode native, CloudPreflightCode expected)>[
          (
            NativeProtectedPreflightCode.unsupportedRecordType,
            CloudPreflightCode.unsupportedRecordType,
          ),
          (
            NativeProtectedPreflightCode.malformedMetadata,
            CloudPreflightCode.malformedMetadata,
          ),
          (
            NativeProtectedPreflightCode.oversizedRecord,
            CloudPreflightCode.oversizedRecord,
          ),
          (
            NativeProtectedPreflightCode.invalidChangeShape,
            CloudPreflightCode.invalidChangeShape,
          ),
        ];

    for (final (native, expected) in cases) {
      bindings.fetchResult = NativeProtectedFetchResult(
        page: NativeProtectedPage(
          changes: [
            NativeProtectedChange(
              changeId: _hash('C'),
              recordIdHash: _hash('R'),
              kind: NativeProtectedChangeKind.quarantined,
              payloadSha256: _sha('b'),
              payloadLength: 1,
              protectedRecordIdentityReference: _reference('I'),
              protectedRawEnvelopeReference: _reference('P'),
              preflightCode: native,
              isTombstone: false,
            ),
          ],
          batchId: _hash('B'),
          generation: 1,
          pageLeaseReference: _lease('3'),
          complete: true,
          admittedRawBytes: 1,
        ),
      );

      final change = (await transport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 20,
      )).changes.single;
      expect(change.preflightFailure, CloudFailureCategory.malformedRecord);
      expect(change.preflightCode, expected);
    }
  });

  test('typed native retry survives without server text', () async {
    bindings.fetchResult = const NativeProtectedFetchResult(
      failure: NativeProtectedFailure(
        category: NativeProtectedFailureCategory.throttled,
        safeCode: 'http_throttled',
        retryAfterSeconds: 91,
      ),
    );

    await expectLater(
      transport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 20,
      ),
      throwsA(
        isA<CloudSyncFailure>()
            .having((failure) => failure.safeCode, 'safeCode', 'http_throttled')
            .having(
              (failure) => failure.retryAfter,
              'retryAfter',
              const Duration(seconds: 91),
            ),
      ),
    );
  });

  test('malformed native capability fails closed before journaling', () async {
    bindings.fetchResult = NativeProtectedFetchResult(
      page: NativeProtectedPage(
        changes: [
          NativeProtectedChange(
            changeId: _hash('C'),
            recordIdHash: _hash('R'),
            kind: NativeProtectedChangeKind.save,
            payloadSha256: _sha('a'),
            payloadLength: 1,
            protectedRecordIdentityReference: 'raw/server/identifier',
            protectedRawEnvelopeReference: _reference('P'),
            isTombstone: false,
          ),
        ],
        batchId: _hash('B'),
        generation: 1,
        pageLeaseReference: _lease('3'),
        complete: true,
        admittedRawBytes: 1,
      ),
    );

    await expectLater(
      transport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 20,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'invalid_protected_change',
        ),
      ),
    );
  });

  test('lease recovery accepts only exact adopted subsets', () async {
    final leaseA = _lease('a');
    final leaseB = _lease('b');
    bindings.recoveryResult = NativeProtectedRecoveryResult(
      recovery: NativeProtectedRecovery(
        finalizedAdoptedLeaseReferences: [leaseA],
        absentAdoptedLeaseReferences: [leaseB],
        rolledBackCount: 0,
        removedTemporaryFilesCount: 0,
        hasMore: false,
      ),
    );

    final recovery = await transport.recoverProtectedPageLeases(
      {leaseB, leaseA},
      CloudProtectedReferenceSnapshot(
        references: {_reference('B'), _reference('A')},
        isComplete: true,
      ),
    );

    expect(bindings.adoptedLeaseReferences, [leaseA, leaseB]);
    expect(bindings.liveReferences, [_reference('A'), _reference('B')]);
    expect(bindings.liveReferenceEnumerationComplete, isTrue);
    expect(recovery.finalizedAdoptedLeaseReferences, {leaseA});
    expect(recovery.absentAdoptedLeaseReferences, {leaseB});
  });

  test('lease methods reject non-opaque values before native access', () async {
    await expectLater(
      transport.commitProtectedPageLease('C:/raw/protected/path', const {}),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'invalid_lease_reference',
        ),
      ),
    );
    expect(bindings.commitCalls, 0);
  });

  test('commit passes an exact sorted retained subset to native', () async {
    await transport.commitProtectedPageLease(_lease('a'), {
      _reference('C'),
      _reference('A'),
    });

    expect(bindings.committedLeaseReference, _lease('a'));
    expect(bindings.retainedReferences, [_reference('A'), _reference('C')]);
  });

  test(
    'incomplete reference enumeration fails closed before native recovery and GC',
    () async {
      final incomplete = CloudProtectedReferenceSnapshot(
        references: {_reference('A')},
        isComplete: false,
      );

      await expectLater(
        transport.recoverProtectedPageLeases({_lease('a')}, incomplete),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'protected_reference_enumeration_incomplete',
          ),
        ),
      );
      await expectLater(
        transport.collectProtectedGarbage(incomplete),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(bindings.recoveryCalls, 0);
      expect(bindings.garbageCollectionCalls, 0);
    },
  );

  test(
    'bounded garbage collection result maps without exposing capabilities',
    () async {
      bindings.garbageCollectionResult =
          const NativeProtectedGarbageCollectionResult(
            collection: NativeProtectedGarbageCollection(
              scannedCount: 64,
              firstObservedCount: 20,
              deletedCount: 10,
              preservedLiveCount: 30,
              preservedActiveLeaseCount: 4,
              hasMore: true,
            ),
          );

      final result = await transport.collectProtectedGarbage(
        CloudProtectedReferenceSnapshot(
          references: {_reference('B'), _reference('A')},
          isComplete: true,
        ),
      );

      expect(bindings.garbageCollectionLiveReferences, [
        _reference('A'),
        _reference('B'),
      ]);
      expect(result.scannedCount, 64);
      expect(result.deletedCount, 10);
      expect(result.hasMore, isTrue);
    },
  );

  test(
    'same store identity serializes every native operation across wrappers',
    () async {
      bindings.fetchResult = _validEmptyFetchResult();
      bindings.recoveryResult = const NativeProtectedRecoveryResult(
        recovery: NativeProtectedRecovery(
          finalizedAdoptedLeaseReferences: [],
          absentAdoptedLeaseReferences: [],
          rolledBackCount: 0,
          removedTemporaryFilesCount: 0,
          hasMore: false,
        ),
      );
      final secondTransport = NativeProtectedCloudSyncTransport(
        cloudMessagesClient: Object(),
        storageDirectory: 'same-private-storage',
        protectedStoreIdentity: _storeIdentity,
        bindings: bindings,
      );
      final entered = <String>[];
      final releases = <String, Completer<void>>{};
      bindings.beforeOperation = (operation) {
        entered.add(operation);
        final release = Completer<void>();
        releases[operation] = release;
        return release.future;
      };

      final operations = <Future<Object?>>[
        transport
            .fetchChanges(scope, previousToken: null, generation: 1, limit: 1)
            .then<Object?>((_) => null),
        secondTransport
            .recoverProtectedPageLeases(
              const {},
              CloudProtectedReferenceSnapshot(references: {}, isComplete: true),
            )
            .then<Object?>((_) => null),
        transport
            .commitProtectedPageLease(_lease('1'), const {})
            .then<Object?>((_) => null),
        secondTransport
            .acknowledgeCommittedPageLease(_lease('2'))
            .then<Object?>((_) => null),
        transport
            .rollbackProtectedPageLease(_lease('3'))
            .then<Object?>((_) => null),
        secondTransport
            .retireProtectedReferences({_reference('R')})
            .then<Object?>((_) => null),
        transport
            .collectProtectedGarbage(
              CloudProtectedReferenceSnapshot(references: {}, isComplete: true),
            )
            .then<Object?>((_) => null),
      ];

      const expectedOrder = [
        'fetch',
        'recover',
        'commit',
        'acknowledge',
        'rollback',
        'retire',
        'garbageCollection',
      ];
      await _waitFor(() => entered.isNotEmpty);
      expect(entered, ['fetch']);
      for (var index = 0; index < expectedOrder.length; index++) {
        final operation = expectedOrder[index];
        releases[operation]!.complete();
        if (index + 1 < expectedOrder.length) {
          await _waitFor(() => entered.length == index + 2);
          expect(entered, expectedOrder.take(index + 2));
        }
      }
      await Future.wait(operations);
      expect(entered, expectedOrder);
    },
  );

  test('same identity nesting is reentrant and cannot deadlock', () async {
    bindings.fetchResult = _validEmptyFetchResult();
    final entered = <String>[];
    bindings.beforeOperation = (operation) async {
      entered.add(operation);
      if (operation == 'fetch') {
        await transport.acknowledgeCommittedPageLease(_lease('a'));
      }
    };

    await transport
        .runProtectedStoreExclusive(
          () => transport.fetchChanges(
            scope,
            previousToken: null,
            generation: 1,
            limit: 1,
          ),
        )
        .timeout(const Duration(seconds: 1));

    expect(entered, ['fetch', 'acknowledge']);
  });

  test(
    'recovery and GC cannot enter the fetch-to-commit crash window',
    () async {
      bindings.fetchResult = _validEmptyFetchResult();
      bindings.recoveryResult = const NativeProtectedRecoveryResult(
        recovery: NativeProtectedRecovery(
          finalizedAdoptedLeaseReferences: [],
          absentAdoptedLeaseReferences: [],
          rolledBackCount: 0,
          removedTemporaryFilesCount: 0,
          hasMore: false,
        ),
      );
      final entered = <String>[];
      bindings.beforeOperation = (operation) async {
        entered.add(operation);
      };
      final fetched = Completer<void>();
      final allowCommit = Completer<void>();
      final lifecycle = transport.runProtectedStoreExclusive(() async {
        await transport.fetchChanges(
          scope,
          previousToken: null,
          generation: 1,
          limit: 1,
        );
        fetched.complete();
        await allowCommit.future;
        await transport.commitProtectedPageLease(_lease('f'), const {});
      });
      await fetched.future;

      final recovery = transport.recoverProtectedPageLeases(
        const {},
        CloudProtectedReferenceSnapshot(references: const {}, isComplete: true),
      );
      final garbageCollection = transport.collectProtectedGarbage(
        CloudProtectedReferenceSnapshot(references: const {}, isComplete: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(entered, ['fetch']);

      allowCommit.complete();
      await Future.wait([lifecycle, recovery, garbageCollection]);
      expect(entered, ['fetch', 'commit', 'recover', 'garbageCollection']);
    },
  );

  test(
    'different protected store identities do not block each other',
    () async {
      final bindingsA = _FakeBindings()..fetchResult = _validEmptyFetchResult();
      final bindingsB = _FakeBindings()..fetchResult = _validEmptyFetchResult();
      final entered = <String>[];
      final release = Completer<void>();
      bindingsA.beforeOperation = (operation) async {
        entered.add('A:$operation');
        await release.future;
      };
      bindingsB.beforeOperation = (operation) async {
        entered.add('B:$operation');
        await release.future;
      };
      final transportA = NativeProtectedCloudSyncTransport(
        cloudMessagesClient: Object(),
        storageDirectory: 'private-storage-a',
        protectedStoreIdentity: 'obcs2.store.${_hash('A')}',
        bindings: bindingsA,
      );
      final transportB = NativeProtectedCloudSyncTransport(
        cloudMessagesClient: Object(),
        storageDirectory: 'private-storage-b',
        protectedStoreIdentity: 'obcs2.store.${_hash('B')}',
        bindings: bindingsB,
      );

      final fetchA = transportA.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 1,
      );
      final fetchB = transportB.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 1,
      );
      await _waitFor(() => entered.length == 2);
      expect(entered.toSet(), {'A:fetch', 'B:fetch'});
      release.complete();
      await Future.wait([fetchA, fetchB]);
    },
  );

  test('same identity queue is bounded and fails closed', () async {
    final release = Completer<void>();
    bindings.beforeOperation = (_) => release.future;
    final accepted = List<Future<void>>.generate(
      64,
      (_) => transport.acknowledgeCommittedPageLease(_lease('a')),
    );
    final overflow = transport.acknowledgeCommittedPageLease(_lease('b'));

    await expectLater(
      overflow,
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'protected_store_operation_queue_bound_exceeded',
        ),
      ),
    );
    release.complete();
    await Future.wait(accepted);
  });

  test(
    'quiesce joins the original native future after Dart timeout detaches',
    () async {
      bindings.fetchResult = _validEmptyFetchResult();
      final nativeRelease = Completer<void>();
      bindings.beforeOperation = (operation) async {
        if (operation == 'fetch') await nativeRelease.future;
      };

      final detached = transport
          .fetchChanges(scope, previousToken: null, generation: 1, limit: 1)
          .timeout(const Duration(milliseconds: 5));
      await expectLater(detached, throwsA(isA<TimeoutException>()));

      var quiesced = false;
      final quiescence = transport.quiesceNativeOperations().then((_) {
        quiesced = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(quiesced, isFalse);
      await expectLater(
        transport.rollbackProtectedPageLease(_lease('a')),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'protected_store_operation_admission_closed',
          ),
        ),
      );

      nativeRelease.complete();
      await quiescence;
      expect(quiesced, isTrue);
    },
  );

  test('protected writer forwards one exact prepared create binding', () async {
    final operation = _writeOperation(scope);
    final protectedOperation = _protectedWriteOperation(operation);
    final identity = _submissionIdentity(operation.operationId);
    bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
      handle: _FakePreparedHandle(),
    );

    final prepared = await transport.prepareSubmission(
      scope,
      submissionIdentity: identity,
      operations: [protectedOperation],
    );

    expect(prepared.operationIds, [operation.operationId]);
    expect(bindings.preparedRequestUuid, identity.requestUuid);
    final input = bindings.preparedInputs.single;
    expect(input.localOperationId, operation.operationId);
    expect(input.logicalEntityKeyHash, operation.logicalEntityKeyHash);
    expect(input.protectedLeaseReference, operation.protectedLeaseReference);
    expect(
      input.protectedPayloadReference,
      operation.encryptedPayloadReference,
    );
    expect(
      input.protectedServerRecordReference,
      operation.encryptedPayloadReference,
    );
    expect(input.payloadSha256, operation.payloadSha256);
    expect(input.serverRecordIdHash, operation.serverRecordIdHash);
    expect(
      input.appleOperationUuid,
      identity.operationUuids[operation.operationId],
    );
  });

  test(
    'protected writer rejects a well-formed but wrong operation identity',
    () async {
      final operation = _writeOperation(scope);
      final wrongOperationId = 'op1:${_sha('f')}';
      final protectedOperation = CloudSyncProtectedWriteOperation(
        operationId: wrongOperationId,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        action: operation.action,
        protectedLeaseReference: operation.protectedLeaseReference,
        protectedServerRecordIdReference: operation.encryptedPayloadReference!,
        serverRecordIdHash: operation.serverRecordIdHash!,
        protectedPayloadReference: operation.encryptedPayloadReference,
        payloadSha256: operation.payloadSha256,
      );

      await expectLater(
        transport.prepareSubmission(
          scope,
          submissionIdentity: _submissionIdentity(wrongOperationId),
          operations: [protectedOperation],
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_outbound_create_only',
          ),
        ),
      );
      expect(bindings.preparedInputs, isEmpty);
    },
  );

  test('protected writer rejects every non-message outbound zone', () async {
    final wrongScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'chatManateeZone',
      streamKind: scope.streamKind,
      schemaVersion: scope.schemaVersion,
    );
    final operation = _writeOperation(wrongScope);

    await expectLater(
      transport.prepareSubmission(
        wrongScope,
        submissionIdentity: _submissionIdentity(operation.operationId),
        operations: [_protectedWriteOperation(operation)],
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'unsupported_protected_outbound_scope',
        ),
      ),
    );
    expect(bindings.preparedInputs, isEmpty);
  });

  test(
    'protected writer is single-use and bounds native retry-after',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition:
                frb_api.CloudSyncOutboundSaveDisposition.unknownOutcome,
            retryAfterSeconds: BigInt.parse('18446744073709551615'),
          ),
        ],
      );
      final prepared = await transport.prepareSubmission(
        scope,
        submissionIdentity: identity,
        operations: [protectedOperation],
      );

      final result = await transport.consumePreparedSubmission(
        scope,
        preparedSubmission: prepared,
        persistedIdentity: identity,
        protectedOperations: [protectedOperation],
        operations: [operation],
      );

      expect(
        result.outcomes.values.single.disposition,
        CloudPushDisposition.unknownOutcome,
      );
      expect(result.outcomes.values.single.retryAfter, const Duration(days: 7));
      expect(bindings.consumeCalls, 1);
      await expectLater(
        transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        ),
        throwsStateError,
      );
      expect(bindings.consumeCalls, 1);
    },
  );

  test('reconciles committed only with the exact protected proof', () async {
    final operation = _unknownOutcomeOperation(scope);
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
      protectedProofReference: operation.encryptedPayloadReference,
    );

    final resolution = await transport.reconcileUnknownOutcome(
      scope,
      operation: operation,
    );

    expect(resolution.disposition, CloudUnknownOutcomeDisposition.committed);
    expect(resolution.failureCategory, isNull);
    expect(resolution.retryAfter, isNull);
    expect(resolution.proof, isNotNull);
    expect(resolution.proof!.binds(operation), isTrue);
    expect(
      resolution.proof!.protectedProofReference,
      operation.encryptedPayloadReference,
    );
    _expectReconcileCall(bindings, operation, scope);
  });

  test(
    'reconciles explicit notApplied only with the exact protected proof',
    () async {
      final operation = _unknownOutcomeOperation(scope);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: operation.encryptedPayloadReference,
      );

      final resolution = await transport.reconcileUnknownOutcome(
        scope,
        operation: operation,
      );

      expect(resolution.disposition, CloudUnknownOutcomeDisposition.notApplied);
      expect(resolution.failureCategory, isNull);
      expect(resolution.retryAfter, isNull);
      expect(resolution.proof, isNotNull);
      expect(resolution.proof!.binds(operation), isTrue);
      expect(
        resolution.proof!.protectedProofReference,
        operation.encryptedPayloadReference,
      );
      _expectReconcileCall(bindings, operation, scope);
    },
  );

  test('maps diverged reconciliation to a quarantined conflict', () async {
    final operation = _unknownOutcomeOperation(scope);
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.diverged,
      protectedProofReference: operation.encryptedPayloadReference,
      failureClass: frb_api.CloudSyncOutboundFailureClass.conflict,
    );

    final resolution = await transport.reconcileUnknownOutcome(
      scope,
      operation: operation,
    );

    expect(resolution.disposition, CloudUnknownOutcomeDisposition.quarantined);
    expect(resolution.failureCategory, CloudFailureCategory.conflict);
    expect(resolution.proof, isNull);
    expect(resolution.retryAfter, isNull);
    _expectReconcileCall(bindings, operation, scope);
  });

  test(
    'maps unresolved retry class and caps retry-after at seven days',
    () async {
      final operation = _unknownOutcomeOperation(scope);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved,
        failureClass: frb_api.CloudSyncOutboundFailureClass.transientServer,
        retryAfterSeconds: BigInt.parse('18446744073709551615'),
      );

      final resolution = await transport.reconcileUnknownOutcome(
        scope,
        operation: operation,
      );

      expect(resolution.disposition, CloudUnknownOutcomeDisposition.unresolved);
      expect(resolution.failureCategory, CloudFailureCategory.server);
      expect(resolution.retryAfter, const Duration(days: 7));
      expect(resolution.proof, isNull);
      _expectReconcileCall(bindings, operation, scope);
    },
  );

  test('malformed or swapped proof references fail closed', () async {
    final operation = _unknownOutcomeOperation(scope);
    for (final proofReference in <String>[
      'raw/proof-reference',
      _reference('Q'),
    ]) {
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: proofReference,
      );

      await expectLater(
        transport.reconcileUnknownOutcome(scope, operation: operation),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_outbound_reconcile_envelope_invalid',
          ),
        ),
      );
    }
    expect(bindings.reconcileCalls, 2);
  });

  test(
    'malformed, cross-scope, non-unknown, and delete operations never reach native',
    () async {
      final otherScope = CloudSyncScope(
        accountFingerprint: _hash('Z'),
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind,
        schemaVersion: scope.schemaVersion,
      );
      final invalidOperations = <CloudOutboxOperation>[
        _unknownOutcomeOperation(
          scope,
          payloadReference: 'raw/payload-reference',
        ),
        _unknownOutcomeOperation(otherScope),
        _unknownOutcomeOperation(scope, status: CloudOutboxStatus.pending),
        _unknownOutcomeOperation(scope, action: CloudOutboxAction.delete),
        _unknownOutcomeOperation(scope, operationId: 'op1:${_sha('f')}'),
      ];

      for (final operation in invalidOperations) {
        await expectLater(
          transport.reconcileUnknownOutcome(scope, operation: operation),
          throwsA(
            isA<CloudSyncFailure>().having(
              (failure) => failure.safeCode,
              'safeCode',
              'cloud_sync_outbound_reconcile_operation_invalid',
            ),
          ),
        );
      }
      expect(bindings.reconcileCalls, 0);
    },
  );

  test(
    'terminal receipt acknowledgement validates scope and correlation',
    () async {
      final operation = _writeOperation(scope);
      await transport.acknowledgeDurableTerminalOperations(
        scope,
        operations: [operation],
        transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
      );
      expect(bindings.acknowledgedLeases, [operation.protectedLeaseReference]);

      final otherScope = CloudSyncScope(
        accountFingerprint: _hash('Z'),
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind,
        schemaVersion: scope.schemaVersion,
      );
      await expectLater(
        transport.acknowledgeDurableTerminalOperations(
          otherScope,
          operations: [operation],
          transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_outbound_receipt_scope_invalid',
          ),
        ),
      );
      expect(bindings.acknowledgedLeases, [operation.protectedLeaseReference]);
    },
  );

  test(
    'outbound stage rejects independently swapped protected references',
    () async {
      bindings.stageResult = frb_api.CloudSyncProtectedOutboundStageResult(
        stage: frb_api.CloudSyncProtectedOutboundStage(
          logicalEntityKeyHash: _hash('L'),
          protectedPayloadReference: _reference('P'),
          payloadSha256: _sha('a'),
          payloadLength: BigInt.one,
          protectedServerRecordReference: _reference('Q'),
          serverRecordIdHash: _hash('S'),
          leaseReference: _lease('a'),
        ),
      );

      await expectLater(
        transport.stageOutboundMessage(scope, message: _FakeCloudMessage()),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_outbound_stage_invalid',
          ),
        ),
      );
    },
  );

  test('legacy write-side CloudKit method remains unavailable', () {
    expect(
      () => transport.pushOperations(scope, operations: const []),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_sync_protected_read_only',
        ),
      ),
    );
  });
}

CloudOutboxOperation _writeOperation(CloudSyncScope scope) {
  final logicalEntityKeyHash = _hash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: logicalEntityKeyHash,
      payloadVersion: 1,
    ),
    logicalEntityKeyHash: logicalEntityKeyHash,
    action: CloudOutboxAction.save,
    payloadVersion: 1,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: _reference('P'),
    payloadSha256: _sha('b'),
    serverRecordIdHash: _hash('S'),
    protectedLeaseReference: _lease('a'),
    dependencyOperationIds: const {},
    createdAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
  );
}

CloudOutboxOperation _unknownOutcomeOperation(
  CloudSyncScope scope, {
  CloudOutboxStatus status = CloudOutboxStatus.unknownOutcome,
  CloudOutboxAction action = CloudOutboxAction.save,
  String? payloadReference,
  String? operationId,
}) {
  final protectedPayloadReference = payloadReference ?? _reference('P');
  final logicalEntityKeyHash = _hash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId:
        operationId ??
        CloudOperationIdentity.forInitialCreate(
          scope: scope,
          logicalEntityKeyHash: logicalEntityKeyHash,
          payloadVersion: 1,
        ),
    logicalEntityKeyHash: logicalEntityKeyHash,
    action: action,
    payloadVersion: 1,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: protectedPayloadReference,
    payloadSha256: _sha('b'),
    serverRecordIdHash: _hash('S'),
    protectedLeaseReference: _lease('a'),
    appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
    dependencyOperationIds: const {},
    createdAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
    status: status,
    attemptCount: 1,
  );
}

void _expectReconcileCall(
  _FakeBindings bindings,
  CloudOutboxOperation operation,
  CloudSyncScope scope,
) {
  expect(bindings.reconcileCalls, 1);
  expect(bindings.reconcileCloudMessagesClient, isNotNull);
  expect(bindings.reconcileStorageDirectory, 'private-storage');
  expect(
    bindings.reconcileExpectedAccountFingerprint,
    scope.accountFingerprint,
  );
  expect(bindings.reconcileExpectedProtectedStoreIdentity, _storeIdentity);
  expect(bindings.reconcileRequestUuid, operation.appleRequestUuid);
  final input = bindings.reconcileInput!;
  expect(input.localOperationId, operation.operationId);
  expect(input.logicalEntityKeyHash, operation.logicalEntityKeyHash);
  expect(input.protectedLeaseReference, operation.protectedLeaseReference);
  expect(input.protectedPayloadReference, operation.encryptedPayloadReference);
  expect(input.payloadSha256, operation.payloadSha256);
  expect(
    input.protectedServerRecordReference,
    operation.encryptedPayloadReference,
  );
  expect(input.serverRecordIdHash, operation.serverRecordIdHash);
  expect(input.appleOperationUuid, operation.appleOperationUuid);
}

CloudSyncProtectedWriteOperation _protectedWriteOperation(
  CloudOutboxOperation operation,
) {
  return CloudSyncProtectedWriteOperation(
    operationId: operation.operationId,
    logicalEntityKeyHash: operation.logicalEntityKeyHash,
    action: operation.action,
    protectedLeaseReference: operation.protectedLeaseReference,
    protectedServerRecordIdReference: operation.encryptedPayloadReference!,
    serverRecordIdHash: operation.serverRecordIdHash!,
    protectedPayloadReference: operation.encryptedPayloadReference,
    payloadSha256: operation.payloadSha256,
  );
}

CloudOutboxSubmissionIdentity _submissionIdentity(String operationId) {
  return CloudOutboxSubmissionIdentity(
    requestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    operationUuids: {operationId: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001'},
  );
}

String _repeat(String character, int count) =>
    List<String>.filled(count, character).join();
String _hash(String character) => _repeat(character, 43);
String _sha(String character) => _repeat(character, 64);
String _reference(String character) => 'obcs2.ref.${_hash(character)}';
String _lease(String character) => 'obcs2.lease.${_repeat(character, 32)}';
final String _storeIdentity = 'obcs2.store.${_hash('S')}';

NativeProtectedFetchResult _validEmptyFetchResult() =>
    NativeProtectedFetchResult(
      page: NativeProtectedPage(
        changes: const [],
        batchId: _hash('B'),
        generation: 1,
        pageLeaseReference: _lease('f'),
        complete: true,
        admittedRawBytes: 0,
      ),
    );

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('condition_not_reached');
}

final class _FakeBindings
    implements
        NativeProtectedCloudSyncBindings,
        NativeProtectedCloudSyncWriteBindings {
  NativeProtectedFetchResult fetchResult = const NativeProtectedFetchResult();
  NativeProtectedRecoveryResult recoveryResult =
      const NativeProtectedRecoveryResult();
  NativeProtectedGarbageCollectionResult garbageCollectionResult =
      const NativeProtectedGarbageCollectionResult(
        collection: NativeProtectedGarbageCollection(
          scannedCount: 0,
          firstObservedCount: 0,
          deletedCount: 0,
          preservedLiveCount: 0,
          preservedActiveLeaseCount: 0,
          hasMore: false,
        ),
      );
  frb_api.CloudSyncProtectedOutboundStageResult stageResult =
      const frb_api.CloudSyncProtectedOutboundStageResult(
        failure: frb_api.CloudSyncOutboundSafeCode.invalidRequest,
      );
  frb_api.CloudSyncPreparedMessageCreateResult prepareResult =
      const frb_api.CloudSyncPreparedMessageCreateResult(
        failure: frb_api.CloudSyncOutboundSafeCode.invalidRequest,
      );
  frb_api.CloudSyncOutboundConsumeResult consumeResult =
      const frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [],
        failure: frb_api.CloudSyncOutboundSafeCode.invalidRequest,
      );
  frb_api.CloudSyncOutboundReconcileResult reconcileResult =
      const frb_api.CloudSyncOutboundReconcileResult(
        failure: frb_api.CloudSyncOutboundSafeCode.invalidRequest,
      );
  String? expectedAccountFingerprint;
  String? stream;
  String? previousCheckpointReference;
  int? maximumChanges;
  List<String>? adoptedLeaseReferences;
  List<String>? liveReferences;
  bool? liveReferenceEnumerationComplete;
  String? committedLeaseReference;
  List<String>? retainedReferences;
  List<String>? garbageCollectionLiveReferences;
  int commitCalls = 0;
  int recoveryCalls = 0;
  int garbageCollectionCalls = 0;
  int consumeCalls = 0;
  int reconcileCalls = 0;
  String? preparedRequestUuid;
  List<frb_api.CloudSyncPreparedMessageCreateInput> preparedInputs = const [];
  Object? reconcileCloudMessagesClient;
  String? reconcileStorageDirectory;
  String? reconcileExpectedAccountFingerprint;
  String? reconcileExpectedProtectedStoreIdentity;
  String? reconcileRequestUuid;
  frb_api.CloudSyncPreparedMessageCreateInput? reconcileInput;
  final List<String> acknowledgedLeases = [];
  Future<void> Function(String operation)? beforeOperation;

  Future<void> _before(String operation) async {
    await beforeOperation?.call(operation);
  }

  @override
  Future<NativeProtectedFetchResult> fetchProtectedPage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String stream,
    required int generation,
    required String? previousCheckpointReference,
    required int maximumChanges,
  }) async {
    await _before('fetch');
    this.expectedAccountFingerprint = expectedAccountFingerprint;
    this.stream = stream;
    this.previousCheckpointReference = previousCheckpointReference;
    this.maximumChanges = maximumChanges;
    return fetchResult;
  }

  @override
  Future<NativeProtectedLeaseResult> commitProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
    required List<String> retainedReferences,
  }) async {
    await _before('commit');
    commitCalls++;
    committedLeaseReference = leaseReference;
    this.retainedReferences = [...retainedReferences];
    return const NativeProtectedLeaseResult();
  }

  @override
  Future<NativeProtectedLeaseResult> acknowledgeCommittedPageLease({
    required String storageDirectory,
    required String leaseReference,
  }) async {
    await _before('acknowledge');
    acknowledgedLeases.add(leaseReference);
    return const NativeProtectedLeaseResult();
  }

  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundMessage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudMessage message,
  }) async {
    await _before('stageOutbound');
    return stageResult;
  }

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) async {
    await _before('prepareOutbound');
    preparedRequestUuid = requestUuid;
    preparedInputs = [...inputs];
    return prepareResult;
  }

  @override
  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
  }) async {
    await _before('consumeOutbound');
    consumeCalls++;
    return consumeResult;
  }

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    await _before('reconcileOutbound');
    reconcileCalls++;
    reconcileCloudMessagesClient = cloudMessagesClient;
    reconcileStorageDirectory = storageDirectory;
    reconcileExpectedAccountFingerprint = expectedAccountFingerprint;
    reconcileExpectedProtectedStoreIdentity = expectedProtectedStoreIdentity;
    reconcileRequestUuid = requestUuid;
    reconcileInput = input;
    return reconcileResult;
  }

  @override
  Future<NativeProtectedGarbageCollectionResult> collectProtectedGarbage({
    required String storageDirectory,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) async {
    await _before('garbageCollection');
    garbageCollectionCalls++;
    garbageCollectionLiveReferences = [...liveReferences];
    this.liveReferenceEnumerationComplete = liveReferenceEnumerationComplete;
    return garbageCollectionResult;
  }

  @override
  Future<NativeProtectedRecoveryResult> recoverProtectedPageLeases({
    required String storageDirectory,
    required List<String> adoptedLeaseReferences,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) async {
    await _before('recover');
    recoveryCalls++;
    this.adoptedLeaseReferences = [...adoptedLeaseReferences];
    this.liveReferences = [...liveReferences];
    this.liveReferenceEnumerationComplete = liveReferenceEnumerationComplete;
    return recoveryResult;
  }

  @override
  Future<NativeProtectedRetirementResult> retireProtectedReferences({
    required String storageDirectory,
    required List<String> references,
  }) async {
    await _before('retire');
    return NativeProtectedRetirementResult(retiredCount: references.length);
  }

  @override
  Future<NativeProtectedLeaseResult> rollbackProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
  }) async {
    await _before('rollback');
    return const NativeProtectedLeaseResult();
  }
}

final class _FakePreparedHandle
    implements frb_api.CloudSyncPreparedMessageCreateHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeCloudMessage implements frb_api.CloudMessage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
