import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_cursor_file.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_producer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

String get _account => 'A' * 43;
String get _store => 'obcs2.store.${'S' * 43}';

CloudSyncHistoricalSourceManifest _manifest({String? snapshot}) =>
    CloudSyncHistoricalSourceManifest(
      snapshotSha256: snapshot ?? 'a' * 64,
      accountFingerprint: _account,
      accountHandles: const ['synthetic@example.invalid'],
      messageCount: 100,
      capturedAtMs: 1700000000000,
    );

void main() {
  late Directory directory;
  late _LocalTransport transport;
  var current = true;

  CloudSyncHistoricalCursorFile cursorFile({
    String? snapshot,
    CloudProtectedPageLeaseTransport? selected,
    CloudSyncHistoricalCursorMode mode =
        CloudSyncHistoricalCursorMode.stageOnly,
    int archiveRevision = 0,
  }) => CloudSyncHistoricalCursorFile(
    privateStorageDirectory: directory.path,
    manifest: _manifest(snapshot: snapshot),
    account: CloudSyncHistoricalAccountBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: _store,
    ),
    transport: selected ?? transport,
    stillCurrent: () => current,
    mode: mode,
    archiveRevision: archiveRevision,
  );

  HistoricalProducerCursor progress(
    CloudSyncHistoricalCursorFile store,
    int? lastId,
  ) => HistoricalProducerCursor(
    scope: store.scope,
    lastId: lastId == null ? null : 'historical-scan:v1:${store.scope}:$lastId',
    done: lastId == null,
  );

  File target(CloudSyncHistoricalCursorFile store) => File(
    path.join(
      directory.path,
      CloudSyncHistoricalCursorFile.directoryName,
      '${store.scope}${store.mode != CloudSyncHistoricalCursorMode.archive
          ? ''
          : store.archiveRevision == 0
          ? '.archive'
          : '.archive-r${store.archiveRevision}'}.json',
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'obcs-historical-cursor-',
    );
    transport = _LocalTransport();
    current = true;
  });
  tearDown(() async => directory.delete(recursive: true));

  test('read never creates progress and save requires a load', () async {
    final store = cursorFile();
    await expectLater(store.save(progress(store, 2)), throwsStateError);
    expect(await store.load(), isNull);
    expect(await directory.list().toList(), isEmpty);
    expect(transport.entries, 1);
  });

  test('media policy and its trial preserve distinct earlier group cursors', () async {
    final saved = <int, String>{};
    for (final revision in [3, 4, 5, 6]) {
      final selected = cursorFile(mode: CloudSyncHistoricalCursorMode.archive,
        archiveRevision: revision);
      expect(await selected.load(), isNull);
      await selected.save(progress(selected, revision));
      saved[revision] = await target(selected).readAsString();
    }
    for (final revision in [3, 4, 5, 6]) {
      final selected = cursorFile(mode: CloudSyncHistoricalCursorMode.archive,
        archiveRevision: revision);
      expect((await selected.load())?.lastId, progress(selected, revision).lastId);
      expect(await target(selected).readAsString(), saved[revision]);
    }
    expect(await target(cursorFile()).parent.list().toList(), hasLength(4));
  });

  test(
    'reopen resumes pages then completion without retaining temp files',
    () async {
      final first = cursorFile();
      await first.load();
      await first.save(progress(first, 5));
      final next = cursorFile();
      expect((await next.load())?.lastId, progress(first, 5).lastId);
      await next.save(progress(next, 10));
      await next.save(progress(next, null));
      expect((await cursorFile().load())?.done, isTrue);
      expect(await target(next).parent.list().toList(), hasLength(1));
      expect(await target(next).length(), lessThan(1024));
    },
  );

  test(
    'same checkpoint is idempotent but reset and rewind are rejected',
    () async {
      final store = cursorFile();
      await store.load();
      await store.save(progress(store, 5));
      final before = await target(store).readAsBytes();
      await store.save(progress(store, 5));
      await expectLater(store.save(progress(store, 4)), throwsStateError);
      await expectLater(store.save(null), throwsStateError);
      expect(await target(store).readAsBytes(), before);
      await store.save(progress(store, null));
      await expectLater(store.save(progress(store, 6)), throwsStateError);
      expect((await cursorFile().load())?.done, isTrue);
    },
  );

  test('stale worker cannot overwrite or complete newer progress', () async {
    final first = cursorFile();
    final stale = cursorFile();
    await first.load();
    await stale.load();
    await first.save(progress(first, 5));
    await expectLater(stale.save(progress(stale, null)), throwsStateError);
    await expectLater(stale.save(progress(stale, 2)), throwsStateError);
    expect((await cursorFile().load())?.lastId, progress(first, 5).lastId);
    await stale.load();
    await stale.save(progress(stale, 6));
  });

  test(
    'new archive policy replays the same snapshot without erasing old progress',
    () async {
      final first = cursorFile(
        mode: CloudSyncHistoricalCursorMode.archive,
        archiveRevision: 1,
      );
      await first.load();
      await first.save(progress(first, null));
      final oldBytes = await target(first).readAsBytes();
      expect(
        (await cursorFile(
          mode: CloudSyncHistoricalCursorMode.archive,
          archiveRevision: 1,
        ).load())?.done,
        isTrue,
      );
      final next = cursorFile(
        mode: CloudSyncHistoricalCursorMode.archive,
        archiveRevision: 2,
      );
      expect(next.scope, first.scope); // Source/account identity is unchanged.
      expect(
        await next.load(),
        isNull,
      ); // A past scan is not new-codec completion.
      await next.save(progress(next, 5));
      expect(
        (await cursorFile(
          mode: CloudSyncHistoricalCursorMode.archive,
          archiveRevision: 1,
        ).load())?.done,
        isTrue,
      );
      expect(
        (await cursorFile(
          mode: CloudSyncHistoricalCursorMode.archive,
          archiveRevision: 2,
        ).load())?.lastId,
        progress(next, 5).lastId,
      );
      expect(await target(first).readAsBytes(), oldBytes);
    },
  );

  test(
    'versioned archive preserves legacy archive and staging progress',
    () async {
      final stage = cursorFile();
      final oldArchive = cursorFile(
        mode: CloudSyncHistoricalCursorMode.archive,
      );
      for (final old in [stage, oldArchive]) {
        await old.load();
        await old.save(progress(old, null));
      }
      final stageBytes = await target(stage).readAsBytes();
      final archiveBytes = await target(oldArchive).readAsBytes();
      final next = cursorFile(
        mode: CloudSyncHistoricalCursorMode.archive,
        archiveRevision: 1,
      );
      expect(await next.load(), isNull);
      await next.save(progress(next, 4));
      expect(await target(stage).readAsBytes(), stageBytes);
      expect(await target(oldArchive).readAsBytes(), archiveBytes);
      expect(await target(next).parent.list().toList(), hasLength(3));
    },
  );

  test(
    'wrong revision content is retained and rejected even if renamed',
    () async {
      final first = cursorFile(
        mode: CloudSyncHistoricalCursorMode.archive,
        archiveRevision: 1,
      );
      await first.load();
      await first.save(progress(first, null));
      final next = cursorFile(
        mode: CloudSyncHistoricalCursorMode.archive,
        archiveRevision: 2,
      );
      final before = await target(first).readAsBytes();
      await target(first).copy(target(next).path);
      await expectLater(next.load(), throwsStateError);
      expect(await target(next).readAsBytes(), before);
      expect(await target(first).readAsBytes(), before);
    },
  );

  test('archive revision retains compare-and-swap protection', () async {
    final first = cursorFile(
      mode: CloudSyncHistoricalCursorMode.archive,
      archiveRevision: 1,
    );
    final stale = cursorFile(
      mode: CloudSyncHistoricalCursorMode.archive,
      archiveRevision: 1,
    );
    await first.load();
    await stale.load();
    await first.save(progress(first, 5));
    await expectLater(stale.save(progress(stale, null)), throwsStateError);
    expect((await stale.load())?.lastId, progress(first, 5).lastId);
  });

  test('archive revision must be bounded and cannot version staging', () {
    for (final invalid in [-1, 0x80000000]) {
      expect(
        () => cursorFile(
          mode: CloudSyncHistoricalCursorMode.archive,
          archiveRevision: invalid,
        ),
        throwsStateError,
      );
    }
    expect(() => cursorFile(archiveRevision: 1), throwsStateError);
  });

  test('snapshot namespaces do not replace previous scan progress', () async {
    final first = cursorFile();
    await first.load();
    await first.save(progress(first, 5));
    final other = cursorFile(snapshot: 'b' * 64);
    expect(await other.load(), isNull);
    await other.save(progress(other, 2));
    expect((await cursorFile().load())?.lastId, progress(first, 5).lastId);
    expect(await target(first).parent.list().toList(), hasLength(2));
  });

  test('completed staging scan cannot shortcut an archive cursor', () async {
    final staged = cursorFile();
    await staged.load();
    await staged.save(progress(staged, null));
    final archive = cursorFile(mode: CloudSyncHistoricalCursorMode.archive);
    expect(await archive.load(), isNull);
    await archive.save(progress(archive, 5));
    expect((await cursorFile().load())?.done, isTrue);
    final reopened = cursorFile(mode: CloudSyncHistoricalCursorMode.archive);
    expect((await reopened.load())?.lastId, progress(archive, 5).lastId);
    await reopened.save(progress(reopened, null));
    expect(
      (await cursorFile(
        mode: CloudSyncHistoricalCursorMode.archive,
      ).load())?.done,
      isTrue,
    );
    expect(await target(archive).parent.list().toList(), hasLength(2));
  });

  for (final archiveTarget in [false, true]) {
    test(
      'cross-purpose progress is rejected (archive target $archiveTarget)',
      () async {
        final source = cursorFile(
          mode: archiveTarget
              ? CloudSyncHistoricalCursorMode.stageOnly
              : CloudSyncHistoricalCursorMode.archive,
        );
        final wrong = cursorFile(
          mode: archiveTarget
              ? CloudSyncHistoricalCursorMode.archive
              : CloudSyncHistoricalCursorMode.stageOnly,
        );
        await source.load();
        await source.save(progress(source, null));
        final encoded = await target(source).readAsBytes();
        await target(wrong).writeAsBytes(encoded);
        await expectLater(wrong.load(), throwsStateError);
        expect(await target(wrong).readAsBytes(), encoded);
        expect((await source.load())?.done, isTrue);
      },
    );
  }

  test('foreign snapshot metadata is retained and rejected', () async {
    final first = cursorFile();
    await first.load();
    await first.save(progress(first, 5));
    final foreign = cursorFile(snapshot: 'b' * 64);
    final encoded = await target(first).readAsBytes();
    await target(foreign).writeAsBytes(encoded);
    await expectLater(foreign.load(), throwsStateError);
    expect(await target(foreign).readAsBytes(), encoded);
  });

  test('incomplete temporary checkpoint is ignored, never promoted', () async {
    final store = cursorFile();
    await store.load();
    await store.save(progress(store, 5));
    final before = await target(store).readAsBytes();
    final orphan = File(
      path.join(target(store).parent.path, '.interrupted.tmp'),
    );
    await orphan.writeAsString('[1,"unfinished');
    expect((await cursorFile().load())?.lastId, progress(store, 5).lastId);
    expect(await target(store).readAsBytes(), before);
    expect(await orphan.exists(), isTrue);
  });

  for (final name in [
    'truncated',
    'checksum',
    'version',
    'oversized',
    'utf8',
  ]) {
    test(
      'damaged $name checkpoint blocks without overwriting evidence',
      () async {
        final store = cursorFile();
        await store.load();
        await store.save(progress(store, 5));
        final fields = jsonDecode(await target(store).readAsString()) as List;
        final bytes = switch (name) {
          'truncated' => utf8.encode('[1,'),
          'checksum' => utf8.encode(jsonEncode([...fields.take(4), '0' * 64])),
          'version' => utf8.encode(jsonEncode([2, ...fields.skip(1)])),
          'oversized' => List<int>.filled(1025, 32),
          _ => [0xff, 0xfe],
        };
        await target(store).writeAsBytes(bytes);
        await expectLater(cursorFile().load(), throwsStateError);
        await expectLater(store.save(progress(store, null)), throwsStateError);
        expect(await target(store).readAsBytes(), bytes);
      },
    );
  }

  for (final suffix in ['0', '-1', '01', '9223372036854775808', '1:extra']) {
    test('invalid cursor position $suffix never writes', () async {
      final store = cursorFile();
      await store.load();
      await expectLater(
        store.save(
          HistoricalProducerCursor(
            scope: store.scope,
            lastId: 'historical-scan:v1:${store.scope}:$suffix',
            done: false,
          ),
        ),
        throwsStateError,
      );
      expect(await directory.list().toList(), isEmpty);
    });
  }

  test('identity drift or missing exclusion prevents storage access', () async {
    final store = cursorFile();
    current = false;
    await expectLater(store.load(), throwsStateError);
    current = true;
    transport.identity = 'other';
    await expectLater(store.load(), throwsStateError);
    await expectLater(
      cursorFile(selected: _NoLocalTransport()).load(),
      throwsStateError,
    );
    expect(transport.entries, 0);
    expect(await directory.list().toList(), isEmpty);
  });

  test('identity change while waiting for lock is checked inside it', () async {
    final store = cursorFile();
    transport.beforeAction = () => current = false;
    await expectLater(store.load(), throwsStateError);
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'directory occupying checkpoint is not removed or overwritten',
    () async {
      final store = cursorFile();
      await store.load();
      await Directory(target(store).path).create(recursive: true);
      await expectLater(store.save(progress(store, 5)), throwsStateError);
      expect(await Directory(target(store).path).exists(), isTrue);
    },
  );

  test(
    'producer resumes only after durable page adoption, not scan attempt',
    () async {
      final adopted = <String, StagedHistoricalSource>{};
      var interrupt = true;
      var calls = 0;
      CloudSyncHistoricalProducer producer() {
        final cursors = cursorFile();
        return CloudSyncHistoricalProducer(
          reader: _SyntheticRows(cursors.scope),
          registry: _EmptyRegistry(),
          cursors: cursors,
          manifest: _manifest(),
          account: CloudSyncHistoricalAccountBinding(
            accountFingerprint: _account,
            protectedStoreIdentity: _store,
          ),
          pageLimit: 1,
          maxPages: 1,
          readCurrentRow: (guid) async => _row(int.parse(guid.split('-').last)),
          stageAndAdopt: (request, bytes) async {
            calls++;
            final sealed = adopted.putIfAbsent(
              request.guid,
              () => StagedHistoricalSource(
                key: request.sourceSha256,
                sha256: historicalBytesSha256(bytes),
                byteLength: bytes.length,
                guid: request.guid,
              ),
            );
            if (request.guid == 'synthetic-2' && interrupt) {
              throw StateError('synthetic_lost_adoption_response');
            }
            return sealed;
          },
        );
      }

      final first = await producer().run();
      expect(first.summary.staged, 1);
      expect(first.summary.completed, isFalse);
      final expected = (await cursorFile().load())!.lastId;
      await expectLater(producer().run(), throwsStateError);
      expect((await cursorFile().load())!.lastId, expected);
      expect(adopted, hasLength(2));
      interrupt = false;
      final resumed = await producer().run();
      expect(resumed.summary.staged, 1);
      expect(resumed.summary.completed, isTrue);
      expect(adopted, hasLength(2));
      expect(calls, 3);
      expect((await producer().run()).summary.assessed, 0);
      expect(calls, 3);
    },
  );
}

class _EmptyRegistry extends HistoricalOwnershipRegistry {
  @override
  Set<String> get ownedGuids => const {};
  @override
  Set<String> get conflictGuids => const {};
}

class _SyntheticRows implements HistoricalRowReader {
  _SyntheticRows(this.scope);
  final String scope;
  @override
  Future<HistoricalRowPage> readPage({
    String? cursor,
    required int limit,
  }) async {
    final id = cursor == null ? 1 : int.parse(cursor.split(':').last) + 1;
    return HistoricalRowPage(
      views: [_row(id)],
      nextCursor: id == 2 ? null : 'historical-scan:v1:$scope:$id',
    );
  }
}

CloudSyncHistoricalRowView _row(int id) => CloudSyncHistoricalRowView(
  guid: 'synthetic-$id',
  text: 'Synthetic history $id',
  attributedBodies: [AttributedBody.raw('Synthetic history $id')],
  hasActualEditOrUnsend: false,
  dateEditedPresent: false,
  associationPresent: false,
  isFromMe: false,
  senderAddress: 'peer@example.invalid',
  chat: const CloudSyncHistoricalChatView(
    id: 1,
    guid: 'iMessage;-;peer@example.invalid',
    style: 45,
    chatIdentifier: 'peer@example.invalid',
    isRoutingStub: false,
    dateDeletedPresent: false,
    isRpSms: false,
    participantCount: 1,
    participantAddress: 'peer@example.invalid',
    participantService: 'iMessage',
  ),
  dateCreatedMs: 1699000000000,
  error: 0,
  isTemp: false,
  stagingGuid: null,
  sendingServiceId: null,
  hasBeenForwarded: false,
  verificationFailed: false,
  ckRecordId: null,
  ckSyncState: false,
  messageId: id,
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
  rowSnapshotSha256: 'a' * 64,
);

class _NoLocalTransport implements CloudProtectedPageLeaseTransport {
  @override
  String get protectedPageLeaseRecoveryIdentity => _store;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_transport_access');
}

// Tests local cursor behavior, not the native cross-process lock implementation.
class _LocalTransport extends _NoLocalTransport
    implements CloudProtectedLocalLifecycleTransport {
  String identity = _store;
  int entries = 0;
  void Function()? beforeAction;
  @override
  String get protectedPageLeaseRecoveryIdentity => identity;
  @override
  Future<T> runLocalProtectedStoreExclusive<T>(
    Future<T> Function() action,
  ) async {
    entries++;
    beforeAction?.call();
    return action();
  }
}
