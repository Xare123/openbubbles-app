import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_fixtures.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:flutter_test/flutter_test.dart';

const _guid = '11234567-89AB-4DEF-8123-456789ABCDEF';
const _otherGuid = '21234567-89AB-4DEF-8123-456789ABCDEF';
const _fixtureId = '01234567-89AB-4DEF-8123-456789ABCDEF';
const _service = 'synthetic-native-send';
const _failed = 'cloud_sync_native_send_failed';
const _unknown = 'cloud_sync_native_send_completion_unknown';
const _marker = CloudSyncLocalSendJournal.nativeSendFailureMetadataKey;
final _now = DateTime.utc(2026, 10, 26);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('durable native failure observation', () {
    late Directory directory;
    late _Fixture f;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('native-send-failure-');
      f = _Fixture(await openStore(directory: directory.path));
      f.seed();
    });
    tearDown(() async {
      if (!f.store.isClosed()) f.store.close();
      await _deleteDisposable(directory);
    });

    test(
      'failure survives reopen with the complete pending intent and lease intact',
      () async {
        // Add unrelated presentation metadata only after source admission.
        final decorated = f.read()..metadata = {'unrelated': 'preserved'};
        f.store.box<Message>().put(decorated);
        final before = _intentSnapshot(f.origin);
        final source = f.source.encode();
        final id = f.message.id!;
        expect(f.fail()?.id, id);
        f.expectFailure();
        f.store.close();
        f.store = await openStore(directory: directory.path);
        f.expectFailure();
        expect(_intentSnapshot(f.origin), before);
        expect(f.origin.state, 0);
        expect(f.origin.idsConfirmationVersion, 0);
        expect(f.origin.protectedSourceBinding, source);
        expect(
          CloudSyncLocalSendSourceBinding.decode(source).leaseReference,
          f.source.leaseReference,
        );
        expect(f.read().metadata!['unrelated'], 'preserved');
        expect(f.store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
        expect(f.store.box<Message>().count(), 1);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    test(
      'arbitrary native error text persists only the allowlisted unknown category',
      () {
        const raw =
            'recipient=private@example.invalid token=synthetic-secret '
            'body=private synthetic message HTTP 6005';
        final before = _intentSnapshot(f.origin);
        expect(
          CloudSyncLocalSendJournal.nativeSendFailureCategory(_failed),
          _failed,
        );
        expect(
          CloudSyncLocalSendJournal.nativeSendFailureCategory(_unknown),
          _unknown,
        );
        expect(f.fail(error: raw), isNotNull);
        f.expectFailure(code: _unknown);
        final marker = Map<String, dynamic>.from(
          f.read().metadata![_marker] as Map,
        );
        expect(marker, {
          'version': 1,
          'code': _unknown,
          'guidHash': f.origin.messageGuidHash,
          'sourceSha256': f.origin.sourceSha256,
        });
        final persisted = jsonEncode([
          f.read().dbMetadata,
          _intentSnapshot(f.origin),
        ]);
        for (final sensitive in [
          raw,
          'private@example.invalid',
          'synthetic-secret',
          'private synthetic message',
          '6005',
          _guid,
        ]) {
          expect(persisted, isNot(contains(sensitive)));
        }
        expect(_intentSnapshot(f.origin), before);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    test(
      'stable staging GUID finds a temporary row and survives canonical reflection',
      () {
        final pending = f.read()
          ..guid = 'temp-synthetic'
          ..stagingGuid = _guid;
        f.store.box<Message>().put(pending);
        final before = _intentSnapshot(f.origin);
        final staleReflection = f.read()
          ..guid = _guid
          ..stagingGuid = null;
        expect(f.fail()?.guid, 'temp-synthetic');
        CloudSyncLocalSendJournal.retainNativeSendFailurePresentation(
          f.store,
          staleReflection,
        );
        f.store.box<Message>().put(staleReflection);
        f.expectFailure();
        expect(f.read().guid, _guid);
        expect(f.read().stagingGuid, isNull);
        expect(_intentSnapshot(f.origin), before);
      },
    );

    test(
      'duplicate and stale callbacks cannot overwrite the first diagnostic or another owner',
      () {
        final message = f.read()..error = 42;
        f.store.box<Message>().put(message);
        expect(f.fail(), isNotNull);
        final first = f.read().dbMetadata;
        expect(f.read().error, 42);
        expect(f.fail(error: 'a later unknown error'), isNull);
        expect(f.read().dbMetadata, first);
        final changedOwner = f.read()..sendingServiceId = 'different-service';
        f.store.box<Message>().put(changedOwner);
        expect(f.fail(error: _unknown), isNull);
        expect(f.read().dbMetadata, first);
        expect(f.read().sendingServiceId, 'different-service');
        expect(f.read().error, 42);
      },
    );

    test(
      'owner matching rejects unrelated callbacks and accepts the Windows empty service',
      () {
        final before = _intentSnapshot(f.origin);
        for (final request in [
          (guid: _otherGuid, service: _service),
          (guid: 'not-a-guid', service: _service),
          (guid: _guid, service: 'different-service'),
          (guid: _guid, service: ''),
        ]) {
          expect(f.fail(guid: request.guid, service: request.service), isNull);
          expect(f.read().error, 0);
          expect(f.read().sendingServiceId, _service);
          expect(f.read().metadata, isNull);
        }
        final windows = f.read()..sendingServiceId = '';
        f.store.box<Message>().put(windows);
        expect(f.fail(service: _service), isNull);
        expect(f.read().sendingServiceId, '');
        expect(f.fail(service: ''), isNotNull);
        f.expectFailure();
        expect(f.fail(service: '', error: _unknown), isNull);
        f.expectFailure();
        expect(_intentSnapshot(f.origin), before);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    test(
      'ambiguous Message or intent ownership refuses the callback and diagnostic',
      () {
        final competing = Message(
          guid: 'temp-competing',
          stagingGuid: _guid,
          isFromMe: true,
          sendingServiceId: _service,
        )..chat.target = f.chat;
        final competingId = f.store.box<Message>().put(competing);
        expect(f.fail(), isNull);
        expect(f.read().error, 0);
        expect(f.store.box<Message>().get(competingId)!.error, 0);
        // Remove only this synthetic competitor, then exercise intent ambiguity.
        f.store.box<Message>().remove(competingId);
        expect(f.fail(), isNotNull);
        final duplicate = f.origin
          ..id = 0
          ..intentKey = 'synthetic-duplicate';
        f.store.box<CloudSyncLocalSendIntentEntity>().put(duplicate);
        final retryOwner = f.read()..sendingServiceId = _service;
        f.store.box<Message>().put(retryOwner);
        expect(f.fail(error: _unknown), isNull);
        expect(
          CloudSyncLocalSendJournal.nativeSendFailureCode(f.store, f.read()),
          isNull,
        );
        expect(f.read().sendingServiceId, _service);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    test(
      'mismatched source and malformed or detached markers are not reported',
      () {
        expect(f.fail(), isNotNull);
        final valid = Map<String, dynamic>.from(
          f.read().metadata![_marker] as Map,
        );
        final original = f.origin;
        final changed = f.origin..sourceSha256 = 'c' * 64;
        f.store.box<CloudSyncLocalSendIntentEntity>().put(changed);
        expect(
          CloudSyncLocalSendJournal.nativeSendFailureCode(f.store, f.read()),
          isNull,
        );
        f.store.box<CloudSyncLocalSendIntentEntity>().put(original);
        for (final bad in <Object>[
          'forged',
          {...valid, 'version': 99},
          {...valid, 'code': 'raw error'},
          {...valid, 'guidHash': '0' * 64},
          {...valid, 'sourceSha256': '0' * 64},
          {...valid, 'rawError': 'private@example.invalid'},
        ]) {
          final message = f.read()..metadata = {_marker: bad};
          f.store.box<Message>().put(message);
          expect(
            CloudSyncLocalSendJournal.nativeSendFailureCode(f.store, f.read()),
            isNull,
          );
        }
        final detached = Message(guid: _otherGuid, metadata: {_marker: valid});
        f.store.box<Message>().put(detached);
        expect(
          CloudSyncLocalSendJournal.nativeSendFailureCode(
            f.store,
            f.store.box<Message>().get(detached.id!)!,
          ),
          isNull,
        );
      },
    );

    test(
      'legacy failure fallback preserves tracked and replacement owners',
      () {
        void clear(String service) =>
            CloudSyncLocalSendJournal.clearUntrackedNativeSendFailure(
              f.store,
              stableGuid: _guid,
              serviceId: service,
            );
        final before = _intentSnapshot(f.origin);
        clear(_service);
        expect(f.read().sendingServiceId, _service);
        clear('different-service');
        expect(f.read().sendingServiceId, _service);
        expect(_intentSnapshot(f.origin), before);
        expect(f.read().metadata, isNull);

        // Only this synthetic fixture's intent is removed to exercise legacy
        // cleanup. No real profile or native/protected store exists here.
        f.store.box<CloudSyncLocalSendIntentEntity>().remove(f.intentId);
        clear('different-service');
        expect(f.read().sendingServiceId, _service);
        clear(_service);
        expect(f.read().sendingServiceId, isNull);
        expect(f.read().guid, _guid);
        expect(f.read().error, 0);
        expect(f.read().metadata, isNull);
        expect(f.store.box<Message>().count(), 1);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    test('legacy failure fallback refuses ambiguous Message ownership', () {
      f.store.box<CloudSyncLocalSendIntentEntity>().remove(f.intentId);
      final competing = Message(
        guid: 'temp-competing',
        stagingGuid: _guid,
        isFromMe: true,
        sendingServiceId: _service,
      )..chat.target = f.chat;
      final id = f.store.box<Message>().put(competing);
      CloudSyncLocalSendJournal.clearUntrackedNativeSendFailure(
        f.store,
        stableGuid: _guid,
        serviceId: _service,
      );
      expect(f.read().sendingServiceId, _service);
      expect(f.store.box<Message>().get(id)!.sendingServiceId, _service);
      expect(f.read().error, 0);
      expect(f.read().metadata, isNull);
    });

    test(
      'authenticated positive journal receipt clears failure and rejects late callbacks',
      () {
        expect(f.fail(), isNotNull);
        final stale = f.read();
        final source = f.origin.protectedSourceBinding;
        expect(f.confirm(), f.origin.id);
        f.expectConfirmed();
        expect(f.origin.protectedSourceBinding, source);
        CloudSyncLocalSendJournal.retainNativeSendFailurePresentation(
          f.store,
          stale,
        );
        f.store.box<Message>().put(stale);
        f.expectConfirmed();
        // Even a leftover transport ID cannot let a failure downgrade IDS proof.
        final leftover = f.read()..sendingServiceId = _service;
        f.store.box<Message>().put(leftover);
        final before = _intentSnapshot(f.origin);
        expect(f.fail(), isNull);
        expect(_intentSnapshot(f.origin), before);
        expect(f.read().error, 0);
        expect(f.read().metadata?.containsKey(_marker) ?? false, false);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    test(
      'fixture status exposes failure while retaining uncertainty and no IDS or outbox',
      () {
        final before = _intentSnapshot(f.origin);
        expect(f.fail(), isNotNull);
        final flags = BackendHarnessFixtures.readStatus(
          f.store,
          f.auth,
          _fixtureId,
        ).flags;
        expect(flags['failure_present'], true);
        expect(flags['outcome_uncertain'], true);
        expect(flags['ids_evidence_present'], false);
        expect(flags['fixture_create_present'], true);
        expect(flags['fixture_create_settled'], false);
        expect(_intentSnapshot(f.origin), before);
        expect(f.origin.state, 0);
        expect(f.origin.idsConfirmationVersion, 0);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );
  });

  group('actual Message persistence races', () {
    late Directory directory;
    late _Fixture f;

    setUpAll(() async {
      // Database bindings are late final. Bind them once to this disposable
      // store, without Database.init, a profile, services, or a native client.
      directory = await Directory.systemTemp.createTemp('native-send-failure-');
      final store = await openStore(directory: directory.path);
      Database.store = store;
      Database.messages = store.box<Message>();
      Database.chats = store.box<Chat>();
      Database.handles = store.box<Handle>();
      Database.attachments = store.box<Attachment>();
      f = _Fixture(store);
    });
    setUp(() {
      f.store.box<CloudSyncLocalSendIntentEntity>().removeAll();
      Database.messages.removeAll();
      Database.chats.removeAll();
      Database.handles.removeAll();
      f.seed(reflected: false);
    });
    tearDownAll(() async {
      f.store.close();
      await _deleteDisposable(directory);
    });

    for (final path in ['save', 'bulkSave', 'replaceMessage']) {
      test(
        '$path preserves callback-before-reflection and positive receipt precedence',
        () async {
          Future<void> persist(Message message, String oldGuid) async {
            switch (path) {
              case 'save':
                message.save(
                  chat: f.chat,
                  updateSendingServiceId: true,
                  throwOnUniqueViolation: true,
                );
                break;
              case 'bulkSave':
                Message.bulkSave([message]);
                break;
              case 'replaceMessage':
                await Message.replaceMessage(oldGuid, message);
                break;
            }
          }

          final before = _intentSnapshot(f.origin);
          final oldGuid = f.read().guid!;
          final staleReflection = f.read()
            ..guid = _guid
            ..stagingGuid = null;
          expect(f.fail(), isNotNull);
          await persist(staleReflection, oldGuid);
          f.expectFailure();
          expect(f.read().guid, _guid);
          expect(f.read().stagingGuid, isNull);
          expect(_intentSnapshot(f.origin), before);

          final staleFailure = f.read();
          expect(staleFailure.error, 1001);
          expect(staleFailure.metadata?.containsKey(_marker), true);
          expect(f.confirm(), f.origin.id);
          f.expectConfirmed();
          final confirmedOrigin = _intentSnapshot(f.origin);
          if (path == 'replaceMessage') {
            // Reflected models need not carry the persisted row ID. The
            // replacement path must bind it before normalizing stale failure.
            staleFailure.id = null;
          }
          await persist(staleFailure, _guid);
          f.expectConfirmed();
          expect(_intentSnapshot(f.origin), confirmedOrigin);
          expect(f.read().id, f.message.id);
          expect(f.store.box<Message>().count(), 1);
          expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
        },
      );
    }
  });
}

/// Synthetic ownership uses the real journal and ObjectBox. Protected source
/// references are inert fixtures; no native store or actual outbound lease is
/// opened, released, retried, or replaced by these tests.
class _Fixture {
  _Fixture(this.store);

  Store store;
  late CloudSyncLocalSendJournal journal;
  late CloudSyncNativeAuthSnapshot auth;
  late CloudSyncLocalSendSourceBinding source;
  late Chat chat;
  late Message message;
  late int intentId;

  CloudSyncLocalSendIntentEntity get origin =>
      store.box<CloudSyncLocalSendIntentEntity>().get(intentId)!;
  Message read() => store.box<Message>().get(message.id!)!;

  void seed({bool reflected = true}) {
    final account = 'A' * 43;
    auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic',
      accountFingerprint: account,
      protectedStoreIdentity: 'obcs2.store.$account',
      cloudMessagesClient: Object(),
    );
    final authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final scope = CloudKitWriterScope(accountFingerprint: account);
    if (authority.read(scope) == null) {
      final disabled = authority.initializeDisabled(scope, now: _now);
      authority.provisionInitialOwner(
        scope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: _now,
      );
    }
    journal = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authority.read(scope)!,
      currentAuth: auth,
    );
    final handle = Handle(
      address: '+16177106179',
      service: 'iMessage',
      uniqueAddressAndService: '+16177106179/iMessage',
    );
    store.box<Handle>().put(handle);
    chat =
        Chat(
            guid: 'iMessage;-;+16177106179',
            chatIdentifier: '+16177106179',
            style: 45,
            usingHandle: 'tel:+19079786948',
          )
          ..cloudGuid = _fixtureId
          ..handles.add(handle);
    store.box<Chat>().put(chat);
    final text = BackendHarnessFixtures.marker(_fixtureId);
    message = Message(
      guid: 'temp-synthetic',
      stagingGuid: _guid,
      text: text,
      attributedBody: [AttributedBody.raw(text)],
      isFromMe: true,
      dateCreated: _now,
    )..chat.target = chat;
    final captured = CloudSyncLocalSendIdentity.capture(message, chat, _guid);
    expect(
      captured,
      isNotNull,
      reason: 'Synthetic source must qualify before submission',
    );
    final identity = captured!;
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message),
      now: _now,
    );
    source = CloudSyncLocalSendSourceBinding(
      accountFingerprint: account,
      protectedStoreIdentity: auth.protectedStoreIdentity,
      messageGuidHash: identity.guidHash,
      sourceSha256: identity.sourceSha256,
      protectedReference: 'obcs2.ref.${'A' * 43}',
      leaseReference: 'obcs2.lease.${'a' * 32}',
      payloadSha256: 'b' * 64,
      payloadLength: 512,
    );
    journal.adoptProtectedSource(
      identity: identity,
      source: source,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _now,
    );
    intentId = store.box<CloudSyncLocalSendIntentEntity>().getAll().single.id;
    message.sendingServiceId = _service;
    if (reflected) {
      message
        ..guid = _guid
        ..stagingGuid = null;
    }
    store.box<Message>().put(message);
  }

  Message? fail({
    String guid = _guid,
    String error = _failed,
    String service = _service,
  }) => CloudSyncLocalSendJournal.recordNativeSendFailure(
    store,
    stableGuid: guid,
    error: error,
    serviceId: service,
  );

  int? confirm() => journal.recordNativeSendConfirmation(
    stableGuid: _guid,
    succeeded: true,
    capturedAuth: auth,
    stillCurrent: () => true,
    protectedSource: source,
    now: _now.add(const Duration(seconds: 1)),
  );

  void expectFailure({String code = _failed}) {
    final saved = read();
    expect(CloudSyncLocalSendJournal.nativeSendFailureCode(store, saved), code);
    expect(saved.error, 1001);
    expect(saved.error, CloudSyncLocalSendJournal.nativeSendFailureErrorCode);
    expect(saved.sendingServiceId, isNull);
  }

  void expectConfirmed() {
    final saved = read();
    expect(origin.state, 3);
    expect(origin.idsConfirmationVersion, 2);
    expect(
      CloudSyncLocalSendJournal.nativeSendFailureCode(store, saved),
      isNull,
    );
    expect(saved.metadata?.containsKey(_marker) ?? false, false);
    expect(saved.error, 0);
    expect(saved.sendingServiceId, isNull);
  }
}

// All persisted origin fields, including timestamps and ownership evidence.
List<Object?> _intentSnapshot(CloudSyncLocalSendIntentEntity row) => [
  row.id,
  row.intentKey,
  row.accountFingerprint,
  row.writerEpoch,
  row.localMessageId,
  row.messageGuidHash,
  row.sourceSha256,
  row.state,
  row.admittedOperationId,
  row.admittedBindingSha256,
  row.admittedChatBinding,
  row.confirmedReadbackBindingSha256,
  row.idsConfirmationVersion,
  row.protectedSourceBinding,
  row.createdAtMs,
  row.updatedAtMs,
];

Future<void> _deleteDisposable(Directory directory) async {
  final resolved = Directory(await directory.resolveSymbolicLinks());
  expect(
    resolved.parent.path,
    await Directory.systemTemp.resolveSymbolicLinks(),
  );
  expect(
    resolved.uri.pathSegments.where((part) => part.isNotEmpty).last,
    startsWith('native-send-failure-'),
  );
  expect(
    await FileSystemEntity.type(directory.path, followLinks: false),
    FileSystemEntityType.directory,
  );
  await directory.delete(recursive: true);
}
