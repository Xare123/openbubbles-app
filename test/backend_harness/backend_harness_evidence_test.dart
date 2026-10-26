import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/backend_harness/backend_harness_evidence.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/backend_harness/backend_harness_fixture_proof.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

const messageGuid = '01234567-89AB-CDEF-0123-456789ABCDEF';
const body = 'synthetic backend reader fixture';
String hash(String value) => sha256.convert(utf8.encode(value)).toString();

void main() {
  test('exact fetch accepts only a private GUID and no expected content or source import', () {
    expect(BackendHarnessEvidence.validFetch({'messageGuid': messageGuid}), isTrue);
    expect(BackendHarnessEvidence.validFetch({'messageGuid': messageGuid.toLowerCase()}), isTrue);
    for (final arguments in <Map<String, Object?>>[
      {}, {'fixtureId': messageGuid}, {'messageGuid': 'arbitrary'},
      {'messageGuid': null}, {'messageGuid': messageGuid, 'visibleTextSha256': 'a' * 64},
      {'messageGuid': messageGuid, 'acknowledgeSend': true},
      {'messageGuid': messageGuid, 'chatGuid': messageGuid},
    ]) {
      expect(BackendHarnessEvidence.validFetch(arguments), isFalse);
    }
  });
  late Directory directory;
  late Store store;
  late CloudSyncNativeAuthSnapshot auth;
  late BackendHarnessEvidence adapter;
  final scope = CloudSyncScope(
    accountFingerprint: 'a' * 43,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semanticV2,
  );
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  Map<String, Object?> request({
    String text = body,
    bool edited = false,
    bool retracted = false,
    int minimumEdits = 0,
    int since = 1000,
  }) => {
    'messageGuid': messageGuid,
    'visibleTextSha256': hash(text),
    'edited': edited,
    'retracted': retracted,
    'minimumEdits': minimumEdits,
    'sinceUtcMs': since,
  };
  CloudSyncNativeAuthSnapshot identity(String account) =>
      CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'synthetic-session',
        accountFingerprint: account,
        protectedStoreIdentity: 'obcs2.store.${'b' * 43}',
        cloudMessagesClient: store,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-backend-evidence-',
    );
    store = await openStore(directory: directory.path);
    auth = identity(scope.accountFingerprint);
    adapter = BackendHarnessEvidence(
      readStore: () => store,
      captureAuth: () async => auth,
      download: (_) => throw StateError('unexpected download'),
    );
    store.box<Message>().put(
      Message(
        guid: messageGuid,
        text: body,
        attributedBody: [AttributedBody.raw(body)],
        isFromMe: true,
      ),
    );
  });
  tearDown(() async {
    store.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final resolved = await directory.resolveSymbolicLinks();
    expect(path.isWithin(root, resolved), isTrue);
    expect(
      path.basename(resolved).startsWith('openbubbles-backend-evidence-'),
      isTrue,
    );
    await Directory(resolved).delete(recursive: true);
  });

  void seedProjection({int created = 1100}) {
    store.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        persistenceLane: scope.persistenceLane.name,
        generation: 2,
        updatedAtMs: created,
      ),
    );
    store.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        snapshotKey: 'synthetic-owner',
        scopeGenerationKey: 'synthetic-generation',
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        generation: 2,
        entityKind: CloudEntityKind.message.name,
        logicalEntityKeyHash: hash('logical'),
        canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
          scope: scope,
          generation: 2,
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: hash('logical'),
          canonicalGuid: messageGuid,
        ),
        canonicalGuidLookupHash:
            CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
              scope: scope,
              generation: 2,
              canonicalGuid: messageGuid,
            ),
        etagHash: hash('etag'),
        updatedAtMs: created,
      ),
    );
    store.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: cloudSyncCanonicalRecordMapKey(scope, hash('logical')),
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        logicalEntityKeyHash: hash('logical'),
        serverRecordIdHash: hash('record'),
        generation: 2,
        encryptedServerRecordId: 'synthetic-private-id',
        encryptedRawRecordRef: 'synthetic-private-ref',
        rawRecordGeneration: 2,
        etagHash: hash('etag'),
        updatedAtMs: created,
      ),
    );
    store.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: 'synthetic-change',
        changeIdHash: hash('change'),
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        serverRecordIdHash: hash('record'),
        etagHash: hash('etag'),
        changeType: 'save',
        encryptedPayloadRef: 'synthetic-private-payload',
        batchId: 'synthetic-batch',
        generation: 2,
        fetchSequence: 1,
        status: 1,
        createdAtMs: created,
        updatedAtMs: created,
        completedAtMs: created,
      ),
    );
  }

  test(
    'matching local content alone never qualifies CloudKit projection',
    () async {
      final result = await adapter.inspect(request());
      expect(result.flags['fixture_content_matches'], isTrue);
      expect(result.flags['cloud_projection_present'], isFalse);
      expect(result.flags['fixture_matches'], isFalse);
      expect(result.flags.containsKey('readback_verified'), isFalse);
      expect(jsonEncode(result.toJson()), isNot(contains(body)));
    },
  );

  test(
    'exact fresh owned projection qualifies only the requested content',
    () async {
      seedProjection();
      final before = store.box<CloudInboxChangeEntity>().getAll().single;
      final result = await adapter.inspect(request());
      expect(result.flags['fixture_matches'], isTrue);
      expect(
        (await adapter.inspect(
          request(text: 'different'),
        )).flags['fixture_matches'],
        isFalse,
      );
      expect(
        store.box<CloudInboxChangeEntity>().getAll().single.updatedAtMs,
        before.updatedAtMs,
      );
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    },
  );

  test('stale cache and mismatched physical mapping do not qualify', () async {
    seedProjection(created: 999);
    expect(
      (await adapter.inspect(request())).flags['cloud_projection_present'],
      isFalse,
    );
    final inbox = store.box<CloudInboxChangeEntity>().getAll().single
      ..createdAtMs = 1200;
    store.box<CloudInboxChangeEntity>().put(inbox);
    final map = store.box<CloudRecordMapEntity>().getAll().single
      ..etagHash = hash('different');
    store.box<CloudRecordMapEntity>().put(map);
    expect(
      (await adapter.inspect(request())).flags['cloud_projection_present'],
      isFalse,
    );
  });

  test(
    'native account replacement refuses a previously matching observation',
    () async {
      seedProjection();
      var calls = 0;
      final replacement = identity('c' * 43);
      adapter = BackendHarnessEvidence(
        readStore: () => store,
        captureAuth: () async => ++calls == 1 ? auth : replacement,
        download: (_) => throw StateError('unexpected'),
      );
      await expectLater(
        adapter.inspect(request()),
        throwsA(
          isA<BackendHarnessFailure>().having(
            (failure) => failure.code,
            'code',
            'backend_identity_changed',
          ),
        ),
      );
    },
  );

  test(
    'exact parent and participant proof rejects the wrong group despite matching text',
    () async {
      seedProjection();
      const chatGuid = '11234567-89AB-CDEF-0123-456789ABCDEF';
      final handles = [
        Handle(address: '+15550000002'),
        Handle(address: '+15550000003'),
      ];
      store.box<Handle>().putMany(handles);
      final chat = Chat(guid: chatGuid, usingHandle: 'tel:+15550000001')
        ..handles.addAll(handles);
      store.box<Chat>().put(chat);
      final message = store.box<Message>().getAll().single..chat.target = chat;
      store.box<Message>().put(message);
      final exact = {
        ...request(),
        'chatGuid': chatGuid,
        'participantsSha256': hash(jsonEncode([
          'tel:+15550000001', 'tel:+15550000002', 'tel:+15550000003',
        ])),
        'editHistorySha256': hash('[]'),
      };
      expect((await adapter.inspect(exact)).flags['fixture_matches'], isTrue);
      final wrongParent = await adapter.inspect({...exact, 'chatGuid': messageGuid});
      expect(wrongParent.flags['fixture_content_matches'], isTrue);
      expect(wrongParent.flags['fixture_parent_matches'], isFalse);
      expect(wrongParent.flags['fixture_matches'], isFalse);
      handles.first.address = '+15550000004';
      store.box<Handle>().put(handles.first);
      final wrongGroup = await adapter.inspect(exact);
      expect(wrongGroup.flags['fixture_participants_match'], isFalse);
      expect(wrongGroup.flags['fixture_matches'], isFalse);
    },
  );

  test('canonical parent route digest rejects a different parent or participant set', () async {
    seedProjection();
    const route = 'iMessage;+;canonical-group-route';
    final handles = [Handle(address: '+15550000002'), Handle(address: '+15550000003')];
    store.box<Handle>().putMany(handles);
    final parent = Chat(guid: route, usingHandle: 'tel:+15550000001')
      ..handles.addAll(handles);
    store.box<Chat>().put(parent);
    final message = store.box<Message>().getAll().single..chat.target = parent;
    store.box<Message>().put(message);
    final exact = {...request(), 'chatGuidSha256': hash(route),
      'participantsSha256': hash(jsonEncode([
        'tel:+15550000001', 'tel:+15550000002', 'tel:+15550000003'])),
      'editHistorySha256': hash('[]')};
    expect(BackendHarnessEvidence.validInspect(exact), isTrue);
    expect((await adapter.inspect(exact)).flags['fixture_matches'], isTrue);
    final wrong = await adapter.inspect({...exact, 'chatGuidSha256': hash('other')});
    expect(wrong.flags['fixture_content_matches'], isTrue);
    expect(wrong.flags['fixture_parent_matches'], isFalse);
    expect(wrong.flags['fixture_matches'], isFalse);
    final wrongMembers = await adapter.inspect({...exact, 'participantsSha256': hash('other')});
    expect(wrongMembers.flags['fixture_matches'], isFalse);
    expect(BackendHarnessEvidence.validInspect({...exact, 'chatGuid': messageGuid}), isFalse);
    expect(BackendHarnessEvidence.validInspect({...exact, 'chatGuidSha256': route}), isFalse);
  });

  test(
    'production part builder distinguishes edited and retracted versions',
    () async {
      seedProjection();
      final message = store.box<Message>().getAll().single;
      message.messageSummaryInfo = [
        MessageSummaryInfo(
          retractedParts: [],
          editedParts: [0],
          originalTextRange: {},
          editedContent: {
            '0': [
              EditedContent(
                text: Content(values: [AttributedBody.raw('original')]),
                date: 1,
              ),
              EditedContent(
                text: Content(values: [AttributedBody.raw(body)]),
                date: 2,
              ),
            ],
          },
        ),
      ];
      store.box<Message>().put(message);
      expect(
        (await adapter.inspect(
          request(edited: true, minimumEdits: 1),
        )).flags['fixture_matches'],
        isTrue,
      );
      expect(
        (await adapter.inspect(request())).flags['fixture_matches'],
        isFalse,
      );
      const chatGuid = '11234567-89AB-CDEF-0123-456789ABCDEF';
      final chat = Chat(guid: chatGuid, usingHandle: 'tel:+15550000001');
      store.box<Chat>().put(chat);
      message.chat.target = chat;
      store.box<Message>().put(message);
      final exact = {
        ...request(edited: true, minimumEdits: 1),
        'chatGuid': chatGuid,
        'participantsSha256': hash('["tel:+15550000001"]'),
        'editHistorySha256': backendFixtureEditHistorySha256(message),
      };
      expect((await adapter.inspect(exact)).flags['fixture_matches'], isTrue);
      message.messageSummaryInfo.first.editedContent['0']!.first.text =
          Content(values: [AttributedBody.raw('different earlier version')]);
      store.box<Message>().put(message);
      final changedHistory = await adapter.inspect(exact);
      expect(changedHistory.flags['fixture_content_matches'], isTrue);
      expect(changedHistory.flags['fixture_edit_matches'], isTrue);
      expect(changedHistory.flags['fixture_history_matches'], isFalse);
      expect(changedHistory.flags['fixture_matches'], isFalse);
      message.messageSummaryInfo.first.retractedParts = [0];
      store.box<Message>().put(message);
      final retracted = await adapter.inspect(
        request(text: '', edited: true, retracted: true),
      );
      expect(retracted.flags['fixture_matches'], isTrue);
      expect(retracted.counts['retracted_parts'], 1);
    },
  );

  test(
    'attachment lookup is parent-bound and compares the actual bytes',
    () async {
      final message = store.box<Message>().getAll().single;
      final bytes = Uint8List.fromList([1, 2, 3]);
      final attachment = Attachment(
        guid: '${messageGuid}_0',
        totalBytes: bytes.length,
      )..message.targetId = message.id!;
      store.box<Attachment>().put(attachment);
      var downloads = 0;
      adapter = BackendHarnessEvidence(
        readStore: () => store,
        captureAuth: () async => auth,
        download: (_) async {
          downloads++;
          return PlatformFile(
            name: 'synthetic.bin',
            size: bytes.length,
            bytes: bytes,
          );
        },
      );
      final args = <String, Object?>{
        'messageGuid': messageGuid,
        'attachmentGuid': attachment.guid!,
        'sha256': sha256.convert(bytes).toString(),
      };
      final result = await adapter.materialize(args);
      expect(result.flags['attachment_bytes_match'], isTrue);
      expect(result.counts['bytes'], 3);
      final indexArgs = <String, Object?>{
        'messageGuid': messageGuid,
        'attachmentIndex': 0,
        'sha256': args['sha256'],
      };
      expect(
        (await adapter.materialize(indexArgs)).flags['attachment_bytes_match'],
        isTrue,
      );
      await expectLater(
        adapter.materialize({...args, 'attachmentGuid': 'foreign'}),
        throwsA(isA<BackendHarnessFailure>()),
      );
      store.box<Attachment>().put(
        Attachment(guid: '${messageGuid}_1', totalBytes: bytes.length)
          ..message.targetId = message.id!,
      );
      await expectLater(
        adapter.materialize(indexArgs),
        throwsA(isA<BackendHarnessFailure>()),
      );
      expect(downloads, 2);
    },
  );

  test(
    'late attachment success cannot cross a native account change',
    () async {
      final message = store.box<Message>().getAll().single;
      final attachment = Attachment(guid: '${messageGuid}_0', totalBytes: 1)
        ..message.targetId = message.id!;
      store.box<Attachment>().put(attachment);
      final entered = Completer<void>();
      final download = Completer<PlatformFile>();
      adapter = BackendHarnessEvidence(
        readStore: () => store,
        captureAuth: () async => auth,
        download: (_) {
          entered.complete();
          return download.future;
        },
      );
      final pending = adapter.materialize({
        'messageGuid': messageGuid,
        'attachmentGuid': attachment.guid!,
        'sha256': hash('x'),
      });
      await entered.future;
      auth = identity('c' * 43);
      download.complete(
        PlatformFile(
          name: 'synthetic',
          size: 1,
          bytes: Uint8List.fromList([120]),
        ),
      );
      await expectLater(
        pending,
        throwsA(
          isA<BackendHarnessFailure>().having(
            (failure) => failure.code,
            'code',
            'backend_identity_changed',
          ),
        ),
      );
    },
  );
}
