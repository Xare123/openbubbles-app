import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_objectbox_reader.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const _snapshot =
    'ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34';
const _otherScope =
    'cc12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34';
const _account = 'account-fp-xyz789';
const _storeIdentity = 'store-1';
const _createdMs = 1699000000000;

void main() {
  late Directory directory;
  late Store store;
  late Chat chat;
  late Chat otherChat;
  late Handle friend;
  late Handle otherFriend;
  late Handle me;

  String scope() => historicalArchiveScope(
    const CloudSyncHistoricalSourceManifest(
      snapshotSha256: _snapshot,
      accountFingerprint: _account,
      accountHandles: ['me@example.com'],
      messageCount: 5,
      capturedAtMs: 1699500000000,
    ),
    const CloudSyncHistoricalAccountBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: _storeIdentity,
    ),
  );

  CloudSyncHistoricalObjectBoxReader reader({
    int? highWaterId,
    int? expectedRowCount,
    int maxPageLimit = 200,
    String? scopeOverride,
  }) {
    final rows = store.box<Message>().getAll();
    final frozen =
        highWaterId ??
        (rows.isEmpty
            ? 0
            : rows.map((m) => m.id ?? -1).reduce((a, b) => a > b ? a : b));
    return CloudSyncHistoricalObjectBoxReader(
      store: store,
      scope: scopeOverride ?? scope(),
      rowSnapshotSha256: _snapshot,
      highWaterId: frozen,
      expectedRowCount: expectedRowCount ?? rows.length,
      maxPageLimit: maxPageLimit,
    );
  }

  Message putMessage({
    required String guid,
    required String text,
    required bool isFromMe,
    required Handle sender,
    required Chat owner,
  }) {
    final message =
        Message(
            guid: guid,
            text: text,
            attributedBody: [AttributedBody.raw(text)],
            dateCreated: DateTime.fromMillisecondsSinceEpoch(_createdMs),
            isFromMe: isFromMe,
          )
          ..handle = sender
          ..handleId = sender.originalROWID
          ..chat.target = owner;
    store.box<Message>().put(message);
    return message;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-historical-reader-',
    );
    store = await openStore(directory: directory.path);
    friend = Handle(
      address: 'friend@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'friend@example.com/iMessage',
    );
    otherFriend = Handle(
      address: 'other@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'other@example.com/iMessage',
    );
    me = Handle(
      address: 'me@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'me@example.com/iMessage',
    );
    store.box<Handle>().putMany([friend, otherFriend, me]);
    friend.originalROWID = 101;
    otherFriend.originalROWID = 103;
    me.originalROWID = 102;
    store.box<Handle>().putMany([friend, otherFriend, me]);
    chat = Chat(
      guid: 'iMessage;-;friend@example.com',
      chatIdentifier: 'friend@example.com',
      usingHandle: 'me@example.com',
      style: 45,
      participants: [friend],
    )..handles.add(friend);
    otherChat = Chat(
      guid: 'iMessage;-;other@example.com',
      chatIdentifier: 'other@example.com',
      usingHandle: 'me@example.com',
      style: 45,
      participants: [otherFriend],
    )..handles.add(otherFriend);
    store.box<Chat>().putMany([chat, otherChat]);
  });

  tearDown(() async {
    final wasOpen = !store.isClosed();
    if (!store.isClosed()) store.close();
    expect(wasOpen, isTrue);
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('pages across boundaries and exhausts exactly once', () async {
    for (var i = 0; i < 5; i++) {
      putMessage(
        guid: 'guid-$i',
        text: 'hello $i',
        isFromMe: false,
        sender: friend,
        owner: chat,
      );
    }
    final pages = <String>[];
    String? cursor;
    var pageCount = 0;
    do {
      final page = await reader().readPage(cursor: cursor, limit: 2);
      pageCount++;
      pages.addAll(page.views.map((v) => v.guid));
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(pages, ['guid-0', 'guid-1', 'guid-2', 'guid-3', 'guid-4']);
    expect(pageCount, 3);
    final empty = await reader().readPage(cursor: null, limit: 200);
    expect(empty.views, hasLength(5));
    expect(empty.nextCursor, isNull);
  });

  test('exact resume continues after the cursor with no overlap', () async {
    for (var i = 0; i < 4; i++) {
      putMessage(
        guid: 'guid-$i',
        text: 'hello $i',
        isFromMe: false,
        sender: friend,
        owner: chat,
      );
    }
    final first = await reader().readPage(limit: 2);
    expect(first.views.map((v) => v.guid), ['guid-0', 'guid-1']);
    expect(first.nextCursor, isNotNull);
    final second = await reader().readPage(cursor: first.nextCursor, limit: 2);
    expect(second.views.map((v) => v.guid), ['guid-2', 'guid-3']);
    expect(second.nextCursor, isNull);
  });

  test('gaps in ids are skipped without offset drift', () async {
    putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final removed = putMessage(
      guid: 'guid-gone',
      text: 'gone',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    putMessage(
      guid: 'guid-2',
      text: 'hello 2',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    store.box<Message>().remove(removed.id!);
    final page = await reader().readPage(limit: 10);
    expect(page.views.map((v) => v.guid), ['guid-0', 'guid-2']);
    expect(page.nextCursor, isNull);
  });

  test('reader over the absolute page ceiling fails closed', () async {
    putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final over = reader(maxPageLimit: 501);
    await expectLater(
      over.readPage(limit: 10),
      throwsA(
        isA<CloudSyncHistoricalReaderException>().having(
          (e) => e.reason,
          'reason',
          CloudSyncHistoricalReaderReasons.pageInvalid,
        ),
      ),
    );
  });

  test('exhausted cursor still validates snapshot count', () async {
    putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final full = await reader().readPage(limit: 10);
    expect(full.nextCursor, isNull);
    final lastId = (await reader().readPage(limit: 1)).nextCursor;
    expect(lastId, isNull);
    final resumed = reader(expectedRowCount: 99);
    final cursor =
        'historical-scan:v1:${scope()}:${store.box<Message>().getAll().map((m) => m.id ?? -1).reduce((a, b) => a > b ? a : b)}';
    await expectLater(
      resumed.readPage(cursor: cursor, limit: 10),
      throwsA(
        isA<CloudSyncHistoricalReaderException>().having(
          (e) => e.reason,
          'reason',
          CloudSyncHistoricalReaderReasons.snapshotMismatch,
        ),
      ),
    );
  });

  test('foreign and malformed cursors are rejected before any read', () async {
    putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final foreign = reader().readPage(
      cursor: 'historical-scan:v1:$_otherScope:0',
      limit: 2,
    );
    await expectLater(
      foreign,
      throwsA(
        isA<CloudSyncHistoricalReaderException>().having(
          (e) => e.reason,
          'reason',
          CloudSyncHistoricalReaderReasons.foreignCursor,
        ),
      ),
    );
    for (final bad in [
      '',
      'v1:1',
      'historical-scan:v1:${scope()}',
      'historical-scan:v1:${scope()}:abc',
      'historical-scan:v1:${scope()}:-1',
    ]) {
      await expectLater(
        reader().readPage(cursor: bad, limit: 2),
        throwsA(
          isA<CloudSyncHistoricalReaderException>().having(
            (e) => e.reason,
            'reason',
            CloudSyncHistoricalReaderReasons.malformedCursor,
          ),
        ),
      );
    }
    await expectLater(
      reader().readPage(limit: 0),
      throwsA(isA<CloudSyncHistoricalReaderException>()),
    );
    await expectLater(
      reader().readPage(limit: 201),
      throwsA(isA<CloudSyncHistoricalReaderException>()),
    );
  });

  test('foreign scope shape and reader binding shape fail closed', () async {
    putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final shortScope = reader(scopeOverride: 'short');
    await expectLater(
      shortScope.readPage(limit: 2),
      throwsA(
        isA<CloudSyncHistoricalReaderException>().having(
          (e) => e.reason,
          'reason',
          CloudSyncHistoricalReaderReasons.pageInvalid,
        ),
      ),
    );
    final mismatch = reader(expectedRowCount: 99);
    await expectLater(
      mismatch.readPage(limit: 2),
      throwsA(
        isA<CloudSyncHistoricalReaderException>().having(
          (e) => e.reason,
          'reason',
          CloudSyncHistoricalReaderReasons.snapshotMismatch,
        ),
      ),
    );
  });

  test('rows appended after high-water freeze are excluded', () async {
    putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final directCount = store.box<Message>().count();
    store.box<Message>().removeAll();
    putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final frozenHighWater = store
        .box<Message>()
        .getAll()
        .map((m) => m.id ?? -1)
        .reduce((a, b) => a > b ? a : b);
    final frozen = CloudSyncHistoricalObjectBoxReader(
      store: store,
      scope: scope(),
      rowSnapshotSha256: _snapshot,
      highWaterId: frozenHighWater,
      expectedRowCount: directCount,
    );
    putMessage(
      guid: 'guid-late',
      text: 'late',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final page = await frozen.readPage(limit: 10);
    expect(page.views.map((v) => v.guid), ['guid-0']);
    expect(page.nextCursor, isNull);
  });

  test('multiple chats resolve with preserved sender and direction', () async {
    putMessage(
      guid: 'guid-incoming',
      text: 'hello',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    putMessage(
      guid: 'guid-sent',
      text: 'reply',
      isFromMe: true,
      sender: me,
      owner: chat,
    );
    putMessage(
      guid: 'guid-other',
      text: 'other hello',
      isFromMe: false,
      sender: otherFriend,
      owner: otherChat,
    );
    final page = await reader().readPage(limit: 10);
    expect(page.views, hasLength(3));
    final byGuid = {for (final v in page.views) v.guid: v};
    expect(byGuid['guid-incoming']!.senderAddress, 'friend@example.com');
    expect(byGuid['guid-incoming']!.isFromMe, isFalse);
    expect(byGuid['guid-incoming']!.chat.guid, 'iMessage;-;friend@example.com');
    expect(byGuid['guid-sent']!.senderAddress, 'me@example.com');
    expect(byGuid['guid-sent']!.isFromMe, isTrue);
    expect(byGuid['guid-other']!.senderAddress, 'other@example.com');
    expect(byGuid['guid-other']!.chat.guid, 'iMessage;-;other@example.com');
    expect(page.nextCursor, isNull);
  });

  test(
    'missing chat relation surfaces a fixed reason instead of dropping',
    () async {
      putMessage(
        guid: 'guid-0',
        text: 'hello 0',
        isFromMe: false,
        sender: friend,
        owner: chat,
      );
      final orphan = putMessage(
        guid: 'guid-orphan',
        text: 'orphan',
        isFromMe: false,
        sender: friend,
        owner: chat,
      );
      orphan.chat.targetId = 999999;
      store.box<Message>().put(orphan);
      await expectLater(
        reader().readPage(limit: 10),
        throwsA(
          isA<CloudSyncHistoricalReaderException>().having(
            (e) => e.reason,
            'reason',
            CloudSyncHistoricalReaderReasons.missingChat,
          ),
        ),
      );
    },
  );

  test('handles resolve by original row id, not object id', () async {
    expect(friend.id, isNot(101));
    putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final handleQuery = store
        .box<Message>()
        .query(Message_.guid.equals('guid-0'))
        .build();
    final fresh = handleQuery.findFirst()!;
    handleQuery.close();
    expect(fresh.handle, isNull);
    final page = await reader().readPage(limit: 10);
    expect(page.views.single.senderAddress, 'friend@example.com');
  });

  test(
    'zero handle id preserves unknown sender without selecting row zero',
    () async {
      final stray = Handle(
        address: 'stray@example.com',
        service: 'iMessage',
        uniqueAddressAndService: 'stray@example.com/iMessage',
      );
      store.box<Handle>().put(stray);
      stray.originalROWID = 0;
      store.box<Handle>().put(stray);
      final message = putMessage(
        guid: 'guid-0',
        text: 'hello 0',
        isFromMe: false,
        sender: friend,
        owner: chat,
      );
      message.handle = null;
      message.handleId = 0;
      store.box<Message>().put(message);
      final page = await reader().readPage(limit: 10);
      expect(page.views.single.senderAddress, isNull);
      final assessment = assessHistoricalArchiveRow(
        page.views.single,
        const CloudSyncHistoricalSourceManifest(
          snapshotSha256: _snapshot,
          accountFingerprint: _account,
          accountHandles: ['me@example.com'],
          messageCount: 1,
          capturedAtMs: 1699500000000,
        ),
        const CloudSyncHistoricalAccountBinding(
          accountFingerprint: _account,
          protectedStoreIdentity: _storeIdentity,
        ),
        nowMs: 1700000000000,
      );
      expect(assessment, isA<CloudSyncHistoricalArchiveIneligible>());
      expect(
        (assessment as CloudSyncHistoricalArchiveIneligible).reason,
        CloudSyncHistoricalArchiveReasons.directionMismatch,
      );
    },
  );

  test('null handle id preserves unknown sender', () async {
    final message = putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    message.handle = null;
    message.handleId = null;
    store.box<Message>().put(message);
    final page = await reader().readPage(limit: 10);
    expect(page.views.single.senderAddress, isNull);
  });

  test('duplicate handle rows surface a handle-specific reason', () async {
    putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    final duplicate = Handle(
      address: 'friend@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'friend@example.com/iMessage-dup',
    );
    store.box<Handle>().put(duplicate);
    duplicate.originalROWID = 101;
    store.box<Handle>().put(duplicate);
    await expectLater(
      reader().readPage(limit: 10),
      throwsA(
        isA<CloudSyncHistoricalReaderException>().having(
          (e) => e.reason,
          'reason',
          CloudSyncHistoricalReaderReasons.ambiguousHandle,
        ),
      ),
    );
  });

  test('unknown direction is preserved for downstream eligibility', () async {
    final message = putMessage(
      guid: 'guid-0',
      text: 'hello 0',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    message.isFromMe = null;
    store.box<Message>().put(message);
    final page = await reader().readPage(limit: 10);
    expect(page.views.single.isFromMe, isNull);
  });

  CloudSyncHistoricalSnapshot capture({bool Function()? current, int rows = 100000, int bytes = 32 * 1024 * 1024}) => CloudSyncHistoricalSnapshot.capture(
    store: store,
    account: const CloudSyncHistoricalAccountBinding(accountFingerprint: _account, protectedStoreIdentity: _storeIdentity),
    accountHandles: ['me@example.com'], capturedAtMs: 1700000000000,
    stillCurrent: current ?? () => true, rowLimit: rows, byteLimit: bytes,
  );

  test('consistent export survives in-place edits, deletion and database restart', () async {
    final message = putMessage(guid: 'stable', text: 'before', isFromMe: true, sender: me, owner: chat);
    final snapshot = capture();
    message.text = 'after';
    message.attributedBody = [AttributedBody.raw('after')];
    store.box<Message>().put(message);
    final changed = capture();
    expect(changed.manifest.snapshotSha256, isNot(snapshot.manifest.snapshotSha256));
    store.box<Message>().remove(message.id!);
    store.close();
    store = await openStore(directory: directory.path);
    final original = (await snapshot.readExact('stable'))!;
    expect(original.text, 'before');
    expect(original.attributedBodies.single.string, 'before');
    expect(original.senderAddress, me.address);
    expect((await snapshot.readPage(limit: 10)).views.single.guid, 'stable');
    expect(store.box<Message>().count(), 0);
  });

  test('consistent export exceeds a page and never depends on mutable relations', () async {
    for (var i = 0; i < 205; i++) {
      putMessage(guid: 'stable-$i', text: 'before-$i', isFromMe: false, sender: friend, owner: chat);
    }
    final snapshot = capture();
    friend.address = 'changed@example.com';
    store.box<Handle>().put(friend);
    final first = await snapshot.readPage(limit: 200);
    final rest = await snapshot.readPage(cursor: first.nextCursor, limit: 200);
    expect(first.views, hasLength(200));
    expect(rest.views, hasLength(5));
    expect(rest.nextCursor, isNull);
    expect(rest.views.every((row) => row.senderAddress == 'friend@example.com'), isTrue);
    expect(store.box<Message>().count(), 205);
  });

  test('consistent export fails bounds and identity without modifying the source', () {
    putMessage(guid: 'a', text: 'before', isFromMe: false, sender: friend, owner: chat);
    putMessage(guid: 'b', text: 'before', isFromMe: false, sender: friend, owner: chat);
    expect(() => capture(rows: 1), throwsStateError);
    expect(() => capture(bytes: 1), throwsStateError);
    expect(() => capture(current: () => false), throwsStateError);
    var checks = 0;
    expect(() => capture(current: () => ++checks < 3), throwsStateError);
    expect(store.isClosed(), isFalse);
    expect(store.box<Message>().count(), 2);
    expect(store.box<Message>().getAll().every((row) => row.text == 'before'), isTrue);
  });
}
