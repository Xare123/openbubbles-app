import 'dart:io';
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_stage_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';

String get _account => 'A' * 43;
String get _storeIdentity => 'obcs2.store.${'S' * 43}';
String get _snapshot => 'a' * 64;

CloudSyncHistoricalProtectedSourceBinding _source({
  String? account,
  String? store,
  String? snapshot,
  String? guid,
  String? sourceHash,
  String? reference,
  String? payloadHash,
  int? payloadLength,
}) => CloudSyncHistoricalProtectedSourceBinding(
  accountFingerprint: account ?? _account,
  protectedStoreIdentity: store ?? _storeIdentity,
  snapshotSha256: snapshot ?? _snapshot,
  messageGuidHash: guid ?? 'b' * 64,
  sourceSha256: sourceHash ?? 'c' * 64,
  protectedReference: reference ?? 'obcs2.ref.${'R' * 43}',
  leaseReference: 'obcs2.lease.${'d' * 32}',
  payloadSha256: payloadHash ?? 'e' * 64,
  payloadLength: payloadLength ?? 128,
);

void main() {
  late Directory directory;
  late Store store;
  late _LocalTransport transport;
  late bool current;
  late int stages;
  late CloudSyncNativeAuthSnapshot identity;
  Future<void> Function()? validateHook;

  CloudSyncHistoricalArchiveJournal journal() =>
      CloudSyncHistoricalArchiveJournal(
        store: store,
        accountFingerprint: _account,
        protectedStoreIdentity: _storeIdentity,
        snapshotSha256: _snapshot,
      );

  CloudSyncHistoricalArchiveStaging staging({
    CloudProtectedPageLeaseTransport? selected,
  }) => CloudSyncHistoricalArchiveStaging(
    journal: journal(),
    transport: selected ?? transport,
    capturedIdentity: identity,
    stillCurrent: () => current,
    validateCurrentIdentity: () async {
      await validateHook?.call();
    },
  );

  Future<CloudSyncHistoricalProtectedSourceBinding> nativeStage() async {
    expect(transport.inside, isTrue);
    stages++;
    return _source();
  }

  Future<CloudSyncHistoricalArchiveIntent> run({
    Future<CloudSyncHistoricalProtectedSourceBinding> Function()? stage,
    CloudProtectedPageLeaseTransport? selected,
  }) async => staging(selected: selected).adopt(
    messageGuidHash: _source().messageGuidHash,
    sourceSha256: _source().sourceSha256,
    stageNative: stage ?? nativeStage,
  );

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ob-historical-staging-');
    store = await openStore(directory: directory.path);
    transport = _LocalTransport();
    current = true;
    stages = 0;
    validateHook = null;
    identity = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic-session',
      accountFingerprint: _account,
      protectedStoreIdentity: _storeIdentity,
      cloudMessagesClient: Object(),
    );
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('stage, durable adopt and exact commit share local exclusion', () async {
    transport.beforeCommit = () {
      expect(
        journal().pendingSourceCommits().single.source.encode(),
        _source().encode(),
      );
    };
    final result = await run();
    expect(result.sourceLeaseCommitted, isTrue);
    expect(stages, 1);
    expect(transport.commits, [_source().leaseReference]);
    expect(transport.retained.single, {_source().protectedReference});
    expect(transport.rollbacks, isEmpty);
    expect(transport.entries, 1);
    expect(transport.inside, isFalse);
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
    expect(store.box<Message>().count(), 0);
  });

  // These cases exercise the real ObjectBox adoption boundary with a synthetic
  // native port, not Apple authentication or native envelope encryption.
  CloudSyncHistoricalArchiveRequest request() =>
      CloudSyncHistoricalArchiveRequest(
        guid: 'synthetic-message',
        guidHash: 'b' * 64,
        sourceSha256: 'c' * 64,
        origin: CloudSyncHistoricalArchiveOrigin.historicalReceived,
        isFromMe: false,
        chatGuid: 'iMessage;-;fixture@example.com',
        dateCreatedMs: 1699000000000,
        snapshotSha256: _snapshot,
        accountFingerprint: _account,
        protectedStoreIdentity: _storeIdentity,
        textSha256: historicalTextDigest('fixture'),
        senderAddress: 'fixture@example.com',
        peerAddress: 'fixture@example.com',
      );

  List<int> payload() => utf8.encode(
    jsonEncode(stagedHistoricalPayload(request: request(), text: 'fixture')),
  );

  CloudSyncHistoricalStageAdapter adapter() => CloudSyncHistoricalStageAdapter(
    staging: staging(),
    stageNative: (request, bytes) async {
      expect(transport.inside, isTrue);
      expect(() => bytes[0] = 0, throwsUnsupportedError);
      stages++;
      return _source(
        payloadHash: historicalBytesSha256(bytes),
        payloadLength: bytes.length,
      );
    },
  );

  test(
    'producer adapter resumes exact native adoption after database reopen',
    () async {
      final first = await adapter()(request(), payload());
      expect(first.sha256, historicalBytesSha256(payload()));
      expect(first.byteLength, payload().length);
      expect(first.key, request().sourceSha256);
      expect(first.guid, request().guid);
      await reopen();
      final second = await adapter()(request(), payload());
      expect(second.sha256, first.sha256);
      expect(stages, 1);
      expect(transport.commits, hasLength(2));
      expect(journal().pendingSourceCommits(), isEmpty);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test('producer adapter does not commit a retained wrong payload', () async {
    journal().adopt(_source());
    await expectLater(adapter()(request(), payload()), throwsStateError);
    expect(stages, 0);
    expect(transport.commits, isEmpty);
    expect(transport.rollbacks, isEmpty);
    expect(journal().pendingSourceCommits(), hasLength(1));
  });

  test('producer adapter does not adopt a fresh wrong payload', () async {
    final wrong = CloudSyncHistoricalStageAdapter(
      staging: staging(),
      stageNative: (request, bytes) async => _source(),
    );
    await expectLater(wrong(request(), payload()), throwsStateError);
    expect(transport.commits, isEmpty);
    expect(transport.rollbacks, isEmpty);
    expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 0);
  });

  test(
    'producer adapter preserves adopted source after interrupted commit',
    () async {
      transport.failCommit = true;
      await expectLater(adapter()(request(), payload()), throwsStateError);
      expect(journal().pendingSourceCommits(), hasLength(1));
      await reopen();
      transport.failCommit = false;
      await adapter()(request(), payload());
      expect(stages, 1);
      expect(journal().pendingSourceCommits(), isEmpty);
    },
  );

  test(
    'lost native commit response resumes same descriptor after reopen',
    () async {
      transport.failCommit = true;
      await expectLater(run(), throwsStateError);
      expect(journal().pendingSourceCommits(), hasLength(1));
      expect(transport.rollbacks, isEmpty);
      await reopen();
      transport.failCommit = false;
      final result = await run();
      expect(stages, 1, reason: 'A lost response is not permission to restage');
      expect(result.sourceLeaseCommitted, isTrue);
      expect(transport.commits, [
        _source().leaseReference,
        _source().leaseReference,
      ]);
      expect(journal().pendingSourceCommits(), isEmpty);
      expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 1);
    },
  );

  test(
    'already committed replay rechecks native lease without restaging',
    () async {
      final first = await run();
      await reopen();
      final second = await run();
      expect(second.id, first.id);
      expect(second.sourceLeaseCommitted, isTrue);
      expect(stages, 1);
      expect(transport.commits, hasLength(2));
      expect(transport.rollbacks, isEmpty);
    },
  );

  test(
    'post-commit identity loss preserves adoption for later exact recovery',
    () async {
      transport.afterCommit = () => current = false;
      await expectLater(run(), throwsStateError);
      expect(journal().pendingSourceCommits(), hasLength(1));
      expect(transport.rollbacks, isEmpty);
      current = true;
      transport.afterCommit = null;
      expect((await run()).sourceLeaseCommitted, isTrue);
      expect(stages, 1);
    },
  );

  test('identity loss before stage performs no local write', () async {
    validateHook = () async {
      current = false;
    };
    await expectLater(run(), throwsStateError);
    expect(stages, 0);
    expect(transport.commits, isEmpty);
    expect(transport.rollbacks, isEmpty);
    expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 0);
  });

  test(
    'identity loss after fresh stage rolls back only the unadopted source',
    () async {
      await expectLater(
        run(
          stage: () async {
            final source = await nativeStage();
            current = false;
            return source;
          },
        ),
        throwsStateError,
      );
      expect(transport.rollbacks, [_source().leaseReference]);
      expect(transport.commits, isEmpty);
      expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 0);
    },
  );

  for (final mismatch
      in <String, CloudSyncHistoricalProtectedSourceBinding Function()>{
        'account': () => _source(account: 'B' * 43),
        'store': () => _source(store: 'obcs2.store.${'T' * 43}'),
        'snapshot': () => _source(snapshot: 'f' * 64),
        'guid': () => _source(guid: 'f' * 64),
        'source': () => _source(sourceHash: 'f' * 64),
      }.entries) {
    test(
      'mismatched ${mismatch.key} descriptor is not adopted or rolled back',
      () async {
        await expectLater(
          run(stage: () async => mismatch.value()),
          throwsStateError,
        );
        expect(transport.commits, isEmpty);
        expect(transport.rollbacks, isEmpty);
        expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 0);
      },
    );
  }

  test(
    'durable source conflict is retained before staging another envelope',
    () async {
      journal().adopt(_source(sourceHash: 'f' * 64));
      await expectLater(run(), throwsStateError);
      expect(stages, 0);
      expect(transport.commits, isEmpty);
      expect(transport.rollbacks, isEmpty);
      expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 1);
    },
  );

  test(
    'changed descriptor after native commit cannot mark another source committed',
    () async {
      transport.afterCommit = () {
        final box = store.box<CloudSyncHistoricalArchiveIntentEntity>();
        final row = box.getAll().single;
        row.protectedSourceBinding = _source(
          reference: 'obcs2.ref.${'T' * 43}',
        ).encode();
        box.put(row);
      };
      await expectLater(run(), throwsStateError);
      expect(journal().pendingSourceCommits(), hasLength(1));
      expect(transport.rollbacks, isEmpty);
    },
  );

  test(
    'wrong store transport or absent cross-engine exclusion never stages',
    () async {
      transport.identity = 'obcs2.store.${'T' * 43}';
      await expectLater(run(), throwsStateError);
      await expectLater(run(selected: _NoLocalTransport()), throwsStateError);
      expect(stages, 0);
      expect(transport.entries, 0);
      expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 0);
    },
  );
}

class _NoLocalTransport implements CloudProtectedPageLeaseTransport {
  @override
  String get protectedPageLeaseRecoveryIdentity => _storeIdentity;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_transport_access');
}

class _LocalTransport extends _NoLocalTransport
    implements CloudProtectedLocalLifecycleTransport {
  String identity = _storeIdentity;
  bool inside = false;
  bool failCommit = false;
  int entries = 0;
  void Function()? beforeCommit;
  void Function()? afterCommit;
  final commits = <String>[];
  final retained = <Set<String>>[];
  final rollbacks = <String>[];

  @override
  String get protectedPageLeaseRecoveryIdentity => identity;

  @override
  Future<T> runLocalProtectedStoreExclusive<T>(
    Future<T> Function() action,
  ) async {
    expect(inside, isFalse);
    entries++;
    inside = true;
    try {
      return await action();
    } finally {
      inside = false;
    }
  }

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> references,
  ) async {
    expect(inside, isTrue);
    beforeCommit?.call();
    commits.add(leaseReference);
    retained.add({...references});
    if (failCommit) throw StateError('synthetic_lost_native_commit_response');
    afterCommit?.call();
  }

  @override
  Future<void> rollbackProtectedPageLease(String reference) async {
    expect(inside, isTrue);
    rollbacks.add(reference);
  }
}
