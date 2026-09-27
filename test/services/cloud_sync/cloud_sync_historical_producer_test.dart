import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_producer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _snapshot =
    'ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34';
const _otherSnapshot =
    'cc12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34';
const _account = 'account-fp-xyz789';
const _nowMs = 1700000000000;
const _createdMs = 1699000000000;

/// Contract model for producer-output assertions only. It mirrors the
/// documented admission decisions (create once, adopt equivalent, retain
/// newer or conflicting, no fresh create on unknown) but does NOT exercise
/// the shared uploader, recovery, or native paths, which parent owns and
/// which remain unverified here.
enum _AdmissionDecision { created, adopted, retained }

class _FakeHistoricalAdmission {
  final Map<String, String> remote = {};
  final Set<String> unknownGuids = {};
  final Map<String, _AdmissionDecision> decisions = {};
  int creates = 0;

  _AdmissionDecision admit(
    StagedHistoricalSource staged,
    Map<String, Object?> payload,
  ) {
    final guid = staged.guid;
    if (unknownGuids.contains(guid)) {
      decisions[guid] = _AdmissionDecision.retained;
      return _AdmissionDecision.retained;
    }
    final contentHash = sha256
        .convert(utf8.encode(payload['text'] as String))
        .toString();
    final existing = remote[guid];
    if (existing == null) {
      remote[guid] = contentHash;
      creates++;
      decisions[guid] = _AdmissionDecision.created;
      return _AdmissionDecision.created;
    }
    if (existing == contentHash) {
      decisions[guid] = _AdmissionDecision.adopted;
      return _AdmissionDecision.adopted;
    }
    decisions[guid] = _AdmissionDecision.retained;
    return _AdmissionDecision.retained;
  }
}

class _StoreReader implements HistoricalRowReader {
  _StoreReader(this.store, this.snapshot);

  final Store store;
  final String snapshot;

  @override
  Future<HistoricalRowPage> readPage({
    String? cursor,
    required int limit,
  }) async {
    final start = cursor == null ? 0 : int.parse(cursor);
    final box = store.box<Message>();
    final handlesByRowId = <int, Handle>{};
    for (final h in store.box<Handle>().getAll()) {
      final rowId = h.originalROWID;
      if (rowId != null) handlesByRowId[rowId] = h;
    }
    final query = box.query()..order(Message_.id);
    final rows = query.build().find();
    final views = <CloudSyncHistoricalRowView>[];
    var last = start;
    var scanned = 0;
    for (final message in rows) {
      final id = message.id ?? -1;
      if (id <= start) continue;
      if (scanned >= limit) break;
      scanned++;
      last = id;
      final chat = message.chat.target;
      if (chat == null) continue;
      message.handle ??= message.handleId == null
          ? null
          : handlesByRowId[message.handleId];
      views.add(
        mapHistoricalRow(
          message: message,
          chat: mapHistoricalChat(chat),
          rowSnapshotSha256: snapshot,
        ),
      );
    }
    final done = rows.every((m) => (m.id ?? -1) <= last);
    return HistoricalRowPage(views: views, nextCursor: done ? null : '$last');
  }
}

class _Registry implements HistoricalOwnershipRegistry {
  _Registry({Set<String>? owned, Set<String>? conflicts})
    : ownedGuids = owned ?? {},
      conflictGuids = conflicts ?? {};

  @override
  final Set<String> ownedGuids;
  @override
  final Set<String> conflictGuids;
}

/// Fixed-view reader for same-pass duplicate coverage.
class _ListReader implements HistoricalRowReader {
  _ListReader(this.views);

  final List<CloudSyncHistoricalRowView> views;

  @override
  Future<HistoricalRowPage> readPage({
    String? cursor,
    required int limit,
  }) async {
    if (cursor != null) {
      return const HistoricalRowPage(views: [], nextCursor: null);
    }
    return HistoricalRowPage(views: views, nextCursor: 'done');
  }
}

/// File-backed byte store so restart tests recreate every service object.
class _FileByteStore implements HistoricalByteStore {
  _FileByteStore(this.dir);

  final Directory dir;

  File _file(String key) => File('${dir.path}/$key');

  @override
  Future<HistoricalPutOutcome> putIfAbsent(String key, List<int> bytes) async {
    // Synchronous section serializes this single-isolate fixture. This is not
    // proof of the future native adapter's cross-process atomicity.
    final file = _file(key);
    if (file.existsSync()) {
      final identical =
          base64Encode(file.readAsBytesSync()) == base64Encode(bytes);
      return identical
          ? HistoricalPutOutcome.identicalExists
          : HistoricalPutOutcome.conflictingExists;
    }
    file.writeAsBytesSync(bytes, flush: true);
    return HistoricalPutOutcome.stored;
  }

  @override
  Future<List<int>?> get(String key) async {
    final file = _file(key);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }
}

/// File-backed cursor store so restart tests recreate every service object.
class _FileCursorStore implements HistoricalCursorStore {
  _FileCursorStore(this.dir);

  final Directory dir;

  File get _file => File('${dir.path}/cursor.json');

  @override
  Future<HistoricalProducerCursor?> load() async {
    if (!await _file.exists()) return null;
    final decoded = jsonDecode(await _file.readAsString());
    if (decoded is! Map<String, Object?>) return null;
    return HistoricalProducerCursor(
      scope: decoded['scope'] as String,
      lastId: decoded['lastId'] as String?,
      done: decoded['done'] as bool,
    );
  }

  @override
  Future<void> save(HistoricalProducerCursor? cursor) async {
    if (cursor == null) {
      if (await _file.exists()) await _file.delete();
      return;
    }
    await _file.writeAsString(
      jsonEncode({
        'scope': cursor.scope,
        'lastId': cursor.lastId,
        'done': cursor.done,
      }),
    );
  }
}

CloudSyncHistoricalAccountBinding _accountBinding() =>
    const CloudSyncHistoricalAccountBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: 'store-1',
    );

Future<CloudSyncHistoricalRowView?> _rowOf(Store store, String guid) async {
  final query = store.box<Message>().query(Message_.guid.equals(guid)).build();
  final Message? message;
  try {
    message = query.findUnique();
  } finally {
    query.close();
  }
  final chat = message?.chat.target;
  if (message == null || chat == null) return null;
  if (message.handleId != null) {
    final handles = store
        .box<Handle>()
        .query(Handle_.originalROWID.equals(message.handleId!))
        .build();
    try {
      message.handle = handles.findUnique();
    } finally {
      handles.close();
    }
  }
  return mapHistoricalRow(
    message: message,
    chat: mapHistoricalChat(chat),
    rowSnapshotSha256: _snapshot,
  );
}

class _FileAdoptions {
  _FileAdoptions(this.directory);
  final Directory directory;
  int newWrites = 0;

  /// Combined stage-and-adopt double: verifies canonical bytes against
  /// the request digest, then durably records the sealed result.
  /// Idempotent for identical bytes, conflicting otherwise.
  Future<StagedHistoricalSource> stageAndAdopt(
    CloudSyncHistoricalArchiveRequest request,
    List<int> canonicalBytes,
  ) async {
    final file = File('${directory.path}/adopted-${request.sourceSha256}.json');
    final sealed = StagedHistoricalSource(
      key: request.sourceSha256,
      sha256: historicalBytesSha256(canonicalBytes),
      byteLength: canonicalBytes.length,
      guid: request.guid,
    );
    final value = jsonEncode({
      'key': sealed.key,
      'sha': sealed.sha256,
      'length': sealed.byteLength,
      'guid': sealed.guid,
    });
    if (file.existsSync()) {
      if (file.readAsStringSync() != value) {
        throw StateError('adoption_conflict');
      }
      return sealed;
    }
    file.writeAsStringSync(value, flush: true);
    newWrites++;
    return sealed;
  }

  List<StagedHistoricalSource> pending() => directory
      .listSync()
      .whereType<File>()
      .where((file) => file.uri.pathSegments.last.startsWith('adopted-'))
      .map((file) {
        final value =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        return StagedHistoricalSource(
          key: value['key'] as String,
          sha256: value['sha'] as String,
          byteLength: value['length'] as int,
          guid: value['guid'] as String,
        );
      })
      .toList();
}

void main() {
  late Directory directory;
  late Store store;
  late Chat chat;
  late Chat groupChat;
  late Handle friend;
  late Handle me;
  late Map<String, StagedHistoricalSource> adoptions;

  Future<StagedHistoricalSource> adopt(
    CloudSyncHistoricalArchiveRequest request,
    List<int> canonicalBytes,
  ) async {
    final sealed = StagedHistoricalSource(
      key: request.sourceSha256,
      sha256: historicalBytesSha256(canonicalBytes),
      byteLength: canonicalBytes.length,
      guid: request.guid,
    );
    final prior = adoptions[sealed.key];
    if (prior != null) {
      if (prior.sha256 != sealed.sha256 ||
          prior.byteLength != sealed.byteLength ||
          prior.guid != sealed.guid) {
        throw StateError('adoption_conflict');
      }
      return prior;
    }
    adoptions[sealed.key] = sealed;
    return sealed;
  }

  CloudSyncHistoricalSourceManifest manifest() =>
      const CloudSyncHistoricalSourceManifest(
        snapshotSha256: _snapshot,
        accountFingerprint: _account,
        accountHandles: ['me@example.com'],
        messageCount: 6,
        capturedAtMs: 1699500000000,
      );

  Message putMessage({
    required String guid,
    required String text,
    required bool isFromMe,
    required Handle sender,
    required Chat owner,
    DateTime? dateDeleted,
    DateTime? dateEdited,
    bool hasAttachments = false,
  }) {
    final message =
        Message(
            guid: guid,
            text: text,
            attributedBody: [AttributedBody.raw(text)],
            dateCreated: DateTime.fromMillisecondsSinceEpoch(_createdMs),
            isFromMe: isFromMe,
            dateDeleted: dateDeleted,
            dateEdited: dateEdited,
            hasAttachments: hasAttachments,
          )
          ..handle = sender
          ..handleId = sender.originalROWID
          ..chat.target = owner;
    store.box<Message>().put(message);
    return message;
  }

  setUp(() async {
    adoptions = {};
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-historical-producer-',
    );
    store = await openStore(directory: directory.path);
    friend = Handle(
      address: 'friend@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'friend@example.com/iMessage',
    );
    me = Handle(
      address: 'me@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'me@example.com/iMessage',
    );
    store.box<Handle>().putMany([friend, me]);
    friend.originalROWID = 101;
    me.originalROWID = 102;
    store.box<Handle>().putMany([friend, me]);
    expect(friend.id, isNot(101));
    expect(me.id, isNot(102));
    chat = Chat(
      guid: 'iMessage;-;friend@example.com',
      chatIdentifier: 'friend@example.com',
      usingHandle: 'me@example.com',
      style: 45,
      participants: [friend],
    )..handles.add(friend);
    groupChat =
        Chat(
            guid: 'iMessage;+;group-1',
            chatIdentifier: 'group-1',
            style: 43,
            participants: [friend, me],
          )
          ..handles.add(friend)
          ..handles.add(me);
    store.box<Chat>().putMany([chat, groupChat]);
    putMessage(
      guid: 'guid-incoming-1',
      text: 'old hello',
      isFromMe: false,
      sender: friend,
      owner: chat,
    );
    putMessage(
      guid: 'guid-sent-1',
      text: 'old reply',
      isFromMe: true,
      sender: me,
      owner: chat,
    );
    putMessage(
      guid: 'guid-tombstone-1',
      text: 'gone',
      isFromMe: false,
      sender: friend,
      owner: chat,
      dateDeleted: DateTime.fromMillisecondsSinceEpoch(_createdMs),
    );
    putMessage(
      guid: 'guid-edited-1',
      text: 'changed',
      isFromMe: false,
      sender: friend,
      owner: chat,
      dateEdited: DateTime.fromMillisecondsSinceEpoch(_createdMs),
    );
    putMessage(
      guid: 'guid-media-1',
      text: 'photo',
      isFromMe: false,
      sender: friend,
      owner: chat,
      hasAttachments: true,
    );
    putMessage(
      guid: 'guid-group-1',
      text: 'group hello',
      isFromMe: false,
      sender: friend,
      owner: groupChat,
    );
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
  }

  test(
    'producer stages eligible rows and retains the rest with reasons',
    () async {
      final cursors = MemoryHistoricalCursorStore();
      final seen = <String, List<int>>{};
      final producer = CloudSyncHistoricalProducer(
        reader: _StoreReader(store, _snapshot),
        registry: _Registry(),
        cursors: cursors,
        manifest: manifest(),
        account: _accountBinding(),
        readCurrentRow: (guid) => _rowOf(store, guid),
        stageAndAdopt: (request, canonicalBytes) {
          seen[request.guid] = List<int>.of(canonicalBytes);
          return adopt(request, canonicalBytes);
        },
        nowMs: _nowMs,
      );
      final result = await producer.run();
      expect(result.summary.assessed, 6);
      expect(result.summary.staged, 2);
      expect(result.summary.completed, isTrue);
      expect(
        result.summary.ineligibleByReason[CloudSyncHistoricalArchiveReasons
            .tombstone],
        1,
      );
      expect(
        result.summary.ineligibleByReason[CloudSyncHistoricalArchiveReasons
            .mutation],
        1,
      );
      expect(
        result.summary.ineligibleByReason[CloudSyncHistoricalArchiveReasons
            .media],
        1,
      );
      expect(
        result.summary.ineligibleByReason[CloudSyncHistoricalArchiveReasons
            .group],
        1,
      );
      expect(result.output.staged.map((s) => s.guid).toSet(), {
        'guid-incoming-1',
        'guid-sent-1',
      });
      for (final staged in result.output.staged) {
        final payload =
            jsonDecode(utf8.decode(seen[staged.guid]!)) as Map<String, dynamic>;
        expect(payload['guid'], staged.guid);
        expect(staged.key.length, 64);
        expect(staged.byteLength, seen[staged.guid]!.length);
      }
    },
  );

  test('same GUID twice and restart stage nothing new', () async {
    final serviceDir = await Directory.systemTemp.createTemp(
      'openbubbles-historical-services-',
    );
    try {
      final admission = _FakeHistoricalAdmission();
      Future<Set<String>> pass() async {
        final cursors = _FileCursorStore(serviceDir);
        final producer = CloudSyncHistoricalProducer(
          reader: _StoreReader(store, _snapshot),
          registry: _Registry(owned: admission.remote.keys.toSet()),
          cursors: cursors,
          manifest: manifest(),
          account: _accountBinding(),
          readCurrentRow: (guid) => _rowOf(store, guid),
          stageAndAdopt: (request, canonicalBytes) async {
            final staged = await _FileAdoptions(
              serviceDir,
            ).stageAndAdopt(request, canonicalBytes);
            final payload =
                jsonDecode(utf8.decode(canonicalBytes))
                    as Map<String, Object?>;
            admission.admit(staged, payload);
            return staged;
          },
          nowMs: _nowMs,
        );
        final result = await producer.run();
        return result.output.staged.map((s) => s.guid).toSet();
      }

      final first = await pass();
      expect(first, {'guid-incoming-1', 'guid-sent-1'});
      expect(admission.creates, 2);
      await reopen();
      final second = await pass();
      expect(second, isEmpty);
      expect(admission.creates, 2);
      expect((await _FileCursorStore(serviceDir).load())?.done, isTrue);
      // Scan completion does not consume the durable pending journal.
      // Recreate the journal independently after all producer objects.
      final pending = _FileAdoptions(serviceDir).pending();
      expect(pending, hasLength(2));
      expect(pending.map((s) => s.guid).toSet(), {
        'guid-incoming-1',
        'guid-sent-1',
      });
    } finally {
      if (serviceDir.existsSync()) await serviceDir.delete(recursive: true);
    }
  });

  test(
    'contract model: found newer remote is retained without overwrite',
    () async {
      final admission = _FakeHistoricalAdmission();
      admission.remote['guid-incoming-1'] = 'newer-remote-content-hash';
      final seen = <String, List<int>>{};
      final producer = CloudSyncHistoricalProducer(
        reader: _StoreReader(store, _snapshot),
        registry: _Registry(),
        cursors: MemoryHistoricalCursorStore(),
        manifest: manifest(),
        account: _accountBinding(),
        readCurrentRow: (guid) => _rowOf(store, guid),
        stageAndAdopt: (request, canonicalBytes) {
          seen[request.guid] = List<int>.of(canonicalBytes);
          return adopt(request, canonicalBytes);
        },
        nowMs: _nowMs,
      );
      final result = await producer.run();
      var retained = 0;
      for (final staged in result.output.staged) {
        final payload =
            jsonDecode(utf8.decode(seen[staged.guid]!))
                as Map<String, Object?>;
        if (staged.guid == 'guid-incoming-1') {
          expect(admission.admit(staged, payload), _AdmissionDecision.retained);
          retained++;
        }
      }
      expect(retained, 1);
      expect(admission.remote['guid-incoming-1'], 'newer-remote-content-hash');
      expect(admission.creates, 0);
    },
  );

  test('contract model: unknown outcome records no fresh create', () async {
    final admission = _FakeHistoricalAdmission();
    admission.unknownGuids.add('guid-sent-1');
    final seen = <String, List<int>>{};
    final producer = CloudSyncHistoricalProducer(
      reader: _StoreReader(store, _snapshot),
      registry: _Registry(),
      cursors: MemoryHistoricalCursorStore(),
      manifest: manifest(),
      account: _accountBinding(),
      readCurrentRow: (guid) => _rowOf(store, guid),
      stageAndAdopt: (request, canonicalBytes) {
        seen[request.guid] = List<int>.of(canonicalBytes);
        return adopt(request, canonicalBytes);
      },
      nowMs: _nowMs,
    );
    final result = await producer.run();
    for (final staged in result.output.staged) {
      final payload =
          jsonDecode(utf8.decode(seen[staged.guid]!)) as Map<String, Object?>;
      admission.admit(staged, payload);
    }
    expect(admission.decisions['guid-sent-1'], _AdmissionDecision.retained);
    expect(admission.remote.containsKey('guid-sent-1'), isFalse);
    expect(admission.creates, 1);
  });

  test('wrong-account manifest stages nothing', () async {
    const wrong = CloudSyncHistoricalSourceManifest(
      snapshotSha256: _otherSnapshot,
      accountFingerprint: 'other-account',
      accountHandles: ['someone@example.com'],
      messageCount: 6,
      capturedAtMs: 1699500000000,
    );
    final producer = CloudSyncHistoricalProducer(
      reader: _StoreReader(store, _snapshot),
      registry: _Registry(),
      cursors: MemoryHistoricalCursorStore(),
      manifest: wrong,
      account: _accountBinding(),
      readCurrentRow: (guid) => _rowOf(store, guid),
      stageAndAdopt: adopt,
      nowMs: _nowMs,
    );
    await expectLater(producer.run(), throwsStateError);
    expect(adoptions, isEmpty);
  });

  test('foreign-scope cursor is preserved instead of overwritten', () async {
    final cursors = MemoryHistoricalCursorStore();
    await cursors.save(
      const HistoricalProducerCursor(
        scope: 'other-snapshot:other-account',
        lastId: '3',
        done: false,
      ),
    );
    final producer = CloudSyncHistoricalProducer(
      reader: _StoreReader(store, _snapshot),
      registry: _Registry(),
      cursors: cursors,
      manifest: manifest(),
      account: _accountBinding(),
      readCurrentRow: (guid) => _rowOf(store, guid),
      stageAndAdopt: adopt,
      nowMs: _nowMs,
    );
    await expectLater(producer.run(), throwsStateError);
    expect((await cursors.load())?.scope, 'other-snapshot:other-account');
    expect((await cursors.load())?.lastId, '3');
    expect(adoptions, isEmpty);
  });

  test('same-pass duplicate GUID stages once', () async {
    final message = store
        .box<Message>()
        .query(Message_.guid.equals('guid-incoming-1'))
        .build()
        .findFirst()!;
    message.handle ??= message.handleId == null
        ? null
        : store
              .box<Handle>()
              .query(Handle_.originalROWID.equals(message.handleId!))
              .build()
              .findFirst();
    final chatView = mapHistoricalChat(chat);
    final view = mapHistoricalRow(
      message: message,
      chat: chatView,
      rowSnapshotSha256: _snapshot,
    );
    final reader = _ListReader([view, view]);
    final producer = CloudSyncHistoricalProducer(
      reader: reader,
      registry: _Registry(),
      cursors: MemoryHistoricalCursorStore(),
      manifest: manifest(),
      account: _accountBinding(),
      readCurrentRow: (_) async => view,
      stageAndAdopt: adopt,
      nowMs: _nowMs,
    );
    final result = await producer.run();
    expect(result.summary.staged, 1);
    expect(result.summary.skippedOwned, 1);
  });

  test('mapper extracts real entity fields for assessment', () async {
    final message = store
        .box<Message>()
        .query(Message_.guid.equals('guid-incoming-1'))
        .build()
        .findFirst()!;
    message.handle ??= message.handleId == null
        ? null
        : store
              .box<Handle>()
              .query(Handle_.originalROWID.equals(message.handleId!))
              .build()
              .findFirst();
    final view = mapHistoricalRow(
      message: message,
      chat: mapHistoricalChat(chat),
      rowSnapshotSha256: _snapshot,
    );
    expect(view.guid, 'guid-incoming-1');
    expect(view.text, 'old hello');
    expect(view.dateCreatedMs, _createdMs);
    expect(view.senderAddress, 'friend@example.com');
    expect(view.messageId, greaterThan(0));
    final assessment = assessHistoricalArchiveRow(
      view,
      manifest(),
      _accountBinding(),
      nowMs: _nowMs,
    );
    expect(assessment, isA<CloudSyncHistoricalArchiveEligible>());
  });

  test('mapper retains unknown direction and persisted-only attachments', () {
    final query = store
        .box<Message>()
        .query(Message_.guid.equals('guid-incoming-1'))
        .build();
    final Message message;
    try {
      message = query.findFirst()!;
    } finally {
      query.close();
    }
    message.isFromMe = null;
    message.handle = friend;
    store.box<Message>().put(message);
    final attachment = Attachment(guid: 'stored-only-attachment');
    attachment.message.targetId = message.id!;
    store.box<Attachment>().put(attachment);
    final restored = store.box<Message>().get(message.id!)!;
    restored.handle = friend;
    expect(restored.attachments, isEmpty);
    expect(restored.hasAttachments, isFalse);
    final view = mapHistoricalRow(
      message: restored,
      chat: mapHistoricalChat(chat),
      rowSnapshotSha256: _snapshot,
    );
    expect(view.isFromMe, isNull);
    expect(view.attachmentCount, 1);
    final unknown = assessHistoricalArchiveRow(
      view,
      manifest(),
      _accountBinding(),
      nowMs: _nowMs,
    );
    expect(
      (unknown as CloudSyncHistoricalArchiveIneligible).reason,
      CloudSyncHistoricalArchiveReasons.directionMismatch,
    );
    restored.isFromMe = false;
    final withAttachment = mapHistoricalRow(
      message: restored,
      chat: mapHistoricalChat(chat),
      rowSnapshotSha256: _snapshot,
    );
    final media = assessHistoricalArchiveRow(
      withAttachment,
      manifest(),
      _accountBinding(),
      nowMs: _nowMs,
    );
    expect(
      (media as CloudSyncHistoricalArchiveIneligible).reason,
      CloudSyncHistoricalArchiveReasons.media,
    );
  });

  for (final afterAdoption in [false, true]) {
    test(
      'restart after ${afterAdoption ? 'durable adoption' : 'staging'} before cursor save',
      () async {
        final serviceDir = Directory('${directory.path}/services')
          ..createSync();
        final journal = _FileAdoptions(serviceDir);
        final interrupted = CloudSyncHistoricalProducer(
          reader: _StoreReader(store, _snapshot),
          registry: _Registry(),
          cursors: _FileCursorStore(serviceDir),
          manifest: manifest(),
          account: _accountBinding(),
          nowMs: _nowMs,
          pageLimit: 1,
          readCurrentRow: (guid) => _rowOf(store, guid),
          stageAndAdopt: (request, canonicalBytes) async {
            if (afterAdoption) {
              await journal.stageAndAdopt(request, canonicalBytes);
            }
            throw StateError('simulated_interruption');
          },
        );
        await expectLater(interrupted.run(), throwsStateError);
        expect(await _FileCursorStore(serviceDir).load(), isNull);
        expect(
          _FileAdoptions(serviceDir).pending(),
          hasLength(afterAdoption ? 1 : 0),
        );
        await reopen();
        final reopenedJournal = _FileAdoptions(serviceDir);
        final resumed = CloudSyncHistoricalProducer(
          reader: _StoreReader(store, _snapshot),
          registry: _Registry(),
          cursors: _FileCursorStore(serviceDir),
          manifest: manifest(),
          account: _accountBinding(),
          nowMs: _nowMs,
          pageLimit: 1,
          readCurrentRow: (guid) => _rowOf(store, guid),
          stageAndAdopt: reopenedJournal.stageAndAdopt,
        );
        expect((await resumed.run()).summary.completed, isTrue);
        expect(reopenedJournal.newWrites, afterAdoption ? 1 : 2);
        expect(_FileAdoptions(serviceDir).pending(), hasLength(2));
        // A completed scan does not rescan, and its pending journal survives.
        final repeated = await resumed.run();
        expect(repeated.summary.assessed, 0);
        expect(repeated.output.staged, isEmpty);
        expect(_FileAdoptions(serviceDir).pending(), hasLength(2));
      },
    );
  }

  test('changed protected store cannot reuse completed scan', () async {
    final cursors = MemoryHistoricalCursorStore();
    final originalScope = historicalArchiveScope(manifest(), _accountBinding());
    await cursors.save(
      HistoricalProducerCursor(scope: originalScope, lastId: null, done: true),
    );
    final producer = CloudSyncHistoricalProducer(
      reader: _StoreReader(store, _snapshot),
      registry: _Registry(),
      cursors: cursors,
      manifest: manifest(),
      account: const CloudSyncHistoricalAccountBinding(
        accountFingerprint: _account,
        protectedStoreIdentity: 'store-2',
      ),
      readCurrentRow: (guid) => _rowOf(store, guid),
      stageAndAdopt: adopt,
      nowMs: _nowMs,
    );
    await expectLater(producer.run(), throwsStateError);
    expect((await cursors.load())?.scope, originalScope);
    expect(adoptions, isEmpty);
  });

  test('invalid manifest is checked before completed scan shortcut', () async {
    const wrong = CloudSyncHistoricalSourceManifest(
      snapshotSha256: _snapshot,
      accountFingerprint: 'other-account',
      accountHandles: ['me@example.com'],
      messageCount: 6,
      capturedAtMs: 1699500000000,
    );
    final cursors = MemoryHistoricalCursorStore();
    await cursors.save(
      HistoricalProducerCursor(
        scope: historicalArchiveScope(wrong, _accountBinding()),
        lastId: null,
        done: true,
      ),
    );
    final producer = CloudSyncHistoricalProducer(
      reader: _StoreReader(store, _snapshot),
      registry: _Registry(),
      cursors: cursors,
      manifest: wrong,
      account: _accountBinding(),
      readCurrentRow: (guid) => _rowOf(store, guid),
      stageAndAdopt: adopt,
      nowMs: _nowMs,
    );
    await expectLater(producer.run(), throwsStateError);
    expect(adoptions, isEmpty);
  });

  test('changed current row cannot stage or advance the scan', () async {
    final cursors = MemoryHistoricalCursorStore();
    final producer = CloudSyncHistoricalProducer(
      reader: _StoreReader(store, _snapshot),
      registry: _Registry(),
      cursors: cursors,
      manifest: manifest(),
      account: _accountBinding(),
      readCurrentRow: (_) async => _rowView(text: 'changed after assessment'),
      stageAndAdopt: adopt,
      nowMs: _nowMs,
    );
    await expectLater(producer.run(), throwsStateError);
    expect(await cursors.load(), isNull);
    expect(adoptions, isEmpty);
  });

  test(
    'full source recheck rejects route time origin and store changes',
    () async {
      final request = _eligibleRequest();
      final changedRows = [
        _rowView(peer: 'other@example.com'),
        _rowView(createdMs: _createdMs + 1),
        _rowView(fromMe: true),
      ];
      final bytes = MemoryHistoricalByteStore();
      for (final current in changedRows) {
        await expectLater(
          stageHistoricalSource(
            store: bytes,
            request: request,
            currentRow: current,
            manifest: _manifestForStaging(),
            account: _accountBinding(),
            nowMs: _nowMs,
          ),
          throwsStateError,
        );
      }
      await expectLater(
        stageHistoricalSource(
          store: bytes,
          request: request,
          currentRow: _rowView(),
          manifest: _manifestForStaging(),
          account: const CloudSyncHistoricalAccountBinding(
            accountFingerprint: _account,
            protectedStoreIdentity: 'store-2',
          ),
          nowMs: _nowMs,
        ),
        throwsStateError,
      );
      expect(await bytes.get(request.sourceSha256), isNull);
    },
  );

  test('atomic byte contract keeps exactly one concurrent winner', () async {
    final bytes = MemoryHistoricalByteStore();
    final outcomes = await Future.wait([
      bytes.putIfAbsent('key', [1]),
      bytes.putIfAbsent('key', [2]),
    ]);
    expect(
      outcomes.where((r) => r == HistoricalPutOutcome.stored),
      hasLength(1),
    );
    expect(
      outcomes.where((r) => r == HistoricalPutOutcome.conflictingExists),
      hasLength(1),
    );
    final original = (await bytes.get('key'))!;
    expect(
      await bytes.putIfAbsent('key', original),
      HistoricalPutOutcome.identicalExists,
    );
    expect(await bytes.get('key'), original);
  });

  test(
    'encoded source is bounded even when text is within its byte limit',
    () async {
      // NUL now rejects during eligibility. A different JSON-escaped control
      // character still exercises the encoded envelope limit, not that guard.
      final row = _rowView(text: List.filled(262144, '\u0001').join());
      final assessed =
          assessHistoricalArchiveRow(
                row,
                _manifestForStaging(),
                _accountBinding(),
                nowMs: _nowMs,
              )
              as CloudSyncHistoricalArchiveEligible;
      final bytes = MemoryHistoricalByteStore();
      await expectLater(
        stageHistoricalSource(
          store: bytes,
          request: assessed.request,
          currentRow: row,
          manifest: _manifestForStaging(),
          account: _accountBinding(),
          nowMs: _nowMs,
        ),
        throwsStateError,
      );
      expect(await bytes.get(assessed.request.sourceSha256), isNull);
    },
  );

  test('stage-and-adopt failure blocks cursor advancement', () async {
    final cursors = MemoryHistoricalCursorStore();
    final producer = CloudSyncHistoricalProducer(
      reader: _StoreReader(store, _snapshot),
      registry: _Registry(),
      cursors: cursors,
      manifest: manifest(),
      account: _accountBinding(),
      readCurrentRow: (guid) => _rowOf(store, guid),
      stageAndAdopt: (_, __) async {
        throw StateError('synthetic_native_stage_failure');
      },
      nowMs: _nowMs,
    );
    await expectLater(producer.run(), throwsStateError);
    expect(await cursors.load(), isNull);
    expect(adoptions, isEmpty);
  });

  test('mismatched sealed metadata blocks cursor advancement', () async {
    for (var field = 0; field < 4; field++) {
      final cursors = MemoryHistoricalCursorStore();
      final seen = <String>[];
      final producer = CloudSyncHistoricalProducer(
        reader: _StoreReader(store, _snapshot),
        registry: _Registry(),
        cursors: cursors,
        manifest: manifest(),
        account: _accountBinding(),
        readCurrentRow: (guid) => _rowOf(store, guid),
        stageAndAdopt: (request, canonicalBytes) async {
          seen.add(request.guid);
          final sha = historicalBytesSha256(canonicalBytes);
          switch (field) {
            case 0:
              return StagedHistoricalSource(
                key: 'wrong-key',
                sha256: sha,
                byteLength: canonicalBytes.length,
                guid: request.guid,
              );
            case 1:
              return StagedHistoricalSource(
                key: request.sourceSha256,
                sha256: sha,
                byteLength: canonicalBytes.length,
                guid: 'wrong-guid',
              );
            case 2:
              return StagedHistoricalSource(
                key: request.sourceSha256,
                sha256: '0' * 64,
                byteLength: canonicalBytes.length,
                guid: request.guid,
              );
            default:
              return StagedHistoricalSource(
                key: request.sourceSha256,
                sha256: sha,
                byteLength: canonicalBytes.length + 1,
                guid: request.guid,
              );
          }
        },
        nowMs: _nowMs,
      );
      await expectLater(producer.run(), throwsStateError);
      expect(seen, isNotEmpty);
      expect(await cursors.load(), isNull);
      expect(adoptions, isEmpty);
    }
  });

  test('callback mutating canonical bytes cannot advance the cursor', () async {
    final cursors = MemoryHistoricalCursorStore();
    final producer = CloudSyncHistoricalProducer(
      reader: _StoreReader(store, _snapshot),
      registry: _Registry(),
      cursors: cursors,
      manifest: manifest(),
      account: _accountBinding(),
      readCurrentRow: (guid) => _rowOf(store, guid),
      stageAndAdopt: (request, canonicalBytes) async {
        // The producer hands over unmodifiable bytes and validates the
        // result against pre-await expectations, so any attempt to alter
        // content or return matching metadata for altered bytes fails.
        try {
          canonicalBytes[0] = 0xFF;
        } catch (_) {
          throw StateError('synthetic_callback_mutation_rejected');
        }
        return StagedHistoricalSource(
          key: request.sourceSha256,
          sha256: historicalBytesSha256(canonicalBytes),
          byteLength: canonicalBytes.length,
          guid: request.guid,
        );
      },
      nowMs: _nowMs,
    );
    await expectLater(producer.run(), throwsStateError);
    expect(await cursors.load(), isNull);
    expect(adoptions, isEmpty);
  });

  test('tampered staged bytes fail on open', () async {
    final bytes = _FileByteStore(directory);
    final request = _eligibleRequest();
    final staged = await stageHistoricalSource(
      store: bytes,
      request: request,
      currentRow: _rowView(),
      manifest: _manifestForStaging(),
      account: _accountBinding(),
      nowMs: _nowMs,
    );
    await File('${directory.path}/${staged.key}').writeAsString('tampered');
    await expectLater(
      openHistoricalSource(store: bytes, staged: staged),
      throwsStateError,
    );
    final missing = StagedHistoricalSource(
      key: 'nope',
      sha256: staged.sha256,
      byteLength: staged.byteLength,
      guid: staged.guid,
    );
    await expectLater(
      openHistoricalSource(store: bytes, staged: missing),
      throwsStateError,
    );
  });
}

CloudSyncHistoricalArchiveRequest _eligibleRequest() {
  final assessment = assessHistoricalArchiveRow(
    _rowView(),
    _manifestForStaging(),
    _accountBinding(),
    nowMs: _nowMs,
  );
  return (assessment as CloudSyncHistoricalArchiveEligible).request;
}

CloudSyncHistoricalSourceManifest _manifestForStaging() =>
    const CloudSyncHistoricalSourceManifest(
      snapshotSha256: _snapshot,
      accountFingerprint: _account,
      accountHandles: ['me@example.com'],
      messageCount: 1,
      capturedAtMs: 1699500000000,
    );

CloudSyncHistoricalRowView _rowView({
  String text = 'old hello',
  String peer = 'friend@example.com',
  bool fromMe = false,
  int createdMs = _createdMs,
}) {
  final chat = CloudSyncHistoricalChatView(
    id: 7,
    guid: 'iMessage;-;$peer',
    style: 45,
    chatIdentifier: peer,
    isRoutingStub: false,
    dateDeletedPresent: false,
    isRpSms: false,
    participantCount: 1,
    participantAddress: peer,
    participantService: 'iMessage',
  );
  return CloudSyncHistoricalRowView(
    guid: 'guid-incoming-1',
    text: text,
    attributedBodies: [AttributedBody.raw(text)],
    hasActualEditOrUnsend: false,
    dateEditedPresent: false,
    associationPresent: false,
    isFromMe: fromMe,
    senderAddress: fromMe ? 'me@example.com' : peer,
    chat: chat,
    dateCreatedMs: createdMs,
    error: 0,
    isTemp: false,
    stagingGuid: null,
    sendingServiceId: null,
    hasBeenForwarded: false,
    verificationFailed: false,
    ckRecordId: null,
    ckSyncState: false,
    messageId: 11,
    itemType: 0,
    groupActionType: 0,
    groupTitle: null,
    isDeleted: false,
    dateScheduledPresent: false,
    threadOriginatorPresent: false,
    hasAttachments: false,
    attachmentCount: 0,
    subjectPresent: false,
    expressiveSendStyleIdPresent: false,
    balloonBundleIdPresent: false,
    payloadDataPresent: false,
    hasApplePayloadData: false,
    amkSessionIdPresent: false,
    rowSnapshotSha256: _snapshot,
  );
}
