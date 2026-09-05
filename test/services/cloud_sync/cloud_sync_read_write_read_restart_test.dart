import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_preflight.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

// Exercises the production sampler, preflight, interlock and durable store.
// Apple and the platform keystore are deliberately synthetic here. This proves
// local read/write/read compatibility, not a successful Apple round trip.
void main() {
  late Directory root;
  late Store box;
  late ObjectBoxCloudSyncStore store;
  final now = DateTime.now().toUtc();
  final client = Object();
  final scope = CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: CloudSyncManualSemanticPullSampler.container,
    database: CloudSyncManualSemanticPullSampler.database,
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final auth = CloudSyncNativeAuthSnapshot.fromNative(
    nativeSessionId: 'test-session',
    accountFingerprint: testAccountFingerprintA,
    protectedStoreIdentity: 'obcs2.store.$testAccountFingerprintA',
    cloudMessagesClient: client,
  );
  var fetches = 0;
  final transports = <FakeCloudSyncTransport>[];

  Future<void> open() async {
    box = await openStore(directory: '${root.path}/db');
    store = ObjectBoxCloudSyncStore(
      store: box,
      protector: const _TestProtector(),
      clock: () => now,
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('obcs-read-write-read-');
    fetches = 0;
    transports.clear();
    await open();
  });
  tearDown(() async {
    if (!box.isClosed()) box.close();
    await root.delete(recursive: true);
  });

  Future<CloudSyncSemanticPullReport> read({void Function()? onFetch}) {
    final preflight = CloudSyncProductionPreflightProbe(
      platformSupported: () => true,
      uiIsolate: () => true,
      rustPushReady: () => true,
      localState: ObjectBoxCloudSyncPreflightReader(store: box).read,
      privateStorageExists: () => true,
      logoutActive: () => false,
      legacySyncEnabled: () => false,
      legacySyncActive: () => false,
      protectorSentinelValid: () => true,
    );
    return CloudSyncManualSemanticPullSampler(
      readPreflight: preflight.read,
      ensureAuthSnapshot: () async => auth,
      prepareAuthSnapshot: (_, __) async => auth,
      readAuthSnapshot: () async => auth,
      createStore: (_) async => store,
      createRawTransport: (_, __, ___) async {
        final transport = FakeCloudSyncTransport();
        transport.fetchHandler = (scope, token, generation, limit) async {
          fetches++;
          onFetch?.call();
          return CloudFetchBatch(
            scope: scope,
            changes: const [],
            batchId: 'empty-$fetches',
            generation: generation,
            nextToken: token,
            hasMore: false,
          );
        };
        transports.add(transport);
        return transport;
      },
      createInboxApplier: (_, __, ___, ____) async => FakeCloudInboxApplier(),
      nativeWriterPause: _TestWriterPause(),
      operationFenceStore: store,
      privateStorageDirectory: root.path,
      platform: 'windows',
      architecture: 'arm64',
      buildCommit: 'read-write-read-test',
      compileGateOverrideForTest: true,
    ).runConfirmed();
  }

  Future<CloudOutboxOperation> confirm() async {
    // The production writer requires all three read checkpoints at head.
    final head = await read();
    expect(head.allZonesObservedEmptyTerminalRead, isTrue);
    const lease = 'synthetic-create-lease';
    const serverHash = 'SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS';
    final fixture = testOutboxOperation(scope, 1, createdAt: now);
    final operation = await store.enqueueOutboxMutation(
      CloudOutboxDraft(
        scope: scope,
        logicalEntityKeyHash: fixture.logicalEntityKeyHash,
        action: CloudOutboxAction.save,
        payloadVersion: cloudSyncOutboundPayloadVersion,
        encryptedPayloadReference: fixture.encryptedPayloadReference,
        payloadSha256: fixture.payloadSha256,
        protectedLeaseReference: fixture.protectedLeaseReference,
        dependencyOperationIds: const [],
        createdAt: now,
      ),
    );
    final leased = await store.leaseEligibleOutbox(
      scope,
      now: now,
      limit: 1,
      leaseId: lease,
      leaseDuration: const Duration(minutes: 5),
      allowedActions: const {CloudOutboxAction.save},
    );
    expect(leased.map((row) => row.operationId), [operation.operationId]);
    await store.upsertRecordMap(
      CloudRecordMapEntry(
        scope: scope,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        serverRecordIdHash: serverHash,
        encryptedServerRecordId: testProtectedReference('S'),
        updatedAt: now,
      ),
      generation: 1,
    );
    await store.attachOutboxRecordMapping(
      scope,
      leaseId: lease,
      operationId: operation.operationId,
      serverRecordIdHash: serverHash,
      now: now,
    );
    await store.markOutboxSubmissionStarted(
      scope,
      leaseId: lease,
      submissionIdentity: testSubmissionIdentity([operation.operationId]),
      now: now,
    );
    await store.commitOutboxCreateReceipt(
      scope,
      leaseId: lease,
      receipt: CloudOutboxCreateReceipt(
        operationId: operation.operationId,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        serverRecordIdHash: serverHash,
        etagHash: 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE',
      ),
      retainProtectedLeaseReference: true,
      now: now,
    );
    return (await store.readOutboxEntries(scope)).single;
  }

  test(
    'read, receipt commit, restart, acknowledge, restart, read twice',
    () async {
      final initial = await read();
      expect(initial.remoteWriteTripwiresIntact, isTrue);
      expect(initial.allZonesObservedEmptyTerminalRead, isTrue);
      final confirmed = await confirm();
      expect(confirmed.status, CloudOutboxStatus.confirmed);
      expect(confirmed.protectedLeaseReference, isNotNull);

      box.close();
      await open();
      final beforeBlocked = fetches;
      await expectLater(
        read(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'outbox_not_empty',
          ),
        ),
      );
      expect(fetches, beforeBlocked);
      // Native exact readback is a separate transport test. Simulate only its
      // durable acknowledgement here, through the real compare-and-swap API.
      await store.clearConfirmedProtectedOutboundLeaseReference(
        expectedOperation: (await store.readOutboxEntries(scope)).single,
      );
      final fingerprint = ObjectBoxCloudSyncPreflightReader(
        store: box,
      ).read().settledOutboxFingerprint;
      expect(fingerprint, isNotNull);
      box.close();
      await open();
      expect(
        ObjectBoxCloudSyncPreflightReader(
          store: box,
        ).read().settledOutboxFingerprint,
        fingerprint,
      );
      for (var repeat = 0; repeat < 2; repeat++) {
        final report = await read();
        expect(report.outboxCountBefore, 1);
        expect(report.outboxCountAfter, 1);
        expect(report.settledOutboxUnchanged, isTrue);
        expect(report.remoteWriteTripwiresIntact, isTrue);
        expect(report.allZonesObservedEmptyTerminalRead, isTrue);
        final retained = (await store.readOutboxEntries(scope)).single;
        expect(retained.operationId, confirmed.operationId);
        expect(retained.status, CloudOutboxStatus.confirmed);
        expect(retained.protectedLeaseReference, isNull);
      }
      expect(
        transports.every((transport) => transport.pushCallCount == 0),
        isTrue,
      );
    },
  );

  test('same-count durable mutation during a read trips the fence', () async {
    final confirmed = await confirm();
    await store.clearConfirmedProtectedOutboundLeaseReference(
      expectedOperation: confirmed,
    );
    await expectLater(
      read(
        onFetch: () {
          final outbox = box.box<CloudOutboxOperationEntity>();
          final row = outbox.getAll().single;
          row.updatedAtMs++;
          outbox.put(row);
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_semantic_remote_write_tripwire',
        ),
      ),
    );
    expect(fetches, greaterThan(0));
    expect(box.box<CloudOutboxOperationEntity>().count(), 1);
    expect(
      transports.every((transport) => transport.pushCallCount == 0),
      isTrue,
    );
  });

  for (final state in [-1, 0, 1, 3, 4, 5, 6, 99]) {
    test('state $state still blocks before any fetch after restart', () async {
      final confirmed = await confirm();
      await store.clearConfirmedProtectedOutboundLeaseReference(
        expectedOperation: confirmed,
      );
      final outbox = box.box<CloudOutboxOperationEntity>();
      final row = outbox.getAll().single..state = state;
      outbox.put(row);
      box.close();
      await open();
      final beforeBlocked = fetches;
      await expectLater(
        read(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'outbox_not_empty',
          ),
        ),
      );
      expect(fetches, beforeBlocked);
    });
  }
}

final class _TestWriterPause implements CloudSyncNativeWriterPause {
  final token = Object();
  @override
  Future<Object> pause() async => token;
  @override
  Future<void> resume(Object value) async => expect(value, same(token));
}

final class _TestProtector implements CloudSyncProtector {
  const _TestProtector();
  @override
  Future<String> fingerprintAccount(String _) async => testAccountFingerprintA;
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => plaintext;
  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => ciphertext;
}
