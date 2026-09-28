import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_journal.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Synthetic ObjectBox ownership tests for historical dedupe.
///
/// NOTE: authored, not executed here. The host blocks the native ObjectBox
/// DLL (Application Control 4551), so no database test can run locally.
/// Parent runs the combined DB qualification.
String _t(String c) => List.filled(43, c).join();
String _h(String c) => List.filled(64, c).join();
String _uuid(int i) =>
    'a3f1c2d4-e5b6-4c7d-8e9f-${i.toRadixString(16).padLeft(12, '0')}';
String _account = _t('A');
String _storeId = 'obcs2.store.${_t('S')}';
String _snapshot = 'a' * 64;

/// Actual historical GUID-hash domain, matching the production request
/// digest. Requests default to the digest of their own raw GUID so an
/// adopted source binds the exact test request unless overridden.
String _hGuid(String guid) => sha256
    .convert(
      utf8.encode(jsonEncode(['cloud-sync-historical-archive-guid-v1', guid])),
    )
    .toString();

void main() {
  late Directory directory;
  late Store store;
  late CloudSyncHistoricalArchiveJournal journal;
  late ObjectBoxHistoricalOwnership ownership;

  CloudSyncHistoricalProtectedSourceBinding binding({
    String? guid,
    String? guidHash,
    String? sourceSha,
  }) {
    final raw = guid ?? _uuid(900);
    return CloudSyncHistoricalProtectedSourceBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: _storeId,
      snapshotSha256: _snapshot,
      messageGuidHash: guidHash ?? _hGuid(raw),
      sourceSha256: sourceSha ?? _h('c'),
      protectedReference: 'obcs2.ref.${_t('R')}',
      leaseReference: 'obcs2.lease.${'d' * 32}',
      payloadSha256: _h('e'),
      payloadLength: 128,
    );
  }

  CloudSyncHistoricalArchiveRequest request({
    required String guid,
    String? guidHash,
    String? sourceSha,
    String? account,
    String? storeIdentity,
    String? snapshot,
  }) => CloudSyncHistoricalArchiveRequest(
    guid: guid,
    guidHash: guidHash ?? _hGuid(guid),
    sourceSha256: sourceSha ?? _h('c'),
    origin: CloudSyncHistoricalArchiveOrigin.historicalReceived,
    isFromMe: false,
    chatGuid: 'iMessage;-;peer@example.com',
    dateCreatedMs: 1700000000000,
    snapshotSha256: snapshot ?? _snapshot,
    accountFingerprint: account ?? _account,
    protectedStoreIdentity: storeIdentity ?? _storeId,
    textSha256: _h('d'),
    senderAddress: 'peer@example.com',
    peerAddress: 'peer@example.com',
  );

  String sendHash(String guid) =>
      CloudSyncReceivedArchiveJournal.localSendGuidHashFor(guid);
  String receivedHash(String guid) =>
      CloudSyncReceivedArchiveJournal.guidHashFor(guid);

  void putSend({
    required String guid,
    String? account,
    int state = 2,
    int idsConfirmationVersion = 2,
    String tag = 'a',
  }) {
    store.box<CloudSyncLocalSendIntentEntity>().put(
      CloudSyncLocalSendIntentEntity(
        intentKey: 'send-$tag-${sendHash(guid)}',
        accountFingerprint: account ?? _account,
        writerEpoch: 1,
        localMessageId: 9,
        messageGuidHash: sendHash(guid),
        sourceSha256: _h('5'),
        state: state,
        idsConfirmationVersion: idsConfirmationVersion,
        createdAtMs: 1,
        updatedAtMs: 1,
      ),
    );
  }

  void putReceived({
    required String guid,
    String? account,
    int state = 1,
    int origin = 0,
    String tag = 'a',
  }) {
    store.box<CloudSyncReceivedArchiveIntentEntity>().put(
      CloudSyncReceivedArchiveIntentEntity(
        intentKey: 'received-$tag-${receivedHash(guid)}',
        accountFingerprint: account ?? _account,
        writerEpoch: 1,
        localMessageId: 9,
        localChatId: 7,
        messageGuidHash: receivedHash(guid),
        sourceSha256: _h('6'),
        origin: origin,
        protectedSourceBinding: binding().encode(),
        state: state,
        createdAtMs: 1,
        updatedAtMs: 1,
      ),
    );
  }

  void putMutation({required String guid, String tag = 'a'}) {
    store.box<CloudSyncLocalMutationIntentEntity>().put(
      CloudSyncLocalMutationIntentEntity(
        intentKey: 'mutation-$tag-${sendHash(guid)}',
        accountFingerprint: _account,
        writerEpoch: 1,
        localMessageId: 9,
        localChatId: 7,
        mutationGuidHash: sendHash('mutation-$tag-$guid'),
        targetGuidHash: sendHash(guid),
        targetPart: 0,
        kind: 0,
        sourceSha256: _h('7'),
        targetSnapshotSha256: _h('8'),
        protectedSourceBinding: 'mutation-binding',
        createdAtMs: 1,
        updatedAtMs: 1,
      ),
    );
  }

  /// Identity/state/binding fingerprint of every lane row. Counts alone
  /// cannot prove resolve() left rows untouched, so the retained fields
  /// themselves are compared before and after each call.
  List<String> fingerprint() {
    final rows = <String>[
      for (final row
          in store.box<CloudSyncHistoricalArchiveIntentEntity>().getAll())
        'hist:${row.id}:${row.intentKey}:${row.state}:${row.protectedSourceBinding}',
      for (final row in store.box<CloudSyncLocalSendIntentEntity>().getAll())
        'send:${row.id}:${row.intentKey}:${row.accountFingerprint}:${row.state}:${row.messageGuidHash}:${row.idsConfirmationVersion}:${row.admittedOperationId}',
      for (final row
          in store.box<CloudSyncReceivedArchiveIntentEntity>().getAll())
        'recv:${row.id}:${row.intentKey}:${row.accountFingerprint}:${row.state}:${row.messageGuidHash}:${row.origin}:${row.protectedSourceBinding}:${row.readerChangeId}:${row.admittedOperationId}',
      for (final row
          in store.box<CloudSyncLocalMutationIntentEntity>().getAll())
        'mut:${row.id}:${row.intentKey}:${row.accountFingerprint}:${row.state}:${row.targetGuidHash}:${row.protectedSourceBinding}',
    ];
    rows.sort();
    return rows;
  }

  CloudSyncHistoricalDedupeVerdict resolveUnchanged(
    CloudSyncHistoricalArchiveRequest value,
  ) {
    final before = fingerprint();
    final verdict = ownership.resolve(value);
    expect(fingerprint(), before);
    return verdict;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'ob-historical-ownership-',
    );
    store = await openStore(directory: directory.path);
    journal = CloudSyncHistoricalArchiveJournal(
      store: store,
      accountFingerprint: _account,
      protectedStoreIdentity: _storeId,
      snapshotSha256: _snapshot,
    );
    ownership = ObjectBoxHistoricalOwnership(store: store, journal: journal);
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('no owner proceeds without touching the database', () {
    expect(
      resolveUnchanged(request(guid: _uuid(1))),
      CloudSyncHistoricalDedupeVerdict.proceed,
    );
  });

  test('positive-confirmed local send is owned, never cloud-confirmed', () {
    final guid = _uuid(2);
    putSend(guid: guid, state: 2, idsConfirmationVersion: 2);
    // skipOwned keeps the producer from restaging a locally owned row. It
    // is not a CloudKit save claim: no outbox, map, or receipt is implied.
    expect(
      resolveUnchanged(request(guid: guid)),
      CloudSyncHistoricalDedupeVerdict.skipOwned,
    );
  });

  test('pending or unconfirmed sends are retained as conflict', () {
    final awaiting = _uuid(3);
    putSend(guid: awaiting, state: 0, idsConfirmationVersion: 0, tag: 'p');
    expect(
      resolveUnchanged(request(guid: awaiting)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
    final unconfirmed = _uuid(4);
    putSend(guid: unconfirmed, state: 0, idsConfirmationVersion: 2, tag: 'q');
    expect(
      resolveUnchanged(request(guid: unconfirmed)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
    final admittedUnconfirmed = _uuid(22);
    putSend(
      guid: admittedUnconfirmed,
      state: 1,
      idsConfirmationVersion: 0,
      tag: 's',
    );
    expect(
      resolveUnchanged(request(guid: admittedUnconfirmed)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
    final ready = _uuid(5);
    putSend(guid: ready, state: 1, idsConfirmationVersion: 2, tag: 'r');
    expect(
      resolveUnchanged(request(guid: ready)),
      CloudSyncHistoricalDedupeVerdict.skipOwned,
    );
  });

  test('current received states are owned without cloud proof', () {
    final captured = _uuid(6);
    putReceived(guid: captured, state: 0, origin: 0, tag: 'p');
    expect(
      resolveUnchanged(request(guid: captured)),
      CloudSyncHistoricalDedupeVerdict.skipOwned,
    );
    final handed = _uuid(7);
    putReceived(guid: handed, state: 4, origin: 1, tag: 'q');
    expect(
      resolveUnchanged(request(guid: handed)),
      CloudSyncHistoricalDedupeVerdict.skipOwned,
    );
    for (final entry in [
      (_uuid(23), 1, 0, 't'),
      (_uuid(24), 2, 1, 'u'),
      (_uuid(25), 3, 0, 'v'),
    ]) {
      putReceived(
        guid: entry.$1,
        state: entry.$2,
        origin: entry.$3,
        tag: entry.$4,
      );
      expect(
        resolveUnchanged(request(guid: entry.$1)),
        CloudSyncHistoricalDedupeVerdict.skipOwned,
      );
    }
    final foreignOrigin = _uuid(8);
    putReceived(guid: foreignOrigin, state: 1, origin: 2, tag: 'r');
    expect(
      resolveUnchanged(request(guid: foreignOrigin)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
  });

  test('foreign lane owners are retained as conflict', () {
    final foreignSend = _uuid(9);
    putSend(
      guid: foreignSend,
      account: _t('Z'),
      state: 2,
      idsConfirmationVersion: 2,
      tag: 'p',
    );
    expect(
      resolveUnchanged(request(guid: foreignSend)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
    final foreignReceived = _uuid(10);
    putReceived(guid: foreignReceived, account: _t('Z'), tag: 'q');
    expect(
      resolveUnchanged(request(guid: foreignReceived)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
    final settled = _uuid(11);
    putReceived(guid: settled, state: 5, tag: 'r');
    expect(
      resolveUnchanged(request(guid: settled)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
  });

  test('duplicate and cross-lane owners conflict', () {
    final duplicated = _uuid(12);
    putSend(guid: duplicated, tag: 'p');
    putSend(guid: duplicated, tag: 'q');
    expect(
      resolveUnchanged(request(guid: duplicated)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
    final crossed = _uuid(13);
    putSend(guid: crossed, tag: 'r');
    putReceived(guid: crossed, tag: 's');
    expect(
      resolveUnchanged(request(guid: crossed)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
  });

  test('mutation targets conflict before lane ownership is read', () {
    final guid = _uuid(14);
    putMutation(guid: guid);
    expect(
      resolveUnchanged(request(guid: guid)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
    final alsoOwned = _uuid(15);
    putMutation(guid: alsoOwned, tag: 'p');
    putSend(guid: alsoOwned, tag: 'q');
    expect(
      resolveUnchanged(request(guid: alsoOwned)),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
  });

  test(
    'retained historical source proceeds despite a later mutation',
    () async {
      final guid = _uuid(16);
      final adopted = journal.adopt(binding(guid: guid));
      journal.markSourceLeaseCommitted(
        intentId: adopted.id,
        expectedSource: binding(guid: guid),
      );
      putMutation(guid: guid);
      expect(
        resolveUnchanged(request(guid: guid)),
        CloudSyncHistoricalDedupeVerdict.proceed,
      );
    },
  );

  test(
    'adopted different guid does not proceed for a mutation-owned target',
    () async {
      final adoptedGuid = _uuid(30);
      final adopted = journal.adopt(binding(guid: adoptedGuid));
      journal.markSourceLeaseCommitted(
        intentId: adopted.id,
        expectedSource: binding(guid: adoptedGuid),
      );
      final target = _uuid(31);
      putMutation(guid: target);
      expect(
        resolveUnchanged(request(guid: target)),
        CloudSyncHistoricalDedupeVerdict.retainConflict,
      );
    },
  );

  test('same guid with a changed source is rejected', () {
    journal.adopt(binding(guid: _uuid(17)));
    expect(
      () => ownership.resolve(request(guid: _uuid(17), sourceSha: _h('f'))),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_journal_source_conflict',
        ),
      ),
    );
  });

  test('changed account, store, or snapshot is rejected', () {
    final guid = _uuid(18);
    for (final mutated in [
      request(guid: guid, account: _t('Z')),
      request(guid: guid, storeIdentity: 'obcs2.store.${_t('Z')}'),
      request(guid: guid, snapshot: _h('f')),
    ]) {
      expect(
        () => ownership.resolve(mutated),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloud_sync_historical_import_identity_changed',
          ),
        ),
      );
    }
  });

  test('registry rereads ownership adopted after construction', () {
    final guid = _uuid(19);
    final value = request(guid: guid);
    expect(resolveUnchanged(value), CloudSyncHistoricalDedupeVerdict.proceed);
    putSend(guid: guid, tag: 'late');
    expect(resolveUnchanged(value), CloudSyncHistoricalDedupeVerdict.skipOwned);
  });

  test('closed store and foreign journal are rejected', () async {
    final foreignDirectory = await Directory.systemTemp.createTemp(
      'ob-historical-ownership-foreign-',
    );
    final foreignStore = await openStore(directory: foreignDirectory.path);
    try {
      final foreignJournal = CloudSyncHistoricalArchiveJournal(
        store: foreignStore,
        accountFingerprint: _account,
        protectedStoreIdentity: _storeId,
        snapshotSha256: _snapshot,
      );
      final foreign = ObjectBoxHistoricalOwnership(
        store: store,
        journal: foreignJournal,
      );
      expect(
        () => foreign.resolve(request(guid: _uuid(20))),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloud_sync_historical_import_identity_changed',
          ),
        ),
      );
    } finally {
      foreignStore.close();
      await foreignDirectory.delete(recursive: true);
    }
    store.close();
    expect(() => ownership.resolve(request(guid: _uuid(21))), throwsStateError);
  });
}
