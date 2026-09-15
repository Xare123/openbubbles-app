import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_protected_page_lease_lifecycle.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

final _identity = 'obcs2.store.${'A' * 43}';
String _lease(int index) =>
    'obcs2.lease.${index.toRadixString(16).padLeft(32, '0')}';

CloudSyncLocalMutationSourceBinding _source(int index, {String? store}) =>
    CloudSyncLocalMutationSourceBinding(
      accountFingerprint: 'A' * 43,
      protectedStoreIdentity: store ?? _identity,
      mutationGuidHash: index.toRadixString(16).padLeft(64, '0'),
      targetGuidHash: 'f' * 64,
      targetPart: 0,
      sourceSha256: 'b' * 64,
      protectedReference: 'obcs2.ref.${index.toString().padLeft(43, 'A')}',
      leaseReference: _lease(index),
      payloadSha256: 'c' * 64,
      payloadLength: 123,
    );

CloudProtectedMutationLeaseRepairClaim _claim(int index, {String? store}) =>
    CloudProtectedMutationLeaseRepairClaim(
      source: _source(index, store: store),
    );

CloudSyncLocalMutationIntentEntity _row(int index, int state) {
  final source = _source(index);
  return CloudSyncLocalMutationIntentEntity(
    intentKey: sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-local-mutation-intent-v1',
              source.accountFingerprint,
              source.mutationGuidHash,
            ]),
          ),
        )
        .toString(),
    accountFingerprint: source.accountFingerprint,
    writerEpoch: 1,
    localMessageId: index + 1,
    localChatId: 1,
    mutationGuidHash: source.mutationGuidHash,
    targetGuidHash: source.targetGuidHash,
    targetPart: source.targetPart,
    kind: index % 2,
    sourceSha256: source.sourceSha256,
    targetSnapshotSha256: 'd' * 64,
    protectedSourceBinding: source.encode(),
    state: state,
    submissionAuthBindingSha256: state >= 1 ? 'e' * 64 : null,
    idsReceiptBindingSha256: state >= 2 ? 'e' * 64 : null,
    reflectedSnapshotSha256: state >= 3 ? 'e' * 64 : null,
    admittedOperationId: state >= 4 ? 'op1:${'e' * 64}' : null,
    admittedBindingSha256: state >= 4 ? 'e' * 64 : null,
    createdAtMs: 1,
    updatedAtMs: 2,
  );
}

final _missing = throwsA(
  isA<CloudSyncFailure>().having(
    (failure) => failure.safeCode,
    'safeCode',
    'protected_outbound_lease_missing',
  ),
);

void main() {
  setUp(CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests);
  tearDown(CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests);

  group('strict local receipt repair', () {
    late _ClaimStore store;
    late _RepairTransport transport;
    late CloudProtectedPageLeaseLifecycle lifecycle;
    setUp(() {
      store = _ClaimStore();
      transport = _RepairTransport();
      lifecycle = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: transport,
      );
    });

    test(
      'success reruns exact recovery and never acknowledges outbound owners',
      () async {
        await lifecycle.ensureRecoveredBeforeWrite();
        expect(transport.recoverySets, [
          {_lease(1)},
          {_lease(1)},
        ]);
        expect(transport.repairs.single.source.encode(), _source(1).encode());
        expect(store.requests.single, {_lease(1)});
        expect(store.outbound, {_lease(1)});
        expect(transport.otherCalls, isEmpty);
      },
    );

    test(
      'fetch never obtains claims or repairs, even with both capabilities',
      () async {
        await lifecycle.ensureRecoveredBeforeFetch();
        expect(store.requests, isEmpty);
        expect(transport.repairs, isEmpty);
        expect(store.outbound, {_lease(1)});
        await lifecycle.ensureRecoveredBeforeWrite();
        expect(transport.repairs, hasLength(1));
        expect(transport.recoverySets, hasLength(3));
      },
    );

    for (final scenario in [
      'uncovered',
      'duplicate',
      'wrong lease',
      'wrong store',
      'not live',
      'store failure',
    ]) {
      test('$scenario is rejected before any metadata repair', () async {
        switch (scenario) {
          case 'uncovered':
            store.claims = [];
          case 'duplicate':
            store.outbound.add(_lease(2));
            store.claims = [_claim(1), _claim(1)];
          case 'wrong lease':
            store.claims = [_claim(2)];
          case 'wrong store':
            store.claims = [_claim(1, store: 'obcs2.store.${'B' * 43}')];
          case 'not live':
            store.live.clear();
          case 'store failure':
            store.fail = true;
        }
        await expectLater(lifecycle.ensureRecoveredBeforeWrite(), _missing);
        expect(transport.repairs, isEmpty);
        expect(store.outbound, contains(_lease(1)));
      });
    }

    test('repair failure preserves original code and owners', () async {
      transport.fail = true;
      await expectLater(lifecycle.ensureRecoveredBeforeWrite(), _missing);
      expect(transport.repairs, hasLength(1));
      expect(transport.recoverySets, hasLength(1));
      expect(store.outbound, {_lease(1)});
      expect(transport.otherCalls, isEmpty);
    });

    test(
      'successful call with receipt still absent is tried only once',
      () async {
        transport.leaveAbsent = true;
        await expectLater(lifecycle.ensureRecoveredBeforeWrite(), _missing);
        expect(transport.repairs, hasLength(1));
        expect(transport.recoverySets, hasLength(2));
        expect(store.requests, hasLength(1));
      },
    );

    test('rerun must explicitly finalize repaired leases', () async {
      transport.omitRepaired = true;
      await expectLater(lifecycle.ensureRecoveredBeforeWrite(), _missing);
      expect(transport.repairs, hasLength(1));
      expect(transport.recoverySets, hasLength(2));
      expect(store.outbound, {_lease(1)});
    });

    test(
      'multiple exact claims are each repaired once in a single round',
      () async {
        store.outbound.add(_lease(2));
        store.live.add(_source(2).protectedReference);
        store.claims.add(_claim(2));
        await lifecycle.ensureRecoveredBeforeWrite();
        expect(transport.repairs.map((claim) => claim.source.leaseReference), [
          _lease(1),
          _lease(2),
        ]);
        expect(transport.recoverySets, hasLength(2));
        expect(store.requests, hasLength(1));
        expect(transport.otherCalls, isEmpty);
      },
    );

    test('missing optional transport fails closed', () async {
      final unsupported = _RecoveryOnlyTransport();
      await expectLater(
        CloudProtectedPageLeaseLifecycle(
          store: store,
          transport: unsupported,
        ).ensureRecoveredBeforeWrite(),
        _missing,
      );
      expect(store.requests, isEmpty);
    });

    test('missing optional store fails closed', () async {
      await expectLater(
        CloudProtectedPageLeaseLifecycle(
          store: _NoClaimStore(),
          transport: transport,
        ).ensureRecoveredBeforeWrite(),
        _missing,
      );
      expect(transport.repairs, isEmpty);
    });
  });

  group('ObjectBox exact claims', () {
    late Directory directory;
    late Store db;
    late ObjectBoxCloudSyncStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'ob-mutation-receipt-test-',
      );
      db = await openStore(directory: directory.path);
      store = ObjectBoxCloudSyncStore(store: db, protector: _UnusedProtector());
    });
    tearDown(() {
      db.close();
      directory.deleteSync(recursive: true);
    });

    test('valid states 0-4 only, exact subset and immutable results', () async {
      for (var state = 0; state <= 5; state++) {
        final row = _row(state + 1, state);
        row.id = db.box<CloudSyncLocalMutationIntentEntity>().put(row);
        validateCloudSyncMutationRow(row);
      }
      final claims = await store.readProtectedMutationLeaseRepairClaims({
        for (var i = 1; i <= 6; i++) _lease(i),
      }, maximumCount: 6);
      expect(claims.map((claim) => claim.source.encode()), [
        for (var i = 1; i <= 5; i++) _source(i).encode(),
      ]);
      expect(() => claims.clear(), throwsUnsupportedError);
      final subset = await store.readProtectedMutationLeaseRepairClaims({
        _lease(3),
        _lease(99),
      }, maximumCount: 6);
      expect(subset.single.source.encode(), _source(3).encode());
    });

    for (final scenario in [
      'binding mismatch',
      'bad state',
      'bad receipt',
      'non-mutation',
      'duplicate lease',
      'duplicate reference',
    ]) {
      test('$scenario fails validation', () async {
        final first = _row(1, 1);
        db.box<CloudSyncLocalMutationIntentEntity>().put(first);
        final row = _row(2, 1);
        switch (scenario) {
          case 'binding mismatch':
            row.sourceSha256 = 'f' * 64;
          case 'bad state':
            row.state = 6;
          case 'bad receipt':
            row.idsReceiptBindingSha256 = 'a' * 64;
          case 'non-mutation':
            row.protectedSourceBinding = row.protectedSourceBinding
                .replaceFirst('idsMutationSource', 'idsMessageSource');
          case 'duplicate lease':
            row.protectedSourceBinding = row.protectedSourceBinding
                .replaceFirst(_lease(2), _lease(1));
          case 'duplicate reference':
            row.protectedSourceBinding = row.protectedSourceBinding
                .replaceFirst(
                  _source(2).protectedReference,
                  _source(1).protectedReference,
                );
        }
        db.box<CloudSyncLocalMutationIntentEntity>().put(row);
        await expectLater(
          store.readProtectedMutationLeaseRepairClaims({
            _lease(1),
            _lease(2),
          }, maximumCount: 4),
          throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())),
        );
      });
    }

    test('request and candidate bounds fail, not silently truncate', () async {
      for (final maximum in [0, -1, 4097]) {
        await expectLater(
          store.readProtectedMutationLeaseRepairClaims({
            _lease(1),
          }, maximumCount: maximum),
          throwsArgumentError,
        );
      }
      await expectLater(
        store.readProtectedMutationLeaseRepairClaims({
          _lease(1),
          _lease(2),
        }, maximumCount: 1),
        throwsArgumentError,
      );
      await expectLater(
        store.readProtectedMutationLeaseRepairClaims({
          'invalid',
        }, maximumCount: 1),
        throwsArgumentError,
      );
      db.box<CloudSyncLocalMutationIntentEntity>().putMany([
        _row(1, 1),
        _row(2, 3),
      ]);
      await expectLater(
        store.readProtectedMutationLeaseRepairClaims({
          _lease(1),
        }, maximumCount: 1),
        throwsA(isA<CloudSyncFailure>()),
      );
    });

    test(
      'state-1 recovery leaves durable state and receipt unchanged without send',
      () async {
        final id = db.box<CloudSyncLocalMutationIntentEntity>().put(_row(1, 1));
        final transport = _RepairTransport();
        await CloudProtectedPageLeaseLifecycle(
          store: store,
          transport: transport,
        ).ensureRecoveredBeforeWrite();
        final row = db.box<CloudSyncLocalMutationIntentEntity>().get(id)!;
        expect(row.state, 1);
        expect(row.idsReceiptBindingSha256, isNull);
        expect(row.admittedOperationId, isNull);
        expect(row.protectedSourceBinding, _source(1).encode());
        expect(db.box<CloudOutboxOperationEntity>().count(), 0);
        expect(
          await store.readLiveProtectedOutboundLeaseReferences(
            maximumCount: 10,
          ),
          {_lease(1)},
        );
        expect(transport.recoverySets, hasLength(2));
        expect(transport.otherCalls, isEmpty);
      },
    );
  });
}

class _NoClaimStore
    implements
        CloudProtectedPageLeaseAdoptionStore,
        CloudProtectedOutboundLeaseAdoptionStore {
  final outbound = {_lease(1)};
  final live = {_source(1).protectedReference};
  @override
  Future<Set<String>> readAdoptedProtectedPageLeaseReferences({
    required int maximumCount,
  }) async => {};
  @override
  Future<Set<String>> readLiveProtectedOutboundLeaseReferences({
    required int maximumCount,
  }) async => Set.unmodifiable(outbound);
  @override
  Future<CloudProtectedReferenceSnapshot> readLiveProtectedReferences({
    required int maximumCount,
  }) async =>
      CloudProtectedReferenceSnapshot(references: live, isComplete: true);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected store mutation');
}

class _ClaimStore extends _NoClaimStore
    implements CloudProtectedMutationLeaseRepairStore {
  List<CloudProtectedMutationLeaseRepairClaim> claims = [_claim(1)];
  final requests = <Set<String>>[];
  bool fail = false;
  @override
  Future<List<CloudProtectedMutationLeaseRepairClaim>>
  readProtectedMutationLeaseRepairClaims(
    Set<String> missingLeaseReferences, {
    required int maximumCount,
  }) async {
    requests.add(missingLeaseReferences);
    if (fail) throw StateError('injected store failure');
    return claims;
  }
}

class _RecoveryOnlyTransport implements CloudProtectedPageLeaseTransport {
  final recoverySets = <Set<String>>[];
  final otherCalls = <Symbol>[];
  final repaired = <String>{};
  bool omitRepaired = false;
  @override
  String get protectedPageLeaseRecoveryIdentity => _identity;
  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  Future<CloudProtectedPageLeaseRecoveryResult> recoverProtectedPageLeases(
    Set<String> adoptedLeaseReferences,
    CloudProtectedReferenceSnapshot liveReferences,
  ) async {
    recoverySets.add(adoptedLeaseReferences);
    return CloudProtectedPageLeaseRecoveryResult(
      finalizedAdoptedLeaseReferences: omitRepaired
          ? const <String>{}
          : adoptedLeaseReferences.intersection(repaired),
      absentAdoptedLeaseReferences: adoptedLeaseReferences.difference(repaired),
      rolledBackCount: 0,
      removedTemporaryFilesCount: 0,
      hasMore: false,
    );
  }

  // Any accidental send, acknowledge, rollback, GC or other behavior fails.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    otherCalls.add(invocation.memberName);
    throw StateError('unexpected transport operation');
  }
}

class _RepairTransport extends _RecoveryOnlyTransport
    implements CloudProtectedMutationLeaseRepairTransport {
  final repairs = <CloudProtectedMutationLeaseRepairClaim>[];
  bool fail = false;
  bool leaveAbsent = false;
  @override
  Future<void> repairProtectedMutationLeaseReceipt(
    CloudProtectedMutationLeaseRepairClaim claim,
  ) async {
    repairs.add(claim);
    if (fail) throw StateError('injected repair failure');
    if (!leaveAbsent) repaired.add(claim.source.leaseReference);
  }
}

class _UnusedProtector implements CloudSyncProtector {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected protector call');
}
