import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

String _repeat(String character, int count) =>
    List.filled(count, character).join();
String get _account => _repeat('A', 43);
String get _storeIdentity => 'obcs2.store.${_repeat('S', 43)}';
String get _snapshot => _repeat('a', 64);
final _invalid = isA<StateError>();

CloudSyncHistoricalProtectedSourceBinding _source({
  String? account,
  String? storeIdentity,
  String? snapshot,
  String? guidHash,
  String? sourceHash,
  String? reference,
  String? lease,
  String? payloadHash,
  int length = 128,
}) => CloudSyncHistoricalProtectedSourceBinding(
  accountFingerprint: account ?? _account,
  protectedStoreIdentity: storeIdentity ?? _storeIdentity,
  snapshotSha256: snapshot ?? _snapshot,
  messageGuidHash: guidHash ?? _repeat('b', 64),
  sourceSha256: sourceHash ?? _repeat('c', 64),
  protectedReference: reference ?? 'obcs2.ref.${_repeat('R', 43)}',
  leaseReference: lease ?? 'obcs2.lease.${_repeat('d', 32)}',
  payloadSha256: payloadHash ?? _repeat('e', 64),
  payloadLength: length,
);

void main() {
  late Directory directory;
  late Store store;
  late DateTime now;

  CloudSyncHistoricalArchiveJournal journal({
    String? account,
    String? storeIdentity,
    String? snapshot,
  }) => CloudSyncHistoricalArchiveJournal(
    store: store,
    accountFingerprint: account ?? _account,
    protectedStoreIdentity: storeIdentity ?? _storeIdentity,
    snapshotSha256: snapshot ?? _snapshot,
    clock: () => now,
  );

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
  }

  ObjectBoxCloudSyncStore inventory() => ObjectBoxCloudSyncStore(
    store: store,
    protector: _UnexpectedProtector(),
    clock: () => now,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ob-historical-journal-');
    store = await openStore(directory: directory.path);
    now = DateTime.utc(2026, 9, 27, 12);
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('adoption survives restart and identical replay owns one row', () async {
    final source = _source();
    final first = journal().adopt(source);
    expect(first.id, greaterThan(0));
    expect(first.sourceLeaseCommitted, isFalse);
    await reopen();
    final restored = journal().read(
      messageGuidHash: source.messageGuidHash,
      sourceSha256: source.sourceSha256,
    )!;
    expect(restored.id, first.id);
    expect(restored.source.encode(), source.encode());
    expect(restored.sourceLeaseCommitted, isFalse);
    expect(journal().pendingSourceCommits().single.id, first.id);
    now = now.add(const Duration(minutes: 1));
    expect(journal().adopt(source).id, first.id);
    expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 1);
    final persisted = store.box<CloudSyncHistoricalArchiveIntentEntity>().get(
      first.id,
    )!;
    expect(persisted.updatedAtMs, persisted.createdAtMs);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    expect(store.box<Message>().count(), 0);
  });

  test(
    'native commit marker resumes idempotently without a remote result',
    () async {
      final source = _source();
      final adopted = journal().adopt(source);
      await reopen(); // A crash may occur before OR after the native lease commit.
      final committed = journal().markSourceLeaseCommitted(
        intentId: adopted.id,
        expectedSource: source,
      );
      expect(committed.sourceLeaseCommitted, isTrue);
      expect(journal().pendingSourceCommits(), isEmpty);
      await reopen();
      expect(
        journal()
            .markSourceLeaseCommitted(
              intentId: adopted.id,
              expectedSource: source,
            )
            .sourceLeaseCommitted,
        isTrue,
      );
      expect(journal().adopt(source).sourceLeaseCommitted, isTrue);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  for (final change
      in <String, CloudSyncHistoricalProtectedSourceBinding Function()>{
        'source digest': () => _source(sourceHash: _repeat('f', 64)),
        'protected reference': () =>
            _source(reference: 'obcs2.ref.${_repeat('T', 43)}'),
        'lease': () => _source(lease: 'obcs2.lease.${_repeat('e', 32)}'),
        'payload digest': () => _source(payloadHash: _repeat('f', 64)),
        'payload length': () => _source(length: 129),
      }.entries) {
    test('conflicting ${change.key} never replaces an adopted source', () {
      final source = _source();
      final adopted = journal().adopt(source);
      expect(() => journal().adopt(change.value()), throwsA(_invalid));
      expect(
        () => journal().markSourceLeaseCommitted(
          intentId: adopted.id,
          expectedSource: change.value(),
        ),
        throwsA(_invalid),
      );
      final retained = journal().read(
        messageGuidHash: source.messageGuidHash,
        sourceSha256: source.sourceSha256,
      )!;
      expect(retained.source.encode(), source.encode());
      expect(retained.sourceLeaseCommitted, isFalse);
      expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 1);
    });
  }

  test('read cannot silently return a different reassessed source', () {
    final source = _source();
    journal().adopt(source);
    expect(
      () => journal().read(
        messageGuidHash: source.messageGuidHash,
        sourceSha256: _repeat('f', 64),
      ),
      throwsA(_invalid),
    );
    expect(
      journal().read(
        messageGuidHash: _repeat('f', 64),
        sourceSha256: source.sourceSha256,
      ),
      isNull,
    );
  });

  test(
    'historical GC retains adopted and committed sources across scopes and reopen',
    () async {
      final first = _source();
      journal().adopt(first);
      final second = _source(
        account: _repeat('B', 43),
        storeIdentity: 'obcs2.store.${_repeat('T', 43)}',
        snapshot: _repeat('f', 64),
        reference: 'obcs2.ref.${_repeat('U', 43)}',
        lease: 'obcs2.lease.${_repeat('e', 32)}',
      );
      final other = journal(
        account: second.accountFingerprint,
        storeIdentity: second.protectedStoreIdentity,
        snapshot: second.snapshotSha256,
      );
      final adopted = other.adopt(second);
      other.markSourceLeaseCommitted(
        intentId: adopted.id,
        expectedSource: second,
      );
      await reopen();
      final live = await inventory().readLiveProtectedReferences(
        maximumCount: 2,
      );
      expect(live.isComplete, isTrue);
      expect(live.references, {
        first.protectedReference,
        second.protectedReference,
      });
      expect(
        await inventory().readLiveProtectedOutboundLeaseReferences(
          maximumCount: 2,
        ),
        {first.leaseReference, second.leaseReference},
      );
      expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 2);
      expect(
        journal().pendingSourceCommits().single.source.encode(),
        first.encode(),
      );
    },
  );

  test(
    'historical GC never reports complete after exceeding its row bound',
    () async {
      final first = _source();
      journal().adopt(first);
      journal().adopt(_source(guidHash: _repeat('d', 64)));
      final limited = await inventory().readLiveProtectedReferences(
        maximumCount: 1,
      );
      expect(limited.isComplete, isFalse);
      expect(limited.references, isEmpty);
      await expectLater(
        inventory().readLiveProtectedOutboundLeaseReferences(maximumCount: 1),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'protected_outbound_lease_recovery_bound_exceeded',
          ),
        ),
      );
      final complete = await inventory().readLiveProtectedReferences(
        maximumCount: 2,
      );
      expect(complete.isComplete, isTrue);
      expect(complete.references, {first.protectedReference});
    },
  );

  test(
    'historical GC traverses every retained page without mutating rows',
    () async {
      final owner = journal();
      for (var index = 0; index < 1025; index++) {
        owner.adopt(
          _source(
            guidHash: index.toRadixString(16).padLeft(64, '0'),
            reference: index == 1024 ? 'obcs2.ref.${_repeat('Z', 43)}' : null,
          ),
        );
      }
      await reopen();
      final live = await inventory().readLiveProtectedReferences(
        maximumCount: 1025,
      );
      expect(live.isComplete, isTrue);
      expect(live.references, {
        _source().protectedReference,
        'obcs2.ref.${_repeat('Z', 43)}',
      });
      expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 1025);
    },
  );

  for (final field in ['account', 'store', 'snapshot']) {
    test(
      '$field scope cannot adopt, read or commit another scope row',
      () async {
        final source = _source();
        final adopted = journal().adopt(source);
        await reopen();
        final other = journal(
          account: field == 'account' ? _repeat('B', 43) : null,
          storeIdentity: field == 'store'
              ? 'obcs2.store.${_repeat('T', 43)}'
              : null,
          snapshot: field == 'snapshot' ? _repeat('f', 64) : null,
        );
        expect(() => other.adopt(source), throwsA(_invalid));
        expect(
          other.read(
            messageGuidHash: source.messageGuidHash,
            sourceSha256: source.sourceSha256,
          ),
          isNull,
        );
        expect(other.pendingSourceCommits(), isEmpty);
        expect(
          () => other.markSourceLeaseCommitted(
            intentId: adopted.id,
            expectedSource: source,
          ),
          throwsA(_invalid),
        );
        expect(journal().pendingSourceCommits().single.id, adopted.id);
      },
    );
  }

  for (final corruption
      in <String, void Function(CloudSyncHistoricalArchiveIntentEntity)>{
        'key': (r) => r.intentKey = 'wrong',
        'scope': (r) => r.scopeKey = 'wrong',
        'binding': (r) => r.protectedSourceBinding = '[]',
        'state': (r) => r.state = 9,
        'created time': (r) => r.createdAtMs = 0,
        'updated time': (r) => r.updatedAtMs = 1,
      }.entries) {
    test(
      'invalid persisted ${corruption.key} is rejected, not repaired',
      () async {
        final source = _source();
        final adopted = journal().adopt(source);
        final box = store.box<CloudSyncHistoricalArchiveIntentEntity>();
        final row = box.get(adopted.id)!;
        corruption.value(row);
        box.put(row);
        expect(
          () => journal().markSourceLeaseCommitted(
            intentId: adopted.id,
            expectedSource: source,
          ),
          throwsA(_invalid),
        );
        expect(box.count(), 1);
        expect(
          box.get(adopted.id)!.protectedSourceBinding,
          row.protectedSourceBinding,
        );
        await reopen();
        await expectLater(
          inventory().readLiveProtectedReferences(maximumCount: 100),
          throwsA(_invalid),
        );
        await expectLater(
          inventory().readLiveProtectedOutboundLeaseReferences(
            maximumCount: 100,
          ),
          throwsA(_invalid),
        );
        expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 1);
      },
    );
  }

  test('pending recovery is bounded and excludes committed sources', () {
    final first = _source();
    final firstIntent = journal().adopt(first);
    final second = journal().adopt(_source(guidHash: _repeat('c', 64)));
    final third = journal().adopt(_source(guidHash: _repeat('d', 64)));
    expect(journal().pendingSourceCommits(limit: 2).map((r) => r.id), [
      firstIntent.id,
      second.id,
    ]);
    journal().markSourceLeaseCommitted(
      intentId: firstIntent.id,
      expectedSource: first,
    );
    expect(journal().pendingSourceCommits(limit: 2).map((r) => r.id), [
      second.id,
      third.id,
    ]);
    for (final limit in [-1, 0, 501]) {
      expect(
        () => journal().pendingSourceCommits(limit: limit),
        throwsArgumentError,
      );
    }
  });

  test('failed scope and malformed input do not create rows', () {
    expect(() => journal(account: 'bad'), throwsA(_invalid));
    expect(() => journal(storeIdentity: 'bad'), throwsA(_invalid));
    expect(() => journal(snapshot: 'bad'), throwsA(_invalid));
    expect(
      () => journal().read(
        messageGuidHash: 'bad',
        sourceSha256: _repeat('a', 64),
      ),
      throwsA(_invalid),
    );
    expect(
      () => journal().markSourceLeaseCommitted(
        intentId: 0,
        expectedSource: _source(),
      ),
      throwsA(_invalid),
    );
    expect(
      () => journal().markSourceLeaseCommitted(
        intentId: 42,
        expectedSource: _source(),
      ),
      throwsA(_invalid),
    );
    expect(store.box<CloudSyncHistoricalArchiveIntentEntity>().count(), 0);
  });

  test('backward clock cannot erase ordering; diagnostics redact metadata', () {
    final source = _source();
    final adopted = journal().adopt(source);
    now = now.subtract(const Duration(minutes: 1));
    final committed = journal().markSourceLeaseCommitted(
      intentId: adopted.id,
      expectedSource: source,
    );
    final row = store.box<CloudSyncHistoricalArchiveIntentEntity>().get(
      adopted.id,
    )!;
    expect(row.updatedAtMs, row.createdAtMs);
    expect(committed.toString(), 'CloudSyncHistoricalArchiveIntent(redacted)');
    expect(committed.toString(), isNot(contains(source.messageGuidHash)));
  });
}

/// Inventory must use retained metadata without opening protected payloads.
class _UnexpectedProtector implements CloudSyncProtector {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_protector_access');
}
