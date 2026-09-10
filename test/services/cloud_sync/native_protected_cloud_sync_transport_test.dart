import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeBindings bindings;
  late NativeProtectedCloudSyncTransport transport;
  late CloudSyncScope scope;
  late Directory writerDirectory;
  late Store writerStore;
  late Object activeClient;
  late int activeCheckpointGeneration;

  NativeProtectedCloudSyncTransport buildTransport({
    bool retainConfirmedReceiptsForReplay = false,
  }) => NativeProtectedCloudSyncTransport(
    cloudMessagesClient: activeClient,
    storageDirectory: 'private-storage',
    protectedStoreIdentity: _storeIdentity,
    bindings: bindings,
    readCheckpointGeneration: (_) async => activeCheckpointGeneration,
    retainConfirmedReceiptsForReplay: retainConfirmedReceiptsForReplay,
    writerMutationGuard: CloudKitWriterMutationGuard.forTest(
      store: writerStore,
      readActiveClient: () => activeClient,
      privateStorageDirectory: writerDirectory.path,
      nativeAuthBinding: _MutationAuthBinding(
        accountFingerprint: scope.accountFingerprint,
        protectedStoreIdentity: _storeIdentity,
      ),
      reconciliationBinding: bindings,
      buildDecision: const CloudKitWriterOwnershipDecision(
        owner: CloudKitWriterOwner.v2,
        configurationValid: true,
      ),
    ),
  );

  setUp(() async {
    writerDirectory = await Directory.systemTemp.createTemp(
      'openbubbles-protected-writer-interlock-',
    );
    writerStore = await openStore(directory: writerDirectory.path);
    bindings = _FakeBindings();
    activeClient = Object();
    activeCheckpointGeneration = 1;
    scope = CloudSyncScope(
      accountFingerprint: _hash('A'),
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'messageManateeZone',
      streamKind: CloudSyncStreamKind.messages,
      schemaVersion: 2,
      persistenceLane: CloudSyncPersistenceLane.shadow,
    );
    const buildDecision = CloudKitWriterOwnershipDecision(
      owner: CloudKitWriterOwner.v2,
      configurationValid: true,
    );
    final writerScope = CloudKitWriterScope(
      accountFingerprint: scope.accountFingerprint,
    );
    final disabledAuthority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: writerStore,
      buildDecision: const CloudKitWriterOwnershipDecision(
        owner: CloudKitWriterOwner.none,
        configurationValid: true,
      ),
    );
    final initial = disabledAuthority.initializeDisabled(
      writerScope,
      now: DateTime.utc(2026, 9, 1),
    );
    ObjectBoxCloudKitWriterAuthority.forTest(
      store: writerStore,
      buildDecision: buildDecision,
    ).provisionInitialOwner(
      writerScope,
      owner: CloudKitWriterOwner.v2,
      expectedEpoch: initial.epoch,
      evidence: const CloudKitWriterTransitionEvidence.forTest(
        operationsQuiesced: true,
        activeIdentityRevalidated: true,
        legacyMutationQueues: LegacyMutationQueueDisposition.empty,
      ),
      now: DateTime.utc(2026, 9, 1, 0, 0, 1),
    );
    transport = buildTransport();
  });

  tearDown(() async {
    if (!writerStore.isClosed()) writerStore.close();
    if (writerDirectory.existsSync()) {
      await writerDirectory.delete(recursive: true);
    }
  });

  Future<T> runV2<T>(Future<T> Function() action) => CloudKitOperationInterlock(
    privateStorageDirectory: writerDirectory.path,
    fenceStore: InMemoryCloudSyncStore(),
  ).runExclusive(kind: CloudKitOperationKind.v2ReadWrite, action: action);

  ObjectBoxCloudKitWriterAuthority writerAuthority() =>
      ObjectBoxCloudKitWriterAuthority.forTest(
        store: writerStore,
        buildDecision: const CloudKitWriterOwnershipDecision(
          owner: CloudKitWriterOwner.v2,
          configurationValid: true,
        ),
      );

  CloudKitWriterScope writerScope() =>
      CloudKitWriterScope(accountFingerprint: scope.accountFingerprint);

  test('every generated protected failure code is report allowlisted', () {
    final mapped = frb_api.CloudSyncProtectedSafeCode.values
        .map(cloudSyncV2ProtectedTransportSafeCode)
        .toSet();
    expect(mapped, CloudSyncV2ProtectedTransportSafeFailureCodes.all);
    for (final code in mapped) {
      expect(cloudSyncV2SafeFailureCodeForCandidate(code), code, reason: code);
    }
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
      expect(bindings.nativeWriterPauseToken, isNull);
      expect(bindings.unboundFetchCalls, 1);
      expect(bindings.boundFetchCalls, 0);
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
    'forwards the exact native writer-pause capability to protected fetch',
    () async {
      bindings.fetchResult = _validEmptyFetchResult();
      final pauseToken = BigInt.from(77);
      final boundTransport = NativeProtectedCloudSyncTransport(
        cloudMessagesClient: Object(),
        storageDirectory: 'private-storage',
        protectedStoreIdentity: _storeIdentity,
        nativeWriterPauseToken: pauseToken,
        bindings: bindings,
      );

      await boundTransport.fetchChanges(
        _semanticScope(),
        previousToken: null,
        generation: 1,
        limit: 1,
      );

      expect(bindings.nativeWriterPauseToken, same(pauseToken));
      expect(bindings.boundFetchCalls, 1);
      expect(bindings.unboundFetchCalls, 0);
    },
  );

  test('rejects an invalid native writer-pause capability before fetch', () {
    expect(
      () => NativeProtectedCloudSyncTransport(
        cloudMessagesClient: Object(),
        storageDirectory: 'private-storage',
        protectedStoreIdentity: _storeIdentity,
        nativeWriterPauseToken: BigInt.zero,
        bindings: bindings,
      ),
      throwsArgumentError,
    );
  });

  test('writer-pause-bound fetch rejects every non-semantic zone', () async {
    final boundTransport = NativeProtectedCloudSyncTransport(
      cloudMessagesClient: Object(),
      storageDirectory: 'private-storage',
      protectedStoreIdentity: _storeIdentity,
      nativeWriterPauseToken: BigInt.one,
      bindings: bindings,
    );
    for (final zone in const <String>[
      'messageUpdateZone',
      'recoverableMessageDeleteZone',
      'scheduledMessageZone',
      'chat1ManateeZone',
    ]) {
      await expectLater(
        boundTransport.fetchChanges(
          CloudSyncScope(
            accountFingerprint: _hash('A'),
            container: 'com.apple.messages.cloud',
            database: 'private',
            zone: zone,
            streamKind: CloudSyncStreamKind.messages,
            schemaVersion: 2,
            persistenceLane: CloudSyncPersistenceLane.semantic,
          ),
          previousToken: null,
          generation: 1,
          limit: 1,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'unsupported_semantic_cloud_zone',
          ),
        ),
        reason: zone,
      );
    }
    expect(bindings.boundFetchCalls, 0);
    expect(bindings.unboundFetchCalls, 0);
  });

  test('semantic fetch requires a native writer-pause capability', () async {
    bindings.fetchResult = _validEmptyFetchResult();

    await expectLater(
      transport.fetchChanges(
        _semanticScope(),
        previousToken: null,
        generation: 1,
        limit: 1,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_sync_native_writer_pause_capability_required',
        ),
      ),
    );
    expect(bindings.boundFetchCalls, 0);
    expect(bindings.unboundFetchCalls, 0);
  });

  test('writer-pause capability cannot authorize a shadow fetch', () async {
    bindings.fetchResult = _validEmptyFetchResult();
    final boundTransport = NativeProtectedCloudSyncTransport(
      cloudMessagesClient: Object(),
      storageDirectory: 'private-storage',
      protectedStoreIdentity: _storeIdentity,
      nativeWriterPauseToken: BigInt.one,
      bindings: bindings,
    );

    await expectLater(
      boundTransport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 1,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'unsupported_semantic_persistence_lane',
        ),
      ),
    );
    expect(bindings.boundFetchCalls, 0);
    expect(bindings.unboundFetchCalls, 0);
  });

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
            persistenceLane: CloudSyncPersistenceLane.shadow,
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

  test('maps a protected reset proof only onto the exact failed fetch', () async {
    final proofReference = _reference('Z');
    bindings.fetchResult = NativeProtectedFetchResult(
      failure: NativeProtectedFailure(
        category: NativeProtectedFailureCategory.unknown,
        safeCode: 'cloudkit_reset_required',
        protectedResetProofReference: proofReference,
      ),
    );

    Object? thrown;
    try {
      await transport.fetchChanges(
        scope,
        previousToken: _reference('O'),
        generation: 7,
        limit: 20,
      );
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isA<CloudSyncFailure>());
    final failure = thrown! as CloudSyncFailure;
    expect(failure.safeCode, 'cloudkit_reset_required');
    expect(failure.resetContext, isNotNull);
    expect(failure.resetContext!.scope, scope);
    expect(failure.resetContext!.expectedGeneration, 7);
    expect(
      failure.resetContext!.protectedRemoteStateProofReference,
      proofReference,
    );
    expect(failure.toString(), isNot(contains(proofReference)));
    expect(failure.resetContext.toString(), isNot(contains(proofReference)));
  });

  test('rejects a reset proof on any non-reset failure', () async {
    bindings.fetchResult = NativeProtectedFetchResult(
      failure: NativeProtectedFailure(
        category: NativeProtectedFailureCategory.authorization,
        safeCode: 'cloudkit_authorization',
        protectedResetProofReference: _reference('Z'),
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
          'invalid_protected_reset_proof',
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

  test(
    'every native writer boundary requires the v2 read-write interlock',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      final genericPrepared =
          CloudSyncPreparedSubmission.fromProtectedPreflight(
            scope: scope,
            identity: identity,
            operations: [protectedOperation],
          );
      final attempts = <Future<Object?> Function()>[
        () =>
            transport.runOutboundAdmissionExclusive<Object?>(() async => null),
        () =>
            transport.stageOutboundMessage(scope, message: _FakeCloudMessage()),
        () => transport.commitOutboundLease(
          operation.protectedLeaseReference!,
          operation.encryptedPayloadReference!,
        ),
        () =>
            transport.rollbackOutboundLease(operation.protectedLeaseReference!),
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        ),
        () => transport.consumePreparedSubmission(
          scope,
          preparedSubmission: genericPrepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        ),
        () => transport.acknowledgeDurableTerminalOperations(
          scope,
          operations: [operation],
          transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
        ),
        () => transport.reconcileUnknownOutcome(
          scope,
          operation: _unknownOutcomeOperation(scope),
        ),
      ];

      for (final attempt in attempts) {
        await expectLater(
          Future<Object?>.sync(attempt),
          throwsA(
            isA<CloudKitOperationInterlockException>().having(
              (error) => error.safeCode,
              'safeCode',
              'cloudkit_interlock_required',
            ),
          ),
        );
      }

      expect(bindings.stageCalls, 0);
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
      expect(bindings.reconcileCalls, 0);
      expect(bindings.commitCalls, 0);
      expect(bindings.rollbackCalls, 0);
      expect(bindings.acknowledgedLeases, isEmpty);
    },
  );

  group('explicit Chat-v1 writer capability', () {
    late _ChatBindings chatBindings;
    setUp(() {
      scope = _semanticScope(zone: 'chatManateeZone');
      chatBindings = _ChatBindings();
      bindings = chatBindings;
      transport = buildTransport();
    });
    void absent() {
      chatBindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: _reference('P'),
      );
      chatBindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
    }

    Future<CloudSyncPreparedSubmission> prepare(
      CloudOutboxOperation operation,
    ) => runV2(
      () => transport.prepareSubmission(
        scope,
        submissionIdentity: _submissionIdentity(operation.operationId),
        operations: [_protectedWriteOperation(operation)],
      ),
    );
    test(
      'staging uses Chat binding only and retains exact protected references',
      () async {
        chatBindings.stageResult =
            frb_api.CloudSyncProtectedOutboundStageResult(
              stage: frb_api.CloudSyncProtectedOutboundStage(
                logicalEntityKeyHash: _hash('L'),
                protectedPayloadReference: _reference('P'),
                payloadSha256: _sha('b'),
                payloadLength: BigInt.from(256),
                protectedServerRecordReference: _reference('P'),
                serverRecordIdHash: _hash('S'),
                leaseReference: _lease('a'),
              ),
            );
        final staged = await runV2(
          () => transport.stageOutboundChat(scope, chat: _FakeCloudChat()),
        );
        expect(staged.protectedEnvelopeReference, _reference('P'));
        expect(staged.leaseReference, _lease('a'));
        expect(chatBindings.chatStageCalls, 1);
        expect(chatBindings.stageCalls, 0);
      },
    );
    test('Message-only bindings cannot stage or prepare Chat', () async {
      bindings = _FakeBindings();
      transport = buildTransport();
      await expectLater(
        runV2(() => transport.stageOutboundChat(scope, chat: _FakeCloudChat())),
        throwsA(isA<CloudSyncFailure>()),
      );
      await expectLater(
        prepare(_chatOperation(scope)),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(bindings.stageCalls, 0);
      expect(bindings.prepareCalls, 0);
      expect(bindings.reconcileCalls, 0);
    });
    test(
      'Chat preparation routes exact original input and UUIDs without Message fallback',
      () async {
        absent();
        final op = _chatOperation(scope);
        final prepared = await prepare(op);
        expect(prepared.operationIds, [op.operationId]);
        expect(chatBindings.chatReconcileCalls, 1);
        expect(chatBindings.chatPrepareCalls, 1);
        expect(chatBindings.prepareCalls, 0);
        expect(chatBindings.reconcileCalls, 0);
        expect(chatBindings.preparedRequestUuid, op.appleRequestUuid);
        expect(
          chatBindings.preparedInputs.single.localOperationId,
          op.operationId,
        );
        expect(
          chatBindings.preparedInputs.single.appleOperationUuid,
          op.appleOperationUuid,
        );
        expect(
          chatBindings.preparedInputs.single.protectedPayloadReference,
          _reference('P'),
        );
        expect(
          chatBindings.preparedInputs.single.protectedLeaseReference,
          _lease('a'),
        );
      },
    );
    test(
      'Message-v2 keeps Message dispatch on bindings that also support Chat',
      () async {
        absent();
        scope = _semanticScope();
        final op = _writeOperation(scope);
        await prepare(op);
        expect(chatBindings.reconcileCalls, 1);
        expect(chatBindings.prepareCalls, 1);
        expect(chatBindings.chatReconcileCalls, 0);
        expect(chatBindings.chatPrepareCalls, 0);
      },
    );
    test(
      'cross-domain version and zone operations fail before any lookup',
      () async {
        absent();
        await expectLater(
          prepare(_writeOperation(scope)),
          throwsA(isA<CloudSyncFailure>()),
        );
        final chat = _chatOperation(scope);
        scope = _semanticScope();
        await expectLater(prepare(chat), throwsA(isA<CloudSyncFailure>()));
        scope = _semanticScope(zone: 'attachmentManateeZone');
        await expectLater(
          prepare(_chatOperation(scope)),
          throwsA(isA<CloudSyncFailure>()),
        );
        scope = CloudSyncScope(
          accountFingerprint: _hash('A'),
          container: 'com.apple.messages.cloud',
          database: 'private',
          zone: 'chatManateeZone',
          streamKind: CloudSyncStreamKind.profiles,
          schemaVersion: 2,
          persistenceLane: CloudSyncPersistenceLane.semantic,
        );
        await expectLater(
          prepare(_chatOperation(scope)),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(chatBindings.chatReconcileCalls, 0);
        expect(chatBindings.reconcileCalls, 0);
        expect(chatBindings.chatPrepareCalls, 0);
        expect(chatBindings.prepareCalls, 0);
      },
    );
    test('Chat rejects two distinct operations before preflight', () async {
      absent();
      final first = _chatOperation(scope);
      final second = _chatOperation(scope, logical: _hash('M'));
      await expectLater(
        runV2(
          () => transport.prepareSubmission(
            scope,
            submissionIdentity: CloudOutboxSubmissionIdentity(
              requestUuid: first.appleRequestUuid!,
              operationUuids: {
                first.operationId: first.appleOperationUuid!,
                second.operationId: 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD',
              },
            ),
            operations: [
              _protectedWriteOperation(first),
              _protectedWriteOperation(second),
            ],
          ),
        ),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(chatBindings.chatReconcileCalls, 0);
      expect(chatBindings.chatPrepareCalls, 0);
    });
    test(
      'unresolved Chat preflight retains retry delay and retries the same envelope',
      () async {
        absent();
        final op = _chatOperation(scope);
        chatBindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
          disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved,
          failureClass: frb_api.CloudSyncOutboundFailureClass.throttled,
          retryAfterSeconds: BigInt.from(17),
        );
        await expectLater(
          prepare(op),
          throwsA(
            isA<CloudSyncFailure>().having(
              (e) => e.retryAfter,
              'retry',
              const Duration(seconds: 17),
            ),
          ),
        );
        expect(chatBindings.chatPrepareCalls, 0);
        expect(chatBindings.consumeCalls, 0);
        absent();
        await prepare(op);
        expect(chatBindings.chatReconcileCalls, 2);
        expect(chatBindings.chatPrepareCalls, 1);
        expect(
          chatBindings.preparedInputs.single.protectedPayloadReference,
          op.encryptedPayloadReference,
        );
        expect(chatBindings.preparedRequestUuid, op.appleRequestUuid);
        expect(chatBindings.chatStageCalls, 0);
      },
    );
    test(
      'existing Chat readback is a confirmed no-op without native prepare or consume',
      () async {
        final op = _chatOperation(scope);
        chatBindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
          disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
          protectedProofReference: _reference('P'),
          serverRecordIdHash: _hash('S'),
          etagHash: _hash('E'),
        );
        final prepared = await prepare(op);
        final result = await runV2(
          () => transport.consumePreparedSubmission(
            scope,
            preparedSubmission: prepared,
            persistedIdentity: _submissionIdentity(op.operationId),
            protectedOperations: [_protectedWriteOperation(op)],
            operations: [op],
          ),
        );
        expect(
          result.outcomes.values.single.disposition,
          CloudPushDisposition.confirmed,
        );
        expect(chatBindings.chatPrepareCalls, 0);
        expect(chatBindings.consumeCalls, 0);
        expect(chatBindings.reconcileCalls, 0);
      },
    );
    test(
      'unknown Chat reconciliation uses the guarded Chat seam and original submission',
      () async {
        final op = _chatOperation(scope);
        chatBindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
          disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved,
          failureClass: frb_api.CloudSyncOutboundFailureClass.transientServer,
          retryAfterSeconds: BigInt.from(11),
        );
        final result = await runV2(
          () => transport.reconcileUnknownOutcome(scope, operation: op),
        );
        expect(result.disposition, CloudUnknownOutcomeDisposition.unresolved);
        expect(result.retryAfter, const Duration(seconds: 11));
        expect(chatBindings.chatReconcileCalls, 1);
        expect(chatBindings.reconcileCalls, 0);
        expect(chatBindings.reconcileRequestUuid, op.appleRequestUuid);
        expect(
          chatBindings.reconcileInput!.appleOperationUuid,
          op.appleOperationUuid,
        );
        expect(chatBindings.consumeCalls, 0);
      },
    );
    test(
      'confirmed Chat proof uses Chat readback while Message proof rejects Chat scope',
      () async {
        final op = _chatOperation(scope, status: CloudOutboxStatus.confirmed);
        chatBindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
          disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
          protectedProofReference: _reference('P'),
          serverRecordIdHash: _hash('S'),
          etagHash: _hash('E'),
        );
        await runV2(
          () => transport.verifyConfirmedChatCreateNoSave(scope, operation: op),
        );
        await expectLater(
          runV2(
            () => transport.verifyConfirmedMessageCreateNoSave(
              scope,
              operation: op,
            ),
          ),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(chatBindings.chatReconcileCalls, 1);
        expect(chatBindings.reconcileCalls, 0);
        expect(chatBindings.consumeCalls, 0);
      },
    );
  });

  group('explicit Attachment-v1 writer capability', () {
    late _AttachmentBindings attachmentBindings;
    setUp(() {
      scope = _semanticScope(zone: 'attachmentManateeZone');
      attachmentBindings = _AttachmentBindings();
      bindings = attachmentBindings;
      transport = buildTransport();
    });
    void absent() {
      attachmentBindings.reconcileResult =
          frb_api.CloudSyncOutboundReconcileResult(
            disposition:
                frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
            protectedProofReference: _reference('P'),
          );
      attachmentBindings.prepareResult =
          frb_api.CloudSyncPreparedMessageCreateResult(
            handle: _FakePreparedHandle(),
            handleBindingSha256: _preparedHandleBindingSha256,
          );
    }

    Future<CloudSyncPreparedSubmission> prepare(
      CloudOutboxOperation operation,
    ) => runV2(
      () => transport.prepareSubmission(
        scope,
        submissionIdentity: _submissionIdentity(operation.operationId),
        operations: [_protectedWriteOperation(operation)],
      ),
    );
    test(
      'Attachment preparation routes exact original input and UUIDs without Message or Chat fallback',
      () async {
        absent();
        final op = _attachmentOperation(scope);
        final prepared = await prepare(op);
        expect(prepared.operationIds, [op.operationId]);
        expect(attachmentBindings.attachmentReconcileCalls, 1);
        expect(attachmentBindings.attachmentPrepareCalls, 1);
        expect(attachmentBindings.prepareCalls, 0);
        expect(attachmentBindings.reconcileCalls, 0);
        expect(attachmentBindings.preparedRequestUuid, op.appleRequestUuid);
        expect(
          attachmentBindings.preparedInputs.single.localOperationId,
          op.operationId,
        );
        expect(
          attachmentBindings.preparedInputs.single.appleOperationUuid,
          op.appleOperationUuid,
        );
        expect(
          attachmentBindings.preparedInputs.single.protectedPayloadReference,
          _reference('P'),
        );
        expect(
          attachmentBindings.preparedInputs.single.protectedLeaseReference,
          _lease('a'),
        );
      },
    );
    test('Message-only bindings cannot prepare Attachment', () async {
      bindings = _FakeBindings();
      transport = buildTransport();
      await expectLater(
        prepare(_attachmentOperation(scope)),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(bindings.stageCalls, 0);
      expect(bindings.prepareCalls, 0);
      expect(bindings.reconcileCalls, 0);
    });
    test(
      'cross-domain version, zone, identity, and action fail before any lookup',
      () async {
        absent();
        await expectLater(
          prepare(_writeOperation(scope)),
          throwsA(isA<CloudSyncFailure>()),
        );
        final attachment = _attachmentOperation(scope);
        scope = _semanticScope();
        await expectLater(prepare(attachment), throwsA(isA<CloudSyncFailure>()));
        scope = _semanticScope(zone: 'attachmentManateeZone');
        // A chat-scoped operation stays bound to its chat scope: resubmitting
        // it under the attachment scope must fail before any native lookup,
        // even though chat-v1 and attachment-v1 share the version number.
        final chatScoped = _chatOperation(
          _semanticScope(zone: 'chatManateeZone'),
        );
        await expectLater(
          prepare(chatScoped),
          throwsA(isA<CloudSyncFailure>()),
        );
        scope = _semanticScope(zone: 'chatManateeZone');
        await expectLater(
          prepare(_attachmentOperation(scope)),
          throwsA(isA<CloudSyncFailure>()),
        );
        scope = _semanticScope(zone: 'attachmentManateeZone');
        await expectLater(
          prepare(_attachmentOperation(scope, payloadVersion: 2)),
          throwsA(isA<CloudSyncFailure>()),
        );
        await expectLater(
          prepare(_attachmentOperation(scope, operationIdFor: _hash('M'))),
          throwsA(isA<CloudSyncFailure>()),
        );
        await expectLater(
          prepare(
            _attachmentOperation(scope, action: CloudOutboxAction.delete),
          ),
          // The shared protected-write constructor rejects non-save actions
          // before the transport is reached; still no native call happens.
          throwsArgumentError,
        );
        expect(attachmentBindings.attachmentReconcileCalls, 0);
        expect(attachmentBindings.reconcileCalls, 0);
        expect(attachmentBindings.attachmentPrepareCalls, 0);
        expect(attachmentBindings.prepareCalls, 0);
      },
    );
    test(
      'Message-v2 dispatch stays unchanged on Attachment-capable bindings',
      () async {
        absent();
        scope = _semanticScope();
        final op = _writeOperation(scope);
        await prepare(op);
        expect(attachmentBindings.reconcileCalls, 1);
        expect(attachmentBindings.prepareCalls, 1);
        expect(attachmentBindings.attachmentReconcileCalls, 0);
        expect(attachmentBindings.attachmentPrepareCalls, 0);
      },
    );
    test(
      'existing Attachment readback is a confirmed no-op without native prepare or consume',
      () async {
        final op = _attachmentOperation(scope);
        attachmentBindings.reconcileResult =
            frb_api.CloudSyncOutboundReconcileResult(
              disposition:
                  frb_api.CloudSyncOutboundReconcileDisposition.committed,
              protectedProofReference: _reference('P'),
              serverRecordIdHash: _hash('S'),
              etagHash: _hash('E'),
            );
        final prepared = await prepare(op);
        final result = await runV2(
          () => transport.consumePreparedSubmission(
            scope,
            preparedSubmission: prepared,
            persistedIdentity: _submissionIdentity(op.operationId),
            protectedOperations: [_protectedWriteOperation(op)],
            operations: [op],
          ),
        );
        expect(
          result.outcomes.values.single.disposition,
          CloudPushDisposition.confirmed,
        );
        expect(attachmentBindings.attachmentReconcileCalls, 1);
        expect(attachmentBindings.attachmentPrepareCalls, 0);
        expect(attachmentBindings.consumeCalls, 0);
        expect(attachmentBindings.reconcileCalls, 0);
      },
    );
    test(
      'confirmed Attachment proof uses Attachment readback while Message and Chat proofs reject Attachment scope',
      () async {
        final op = _attachmentOperation(
          scope,
          status: CloudOutboxStatus.confirmed,
        );
        attachmentBindings.reconcileResult =
            frb_api.CloudSyncOutboundReconcileResult(
              disposition:
                  frb_api.CloudSyncOutboundReconcileDisposition.committed,
              protectedProofReference: _reference('P'),
              serverRecordIdHash: _hash('S'),
              etagHash: _hash('E'),
            );
        await runV2(
          () => transport.verifyConfirmedAttachmentCreateNoSave(
            scope,
            operation: op,
          ),
        );
        await expectLater(
          runV2(
            () => transport.verifyConfirmedMessageCreateNoSave(
              scope,
              operation: op,
            ),
          ),
          throwsA(isA<CloudSyncFailure>()),
        );
        await expectLater(
          runV2(
            () => transport.verifyConfirmedChatCreateNoSave(
              scope,
              operation: op,
            ),
          ),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(attachmentBindings.attachmentReconcileCalls, 1);
        expect(attachmentBindings.reconcileCalls, 0);
        expect(attachmentBindings.consumeCalls, 0);
      },
    );
    test(
      'Attachment unknown-outcome reconciliation requires Attachment bindings',
      () async {
        final op = _attachmentOperation(scope);
        bindings = _FakeBindings();
        transport = buildTransport();
        await expectLater(
          runV2(() => transport.reconcileUnknownOutcome(scope, operation: op)),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(bindings.reconcileCalls, 0);
        expect(bindings.prepareCalls, 0);
        expect(bindings.consumeCalls, 0);
      },
    );
  });

  test('protected writer forwards one exact prepared create binding', () async {
    final operation = _writeOperation(scope);
    final protectedOperation = _protectedWriteOperation(operation);
    final identity = _submissionIdentity(operation.operationId);
    bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
      handle: _FakePreparedHandle(),
      handleBindingSha256: _preparedHandleBindingSha256,
    );
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: protectedOperation.protectedPayloadReference,
    );

    final prepared = await runV2(
      () => transport.prepareSubmission(
        scope,
        submissionIdentity: identity,
        operations: [protectedOperation],
      ),
    );

    expect(prepared.operationIds, [operation.operationId]);
    expect(bindings.reconcileCalls, 1);
    expect(bindings.prepareCalls, 1);
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
    'exact existing create preflight becomes a local confirmed no-op',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: protectedOperation.protectedPayloadReference,
        serverRecordIdHash: _hash('S'),
        etagHash: _hash('E'),
      );

      final prepared = await runV2(
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        ),
      );
      final result = await runV2(
        () => transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        ),
      );

      expect(
        result.outcomes.values.single.disposition,
        CloudPushDisposition.confirmed,
      );
      final receipt = result.outcomes.values.single.createReceipt;
      expect(receipt, isNotNull);
      expect(receipt!.operationId, operation.operationId);
      expect(receipt.logicalEntityKeyHash, operation.logicalEntityKeyHash);
      expect(receipt.serverRecordIdHash, operation.serverRecordIdHash);
      expect(receipt.etagHash, _hash('E'));
      expect(bindings.reconcileCalls, 1);
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
      expect(bindings.preparedInputs, isEmpty);
    },
  );

  test(
    'existing create preflight without receipt hashes fails closed',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );

      await expectLater(
        runV2(
          () => transport.prepareSubmission(
            scope,
            submissionIdentity: identity,
            operations: [protectedOperation],
          ),
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_outbound_create_preflight_receipt_invalid',
          ),
        ),
      );
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
    },
  );

  test(
    'existing create preflight with a swapped server hash fails closed',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: protectedOperation.protectedPayloadReference,
        serverRecordIdHash: _hash('T'),
        etagHash: _hash('E'),
      );

      await expectLater(
        runV2(
          () => transport.prepareSubmission(
            scope,
            submissionIdentity: identity,
            operations: [protectedOperation],
          ),
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_outbound_create_preflight_receipt_mismatch',
          ),
        ),
      );
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
    },
  );

  test(
    'divergent create preflight quarantines before native prepare',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.diverged,
        protectedProofReference: protectedOperation.protectedPayloadReference,
        failureClass: frb_api.CloudSyncOutboundFailureClass.conflict,
      );

      await expectLater(
        runV2(
          () => transport.prepareSubmission(
            scope,
            submissionIdentity: _submissionIdentity(operation.operationId),
            operations: [protectedOperation],
          ),
        ),
        throwsA(
          isA<CloudSyncFailure>()
              .having(
                (failure) => failure.category,
                'category',
                CloudFailureCategory.conflict,
              )
              .having(
                (failure) => failure.safeCode,
                'safeCode',
                'cloud_sync_outbound_create_preflight_conflict',
              ),
        ),
      );
      expect(bindings.reconcileCalls, 1);
      expect(bindings.prepareCalls, 0);
    },
  );

  test('indeterminate create preflight remains pre-submit retryable', () async {
    final operation = _writeOperation(scope);
    final protectedOperation = _protectedWriteOperation(operation);
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved,
      failureClass: frb_api.CloudSyncOutboundFailureClass.transientServer,
      retryAfterSeconds: BigInt.from(41),
    );

    await expectLater(
      runV2(
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: _submissionIdentity(operation.operationId),
          operations: [protectedOperation],
        ),
      ),
      throwsA(
        isA<CloudSyncFailure>()
            .having(
              (failure) => failure.category,
              'category',
              CloudFailureCategory.server,
            )
            .having(
              (failure) => failure.retryAfter,
              'retryAfter',
              const Duration(seconds: 41),
            )
            .having(
              (failure) => failure.safeCode,
              'safeCode',
              'cloud_sync_outbound_create_preflight_unresolved',
            ),
      ),
    );
    expect(bindings.reconcileCalls, 1);
    expect(bindings.prepareCalls, 0);
  });

  test('create preflight rejects a swapped decisive proof', () async {
    final operation = _writeOperation(scope);
    final protectedOperation = _protectedWriteOperation(operation);
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: _reference('Q'),
    );

    await expectLater(
      runV2(
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: _submissionIdentity(operation.operationId),
          operations: [protectedOperation],
        ),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_sync_outbound_create_preflight_envelope_invalid',
        ),
      ),
    );
    expect(bindings.prepareCalls, 0);
  });

  test('native preflight safe codes remain valid snake case', () async {
    final operation = _writeOperation(scope);
    final protectedOperation = _protectedWriteOperation(operation);
    bindings.reconcileResult = const frb_api.CloudSyncOutboundReconcileResult(
      failure: frb_api.CloudSyncOutboundSafeCode.invalidRequest,
    );

    await expectLater(
      runV2(
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: _submissionIdentity(operation.operationId),
          operations: [protectedOperation],
        ),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_sync_outbound_invalid_request',
        ),
      ),
    );
    expect(bindings.prepareCalls, 0);
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
        runV2(
          () => transport.prepareSubmission(
            scope,
            submissionIdentity: _submissionIdentity(wrongOperationId),
            operations: [protectedOperation],
          ),
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
      runV2(
        () => transport.prepareSubmission(
          wrongScope,
          submissionIdentity: _submissionIdentity(operation.operationId),
          operations: [_protectedWriteOperation(operation)],
        ),
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
    'invalid local claim never arms a mutation fence and preserves the handle',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      final wrongIdentity = CloudOutboxSubmissionIdentity(
        requestUuid: '99999999-9999-4999-8999-999999999999',
        operationUuids: identity.operationUuids,
      );
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition: frb_api.CloudSyncOutboundSaveDisposition.succeeded,
            serverRecordIdHash: operation.serverRecordIdHash,
            etagHash: _hash('E'),
          ),
        ],
      );
      final fence = File(
        '${writerDirectory.path}${Platform.pathSeparator}'
        '.openbubbles-cloudkit-writer-mutation-v1.fence',
      );

      await runV2(() async {
        final prepared = await transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        );
        await expectLater(
          transport.consumePreparedSubmission(
            scope,
            preparedSubmission: prepared,
            persistedIdentity: wrongIdentity,
            protectedOperations: [protectedOperation],
            operations: [operation],
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(bindings.consumeCalls, 0);
        expect(fence.existsSync(), isFalse);
        expect(
          writerAuthority().read(writerScope())!.state,
          CloudKitWriterAuthorityState.stable,
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
          CloudPushDisposition.confirmed,
        );
        await expectLater(
          transport.consumePreparedSubmission(
            scope,
            preparedSubmission: prepared,
            persistedIdentity: identity,
            protectedOperations: [protectedOperation],
            operations: [operation],
          ),
          throwsA(isA<StateError>()),
        );
        expect(bindings.consumeCalls, 1);
        expect(fence.existsSync(), isFalse);
        expect(
          writerAuthority().read(writerScope())!.state,
          CloudKitWriterAuthorityState.stable,
        );
      });
    },
  );

  test(
    'confirmed mutation passes one digest-only capability and releases its fence',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition: frb_api.CloudSyncOutboundSaveDisposition.succeeded,
            serverRecordIdHash: _hash('S'),
            etagHash: _hash('E'),
          ),
        ],
      );
      final fence = File(
        '${writerDirectory.path}${Platform.pathSeparator}'
        '.openbubbles-cloudkit-writer-mutation-v1.fence',
      );
      bindings.beforeOperation = (name) async {
        if (name != 'consumeOutbound') return;
        final token = bindings.consumedMutationCapabilityToken!;
        expect(token, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(fence.existsSync(), isTrue);
        final encoded = fence.readAsStringSync();
        final payload = jsonDecode(encoded) as Map<String, dynamic>;
        expect(payload['version'], 3);
        expect(
          payload['capabilitySha256'],
          sha256.convert(utf8.encode(token)).toString(),
        );
        expect(
          payload['preparedHandleBindingSha256'],
          _preparedHandleBindingSha256,
        );
        expect(
          payload['reconciliationBindingSha256'],
          cloudKitWriterReconciliationBindingSha256(
            operation,
            appleRequestUuid: identity.requestUuid,
            appleOperationUuid: identity.operationUuids[operation.operationId],
          ),
        );
        expect(encoded, isNot(contains(token)));
      };

      final result = await runV2(() async {
        final prepared = await transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        );
        return transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        );
      });

      expect(
        result.outcomes.values.single.disposition,
        CloudPushDisposition.confirmed,
      );
      expect(bindings.consumeCalls, 1);
      expect(fence.existsSync(), isFalse);
      final confirmedOutcome = result.outcomes.values.single;
      expect(confirmedOutcome.createReceipt, isNotNull);
      expect(
        confirmedOutcome.createReceipt!.operationId,
        operation.operationId,
      );
      expect(
        confirmedOutcome.createReceipt!.logicalEntityKeyHash,
        operation.logicalEntityKeyHash,
      );
      expect(
        confirmedOutcome.createReceipt!.serverRecordIdHash,
        operation.serverRecordIdHash,
      );
      expect(confirmedOutcome.createReceipt!.etagHash, _hash('E'));
      expect(
        writerAuthority().read(writerScope())!.state,
        CloudKitWriterAuthorityState.stable,
      );
    },
  );

  test(
    'same-account active client replacement is rejected before native consume',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      final prepared = await runV2(
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        ),
      );

      activeClient = Object();

      await expectLater(
        runV2(
          () => transport.consumePreparedSubmission(
            scope,
            preparedSubmission: prepared,
            persistedIdentity: identity,
            protectedOperations: [protectedOperation],
            operations: [operation],
          ),
        ),
        throwsA(
          isA<CloudKitWriterAuthorityFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloudkit_writer_transport_client_mismatch',
          ),
        ),
      );
      expect(bindings.consumeCalls, 0);
      expect(
        writerAuthority().read(writerScope())!.state,
        CloudKitWriterAuthorityState.stable,
      );
    },
  );

  test(
    'checkpoint generation change after prepare blocks and preserves handle',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition: frb_api.CloudSyncOutboundSaveDisposition.succeeded,
            serverRecordIdHash: operation.serverRecordIdHash,
            etagHash: _hash('E'),
          ),
        ],
      );
      final prepared = await runV2(
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        ),
      );

      activeCheckpointGeneration = 2;
      await expectLater(
        runV2(
          () => transport.consumePreparedSubmission(
            scope,
            preparedSubmission: prepared,
            persistedIdentity: identity,
            protectedOperations: [protectedOperation],
            operations: [operation],
          ),
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_outbound_stale_checkpoint_generation',
          ),
        ),
      );
      expect(bindings.consumeCalls, 0);
      expect(
        File(
          '${writerDirectory.path}${Platform.pathSeparator}'
          '.openbubbles-cloudkit-writer-mutation-v1.fence',
        ).existsSync(),
        isFalse,
      );

      activeCheckpointGeneration = 1;
      final result = await runV2(
        () => transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        ),
      );
      expect(bindings.consumeCalls, 1);
      expect(
        result.outcomes.values.single.disposition,
        CloudPushDisposition.confirmed,
      );
    },
  );

  test(
    'timeout poison during identity capture prevents late submission',
    () async {
      final captureEntered = Completer<void>();
      final releaseCapture = Completer<void>();
      transport = NativeProtectedCloudSyncTransport(
        cloudMessagesClient: activeClient,
        storageDirectory: 'private-storage',
        protectedStoreIdentity: _storeIdentity,
        bindings: bindings,
        readCheckpointGeneration: (_) async => activeCheckpointGeneration,
        writerMutationGuard: CloudKitWriterMutationGuard.forTest(
          store: writerStore,
          readActiveClient: () => activeClient,
          privateStorageDirectory: writerDirectory.path,
          nativeAuthBinding: _MutationAuthBinding(
            accountFingerprint: scope.accountFingerprint,
            protectedStoreIdentity: _storeIdentity,
            beforeCapture: () async {
              if (!captureEntered.isCompleted) captureEntered.complete();
              await releaseCapture.future;
            },
          ),
          buildDecision: const CloudKitWriterOwnershipDecision(
            owner: CloudKitWriterOwner.v2,
            configurationValid: true,
          ),
        ),
      );
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      final prepared = await runV2(
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        ),
      );

      final pending = runV2(
        () => transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        ),
      );
      await captureEntered.future;
      transport.markActiveMutationUnknown();
      releaseCapture.complete();

      await expectLater(
        pending,
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_mutation_timeout_poisoned',
          ),
        ),
      );
      expect(bindings.consumeCalls, 0);
      expect(
        File(
          '${writerDirectory.path}${Platform.pathSeparator}'
          '.openbubbles-cloudkit-writer-mutation-v1.fence',
        ).existsSync(),
        isFalse,
      );
      expect(
        writerAuthority().read(writerScope())!.state,
        CloudKitWriterAuthorityState.stable,
      );
    },
  );

  test('timeout poison survives a late confirmed native completion', () async {
    final operation = _writeOperation(scope);
    final protectedOperation = _protectedWriteOperation(operation);
    final identity = _submissionIdentity(operation.operationId);
    final consumeEntered = Completer<void>();
    final releaseConsume = Completer<void>();
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: protectedOperation.protectedPayloadReference,
    );
    bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
      handle: _FakePreparedHandle(),
      handleBindingSha256: _preparedHandleBindingSha256,
    );
    bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
      outcomes: [
        frb_api.CloudSyncOutboundSaveOutcome(
          localOperationId: operation.operationId,
          appleOperationUuid: identity.operationUuids[operation.operationId]!,
          disposition: frb_api.CloudSyncOutboundSaveDisposition.succeeded,
        ),
      ],
    );
    bindings.beforeOperation = (name) async {
      if (name != 'consumeOutbound') return;
      consumeEntered.complete();
      await releaseConsume.future;
    };

    final pending = runV2(() async {
      final prepared = await transport.prepareSubmission(
        scope,
        submissionIdentity: identity,
        operations: [protectedOperation],
      );
      return transport.consumePreparedSubmission(
        scope,
        preparedSubmission: prepared,
        persistedIdentity: identity,
        protectedOperations: [protectedOperation],
        operations: [operation],
      );
    });
    await consumeEntered.future;
    final fence = File(
      '${writerDirectory.path}${Platform.pathSeparator}'
      '.openbubbles-cloudkit-writer-mutation-v1.fence',
    );
    expect(fence.existsSync(), isTrue);
    transport.markActiveMutationUnknown();
    releaseConsume.complete();
    final result = await pending;

    expect(
      result.outcomes.values.single.disposition,
      CloudPushDisposition.unknownOutcome,
    );
    expect(bindings.consumeCalls, 1);
    expect(fence.existsSync(), isTrue);
    expect(
      writerAuthority().read(writerScope())!.state,
      CloudKitWriterAuthorityState.mutationUnknown,
    );
  });

  test(
    'protected writer is single-use and bounds native retry-after',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
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
      final (prepared, result) = await runV2(() async {
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
        return (prepared, result);
      });

      expect(
        result.outcomes.values.single.disposition,
        CloudPushDisposition.unknownOutcome,
      );
      expect(result.outcomes.values.single.retryAfter, const Duration(days: 7));
      expect(bindings.consumeCalls, 1);
      await expectLater(
        runV2(
          () => transport.consumePreparedSubmission(
            scope,
            preparedSubmission: prepared,
            persistedIdentity: identity,
            protectedOperations: [protectedOperation],
            operations: [operation],
          ),
        ),
        throwsA(
          isA<CloudKitWriterAuthorityFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloudkit_writer_mutation_reconciliation_required',
          ),
        ),
      );
      expect(bindings.consumeCalls, 1);
    },
  );

  test(
    'classified failure after capability consume remains outcome unknown',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: operation.encryptedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition: frb_api.CloudSyncOutboundSaveDisposition.failed,
            failureClass: frb_api.CloudSyncOutboundFailureClass.authentication,
          ),
        ],
      );

      final result = await runV2(() async {
        final prepared = await transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        );
        return transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        );
      });

      final outcome = result.outcomes.values.single;
      expect(outcome.disposition, CloudPushDisposition.unknownOutcome);
      expect(outcome.failureCategory, CloudFailureCategory.authorization);
      expect(bindings.consumeCalls, 1);
      expect(
        File(
          '${writerDirectory.path}${Platform.pathSeparator}'
          '.openbubbles-cloudkit-writer-mutation-v1.fence',
        ).existsSync(),
        isTrue,
      );
      expect(
        writerAuthority().read(writerScope())!.state,
        CloudKitWriterAuthorityState.mutationUnknown,
      );
    },
  );

  test(
    'exact readback releases an ambiguous mutation fence without another save',
    () async {
      final semanticScope = _semanticScope();
      final operation = _unknownOutcomeOperation(semanticScope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      final beforeEpoch = writerAuthority().read(writerScope())!.epoch;
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: operation.encryptedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: operation.appleOperationUuid!,
            disposition:
                frb_api.CloudSyncOutboundSaveDisposition.unknownOutcome,
          ),
        ],
      );

      final ambiguous = await runV2(() async {
        final prepared = await transport.prepareSubmission(
          semanticScope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        );
        return transport.consumePreparedSubmission(
          semanticScope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        );
      });
      final fence = File(
        '${writerDirectory.path}${Platform.pathSeparator}'
        '.openbubbles-cloudkit-writer-mutation-v1.fence',
      );
      expect(
        ambiguous.outcomes.values.single.disposition,
        CloudPushDisposition.unknownOutcome,
      );
      expect(fence.existsSync(), isTrue);
      expect(
        writerAuthority().read(writerScope())!.state,
        CloudKitWriterAuthorityState.mutationUnknown,
      );

      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: operation.encryptedPayloadReference,
        serverRecordIdHash: _hash('S'),
        etagHash: _hash('E'),
      );
      final resolution = await runV2(
        () => transport.reconcileUnknownOutcome(
          semanticScope,
          operation: operation,
        ),
      );

      expect(resolution.disposition, CloudUnknownOutcomeDisposition.committed);
      expect(fence.existsSync(), isFalse);
      final reconciled = writerAuthority().read(writerScope())!;
      expect(reconciled.state, CloudKitWriterAuthorityState.stable);
      expect(reconciled.epoch, beforeEpoch + 2);
      expect(bindings.prepareCalls, 1);
      expect(bindings.consumeCalls, 1);

      // A crash after fence release but before the local outbox transition is
      // harmless: the same exact readback is accepted without rotating the
      // authority again or reaching either native mutation method.
      final replay = await runV2(
        () => transport.reconcileUnknownOutcome(
          semanticScope,
          operation: operation,
        ),
      );
      expect(replay.disposition, CloudUnknownOutcomeDisposition.committed);
      expect(writerAuthority().read(writerScope())!.epoch, beforeEpoch + 2);
      expect(bindings.prepareCalls, 1);
      expect(bindings.consumeCalls, 1);
    },
  );

  test(
    'create-only race enters exact reconciliation without update merge',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition: frb_api.CloudSyncOutboundSaveDisposition.failed,
            failureClass: frb_api.CloudSyncOutboundFailureClass.conflict,
          ),
        ],
      );

      final result = await runV2(() async {
        final prepared = await transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        );
        return transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        );
      });

      final outcome = result.outcomes.values.single;
      expect(outcome.disposition, CloudPushDisposition.unknownOutcome);
      expect(outcome.failureCategory, CloudFailureCategory.unknown);
      expect(bindings.reconcileCalls, 1);
      expect(bindings.prepareCalls, 1);
      expect(bindings.consumeCalls, 1);
    },
  );

  test('reconciles committed only with the exact protected proof', () async {
    final semanticScope = _semanticScope();
    final operation = _unknownOutcomeOperation(semanticScope);
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
      protectedProofReference: operation.encryptedPayloadReference,
      serverRecordIdHash: _hash('S'),
      etagHash: _hash('E'),
    );

    final resolution = await runV2(
      () => transport.reconcileUnknownOutcome(
        semanticScope,
        operation: operation,
      ),
    );

    expect(resolution.disposition, CloudUnknownOutcomeDisposition.committed);
    expect(resolution.failureCategory, isNull);
    expect(resolution.retryAfter, isNull);
    expect(resolution.createReceipt, isNotNull);
    expect(resolution.createReceipt!.operationId, operation.operationId);
    expect(
      resolution.createReceipt!.logicalEntityKeyHash,
      operation.logicalEntityKeyHash,
    );
    expect(
      resolution.createReceipt!.serverRecordIdHash,
      operation.serverRecordIdHash,
    );
    expect(resolution.createReceipt!.etagHash, _hash('E'));
    _expectReconcileCall(
      bindings,
      operation,
      semanticScope,
      expectedStorageDirectory: writerDirectory.path,
    );
  });

  test(
    'confirmed replay verifies the exact protected digest without a save path',
    () async {
      final operation = _unknownOutcomeOperation(
        scope,
        status: CloudOutboxStatus.confirmed,
      );
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: operation.encryptedPayloadReference,
        serverRecordIdHash: _hash('S'),
        etagHash: _hash('E'),
      );

      await runV2(
        () => transport.verifyConfirmedMessageCreateNoSave(
          scope,
          operation: operation,
        ),
      );

      _expectReconcileCall(bindings, operation, scope);
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
    },
  );

  test(
    'confirmed replay rejects non-confirmed or malformed operations before native',
    () async {
      final invalidOperations = <CloudOutboxOperation>[
        _unknownOutcomeOperation(scope),
        _unknownOutcomeOperation(
          scope,
          status: CloudOutboxStatus.confirmed,
          payloadReference: 'raw/payload-reference',
        ),
      ];

      for (final operation in invalidOperations) {
        await expectLater(
          runV2(
            () => transport.verifyConfirmedMessageCreateNoSave(
              scope,
              operation: operation,
            ),
          ),
          throwsA(
            isA<CloudSyncFailure>().having(
              (failure) => failure.safeCode,
              'safeCode',
              'cloud_sync_outbound_replay_operation_invalid',
            ),
          ),
        );
      }

      expect(bindings.reconcileCalls, 0);
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
    },
  );

  test(
    'confirmed replay fails closed for missing diverged or unresolved records',
    () async {
      final operation = _unknownOutcomeOperation(
        scope,
        status: CloudOutboxStatus.confirmed,
      );
      final cases =
          <
            ({
              frb_api.CloudSyncOutboundReconcileDisposition disposition,
              frb_api.CloudSyncOutboundFailureClass? failureClass,
              String safeCode,
            })
          >[
            (
              disposition:
                  frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
              failureClass: null,
              safeCode: 'cloud_sync_outbound_replay_record_missing',
            ),
            (
              disposition:
                  frb_api.CloudSyncOutboundReconcileDisposition.diverged,
              failureClass: frb_api.CloudSyncOutboundFailureClass.conflict,
              safeCode: 'cloud_sync_outbound_replay_conflict',
            ),
            (
              disposition:
                  frb_api.CloudSyncOutboundReconcileDisposition.unresolved,
              failureClass:
                  frb_api.CloudSyncOutboundFailureClass.transientServer,
              safeCode: 'cloud_sync_outbound_replay_unresolved',
            ),
          ];

      for (final testCase in cases) {
        bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
          disposition: testCase.disposition,
          protectedProofReference:
              testCase.disposition ==
                  frb_api.CloudSyncOutboundReconcileDisposition.unresolved
              ? null
              : operation.encryptedPayloadReference,
          failureClass: testCase.failureClass,
        );

        await expectLater(
          runV2(
            () => transport.verifyConfirmedMessageCreateNoSave(
              scope,
              operation: operation,
            ),
          ),
          throwsA(
            isA<CloudSyncFailure>().having(
              (failure) => failure.safeCode,
              'safeCode',
              testCase.safeCode,
            ),
          ),
        );
      }

      expect(bindings.reconcileCalls, cases.length);
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
    },
  );

  test(
    'reconciles explicit notApplied only with the exact protected proof',
    () async {
      final semanticScope = _semanticScope();
      final operation = _unknownOutcomeOperation(semanticScope);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: operation.encryptedPayloadReference,
      );

      final resolution = await runV2(
        () => transport.reconcileUnknownOutcome(
          semanticScope,
          operation: operation,
        ),
      );

      expect(resolution.disposition, CloudUnknownOutcomeDisposition.notApplied);
      expect(resolution.failureCategory, isNull);
      expect(resolution.retryAfter, isNull);
      _expectReconcileCall(
        bindings,
        operation,
        semanticScope,
        expectedStorageDirectory: writerDirectory.path,
      );
    },
  );

  test('maps diverged reconciliation to a quarantined conflict', () async {
    final semanticScope = _semanticScope();
    final operation = _unknownOutcomeOperation(semanticScope);
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.diverged,
      protectedProofReference: operation.encryptedPayloadReference,
      failureClass: frb_api.CloudSyncOutboundFailureClass.conflict,
    );

    final resolution = await runV2(
      () => transport.reconcileUnknownOutcome(
        semanticScope,
        operation: operation,
      ),
    );

    expect(resolution.disposition, CloudUnknownOutcomeDisposition.quarantined);
    expect(resolution.failureCategory, CloudFailureCategory.conflict);
    expect(resolution.retryAfter, isNull);
    _expectReconcileCall(
      bindings,
      operation,
      semanticScope,
      expectedStorageDirectory: writerDirectory.path,
    );
  });

  test(
    'maps unresolved retry class and caps retry-after at seven days',
    () async {
      final semanticScope = _semanticScope();
      final operation = _unknownOutcomeOperation(semanticScope);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved,
        failureClass: frb_api.CloudSyncOutboundFailureClass.transientServer,
        retryAfterSeconds: BigInt.parse('18446744073709551615'),
      );

      final resolution = await runV2(
        () => transport.reconcileUnknownOutcome(
          semanticScope,
          operation: operation,
        ),
      );

      expect(resolution.disposition, CloudUnknownOutcomeDisposition.unresolved);
      expect(resolution.failureCategory, CloudFailureCategory.server);
      expect(resolution.retryAfter, const Duration(days: 7));
      _expectReconcileCall(
        bindings,
        operation,
        semanticScope,
        expectedStorageDirectory: writerDirectory.path,
      );
    },
  );

  test('malformed or swapped proof references fail closed', () async {
    final semanticScope = _semanticScope();
    final operation = _unknownOutcomeOperation(semanticScope);
    for (final proofReference in <String>[
      'raw/proof-reference',
      _reference('Q'),
    ]) {
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: proofReference,
      );

      await expectLater(
        runV2(
          () => transport.reconcileUnknownOutcome(
            semanticScope,
            operation: operation,
          ),
        ),
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
      final semanticScope = _semanticScope();
      final otherScope = CloudSyncScope(
        accountFingerprint: _hash('Z'),
        container: semanticScope.container,
        database: semanticScope.database,
        zone: semanticScope.zone,
        streamKind: semanticScope.streamKind,
        schemaVersion: semanticScope.schemaVersion,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final authorityFailure = isA<CloudKitWriterAuthorityFailure>().having(
        (failure) => failure.safeCode,
        'safeCode',
        'cloudkit_writer_mutation_reconciliation_operation_invalid',
      );
      final invalidCases =
          <({CloudOutboxOperation operation, Matcher matcher})>[
            (
              operation: _unknownOutcomeOperation(
                semanticScope,
                payloadReference: 'raw/payload-reference',
              ),
              matcher: authorityFailure,
            ),
            (
              operation: _unknownOutcomeOperation(otherScope),
              matcher: isA<CloudSyncFailure>().having(
                (failure) => failure.safeCode,
                'safeCode',
                'cloud_sync_outbound_reconcile_operation_invalid',
              ),
            ),
            (
              operation: _unknownOutcomeOperation(
                semanticScope,
                status: CloudOutboxStatus.pending,
              ),
              matcher: authorityFailure,
            ),
            (
              operation: _unknownOutcomeOperation(
                semanticScope,
                action: CloudOutboxAction.delete,
              ),
              matcher: authorityFailure,
            ),
            (
              operation: _unknownOutcomeOperation(
                semanticScope,
                operationId: 'op1:${_sha('f')}',
              ),
              matcher: authorityFailure,
            ),
          ];

      for (final testCase in invalidCases) {
        await expectLater(
          runV2(
            () => transport.reconcileUnknownOutcome(
              semanticScope,
              operation: testCase.operation,
            ),
          ),
          throwsA(testCase.matcher),
        );
      }
      expect(bindings.reconcileCalls, 0);
    },
  );

  test(
    'terminal receipt acknowledgement validates scope and correlation',
    () async {
      final operation = _writeOperation(scope);
      await runV2(
        () => transport.acknowledgeDurableTerminalOperations(
          scope,
          operations: [operation],
          transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
        ),
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
        runV2(
          () => transport.acknowledgeDurableTerminalOperations(
            otherScope,
            operations: [operation],
            transitions: [
              CloudOutboxTransition.confirmed(operation.operationId),
            ],
          ),
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
    'outbound Canary retains confirmed receipts but releases quarantined ones',
    () async {
      final retainedTransport = buildTransport(
        retainConfirmedReceiptsForReplay: true,
      );
      final operation = _writeOperation(scope);

      await runV2(
        () => retainedTransport.acknowledgeDurableTerminalOperations(
          scope,
          operations: [operation],
          transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
        ),
      );
      expect(bindings.acknowledgedLeases, isEmpty);

      await runV2(
        () => retainedTransport.acknowledgeDurableTerminalOperations(
          scope,
          operations: [operation],
          transitions: [
            CloudOutboxTransition.quarantined(
              operation.operationId,
              category: CloudFailureCategory.conflict,
            ),
          ],
        ),
      );
      expect(bindings.acknowledgedLeases, [operation.protectedLeaseReference]);
    },
  );

  test(
    'confirmed replay proof releases only its exact local receipt',
    () async {
      final operation = _unknownOutcomeOperation(
        scope,
        status: CloudOutboxStatus.confirmed,
      );
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: operation.encryptedPayloadReference,
        serverRecordIdHash: _hash('S'),
        etagHash: _hash('E'),
      );

      final proof = await runV2(
        () => transport.verifyConfirmedMessageCreateNoSave(
          scope,
          operation: operation,
        ),
      );

      var durableMarkerCleared = false;
      await runV2(
        () => transport.releaseConfirmedReplayReceipt(
          scope,
          operation: operation,
          proof: proof,
          clearDurableAdoptionMarker: () async {
            expect(bindings.acknowledgedLeases, isEmpty);
            durableMarkerCleared = true;
          },
        ),
      );

      expect(durableMarkerCleared, isTrue);
      expect(bindings.acknowledgedLeases, [operation.protectedLeaseReference]);
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
      expect(bindings.reconcileCalls, 1);
    },
  );

  test('confirmed replay proof cannot release a changed receipt', () async {
    final operation = _unknownOutcomeOperation(
      scope,
      status: CloudOutboxStatus.confirmed,
    );
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
      protectedProofReference: operation.encryptedPayloadReference,
      serverRecordIdHash: _hash('S'),
      etagHash: _hash('E'),
    );
    final proof = await runV2(
      () => transport.verifyConfirmedMessageCreateNoSave(
        scope,
        operation: operation,
      ),
    );

    await expectLater(
      runV2(
        () => transport.releaseConfirmedReplayReceipt(
          scope,
          operation: operation.copyWith(protectedLeaseReference: _lease('b')),
          proof: proof,
          clearDurableAdoptionMarker: () async =>
              fail('invalid proof must not clear the durable marker'),
        ),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_sync_outbound_replay_operation_invalid',
        ),
      ),
    );
    expect(bindings.acknowledgedLeases, isEmpty);
  });

  test(
    'confirmed replay proof clears durable adoption before acknowledgement',
    () async {
      final operation = _unknownOutcomeOperation(
        scope,
        status: CloudOutboxStatus.confirmed,
      );
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: operation.encryptedPayloadReference,
        serverRecordIdHash: _hash('S'),
        etagHash: _hash('E'),
      );
      final proof = await runV2(
        () => transport.verifyConfirmedMessageCreateNoSave(
          scope,
          operation: operation,
        ),
      );

      await expectLater(
        runV2(
          () => transport.releaseConfirmedReplayReceipt(
            scope,
            operation: operation,
            proof: proof,
            clearDurableAdoptionMarker: () async {
              expect(bindings.acknowledgedLeases, isEmpty);
              throw StateError('durable-clear-failed');
            },
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(bindings.acknowledgedLeases, isEmpty);

      await expectLater(
        runV2(
          () => transport.releaseConfirmedReplayReceipt(
            scope,
            operation: operation,
            proof: proof,
            clearDurableAdoptionMarker: () async =>
                fail('consumed proof must not retry the durable clear'),
          ),
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_sync_outbound_replay_operation_invalid',
          ),
        ),
      );
      expect(bindings.acknowledgedLeases, isEmpty);
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
        runV2(
          () => transport.stageOutboundMessage(
            scope,
            message: _FakeCloudMessage(),
          ),
        ),
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

  test('create receipt rejects malformed values without leaking them', () {
    final operationId = 'op1:${_sha('a')}';
    final receipt = CloudOutboxCreateReceipt(
      operationId: operationId,
      logicalEntityKeyHash: _hash('L'),
      serverRecordIdHash: _hash('S'),
      etagHash: _hash('E'),
    );
    expect(receipt.operationId, operationId);
    expect(receipt.toString(), 'CloudOutboxCreateReceipt(redacted)');

    final malformed = <CloudOutboxCreateReceipt Function()>[
      () => CloudOutboxCreateReceipt(
        operationId: 'LEAK-OPERATION-ID',
        logicalEntityKeyHash: _hash('L'),
        serverRecordIdHash: _hash('S'),
        etagHash: _hash('E'),
      ),
      () => CloudOutboxCreateReceipt(
        operationId: operationId,
        logicalEntityKeyHash: 'LEAK-LOGICAL',
        serverRecordIdHash: _hash('S'),
        etagHash: _hash('E'),
      ),
      () => CloudOutboxCreateReceipt(
        operationId: operationId,
        logicalEntityKeyHash: _hash('L'),
        serverRecordIdHash: 'LEAK-SERVER',
        etagHash: _hash('E'),
      ),
      () => CloudOutboxCreateReceipt(
        operationId: operationId,
        logicalEntityKeyHash: _hash('L'),
        serverRecordIdHash: _hash('S'),
        etagHash: 'LEAK-ETAG',
      ),
    ];
    for (final make in malformed) {
      try {
        make();
        fail('malformed receipt must throw ArgumentError');
      } on ArgumentError catch (error) {
        expect(error.message, isNot(contains('LEAK')));
        expect(error.toString(), isNot(contains('LEAK')));
      }
    }
  });

  test('confirmed outcomes carry receipts only for their own operation', () {
    final operationId = 'op1:${_sha('a')}';
    final otherOperationId = 'op1:${_sha('b')}';
    CloudOutboxCreateReceipt receiptFor(String operation) =>
        CloudOutboxCreateReceipt(
          operationId: operation,
          logicalEntityKeyHash: _hash('L'),
          serverRecordIdHash: _hash('S'),
          etagHash: _hash('E'),
        );

    // Existing confirmed fakes without a receipt keep compiling; the parent
    // engine fails closed for the protected production lane.
    expect(
      CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.confirmed,
      ).createReceipt,
      isNull,
    );
    final withReceipt = CloudPushOutcome(
      operationId: operationId,
      disposition: CloudPushDisposition.confirmed,
      createReceipt: receiptFor(operationId),
    );
    expect(withReceipt.createReceipt!.etagHash, _hash('E'));
    expect(
      () => CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.confirmed,
        createReceipt: receiptFor(otherOperationId),
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.retryable,
        failureCategory: CloudFailureCategory.throttled,
        createReceipt: receiptFor(operationId),
      ),
      throwsArgumentError,
    );
  });

  test('only committed resolutions carry a create receipt', () {
    final receipt = CloudOutboxCreateReceipt(
      operationId: 'op1:${_sha('a')}',
      logicalEntityKeyHash: _hash('L'),
      serverRecordIdHash: _hash('S'),
      etagHash: _hash('E'),
    );
    final committed = CloudUnknownOutcomeResolution.committed(
      createReceipt: receipt,
    );
    expect(committed.disposition, CloudUnknownOutcomeDisposition.committed);
    expect(committed.createReceipt, same(receipt));
    expect(
      const CloudUnknownOutcomeResolution.notApplied().createReceipt,
      isNull,
    );
    expect(
      const CloudUnknownOutcomeResolution.serverRecordChanged().createReceipt,
      isNull,
    );
    expect(
      const CloudUnknownOutcomeResolution.unresolved(
        failureCategory: CloudFailureCategory.unknown,
      ).createReceipt,
      isNull,
    );
    expect(
      const CloudUnknownOutcomeResolution.quarantined(
        failureCategory: CloudFailureCategory.conflict,
      ).createReceipt,
      isNull,
    );
  });

  test(
    'succeeded save without receipt hashes stays reconciliation-only',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition: frb_api.CloudSyncOutboundSaveDisposition.succeeded,
          ),
        ],
      );

      final result = await runV2(() async {
        final prepared = await transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        );
        return transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        );
      });

      final outcome = result.outcomes.values.single;
      expect(outcome.disposition, CloudPushDisposition.unknownOutcome);
      expect(outcome.failureCategory, CloudFailureCategory.unknown);
      expect(outcome.createReceipt, isNull);
      expect(bindings.consumeCalls, 1);
      expect(
        File(
          '${writerDirectory.path}${Platform.pathSeparator}'
          '.openbubbles-cloudkit-writer-mutation-v1.fence',
        ).existsSync(),
        isTrue,
      );
      expect(
        writerAuthority().read(writerScope())!.state,
        CloudKitWriterAuthorityState.mutationUnknown,
      );
    },
  );

  test(
    'succeeded save with malformed receipt hashes stays reconciliation-only',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition: frb_api.CloudSyncOutboundSaveDisposition.succeeded,
            serverRecordIdHash: 'not-a-native-digest',
            etagHash: 'also-not-a-native-digest',
          ),
        ],
      );

      final result = await runV2(() async {
        final prepared = await transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        );
        return transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        );
      });

      final outcome = result.outcomes.values.single;
      expect(outcome.disposition, CloudPushDisposition.unknownOutcome);
      expect(outcome.failureCategory, CloudFailureCategory.unknown);
      expect(outcome.createReceipt, isNull);
      expect(
        File(
          '${writerDirectory.path}${Platform.pathSeparator}'
          '.openbubbles-cloudkit-writer-mutation-v1.fence',
        ).existsSync(),
        isTrue,
      );
    },
  );

  test(
    'succeeded save with a swapped server hash stays reconciliation-only',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: protectedOperation.protectedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition: frb_api.CloudSyncOutboundSaveDisposition.succeeded,
            serverRecordIdHash: _hash('T'),
            etagHash: _hash('E'),
          ),
        ],
      );

      final result = await runV2(() async {
        final prepared = await transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        );
        return transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        );
      });

      final outcome = result.outcomes.values.single;
      expect(outcome.disposition, CloudPushDisposition.unknownOutcome);
      expect(outcome.failureCategory, CloudFailureCategory.unknown);
      expect(outcome.createReceipt, isNull);
      expect(
        File(
          '${writerDirectory.path}${Platform.pathSeparator}'
          '.openbubbles-cloudkit-writer-mutation-v1.fence',
        ).existsSync(),
        isTrue,
      );
    },
  );

  test(
    'committed reconciliation without receipt hashes fails closed',
    () async {
      final semanticScope = _semanticScope();
      final operation = _unknownOutcomeOperation(semanticScope);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: operation.encryptedPayloadReference,
      );

      await expectLater(
        runV2(
          () => transport.reconcileUnknownOutcome(
            semanticScope,
            operation: operation,
          ),
        ),
        throwsA(
          isA<CloudKitWriterAuthorityFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloudkit_writer_reconciliation_receipt_invalid',
          ),
        ),
      );
      expect(bindings.reconcileCalls, 1);
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
    },
  );

  test(
    'committed reconciliation with a swapped server hash fails closed',
    () async {
      final semanticScope = _semanticScope();
      final operation = _unknownOutcomeOperation(semanticScope);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: operation.encryptedPayloadReference,
        serverRecordIdHash: _hash('T'),
        etagHash: _hash('E'),
      );

      await expectLater(
        runV2(
          () => transport.reconcileUnknownOutcome(
            semanticScope,
            operation: operation,
          ),
        ),
        throwsA(
          isA<CloudKitWriterAuthorityFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloudkit_writer_reconciliation_receipt_mismatch',
          ),
        ),
      );
      expect(bindings.reconcileCalls, 1);
      expect(bindings.prepareCalls, 0);
      expect(bindings.consumeCalls, 0);
    },
  );

  test(
    'reset-required consume failure stays outcome-unknown without PCS pause',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      final identity = _submissionIdentity(operation.operationId);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
        protectedProofReference: operation.encryptedPayloadReference,
      );
      bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
        handle: _FakePreparedHandle(),
        handleBindingSha256: _preparedHandleBindingSha256,
      );
      bindings.consumeResult = frb_api.CloudSyncOutboundConsumeResult(
        outcomes: [
          frb_api.CloudSyncOutboundSaveOutcome(
            localOperationId: operation.operationId,
            appleOperationUuid: identity.operationUuids[operation.operationId]!,
            disposition: frb_api.CloudSyncOutboundSaveDisposition.failed,
            failureClass: frb_api.CloudSyncOutboundFailureClass.resetRequired,
          ),
        ],
      );

      final result = await runV2(() async {
        final prepared = await transport.prepareSubmission(
          scope,
          submissionIdentity: identity,
          operations: [protectedOperation],
        );
        return transport.consumePreparedSubmission(
          scope,
          preparedSubmission: prepared,
          persistedIdentity: identity,
          protectedOperations: [protectedOperation],
          operations: [operation],
        );
      });

      final outcome = result.outcomes.values.single;
      expect(outcome.disposition, CloudPushDisposition.unknownOutcome);
      expect(outcome.failureCategory, CloudFailureCategory.unknown);
      expect(bindings.consumeCalls, 1);
    },
  );

  test(
    'reset-required preflight preserves its safe code and fails closed',
    () async {
      final operation = _writeOperation(scope);
      final protectedOperation = _protectedWriteOperation(operation);
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved,
        failureClass: frb_api.CloudSyncOutboundFailureClass.resetRequired,
        retryAfterSeconds: BigInt.from(41),
      );

      await expectLater(
        runV2(
          () => transport.prepareSubmission(
            scope,
            submissionIdentity: _submissionIdentity(operation.operationId),
            operations: [protectedOperation],
          ),
        ),
        throwsA(
          isA<CloudSyncFailure>()
              .having(
                (failure) => failure.category,
                'category',
                CloudFailureCategory.unknown,
              )
              .having(
                (failure) => failure.retryAfter,
                'retryAfter',
                const Duration(seconds: 41),
              )
              .having(
                (failure) => failure.safeCode,
                'safeCode',
                CloudSyncV2ProtectedTransportSafeFailureCodes
                    .cloudKitResetRequired,
              ),
        ),
      );
      expect(bindings.reconcileCalls, 1);
      expect(bindings.prepareCalls, 0);
    },
  );
}

CloudOutboxOperation _chatOperation(
  CloudSyncScope scope, {
  String? logical,
  CloudOutboxStatus status = CloudOutboxStatus.unknownOutcome,
}) {
  final key = logical ?? _hash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: key,
      payloadVersion: cloudSyncOutboundChatPayloadVersion,
    ),
    logicalEntityKeyHash: key,
    action: CloudOutboxAction.save,
    payloadVersion: cloudSyncOutboundChatPayloadVersion,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: _reference('P'),
    payloadSha256: _sha('b'),
    serverRecordIdHash: _hash('S'),
    protectedLeaseReference: _lease('a'),
    appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
    dependencyOperationIds: const {},
    createdAt: DateTime.utc(2026, 9, 5),
    status: status,
    attemptCount: 1,
  );
}

final class _FakeCloudChat implements frb_api.CloudChat {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ChatBindings extends _FakeBindings
    implements
        NativeProtectedCloudSyncChatWriteBindings,
        CloudKitWriterChatReconciliationBinding {
  int chatStageCalls = 0, chatPrepareCalls = 0, chatReconcileCalls = 0;
  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundChat({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudChat chat,
  }) async {
    chatStageCalls++;
    return stageResult;
  }

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareChatCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) async {
    chatPrepareCalls++;
    preparedRequestUuid = requestUuid;
    preparedInputs = [...inputs];
    return prepareResult;
  }

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileChatCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    chatReconcileCalls++;
    reconcileCloudMessagesClient = cloudMessagesClient;
    reconcileStorageDirectory = storageDirectory;
    reconcileExpectedAccountFingerprint = expectedAccountFingerprint;
    reconcileExpectedProtectedStoreIdentity = expectedProtectedStoreIdentity;
    reconcileRequestUuid = requestUuid;
    reconcileInput = input;
    return reconcileResult;
  }
}

/// Attachment-v1 operation helper. The operation id always comes from the
/// real [CloudOperationIdentity.forInitialCreate] generator at attachment
/// payload version 1 (never a hand-made hex string); mismatched-identity
/// cases bind the id to a different logical key via [operationIdFor].
CloudOutboxOperation _attachmentOperation(
  CloudSyncScope scope, {
  String? logical,
  CloudOutboxStatus status = CloudOutboxStatus.unknownOutcome,
  CloudOutboxAction action = CloudOutboxAction.save,
  int payloadVersion = 1,
  String? operationIdFor,
}) {
  final key = logical ?? _hash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: operationIdFor ?? key,
      payloadVersion: payloadVersion,
    ),
    logicalEntityKeyHash: key,
    action: action,
    payloadVersion: payloadVersion,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: _reference('P'),
    payloadSha256: _sha('b'),
    serverRecordIdHash: _hash('S'),
    protectedLeaseReference: _lease('a'),
    appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
    dependencyOperationIds: const {},
    createdAt: DateTime.utc(2026, 9, 5),
    status: status,
    attemptCount: 1,
  );
}

final class _AttachmentBindings extends _FakeBindings
    implements NativeProtectedCloudSyncAttachmentWriteBindings {
  int attachmentPrepareCalls = 0, attachmentReconcileCalls = 0;
  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareAttachmentCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) async {
    attachmentPrepareCalls++;
    preparedRequestUuid = requestUuid;
    preparedInputs = [...inputs];
    return prepareResult;
  }

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileAttachmentCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    attachmentReconcileCalls++;
    reconcileCloudMessagesClient = cloudMessagesClient;
    reconcileStorageDirectory = storageDirectory;
    reconcileExpectedAccountFingerprint = expectedAccountFingerprint;
    reconcileExpectedProtectedStoreIdentity = expectedProtectedStoreIdentity;
    reconcileRequestUuid = requestUuid;
    reconcileInput = input;
    return reconcileResult;
  }
}

CloudOutboxOperation _writeOperation(CloudSyncScope scope) {
  final logicalEntityKeyHash = _hash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: logicalEntityKeyHash,
      payloadVersion: cloudSyncOutboundPayloadVersion,
    ),
    logicalEntityKeyHash: logicalEntityKeyHash,
    action: CloudOutboxAction.save,
    payloadVersion: cloudSyncOutboundPayloadVersion,
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
          payloadVersion: cloudSyncOutboundPayloadVersion,
        ),
    logicalEntityKeyHash: logicalEntityKeyHash,
    action: action,
    payloadVersion: cloudSyncOutboundPayloadVersion,
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
  CloudSyncScope scope, {
  String expectedStorageDirectory = 'private-storage',
}) {
  expect(bindings.reconcileCalls, 1);
  expect(bindings.reconcileCloudMessagesClient, isNotNull);
  expect(bindings.reconcileStorageDirectory, expectedStorageDirectory);
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
final String _preparedHandleBindingSha256 = _sha('a');

CloudSyncScope _semanticScope({String zone = 'messageManateeZone'}) =>
    CloudSyncScope(
      accountFingerprint: _hash('A'),
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: zone,
      streamKind: CloudSyncStreamKind.messages,
      schemaVersion: 2,
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );

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

final class _MutationAuthBinding implements CloudSyncNativeAuthBinding {
  const _MutationAuthBinding({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    this.beforeCapture,
  });

  final String accountFingerprint;
  final String protectedStoreIdentity;
  final Future<void> Function()? beforeCapture;

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
  }) async {
    await beforeCapture?.call();
    return CloudSyncNativeAuthMetadata(
      nativeSessionId: _hash('N'),
      accountFingerprint: accountFingerprint,
      protectedStoreIdentity: protectedStoreIdentity,
    );
  }
}

final class _FakeBindings
    implements
        NativeProtectedCloudSyncBindings,
        NativeProtectedCloudSyncWriteBindings,
        CloudKitWriterReconciliationBinding {
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
  BigInt? nativeWriterPauseToken;
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
  int unboundFetchCalls = 0;
  int boundFetchCalls = 0;
  int recoveryCalls = 0;
  int garbageCollectionCalls = 0;
  int stageCalls = 0;
  int prepareCalls = 0;
  int consumeCalls = 0;
  int reconcileCalls = 0;
  int rollbackCalls = 0;
  String? consumedMutationCapabilityToken;
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
    unboundFetchCalls++;
    this.expectedAccountFingerprint = expectedAccountFingerprint;
    nativeWriterPauseToken = null;
    this.stream = stream;
    this.previousCheckpointReference = previousCheckpointReference;
    this.maximumChanges = maximumChanges;
    return fetchResult;
  }

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
  }) async {
    await _before('fetch');
    boundFetchCalls++;
    this.expectedAccountFingerprint = expectedAccountFingerprint;
    this.nativeWriterPauseToken = nativeWriterPauseToken;
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
    await _before('prepareOutbound');
    prepareCalls++;
    preparedRequestUuid = requestUuid;
    preparedInputs = [...inputs];
    return prepareResult;
  }

  @override
  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  }) async {
    consumeCalls++;
    consumedMutationCapabilityToken = mutationCapabilityToken;
    await _before('consumeOutbound');
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
    rollbackCalls++;
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
