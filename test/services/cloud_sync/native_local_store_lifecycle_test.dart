import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

const _identity = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _lease = 'obcs2.lease.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _reference = 'obcs2.ref.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  late _Bindings bindings;
  late NativeProtectedCloudSyncTransport transport;

  NativeProtectedCloudSyncTransport create({String directory = 'synthetic'}) =>
      NativeProtectedCloudSyncTransport(
        cloudMessagesClient: Object(),
        storageDirectory: directory,
        protectedStoreIdentity: _identity,
        bindings: bindings,
      );

  setUp(() {
    CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests();
    bindings = _Bindings();
    transport = create();
  });
  tearDown(CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests);

  test(
    'local capture and commit do not wait behind history network gate',
    () async {
      final entered = Completer<void>();
      final finishFetch = Completer<void>();
      final fetch = transport.runProtectedStoreExclusive(() async {
        entered.complete();
        await finishFetch.future;
      });
      await entered.future;
      try {
        await create()
            .runLocalProtectedStoreExclusive(() async {
              await transport.commitProtectedPageLease(_lease, {_reference});
            })
            .timeout(const Duration(seconds: 2));
        expect(bindings.commits, 1);
        expect(bindings.acquisitions, 1);
        expect(bindings.releases, 1);
      } finally {
        finishFetch.complete();
        await fetch;
      }
    },
  );

  test(
    'recovery takes local lease before inventory and retains new capture',
    () async {
      final store = _Inventory(bindings);
      final maintenance = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: create(),
      );
      final staged = Completer<void>();
      final allowAdoption = Completer<void>();
      final receive = transport.runLocalProtectedStoreExclusive(() async {
        staged.complete();
        await allowAdoption.future;
        store.live = {_reference};
        await transport.commitProtectedPageLease(_lease, {_reference});
      });
      await staged.future;
      final recovery = maintenance.ensureRecoveredBeforeWrite();
      await Future<void>.delayed(Duration.zero);
      expect(
        store.reads,
        0,
        reason: 'Inventory must not precede local exclusion',
      );
      allowAdoption.complete();
      await Future.wait([
        receive,
        recovery,
      ]).timeout(const Duration(seconds: 2));
      expect(bindings.recovered, {_reference});
      expect(bindings.releases, 2);
    },
  );

  test(
    'maintenance still waits for a preexisting fetched-page lifecycle',
    () async {
      final store = _Inventory(bindings);
      final maintenance = CloudProtectedPageLeaseLifecycle(
        store: store,
        transport: create(),
      );
      final entered = Completer<void>();
      final finishFetch = Completer<void>();
      final fetch = transport.runProtectedStoreExclusive(() async {
        entered.complete();
        await finishFetch.future;
        store.live = {_reference};
      });
      await entered.future;
      final recovery = maintenance.ensureRecoveredBeforeWrite();
      await Future<void>.delayed(Duration.zero);
      expect(store.reads, 0);
      expect(bindings.acquisitions, 0);
      finishFetch.complete();
      await Future.wait([fetch, recovery]);
      expect(bindings.recovered, {_reference});
    },
  );

  test(
    'local nesting reuses one native lease and rejects other directories',
    () async {
      await transport.runLocalProtectedStoreExclusive(() async {
        await create().runLocalProtectedStoreExclusive(() async {
          await transport.commitProtectedPageLease(_lease, {_reference});
        });
        await expectLater(
          create(directory: 'different').runLocalProtectedStoreExclusive(
            () async => fail('foreign directory entered'),
          ),
          throwsA(isA<CloudSyncFailure>()),
        );
      });
      expect(bindings.acquisitions, 1);
      expect(bindings.releases, 1);
    },
  );

  test('released local scope rejects commit and reacquisition', () async {
    late Zone captured;
    await transport.runLocalProtectedStoreExclusive(() async {
      captured = Zone.current;
    });
    await expectLater(
      captured.run(() => transport.commitProtectedPageLease(_lease, {})),
      throwsA(isA<CloudSyncFailure>()),
    );
    await expectLater(
      captured.run(
        () => transport.runLocalProtectedStoreExclusive(
          () async => fail('expired scope entered'),
        ),
      ),
      throwsA(isA<CloudSyncFailure>()),
    );
    expect(bindings.commits, 0);
    expect(bindings.acquisitions, 1);
  });

  test(
    'quiescence joins explicit local release and closes new admission',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      final action = transport.runLocalProtectedStoreExclusive(() async {
        entered.complete();
        await finish.future;
        await transport.commitProtectedPageLease(_lease, {_reference});
      });
      await entered.future;
      var quiet = false;
      final drain = transport.quiesceNativeOperations().then(
        (_) => quiet = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(quiet, isFalse);
      await expectLater(
        transport.runLocalProtectedStoreExclusive(() async {}),
        throwsA(isA<CloudSyncFailure>()),
      );
      finish.complete();
      await Future.wait([action, drain]);
      expect(bindings.commits, 1);
      expect(bindings.releases, 1);
    },
  );

  test('body failure still releases and a later capture may proceed', () async {
    await expectLater(
      transport.runLocalProtectedStoreExclusive(() async {
        throw StateError('synthetic capture error');
      }),
      throwsStateError,
    );
    await transport.runLocalProtectedStoreExclusive(() async {});
    expect(bindings.releases, 2);
  });

  test(
    'release failure is retained by quiescence, never declared drained',
    () async {
      bindings.failRelease = true;
      await expectLater(
        transport.runLocalProtectedStoreExclusive(() async {}),
        throwsA(isA<CloudSyncFailure>()),
      );
      await expectLater(
        transport.quiesceNativeOperations(),
        throwsA(isA<CloudSyncFailure>()),
      );
      await expectLater(
        transport.runLocalProtectedStoreExclusive(() async {}),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(bindings.acquisitions, 1);
    },
  );
}

// Synthetic serialization only; real cross-isolate/process exclusion is tested
// in Rust's LocalProtectedStoreLease tests, not inferred from this fake.
class _Bindings
    implements
        NativeProtectedCloudSyncBindings,
        NativeProtectedLocalStoreLockBindings {
  Future<void> tail = Future.value();
  bool held = false;
  bool failRelease = false;
  int acquisitions = 0, releases = 0, commits = 0;
  Set<String>? recovered;

  @override
  Future<Object> acquireLocalStoreLease({
    required String storageDirectory,
  }) async {
    final previous = tail;
    final release = Completer<void>();
    tail = release.future;
    await previous;
    expect(held, isFalse);
    held = true;
    acquisitions++;
    return release;
  }

  @override
  Future<void> releaseLocalStoreLease(Object lease) async {
    expect(held, isTrue);
    releases++;
    held = false;
    (lease as Completer<void>).complete();
    if (failRelease) throw StateError('synthetic lost release response');
  }

  @override
  Future<NativeProtectedLeaseResult> commitProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
    required List<String> retainedReferences,
  }) async {
    expect(held, isTrue);
    commits++;
    return const NativeProtectedLeaseResult();
  }

  @override
  Future<NativeProtectedRecoveryResult> recoverProtectedPageLeases({
    required String storageDirectory,
    required List<String> adoptedLeaseReferences,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) async {
    expect(held, isTrue);
    recovered = liveReferences.toSet();
    return const NativeProtectedRecoveryResult(
      recovery: NativeProtectedRecovery(
        finalizedAdoptedLeaseReferences: [],
        absentAdoptedLeaseReferences: [],
        rolledBackCount: 0,
        removedTemporaryFilesCount: 0,
        hasMore: false,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected native operation');
}

class _Inventory implements CloudProtectedPageLeaseAdoptionStore {
  _Inventory(this.bindings);
  final _Bindings bindings;
  int reads = 0;
  Set<String> live = {};
  @override
  Future<Set<String>> readAdoptedProtectedPageLeaseReferences({
    required int maximumCount,
  }) async {
    expect(bindings.held, isTrue);
    reads++;
    return {};
  }

  @override
  Future<CloudProtectedReferenceSnapshot> readLiveProtectedReferences({
    required int maximumCount,
  }) async {
    expect(bindings.held, isTrue);
    reads++;
    return CloudProtectedReferenceSnapshot(references: live, isComplete: true);
  }

  @override
  Future<void> releaseAdoptedProtectedPageLeaseReferences(
    Iterable<String> references,
  ) async {
    fail('no page markers to release');
  }
}
