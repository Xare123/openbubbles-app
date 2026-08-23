import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

const _leaseA = 'obcs2.lease.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _leaseB = 'obcs2.lease.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _storeIdentity =
    'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  late List<String> timeline;
  late _AdoptionStore store;
  late _LeaseTransport transport;
  late CloudProtectedPageLeaseLifecycle lifecycle;

  setUp(() {
    CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests();
    timeline = [];
    store = _AdoptionStore({_leaseA, _leaseB}, timeline: timeline);
    transport = _LeaseTransport(timeline: timeline);
    lifecycle = CloudProtectedPageLeaseLifecycle(
      store: store,
      transport: transport,
    );
  });

  tearDown(CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests);

  test(
    'startup recovery supplies the complete set before releasing markers',
    () async {
      await lifecycle.ensureRecoveredBeforeFetch();

      expect(transport.recoverySets, [
        {_leaseA, _leaseB},
      ]);
      expect(store.adopted, isEmpty);
      expect(store.events, [
        'read',
        'read-live',
        'release:${[_leaseA, _leaseB].join(',')}',
      ]);
    },
  );

  test('failed startup recovery retains markers and may retry', () async {
    transport.recoveryFailuresRemaining = 1;

    await expectLater(
      lifecycle.ensureRecoveredBeforeFetch(),
      throwsA(isA<StateError>()),
    );
    expect(store.adopted, {_leaseA, _leaseB});

    await lifecycle.ensureRecoveredBeforeFetch();
    expect(transport.recoverySets, [
      {_leaseA, _leaseB},
      {_leaseA, _leaseB},
    ]);
    expect(store.adopted, isEmpty);
  });

  test(
    'separate wrappers for one native store share process recovery',
    () async {
      final secondTransport = _LeaseTransport(timeline: timeline);
      final secondLifecycle = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: secondTransport,
      );

      await Future.wait([
        lifecycle.ensureRecoveredBeforeFetch(),
        secondLifecycle.ensureRecoveredBeforeFetch(),
      ]);

      expect(transport.recoverySets, hasLength(1));
      expect(secondTransport.recoverySets, isEmpty);
    },
  );

  test(
    'recovery beyond one native page releases only finalized leases',
    () async {
      final leases = {
        for (var index = 0; index < 65; index++)
          'obcs2.lease.${index.toRadixString(16).padLeft(32, '0')}',
      };
      store = _AdoptionStore(leases, timeline: timeline);
      transport = _LeaseTransport(timeline: timeline)
        ..maximumRecoveryPageSize = 64;
      lifecycle = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: transport,
      );

      await lifecycle.ensureRecoveredBeforeFetch();

      expect(transport.recoverySets, hasLength(2));
      expect(transport.recoverySets.first, hasLength(65));
      expect(transport.recoverySets.last, hasLength(1));
      expect(store.adopted, isEmpty);
    },
  );

  test(
    'stale marker is released only when native reports its manifest absent',
    () async {
      transport.absentRecoveryReferences.add(_leaseA);

      await lifecycle.ensureRecoveredBeforeFetch();

      expect(store.adopted, isEmpty);
      expect(transport.recoverySets, [
        {_leaseA, _leaseB},
      ]);
    },
  );

  test(
    'outbound receipts participate in recovery but page cleanup never acknowledges them',
    () async {
      store = _AdoptionStore(
        {_leaseA},
        outboundAdopted: {_leaseB},
        timeline: timeline,
      );
      lifecycle = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: transport,
      );

      await lifecycle.ensureRecoveredBeforeFetch();

      expect(transport.recoverySets.single, {_leaseA, _leaseB});
      expect(store.adopted, isEmpty);
      expect(store.outboundAdopted, {_leaseB});
      expect(transport.events.where((event) => event.startsWith('ack:')), [
        'ack:$_leaseA',
      ]);
    },
  );

  test(
    'missing outbound receipt fails closed without releasing adoption',
    () async {
      store = _AdoptionStore(
        const {},
        outboundAdopted: {_leaseB},
        timeline: timeline,
      );
      transport.absentRecoveryReferences.add(_leaseB);
      lifecycle = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: transport,
      );

      await expectLater(
        lifecycle.ensureRecoveredBeforeFetch(),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'protected_outbound_lease_missing',
          ),
        ),
      );
      expect(store.outboundAdopted, {_leaseB});
      expect(
        transport.events.where((event) => event.startsWith('ack:')),
        isEmpty,
      );
    },
  );

  test(
    'page and outbound lease namespace collision fails before native recovery',
    () async {
      store = _AdoptionStore(
        {_leaseA},
        outboundAdopted: {_leaseA},
        timeline: timeline,
      );
      lifecycle = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: transport,
      );

      await expectLater(
        lifecycle.ensureRecoveredBeforeFetch(),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'protected_lease_namespace_collision',
          ),
        ),
      );
      expect(transport.recoverySets, isEmpty);
      expect(store.adopted, {_leaseA});
      expect(store.outboundAdopted, {_leaseA});
    },
  );

  test(
    'rolling back more than one page of unadopted manifests is progress',
    () async {
      store = _AdoptionStore({}, timeline: timeline);
      transport = _LeaseTransport(timeline: timeline)
        ..maximumRecoveryPageSize = 64
        ..unadoptedManifestsRemaining = 65;
      lifecycle = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: transport,
      );

      await lifecycle.ensureRecoveredBeforeFetch();

      expect(transport.recoverySets, hasLength(2));
      expect(transport.unadoptedManifestsRemaining, 0);
    },
  );

  test(
    'removing more than one native page of temporary files is progress',
    () async {
      store = _AdoptionStore({}, timeline: timeline);
      transport = _LeaseTransport(timeline: timeline)
        ..maximumRecoveryPageSize = 64
        ..temporaryFilesRemaining = 65;
      lifecycle = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: transport,
      );

      await lifecycle.ensureRecoveredBeforeFetch();

      expect(transport.recoverySets, hasLength(2));
      expect(transport.temporaryFilesRemaining, 0);
    },
  );

  test('journaled page releases adoption only after native commit', () async {
    store.adopted
      ..clear()
      ..add(_leaseA);

    await lifecycle.commitJournaledPage(
      _batch(_leaseA),
      previousCheckpointReference: null,
    );

    expect(transport.events, ['commit:$_leaseA:', 'ack:$_leaseA']);
    expect(store.adopted, isEmpty);
  });

  test('failed native commit retains the durable adoption marker', () async {
    store.adopted
      ..clear()
      ..add(_leaseA);
    transport.commitFailure = StateError('commit failed');

    await expectLater(
      lifecycle.commitJournaledPage(
        _batch(_leaseA),
        previousCheckpointReference: null,
      ),
      throwsA(isA<StateError>()),
    );

    expect(store.adopted, {_leaseA});
  });

  test(
    'commit failure invalidates a completed process recovery for retry',
    () async {
      await lifecycle.ensureRecoveredBeforeFetch();
      store.adopted.add(_leaseA);
      transport.commitFailure = StateError('commit failed');

      await expectLater(
        lifecycle.commitJournaledPage(
          _batch(_leaseA),
          previousCheckpointReference: null,
        ),
        throwsA(isA<StateError>()),
      );

      transport.commitFailure = null;
      await lifecycle.ensureRecoveredBeforeFetch();
      expect(transport.recoverySets, hasLength(2));
      expect(transport.recoverySets.last, {_leaseA});
      expect(store.adopted, isEmpty);
    },
  );

  test(
    'unjournaled page rolls back without touching adoption markers',
    () async {
      await lifecycle.rollbackUnjournaledPage(_batch(_leaseA));

      expect(transport.events, ['rollback:$_leaseA']);
      expect(store.adopted, {_leaseA, _leaseB});
    },
  );

  test(
    'all-duplicate page retains only the newly committed checkpoint',
    () async {
      final duplicateA = _reference('A');
      final duplicateB = _reference('B');
      final duplicateC = _reference('C');
      final nextCheckpoint = _reference('N');
      store.adopted
        ..clear()
        ..add(_leaseA);
      store.liveReferences = {nextCheckpoint};

      await lifecycle.commitJournaledPage(
        _batch(
          _leaseA,
          changes: [
            _change(
              serverReference: duplicateA,
              systemFieldsReference: duplicateB,
              payloadReference: duplicateC,
            ),
          ],
          nextToken: nextCheckpoint,
        ),
        previousCheckpointReference: _reference('O'),
      );

      expect(transport.retainedSets.single, {nextCheckpoint});
    },
  );

  test(
    'mixed duplicate and new page retains only ObjectBox-live page references',
    () async {
      final duplicate = [_reference('A'), _reference('B'), _reference('C')];
      final inserted = [_reference('D'), _reference('E'), _reference('F')];
      final nextCheckpoint = _reference('N');
      store.adopted
        ..clear()
        ..add(_leaseA);
      store.liveReferences = {...inserted, nextCheckpoint};

      await lifecycle.commitJournaledPage(
        _batch(
          _leaseA,
          changes: [
            _change(
              serverReference: duplicate[0],
              systemFieldsReference: duplicate[1],
              payloadReference: duplicate[2],
            ),
            _change(
              changeId: 'new-change',
              serverReference: inserted[0],
              systemFieldsReference: inserted[1],
              payloadReference: inserted[2],
            ),
          ],
          nextToken: nextCheckpoint,
        ),
        previousCheckpointReference: null,
      );

      expect(transport.retainedSets.single, {...inserted, nextCheckpoint});
    },
  );

  test(
    'checkpoint replacement retires the prior capability after commit and marker release',
    () async {
      final oldCheckpoint = _reference('O');
      final nextCheckpoint = _reference('N');
      store.adopted
        ..clear()
        ..add(_leaseA);
      store.liveReferences = {nextCheckpoint};

      await lifecycle.commitJournaledPage(
        _batch(_leaseA, nextToken: nextCheckpoint),
        previousCheckpointReference: oldCheckpoint,
      );

      expect(
        timeline.where(
          (event) =>
              event.startsWith('commit:') ||
              event.startsWith('release:') ||
              event.startsWith('ack:') ||
              event.startsWith('retire:'),
        ),
        [
          'commit:$_leaseA:$nextCheckpoint',
          'release:$_leaseA',
          'ack:$_leaseA',
          'retire:$oldCheckpoint',
        ],
      );
    },
  );

  test(
    'marker-release failure invalidates cached recovery in the same process',
    () async {
      store.adopted.clear();
      await lifecycle.ensureRecoveredBeforeFetch();
      store.adopted.add(_leaseA);
      store.releaseFailuresRemaining = 1;

      await expectLater(
        lifecycle.commitJournaledPage(
          _batch(_leaseA),
          previousCheckpointReference: null,
        ),
        throwsA(isA<StateError>()),
      );
      expect(store.adopted, {_leaseA});
      expect(transport.retainedSets, [<String>{}]);

      await lifecycle.ensureRecoveredBeforeFetch();

      expect(store.adopted, isEmpty);
      expect(transport.recoverySets.last, {_leaseA});
    },
  );

  test(
    'failed receipt acknowledgement schedules bounded cleanup in the same process',
    () async {
      store.adopted.clear();
      await lifecycle.ensureRecoveredBeforeFetch();
      store.adopted.add(_leaseA);
      transport.acknowledgementFailuresRemaining = 1;

      await lifecycle.commitJournaledPage(
        _batch(_leaseA),
        previousCheckpointReference: null,
      );
      expect(store.adopted, isEmpty);
      expect(transport.recoverySets, [<String>{}]);

      await lifecycle.ensureRecoveredBeforeFetch();

      expect(transport.recoverySets, [<String>{}, <String>{}]);
    },
  );

  test(
    'incomplete live-reference enumeration fails closed before commit or GC',
    () async {
      store.adopted
        ..clear()
        ..add(_leaseA);
      store.liveComplete = false;

      await expectLater(
        lifecycle.commitJournaledPage(
          _batch(_leaseA),
          previousCheckpointReference: null,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'protected_reference_enumeration_incomplete',
          ),
        ),
      );
      await expectLater(
        lifecycle.collectOneProtectedGarbagePage(),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(transport.retainedSets, isEmpty);
      expect(transport.garbageCollectionCalls, 0);
      expect(store.adopted, {_leaseA});
    },
  );
}

CloudFetchBatch _batch(
  String leaseReference, {
  Iterable<CloudFetchedChange> changes = const [],
  String? nextToken,
}) {
  return CloudFetchBatch(
    scope: CloudSyncScope(
      accountFingerprint: List.filled(43, 'A').join(),
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'messageManateeZone',
      streamKind: CloudSyncStreamKind.messages,
      schemaVersion: 2,
    ),
    changes: changes,
    batchId: 'batch',
    generation: 1,
    nextToken: nextToken,
    hasMore: false,
    protectedPageLeaseReference: leaseReference,
  );
}

CloudFetchedChange _change({
  String changeId = 'change',
  required String serverReference,
  required String systemFieldsReference,
  required String payloadReference,
}) {
  return CloudFetchedChange(
    changeId: changeId,
    recordIdHash: List.filled(43, 'R').join(),
    type: CloudChangeType.save,
    encryptedServerRecordId: serverReference,
    protectedSystemFieldsReference: systemFieldsReference,
    encryptedPayloadReference: payloadReference,
    payloadSha256: List.filled(64, 'a').join(),
  );
}

String _reference(String character) =>
    'obcs2.ref.${List.filled(43, character).join()}';

final class _AdoptionStore
    implements
        CloudProtectedPageLeaseAdoptionStore,
        CloudProtectedOutboundLeaseAdoptionStore {
  _AdoptionStore(
    Set<String> adopted, {
    Set<String> outboundAdopted = const {},
    required this.timeline,
  }) : adopted = {...adopted},
       outboundAdopted = {...outboundAdopted};

  final Set<String> adopted;
  final Set<String> outboundAdopted;
  final List<String> timeline;
  final List<String> events = [];
  Set<String> liveReferences = {};
  bool liveComplete = true;
  int releaseFailuresRemaining = 0;

  @override
  Future<Set<String>> readAdoptedProtectedPageLeaseReferences({
    required int maximumCount,
  }) async {
    events.add('read');
    timeline.add('read-adopted');
    if (adopted.length > maximumCount) throw StateError('bounded');
    return Set.unmodifiable(adopted);
  }

  @override
  Future<Set<String>> readNonterminalProtectedOutboundLeaseReferences({
    required int maximumCount,
  }) async {
    if (outboundAdopted.length > maximumCount) throw StateError('bounded');
    return Set.unmodifiable(outboundAdopted);
  }

  @override
  Future<CloudProtectedReferenceSnapshot> readLiveProtectedReferences({
    required int maximumCount,
  }) async {
    events.add('read-live');
    timeline.add('read-live');
    if (liveReferences.length > maximumCount) {
      return CloudProtectedReferenceSnapshot(
        references: const [],
        isComplete: false,
      );
    }
    return CloudProtectedReferenceSnapshot(
      references: liveReferences,
      isComplete: liveComplete,
    );
  }

  @override
  Future<void> releaseAdoptedProtectedPageLeaseReferences(
    Iterable<String> leaseReferences,
  ) async {
    final sorted = leaseReferences.toList()..sort();
    events.add('release:${sorted.join(',')}');
    timeline.add('release:${sorted.join(',')}');
    if (releaseFailuresRemaining > 0) {
      releaseFailuresRemaining--;
      throw StateError('release failed');
    }
    adopted.removeAll(sorted);
  }
}

final class _LeaseTransport implements CloudProtectedPageLeaseTransport {
  _LeaseTransport({required this.timeline});

  final List<String> timeline;
  final List<Set<String>> recoverySets = [];
  final List<Set<String>> recoveryLiveSets = [];
  final List<Set<String>> retainedSets = [];
  final List<String> events = [];
  int recoveryFailuresRemaining = 0;
  int maximumRecoveryPageSize = 4096;
  Object? commitFailure;
  Object? rollbackFailure;
  final absentRecoveryReferences = <String>{};
  int unadoptedManifestsRemaining = 0;
  int temporaryFilesRemaining = 0;
  int garbageCollectionCalls = 0;
  int acknowledgementFailuresRemaining = 0;

  @override
  String get protectedPageLeaseRecoveryIdentity => _storeIdentity;

  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      action();

  @override
  Future<CloudProtectedPageLeaseRecoveryResult> recoverProtectedPageLeases(
    Set<String> adoptedLeaseReferences,
    CloudProtectedReferenceSnapshot liveReferences,
  ) async {
    recoverySets.add({...adoptedLeaseReferences});
    recoveryLiveSets.add({...liveReferences.references});
    if (recoveryFailuresRemaining > 0) {
      recoveryFailuresRemaining--;
      throw StateError('recovery failed');
    }
    final absent = adoptedLeaseReferences
        .where(absentRecoveryReferences.contains)
        .toSet();
    final finalized = adoptedLeaseReferences
        .where((reference) => !absent.contains(reference))
        .take(maximumRecoveryPageSize)
        .toSet();
    final rolledBack = unadoptedManifestsRemaining > maximumRecoveryPageSize
        ? maximumRecoveryPageSize
        : unadoptedManifestsRemaining;
    unadoptedManifestsRemaining -= rolledBack;
    final removedTemporaryFiles =
        temporaryFilesRemaining > maximumRecoveryPageSize
        ? maximumRecoveryPageSize
        : temporaryFilesRemaining;
    temporaryFilesRemaining -= removedTemporaryFiles;
    return CloudProtectedPageLeaseRecoveryResult(
      finalizedAdoptedLeaseReferences: finalized,
      absentAdoptedLeaseReferences: absent,
      rolledBackCount: rolledBack,
      removedTemporaryFilesCount: removedTemporaryFiles,
      hasMore:
          adoptedLeaseReferences.length > finalized.length + absent.length ||
          unadoptedManifestsRemaining > 0 ||
          temporaryFilesRemaining > 0,
    );
  }

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> retainedReferences,
  ) async {
    final retained = retainedReferences.toList()..sort();
    retainedSets.add({...retainedReferences});
    events.add('commit:$leaseReference:${retained.join(',')}');
    timeline.add('commit:$leaseReference:${retained.join(',')}');
    final failure = commitFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> acknowledgeCommittedPageLease(String leaseReference) async {
    events.add('ack:$leaseReference');
    timeline.add('ack:$leaseReference');
    if (acknowledgementFailuresRemaining > 0) {
      acknowledgementFailuresRemaining--;
      throw StateError('acknowledgement failed');
    }
  }

  @override
  Future<CloudProtectedGarbageCollectionResult> collectProtectedGarbage(
    CloudProtectedReferenceSnapshot liveReferences,
  ) async {
    garbageCollectionCalls++;
    return const CloudProtectedGarbageCollectionResult(
      scannedCount: 0,
      firstObservedCount: 0,
      deletedCount: 0,
      preservedLiveCount: 0,
      preservedActiveLeaseCount: 0,
      hasMore: false,
    );
  }

  @override
  Future<int> retireProtectedReferences(Set<String> references) async {
    final sorted = references.toList()..sort();
    events.add('retire:${sorted.join(',')}');
    timeline.add('retire:${sorted.join(',')}');
    return references.length;
  }

  @override
  Future<void> rollbackProtectedPageLease(String leaseReference) async {
    events.add('rollback:$leaseReference');
    timeline.add('rollback:$leaseReference');
    final failure = rollbackFailure;
    if (failure != null) throw failure;
  }
}
