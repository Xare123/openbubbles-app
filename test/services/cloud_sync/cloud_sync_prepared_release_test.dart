import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

// Focused lifecycle for explicit prepared-handle release: every
// prepared-but-unconsumed native owner is dropped without GC, exactly
// once, and a failed release closes native admission loudly.
void main() {
  group('transport release seam', () {
    late _ReleaseFakeBindings bindings;
    late CloudSyncScope scope;
    late Directory interlockDirectory;
    late Object activeClient;
    late Store writerStore;

    NativeProtectedCloudSyncTransport buildTransport() =>
        NativeProtectedCloudSyncTransport(
          cloudMessagesClient: activeClient,
          storageDirectory: 'private-storage',
          protectedStoreIdentity: _rstore,
          bindings: bindings,
          readCheckpointGeneration: (_) async => 1,
          writerMutationGuard: CloudKitWriterMutationGuard.forTest(
            store: writerStore,
            readActiveClient: () => activeClient,
            privateStorageDirectory: interlockDirectory.path,
            nativeAuthBinding: _ReleaseAuthBinding(),
            buildDecision: const CloudKitWriterOwnershipDecision(
              owner: CloudKitWriterOwner.v2,
              configurationValid: true,
            ),
          ),
        );

    setUp(() async {
      interlockDirectory = await Directory.systemTemp.createTemp(
        'openbubbles-prepared-release-',
      );
      bindings = _ReleaseFakeBindings();
      activeClient = Object();
      writerStore = await openStore(directory: interlockDirectory.path);
      scope = CloudSyncScope(
        accountFingerprint: _rhash('A'),
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'messageManateeZone',
        streamKind: CloudSyncStreamKind.messages,
        schemaVersion: 2,
        persistenceLane: CloudSyncPersistenceLane.shadow,
      );
      final writerScope = CloudKitWriterScope(
        accountFingerprint: scope.accountFingerprint,
      );
      final initial = ObjectBoxCloudKitWriterAuthority.forTest(
        store: writerStore,
        buildDecision: const CloudKitWriterOwnershipDecision(
          owner: CloudKitWriterOwner.none,
          configurationValid: true,
        ),
      ).initializeDisabled(writerScope, now: testEpoch);
      ObjectBoxCloudKitWriterAuthority.forTest(
        store: writerStore,
        buildDecision: const CloudKitWriterOwnershipDecision(
          owner: CloudKitWriterOwner.v2,
          configurationValid: true,
        ),
      ).provisionInitialOwner(
        writerScope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: initial.epoch,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: testEpoch.add(const Duration(seconds: 1)),
      );
    });

    tearDown(() async {
      if (!writerStore.isClosed()) writerStore.close();
      if (interlockDirectory.existsSync()) {
        await interlockDirectory.delete(recursive: true);
      }
    });

    Future<T> runV2<T>(Future<T> Function() action) =>
        CloudKitOperationInterlock(
          privateStorageDirectory: interlockDirectory.path,
          fenceStore: InMemoryCloudSyncStore(),
        ).runExclusive(kind: CloudKitOperationKind.v2ReadWrite, action: action);

    void reconcileAbsent() {
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: _rref('P'),
      );
    }

    void reconcileCommitted() {
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: _rref('P'),
        serverRecordIdHash: _rhash('S'),
        etagHash: _rhash('E'),
      );
    }

    void prepareWithHandle() {
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakeReleaseHandle(),
        handleBindingSha256: _rsha('a'),
      );
    }

    Future<CloudSyncPreparedSubmission> prepareMessageOp() {
      final operation = _releaseMessageOp(scope);
      return runV2(
        () => buildTransport().prepareSubmission(
          scope,
          submissionIdentity: _releaseSubmissionIdentity(operation.operationId),
          operations: [_releaseProtectedOp(operation)],
        ),
      );
    }

    test('foreign submissions fail closed with no native call', () async {
      final transport = buildTransport();
      final foreignId = 'op1:${_rsha('9')}';
      final foreign = CloudSyncPreparedSubmission.fromProtectedPreflight(
        scope: scope,
        identity: _releaseSubmissionIdentity(foreignId),
        operations: [
          CloudSyncProtectedWriteOperation(
            operationId: foreignId,
            logicalEntityKeyHash: _rhash('L'),
            action: CloudOutboxAction.save,
            protectedServerRecordIdReference: _rref('P'),
            serverRecordIdHash: _rhash('S'),
            protectedPayloadReference: _rref('P'),
            payloadSha256: _rsha('b'),
            protectedLeaseReference: _rlease('a'),
          ),
        ],
      );
      await expectLater(
        runV2(() => transport.releasePreparedSubmission(foreign)),
        throwsA(isA<ArgumentError>()),
      );
      expect(bindings.releaseCalls, 0);
    });

    test(
      'all-preconfirmed submissions report false with no native call',
      () async {
        reconcileCommitted();
        final prepared = await prepareMessageOp();
        expect(bindings.prepareCalls, 0);
        final transport = buildTransport();
        expect(
          await runV2(() => transport.releasePreparedSubmission(prepared)),
          isFalse,
        );
        expect(bindings.releaseCalls, 0);
      },
    );

    test(
      'release drops the exact handle once across concurrent calls',
      () async {
        reconcileAbsent();
        prepareWithHandle();
        final prepared = await prepareMessageOp();
        final transport = buildTransport();
        final results = await runV2(
          () => Future.wait([
            transport.releasePreparedSubmission(prepared),
            transport.releasePreparedSubmission(prepared),
          ]),
        );
        expect(results, [true, true]);
        expect(bindings.releaseCalls, 1);
        expect(bindings.releasedHandles.length, 1);
      },
    );

    test('release failure closes admission with a safe diagnostic', () async {
      reconcileAbsent();
      prepareWithHandle();
      final transport = buildTransport();
      final operation = _releaseMessageOp(scope);
      final prepared = await runV2(
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: _releaseSubmissionIdentity(operation.operationId),
          operations: [_releaseProtectedOp(operation)],
        ),
      );
      bindings.failRelease = true;
      await expectLater(
        runV2(() => transport.releasePreparedSubmission(prepared)),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_prepared_release_failed',
          ),
        ),
      );
      expect(bindings.releaseCalls, 1);
      await expectLater(
        transport.quiesceNativeOperations(),
        throwsA(
          isA<CloudSyncFailure>().having(
            (e) => e.safeCode,
            'safeCode',
            'cloud_sync_prepared_release_failed',
          ),
        ),
      );
      await expectLater(
        runV2(
          () => transport.stageOutboundMessage(
            scope,
            message: _FakeReleaseMessage(),
          ),
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'protected_store_operation_admission_closed',
          ),
        ),
      );
    });

    test('release failure remains visible after cached quiescence', () async {
      reconcileAbsent();
      prepareWithHandle();
      final transport = buildTransport();
      final operation = _releaseMessageOp(scope);
      await runV2(() async {
        final prepared = await transport.prepareSubmission(
          scope,
          submissionIdentity: _releaseSubmissionIdentity(operation.operationId),
          operations: [_releaseProtectedOp(operation)],
        );
        await transport.quiesceNativeOperations();
        bindings.failRelease = true;
        final failure = throwsA(
          isA<CloudSyncFailure>().having(
            (e) => e.safeCode,
            'safeCode',
            'cloud_sync_prepared_release_failed',
          ),
        );
        await expectLater(
          transport.releasePreparedSubmission(prepared),
          failure,
        );
        await expectLater(transport.quiesceNativeOperations(), failure);
        await expectLater(transport.quiesceNativeOperations(), failure);
        expect(bindings.releaseCalls, 1);
      });
    });

    test('prepare validation failure releases the abandoned handle', () async {
      reconcileAbsent();
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakeReleaseHandle(),
      );
      final operation = _releaseMessageOp(scope);
      await expectLater(
        runV2(
          () => buildTransport().prepareSubmission(
            scope,
            submissionIdentity: _releaseSubmissionIdentity(
              operation.operationId,
            ),
            operations: [_releaseProtectedOp(operation)],
          ),
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_outbound_prepare_envelope_invalid',
          ),
        ),
      );
      expect(bindings.releaseCalls, 1);
    });
    test(
      'release runs after admission close without reopening general ops',
      () async {
        reconcileAbsent();
        prepareWithHandle();
        final transport = buildTransport();
        final operation = _releaseMessageOp(scope);
        final prepared = await runV2(
          () => transport.prepareSubmission(
            scope,
            submissionIdentity: _releaseSubmissionIdentity(
              operation.operationId,
            ),
            operations: [_releaseProtectedOp(operation)],
          ),
        );
        await runV2(() => transport.quiesceNativeOperations());
        expect(
        await transport.releasePreparedSubmission(prepared),
        isTrue,
        );
        expect(bindings.releaseCalls, 1);
        await expectLater(
          runV2(
            () => transport.stageOutboundMessage(
              scope,
              message: _FakeReleaseMessage(),
            ),
          ),
          throwsA(
            isA<CloudSyncFailure>().having(
              (failure) => failure.safeCode,
              'safeCode',
              'protected_store_operation_admission_closed',
            ),
          ),
        );
      },
    );

    test(
      'late prepare handle after quiesce is released, never handed out',
      () async {
        reconcileAbsent();
        prepareWithHandle();
        final prepareEntered = Completer<void>();
        final finishPrepare = Completer<void>();
        final releaseEntered = Completer<void>();
        final finishRelease = Completer<void>();
        bindings.onPrepare = () async {
          prepareEntered.complete();
          await finishPrepare.future;
        };
        bindings.onRelease = () async {
          releaseEntered.complete();
          await finishRelease.future;
        };
        final transport = buildTransport();
        final operation = _releaseMessageOp(scope);
        final pending = runV2(
          () => transport.prepareSubmission(
            scope,
            submissionIdentity: _releaseSubmissionIdentity(
              operation.operationId,
            ),
            operations: [_releaseProtectedOp(operation)],
          ),
        );
        final rejected = expectLater(
          pending,
          throwsA(
            isA<CloudSyncFailure>().having(
              (failure) => failure.safeCode,
              'safeCode',
              'protected_store_operation_admission_closed',
            ),
          ),
        );
        await prepareEntered.future;
        var quiesced = false;
        final quiescence = transport.quiesceNativeOperations().then((_) {
          quiesced = true;
        });
        finishPrepare.complete();
        await releaseEntered.future;
        await Future<void>.delayed(Duration.zero);
        expect(quiesced, isFalse);
        expect(bindings.consumeCalls, 0);
        finishRelease.complete();
        await quiescence;
        await rejected;
        expect(bindings.releaseCalls, 1);
        expect(bindings.releasedHandles.length, 1);
      },
    );

    for (final outcome in [
      'returned protectedStorage',
      'thrown bridge failure',
      'success',
    ]) {
      test(
        'real transport releases exact settled handle after $outcome',
        () async {
          reconcileAbsent();
          prepareWithHandle();
          final operation = _releaseMessageOp(scope);
          final identity = _releaseSubmissionIdentity(operation.operationId);
          bindings.consumeResult = outcome == 'success'
              ? frb_api.CloudSyncOutboundConsumeResult(
                  outcomes: [
                    frb_api.CloudSyncOutboundSaveOutcome(
                      localOperationId: operation.operationId,
                      appleOperationUuid:
                          identity.operationUuids[operation.operationId]!,
                      disposition:
                          frb_api.CloudSyncOutboundSaveDisposition.succeeded,
                      serverRecordIdHash: operation.serverRecordIdHash,
                      etagHash: _rhash('E'),
                    ),
                  ],
                )
              : const frb_api.CloudSyncOutboundConsumeResult(
                  outcomes: [],
                  failure: frb_api.CloudSyncOutboundSafeCode.protectedStorage,
                );
          bindings.throwConsume = outcome == 'thrown bridge failure';
          bindings.releaseResult = outcome != 'success';
          final transport = buildTransport();
          await runV2(() async {
            final protected = _releaseProtectedOp(operation);
            final prepared = await transport.prepareSubmission(
              scope,
              submissionIdentity: identity,
              operations: [protected],
            );
            final result = await transport.consumePreparedSubmission(
              scope,
              preparedSubmission: prepared,
              persistedIdentity: identity,
              protectedOperations: [protected],
              operations: [operation],
            );
            expect(
              result.outcomes.values.single.disposition,
              outcome == 'success'
                  ? CloudPushDisposition.confirmed
                  : CloudPushDisposition.unknownOutcome,
            );
            expect(bindings.consumeCalls, 1);
            expect(bindings.consumeSettled, isTrue);
            expect(bindings.releaseCalls, 0);
            await transport.quiesceNativeOperations();
            expect(
              await transport.releasePreparedSubmission(prepared),
              bindings.releaseResult,
            );
            await transport.releasePreparedSubmission(prepared);
            expect(bindings.releaseCalls, 1);
            expect(
              bindings.releasedHandles.single,
              same(bindings.prepareResult.handle),
            );
            expect(
              bindings.consumedHandle,
              same(bindings.prepareResult.handle),
            );
          });
        },
      );
    }
  });

  group('engine release finally', () {
    late CloudSyncScope scope;
    late InMemoryCloudSyncStore store;
    late _ReleasingFakeTransport transport;
    late FakeCloudInboxApplier applier;
    late FakeCloudSyncWriterAuthority writerAuthority;
    late FakeCloudKitOperationExclusion writerExclusion;
    late MutableTestClock clock;

    CloudSyncEngine buildEngine({Duration? writeTimeout}) {
      return CloudSyncEngine(
        scope: scope,
        coordinatorId: 'release-test',
        store: store,
        transport: transport,
        inboxApplier: applier,
        writerAuthority: writerAuthority,
        writerExclusion: writerExclusion,
        backoff: CloudSyncBackoffPolicy(
          baseDelay: const Duration(seconds: 10),
          maximumDelay: const Duration(minutes: 1),
          randomUnit: () => 1,
        ),
        observer: MemoryCloudSyncObserver(),
        clock: clock.call,
        config: CloudSyncEngineConfig(
          maximumBatchSize: 256,
          maximumOutboxBatchesPerRun: 1,
          writeOperationTimeout: writeTimeout ?? const Duration(seconds: 45),
          flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        ),
      );
    }

    setUp(() {
      scope = testScope();
      store = InMemoryCloudSyncStore();
      transport = _ReleasingFakeTransport();
      applier = FakeCloudInboxApplier();
      writerAuthority = FakeCloudSyncWriterAuthority();
      writerExclusion = FakeCloudKitOperationExclusion();
      clock = MutableTestClock(testEpoch);
    });

    CloudPushOutcome confirmedFor(CloudOutboxOperation operation) =>
        CloudPushOutcome(
          operationId: operation.operationId,
          disposition: CloudPushDisposition.confirmed,
          createReceipt: CloudOutboxCreateReceipt(
            operationId: operation.operationId,
            logicalEntityKeyHash: operation.logicalEntityKeyHash,
            // Must equal the allocated record-map hash below: the commit
            // rejects any operation/server binding drift as a conflict.
            serverRecordIdHash: _rhash('M'),
            etagHash: _rhash('E'),
          ),
        );

    void useFixedRecordMapping() {
      transport.recordMappingHandler = (scope, key) async =>
          CloudRecordMapEntry(
            scope: scope,
            logicalEntityKeyHash: key,
            serverRecordIdHash: _rhash('M'),
            encryptedServerRecordId: _rref('M'),
            updatedAt: testEpoch,
          );
    }

    test('permit revoked after prepare still releases', () async {
      final operation = testOutboxOperation(scope, 10);
      await store.enqueueOutbox(operation);
      writerAuthority.verifyHandler = (call) async {
        // Calls 1-2 precede the batch prepare (recovery/permit checks);
        // revoking on 3 rejects after prepare, with an owner outstanding.
        if (call == 3) writerAuthority.allowVerify = false;
      };
      final result = await buildEngine().synchronize(
        trigger: CloudSyncTrigger.localOutbox,
      );
      expect(result.status, CloudSyncRunStatus.failed);
      expect(result.failureCategory, CloudFailureCategory.authorization);
      expect(transport.prepareSubmissionCallCount, 1);
      expect(transport.released.length, 1);
      expect(transport.released.single.operationIds, [operation.operationId]);
    });

    test('consume failure releases without masking the outcome', () async {
      final operation = testOutboxOperation(scope, 11);
      await store.enqueueOutbox(operation);
      transport.enqueuePreparedPushFailure(
        CloudSyncFailure(
          category: CloudFailureCategory.server,
          safeCode: 'test_push_failed',
        ),
      );
      final result = await buildEngine().synchronize(
        trigger: CloudSyncTrigger.localOutbox,
      );
      expect(result.status, CloudSyncRunStatus.completed);
      expect(transport.released.length, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.unknownOutcome,
      );
    });

    test('success releases as a no-op', () async {
      final operation = testOutboxOperation(scope, 12);
      await store.enqueueOutbox(operation);
      useFixedRecordMapping();
      transport.enqueuePreparedPushResult(
        CloudPushBatchResult(outcomes: [confirmedFor(operation)]),
      );
      final result = await buildEngine().synchronize(
        trigger: CloudSyncTrigger.localOutbox,
      );
      expect(result.status, CloudSyncRunStatus.completed);
      expect(transport.released.length, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.confirmed,
      );
    });

    test('push timeout releases after quiescence', () async {
      final operation = testOutboxOperation(scope, 13);
      await store.enqueueOutbox(operation);
      final finishConsume = Completer<void>();
      final quiescenceEntered = Completer<void>();
      final consumeSettled = Completer<void>();
      transport.preparedSubmissionHandler = (scope, prepared, identity) async {
        await finishConsume.future;
        consumeSettled.complete();
        return CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.unknownOutcome,
            ),
          ],
        );
      };
      transport.quiescenceHandler = () async {
        quiescenceEntered.complete();
        await consumeSettled.future;
      };
      final pending = buildEngine(
        writeTimeout: const Duration(milliseconds: 50),
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);
      await quiescenceEntered.future;
      expect(transport.released, isEmpty);
      finishConsume.complete();
      final result = await pending;
      expect(result.status, CloudSyncRunStatus.completed);
      expect(transport.mutationUnknownSignalCount, 1);
      expect(transport.quiescenceCallCount, 1);
      expect(transport.released.length, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.unknownOutcome,
      );
    });

    for (final coordinator in [false, true]) {
      test(
        'post-prepare ${coordinator ? 'coordinator' : 'outbox'} lease loss releases before rethrow',
        () async {
          final failingStore = _ReleaseRenewalStore();
          store = failingStore;
          final operation = testOutboxOperation(scope, coordinator ? 18 : 17);
          await store.enqueueOutbox(operation);
          transport.writePreflightHandler = (_, __, ___) async {
            failingStore.failCoordinator = coordinator;
            failingStore.failOutbox = !coordinator;
          };
          final releaseEntered = Completer<void>();
          final finishRelease = Completer<void>();
          transport.onRelease = () async {
            releaseEntered.complete();
            await finishRelease.future;
          };
          var finished = false;
          final pending = buildEngine()
              .synchronize(trigger: CloudSyncTrigger.localOutbox)
              .then((result) {
                finished = true;
                return result;
              });
          await releaseEntered.future;
          expect(finished, isFalse);
          expect(transport.consumePreparedSubmissionCallCount, 0);
          finishRelease.complete();
          final result = await pending;
          expect(result.status, CloudSyncRunStatus.failed);
          expect(transport.prepareSubmissionCallCount, 1);
          expect(transport.released.single.operationIds, [
            operation.operationId,
          ]);
          final retained = (await store.outboxEntries(scope)).single;
          expect(retained.attemptCount, 0);
          expect(retained.appleRequestUuid, isNull);
        },
      );
    }

    test('settled failure result still releases', () async {
      // A failure *result* (not a throw) leaves the owner possibly untaken:
      // taken-ness is decided natively, never inferred from the return.
      final operation = testOutboxOperation(scope, 16);
      await store.enqueueOutbox(operation);
      transport.preparedSubmissionHandler = (scope, prepared, identity) async {
        return CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.unknownOutcome,
              failureCategory: CloudFailureCategory.unknown,
            ),
          ],
        );
      };
      final result = await buildEngine().synchronize(
        trigger: CloudSyncTrigger.localOutbox,
      );
      expect(result.status, CloudSyncRunStatus.completed);
      expect(transport.released.length, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.unknownOutcome,
      );
    });

    test('release failure surfaces without masking a success', () async {
      final operation = testOutboxOperation(scope, 14);
      await store.enqueueOutbox(operation);
      useFixedRecordMapping();
      transport.enqueuePreparedPushResult(
        CloudPushBatchResult(outcomes: [confirmedFor(operation)]),
      );
      transport.failRelease = true;
      final result = await buildEngine().synchronize(
        trigger: CloudSyncTrigger.localOutbox,
      );
      expect(result.status, CloudSyncRunStatus.failed);
      expect(transport.released.length, 1);
    });

    test('release failure does not mask a consume failure', () async {
      final operation = testOutboxOperation(scope, 15);
      await store.enqueueOutbox(operation);
      transport.enqueuePreparedPushFailure(
        CloudSyncFailure(
          category: CloudFailureCategory.server,
          safeCode: 'test_push_failed',
        ),
      );
      transport.failRelease = true;
      final result = await buildEngine().synchronize(
        trigger: CloudSyncTrigger.localOutbox,
      );
      expect(result.status, CloudSyncRunStatus.completed);
      expect(transport.released.length, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.unknownOutcome,
      );
    });
  });
}

String _rrepeat(String character, int count) =>
    List<String>.filled(count, character).join();
String _rhash(String character) => _rrepeat(character, 43);
String _rsha(String character) => _rrepeat(character, 64);
String _rref(String character) => 'obcs2.ref.${_rhash(character)}';
String _rlease(String character) => 'obcs2.lease.${_rrepeat(character, 32)}';
final String _rstore = 'obcs2.store.${_rhash('S')}';

CloudOutboxOperation _releaseMessageOp(CloudSyncScope scope) {
  final key = _rhash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: key,
      payloadVersion: cloudSyncOutboundPayloadVersion,
    ),
    logicalEntityKeyHash: key,
    action: CloudOutboxAction.save,
    payloadVersion: cloudSyncOutboundPayloadVersion,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: _rref('P'),
    payloadSha256: _rsha('b'),
    serverRecordIdHash: _rhash('S'),
    protectedLeaseReference: _rlease('a'),
    appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
    dependencyOperationIds: const {},
    createdAt: DateTime.utc(2026, 9, 5),
    status: CloudOutboxStatus.unknownOutcome,
    attemptCount: 1,
  );
}

CloudSyncProtectedWriteOperation _releaseProtectedOp(
  CloudOutboxOperation operation,
) => CloudSyncProtectedWriteOperation(
  operationId: operation.operationId,
  logicalEntityKeyHash: operation.logicalEntityKeyHash,
  action: operation.action,
  protectedLeaseReference: operation.protectedLeaseReference,
  protectedServerRecordIdReference: operation.encryptedPayloadReference!,
  serverRecordIdHash: operation.serverRecordIdHash!,
  protectedPayloadReference: operation.encryptedPayloadReference,
  payloadSha256: operation.payloadSha256,
);

CloudOutboxSubmissionIdentity _releaseSubmissionIdentity(String operationId) =>
    CloudOutboxSubmissionIdentity(
      requestUuid: '11111111-2222-4ABC-8DEF-555555555555',
      operationUuids: {operationId: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001'},
    );

final class _FakeReleaseHandle
    implements frb_api.CloudSyncPreparedMessageCreateHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeReleaseMessage implements frb_api.CloudMessage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReleaseFakeBindings
    implements
        NativeProtectedCloudSyncBindings,
        NativeProtectedCloudSyncWriteBindings,
        NativeProtectedPreparedReleaseBindings {
  int stageCalls = 0;
  int prepareCalls = 0;
  int reconcileCalls = 0;
  int releaseCalls = 0;
  int consumeCalls = 0;
  bool consumeSettled = false;
  bool throwConsume = false;
  bool releaseResult = true;
  Future<void> Function()? onPrepare;
  Future<void> Function()? onRelease;
  frb_api.CloudSyncPreparedMessageCreateHandle? consumedHandle;
  frb_api.CloudSyncOutboundConsumeResult consumeResult =
      const frb_api.CloudSyncOutboundConsumeResult(outcomes: []);
  bool failRelease = false;
  Duration prepareDelay = Duration.zero;
  final List<frb_api.CloudSyncPreparedMessageCreateHandle> releasedHandles = [];

  frb_api.CloudSyncProtectedOutboundStageResult stageResult =
      const frb_api.CloudSyncProtectedOutboundStageResult();
  frb_api.CloudSyncOutboundReconcileResult reconcileResult =
      const frb_api.CloudSyncOutboundReconcileResult();
  frb_api.CloudSyncPreparedMessageCreateResult prepareResult =
      const frb_api.CloudSyncPreparedMessageCreateResult();

  @override
  Future<NativeProtectedFetchResult> fetchProtectedPage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String stream,
    required int generation,
    required String? previousCheckpointReference,
    required int maximumChanges,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedFetchResult> fetchProtectedPageUnderWriterPause({
    required Object cloudMessagesClient,
    required BigInt nativeWriterPauseToken,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String stream,
    required int generation,
    required String? previousCheckpointReference,
    required int maximumChanges,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedLeaseResult> commitProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
    required List<String> retainedReferences,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedLeaseResult> acknowledgeCommittedPageLease({
    required String storageDirectory,
    required String leaseReference,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedLeaseResult> rollbackProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedRecoveryResult> recoverProtectedPageLeases({
    required String storageDirectory,
    required List<String> adoptedLeaseReferences,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedRetirementResult> retireProtectedReferences({
    required String storageDirectory,
    required List<String> references,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedGarbageCollectionResult> collectProtectedGarbage({
    required String storageDirectory,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) => throw UnimplementedError();

  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundMessage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudMessage message,
  }) async {
    stageCalls++;
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
    prepareCalls++;
    await onPrepare?.call();
    if (prepareDelay > Duration.zero) {
      await Future<void>.delayed(prepareDelay);
    }
    return prepareResult;
  }

  @override
  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  }) async {
    consumeCalls++;
    consumedHandle = handle;
    try {
      if (throwConsume) throw StateError('test_native_bridge_failed');
      return consumeResult;
    } finally {
      consumeSettled = true;
    }
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
    reconcileCalls++;
    return reconcileResult;
  }

  @override
  Future<bool> releasePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
  }) async {
    releaseCalls++;
    await onRelease?.call();
    if (failRelease) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'test_release_failed',
      );
    }
    releasedHandles.add(handle);
    return releaseResult;
  }
}

final class _ReleasingFakeTransport extends FakeCloudSyncTransport
    implements CloudSyncPreparedSubmissionReleaser {
  final List<CloudSyncPreparedSubmission> released = [];
  bool failRelease = false;
  Future<void> Function()? onRelease;

  @override
  Future<bool> releasePreparedSubmission(
    CloudSyncPreparedSubmission prepared,
  ) async {
    released.add(prepared);
    await onRelease?.call();
    if (failRelease) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        safeCode: 'test_release_failed',
      );
    }
    return true;
  }
}

final class _ReleaseAuthBinding implements CloudSyncNativeAuthBinding {
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
  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async => CloudSyncNativeAuthMetadata(
    nativeSessionId: _rhash('N'),
    accountFingerprint: _rhash('A'),
    protectedStoreIdentity: _rstore,
  );
}

final class _ReleaseRenewalStore extends InMemoryCloudSyncStore {
  bool failCoordinator = false;
  bool failOutbox = false;

  @override
  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  }) => failCoordinator
      ? Future.value(false)
      : super.renewCoordinatorLease(
          scope,
          leaseFence: leaseFence,
          now: now,
          leaseDuration: leaseDuration,
        );

  @override
  Future<bool> renewOutboxLease(
    CloudSyncScope scope, {
    required String leaseId,
    required Iterable<String> operationIds,
    required DateTime now,
    required Duration leaseDuration,
  }) => failOutbox
      ? Future.value(false)
      : super.renewOutboxLease(
          scope,
          leaseId: leaseId,
          operationIds: operationIds,
          now: now,
          leaseDuration: leaseDuration,
        );
}
