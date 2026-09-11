import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart';
import 'package:bluebubbles/cloud_sync_v2_windows_write_checkpoint.dart';
import 'package:bluebubbles/cloud_sync_v2_windows_attachment_fixture.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_send_body.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

void main() {
  test('registration diagnostics expose fixed causes, never raw server data', () {
    expect(
      cloudSyncWindowsWriteFailureCode(
        AnyhowException(
          'Registration Error An alias was just removed from your account. Try again. (5052)',
        ),
      ),
      'cloud_sync_windows_sender_alias_changed',
    );
    expect(
      cloudSyncWindowsWriteFailureCode(
        AnyhowException('Registration Error Bad authentication. (6005)'),
      ),
      'cloud_sync_windows_sender_bad_authentication',
    );
    expect(
      cloudSyncWindowsWriteFailureCode(
        AnyhowException('secret raw server data'),
      ),
      'cloud_sync_unknown_failure',
    );
    expect(
      cloudSyncWindowsWriteFailureCode(
        AnyhowException('cloud_sync_windows_sender_auth_required'),
      ),
      'cloud_sync_windows_sender_auth_required',
    );
  });
  Map<String, dynamic> request() => {
    'version': 1,
    'id': 'qualification-1',
    'allowSend': true,
    'recipient': '+15555550100',
    'sender': 'sender@example.com',
    'text': 'Test',
  };
  test('writer mode is explicit and exclusive', () {
    expect(
      CloudSyncV2WindowsHarnessOperation.parse([
        'local-write',
        '--launch-id=0123456789abcdef0123456789abcdef',
      ]),
      CloudSyncV2WindowsHarnessOperation.localWrite,
    );
    expect(
      () => CloudSyncV2WindowsHarnessOperation.parse([
        'local-write',
        'run-once',
        '--launch-id=0123456789abcdef0123456789abcdef',
      ]),
      throwsStateError,
    );
  });
  test(
    'v4 binds a synthetic attachment and preserves plaintext request hashes',
    () {
      final input = {
        ...request(),
        'version': 4,
        'text': '',
        'attachmentFixture': 'png-v1',
      };
      final image = CloudSyncWindowsWriteRequest.fromJson(input);
      expect(image.attachmentFixture!.mimeType, 'image/png');
      expect(
        image.binding,
        CloudSyncWindowsWriteRequest.fromJson(input).binding,
      );
      for (final changes in [
        {'attachmentFixture': 'text-v1'},
        {'existingChatFromRequestId': 'previous-1'},
        {'recipient': '+15555550101'},
        {'refreshSenderAuthentication': true},
      ]) {
        expect(
          CloudSyncWindowsWriteRequest.fromJson({...input, ...changes}).binding,
          isNot(image.binding),
        );
      }
      for (final changes in [
        {'version': 1},
        {'version': 2},
        {'version': 3},
        {'attachmentFixture': '../private.png'},
        {'attachmentFixture': null},
        {'text': 'unsupported caption'},
        {'allowSend': false},
        {'existingChatFromRequestId': 'qualification-1'},
        {'existingChatFromRequestId': '../old'},
        {
          'recipients': ['+15555550100'],
        },
        {'restoredGroupGuid': 'iMessage;+;other'},
      ]) {
        expect(
          () => CloudSyncWindowsWriteRequest.fromJson({...input, ...changes}),
          throwsStateError,
        );
      }
    },
  );
  test('request requires explicit authorization and bounded input', () {
    for (final changes in [
      {'allowSend': false},
      {'version': 2},
      {'id': '../escape'},
      {'recipient': 'someone@example.com'},
      {'sender': 'mailto:sender@example.com'},
      {'text': ''},
      {'text': 'x' * 513},
      {'refreshSenderAuthentication': 'true'},
      {'refreshSenderAuthentication': null},
    ]) {
      expect(
        () => CloudSyncWindowsWriteRequest.fromJson({...request(), ...changes}),
        throwsStateError,
      );
    }
  });
  test('sender repair is explicit and old request bindings stay unchanged', () {
    for (final input in [
      request(),
      {...request(), 'version': 2, 'existingChatFromRequestId': 'previous-1'},
    ]) {
      final retained = CloudSyncWindowsWriteRequest.fromJson(input);
      final explicitRetain = CloudSyncWindowsWriteRequest.fromJson({
        ...input,
        'refreshSenderAuthentication': false,
      });
      final repair = CloudSyncWindowsWriteRequest.fromJson({
        ...input,
        'refreshSenderAuthentication': true,
      });
      final originalFields = input['version'] == 1
          ? [
              'windows-local-write-v1',
              retained.id,
              retained.recipient,
              retained.sender,
              retained.text,
            ]
          : [
              'windows-local-write-v2',
              retained.id,
              retained.recipient,
              retained.sender,
              retained.text,
              retained.existingChatFromRequestId,
            ];
      expect(retained.refreshSenderAuthentication, isFalse);
      expect(explicitRetain.binding, retained.binding);
      expect(
        retained.binding,
        sha256.convert(utf8.encode(jsonEncode(originalFields))).toString(),
      );
      expect(repair.refreshSenderAuthentication, isTrue);
      expect(repair.binding, isNot(retained.binding));
    }
  });
  test('replay binds request id, body, recipient and sender', () {
    final original = CloudSyncWindowsWriteRequest.fromJson(request());
    expect(
      original.binding,
      CloudSyncWindowsWriteRequest.fromJson(request()).binding,
    );
    for (final changes in [
      {'id': 'qualification-2'},
      {'text': 'Changed'},
      {'sender': 'changed@example.com'},
      {'recipient': '+15555550101'},
    ]) {
      expect(
        original.binding,
        isNot(
          CloudSyncWindowsWriteRequest.fromJson({
            ...request(),
            ...changes,
          }).binding,
        ),
      );
    }
  });
  test(
    'existing-chat requests are versioned and bound to their predecessor',
    () {
      final input = {
        ...request(),
        'version': 2,
        'existingChatFromRequestId': 'previous-1',
      };
      final existing = CloudSyncWindowsWriteRequest.fromJson(input);
      expect(existing.existingChatFromRequestId, 'previous-1');
      expect(
        existing.binding,
        isNot(CloudSyncWindowsWriteRequest.fromJson(request()).binding),
      );
      expect(
        existing.binding,
        isNot(
          CloudSyncWindowsWriteRequest.fromJson({
            ...input,
            'existingChatFromRequestId': 'previous-2',
          }).binding,
        ),
      );
      for (final invalid in [null, '../alpha', '', 'qualification-1']) {
        expect(
          () => CloudSyncWindowsWriteRequest.fromJson({
            ...input,
            'existingChatFromRequestId': invalid,
          }),
          throwsStateError,
        );
      }
      expect(
        () => CloudSyncWindowsWriteRequest.fromJson({...input, 'version': 1}),
        throwsStateError,
      );
    },
  );
  group('existing conversation and pre-send cursor selection', () {
    late Directory directory;
    late Store store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'windows-write-fixture-',
      );
      store = await openStore(directory: directory.path);
    });
    tearDown(() async {
      store.close();
      await directory.delete(recursive: true);
    });
    for (final fixtureId in ['text-v1', 'png-v1']) {
      test(
        '$fixtureId submission retains exact descriptor and wire identity after reopen',
        () async {
          final fixture = CloudSyncWindowsAttachmentFixture.fromId(fixtureId);
          const guid = '00000000-0000-4000-8000-000000000001';
          const descriptor = '<synthetic-exact-mmcs-descriptor/>';
          final handle = Handle(
            address: '+15555550100',
            service: 'iMessage',
            uniqueAddressAndService: '+15555550100/iMessage',
          );
          store.box<Handle>().put(handle);
          final chat = Chat(
            guid: 'iMessage;-;+15555550100',
            chatIdentifier: '+15555550100',
            style: 45,
            usingHandle: 'mailto:sender@example.com',
            participants: [handle],
          );
          chat.handles.add(handle);
          store.box<Chat>().put(chat);
          final attachment = api.Attachment(
            aType: api.AttachmentType.mmcs(
              api.MMCSFile(
                signature: Uint8List(32),
                object: 'synthetic',
                url: 'https://example.invalid/synthetic',
                key: Uint8List(32),
                size: fixture.bytes.length,
              ),
            ),
            part_: 0,
            utiType: fixture.uti,
            mime: fixture.mimeType,
            name: fixture.filename,
            iris: false,
          );
          final wire = api.MessageInst(
            id: guid,
            sender: 'mailto:sender@example.com',
            conversation: api.ConversationData(
              participants: ['tel:+15555550100', 'mailto:sender@example.com'],
              senderGuid: chat.guid,
            ),
            message: api.Message.message(
              api.NormalMessage(
                parts: api.MessageParts(
                  field0: [
                    api.IndexedMessagePart(
                      part_: api.MessagePart.attachment(attachment),
                    ),
                  ],
                ),
                service: const api.MessageType.iMessage(),
                voice: false,
              ),
            ),
            sentTimestamp: 1,
            sendDelivered: false,
            verificationFailed: false,
          );
          final message =
              cloudSyncWindowsAttachmentSubmission(
                  fixture: fixture,
                  wire: wire,
                  descriptor: descriptor,
                )
                ..stagingGuid = guid
                ..chat.target = chat;
          final before = await CloudSyncLocalSendIdentity.captureAttachmentWire(
            message,
            chat,
            wire,
            serializeAttachment: (_) async => descriptor,
          );
          expect(before, isNotNull);
          expect(before!.isAttachment, isTrue);
          store.box<Message>().put(message);
          final id = message.id!;
          store.close();
          store = await openStore(directory: directory.path);
          final restored = store.box<Message>().get(id)!;
          expect(
            restored.dbAttachments.single.metadata!['rustpush'],
            descriptor,
          );
          final after = await CloudSyncLocalSendIdentity.captureAttachmentWire(
            restored,
            restored.chat.target!,
            wire,
            expectedSourceSha256: before.sourceSha256,
            serializeAttachment: (_) async => descriptor,
          );
          expect(after?.sourceSha256, before.sourceSha256);
          expect(
            CloudSyncAttachmentSendBody.capture(restored)?.attachmentGuids,
            ['${guid}_0'],
          );
          expect(
            await CloudSyncLocalSendIdentity.captureAttachmentWire(
              restored,
              restored.chat.target!,
              wire,
              expectedSourceSha256: before.sourceSha256,
              serializeAttachment: (_) async => '<different/>',
            ),
            isNull,
          );
          expect(
            () => cloudSyncWindowsAttachmentSubmission(
              fixture: fixture,
              wire: wire,
              descriptor: '',
            ),
            throwsStateError,
          );
        },
      );
    }
    test(
      'selects exact prior journal message, rejects wrong recipient/account or unconfirmed send',
      () {
        const guid = '00000000-0000-4000-8000-000000000001';
        final handle = Handle(
          address: '+15555550100',
          service: 'iMessage',
          uniqueAddressAndService: '+15555550100/iMessage',
        );
        store.box<Handle>().put(handle);
        final chat = Chat(
          guid: 'iMessage;-;+15555550100',
          style: 45,
          usingHandle: 'mailto:sender@example.com',
          participants: [handle],
        );
        chat.handles.add(handle);
        store.box<Chat>().put(chat);
        final message = Message(guid: guid, text: 'Fixture', isFromMe: true);
        message.chat.target = chat;
        store.box<Message>().put(message);
        final intent = CloudSyncLocalSendIntentEntity(
          intentKey: 'fixture',
          accountFingerprint: 'account',
          writerEpoch: 1,
          localMessageId: message.id!,
          messageGuidHash: sha256
              .convert(
                utf8.encode(
                  jsonEncode(['cloud-sync-local-send-guid-v1', guid]),
                ),
              )
              .toString(),
          sourceSha256: 'source',
          state: 2,
          admittedOperationId: 'operation',
          createdAtMs: 1,
          updatedAtMs: 2,
        );
        store.box<CloudSyncLocalSendIntentEntity>().put(intent);
        final claim = <String, dynamic>{
          'version': 1,
          'guid': guid,
          'account': 'account',
          'binding': 'binding',
        };
        final req = CloudSyncWindowsWriteRequest.fromJson(request());
        expect(
          cloudSyncWindowsExistingWriteChat(store, claim, req, 'account').id,
          chat.id,
        );
        expect(
          () => cloudSyncWindowsExistingWriteChat(store, claim, req, 'other'),
          throwsStateError,
        );
        expect(
          () => cloudSyncWindowsExistingWriteChat(
            store,
            claim,
            CloudSyncWindowsWriteRequest.fromJson({
              ...request(),
              'recipient': '+15555550101',
            }),
            'account',
          ),
          throwsStateError,
        );
        intent.state = 0;
        store.box<CloudSyncLocalSendIntentEntity>().put(intent);
        expect(
          () => cloudSyncWindowsExistingWriteChat(store, claim, req, 'account'),
          throwsStateError,
        );
      },
    );
    test(
      'checkpoint must be exact account, semantic lane, drained and token-bearing',
      () {
        final row = CloudSyncCheckpointEntity(
          checkpointKey: 'checkpoint',
          accountFingerprint: 'account',
          container: 'com.apple.messages.cloud',
          database: 'private',
          zone: 'messageManateeZone',
          streamKind: 'messages',
          persistenceLane: 'semantic',
          fetchedTokenCiphertext: 'opaque',
          updatedAtMs: 1,
        );
        store.box<CloudSyncCheckpointEntity>().put(row);
        expect(cloudSyncWindowsMessageCheckpoint(store, 'account').id, row.id);
        expect(
          () => cloudSyncWindowsMessageCheckpoint(store, 'other'),
          throwsStateError,
        );
        row.pendingFetchedTokenCiphertext = 'pending';
        store.box<CloudSyncCheckpointEntity>().put(row);
        expect(
          () => cloudSyncWindowsMessageCheckpoint(store, 'account'),
          throwsStateError,
        );
        row
          ..pendingFetchedTokenCiphertext = null
          ..fetchedTokenCiphertext = null;
        store.box<CloudSyncCheckpointEntity>().put(row);
        expect(
          () => cloudSyncWindowsMessageCheckpoint(store, 'account'),
          throwsStateError,
        );
      },
    );
  });
  test('Windows composition uses production gates and no blanket runtime', () {
    final source = File(
      'lib/cloud_sync_v2_windows_local_write.dart',
    ).readAsStringSync();
    expect(source, contains('initialOwnerOnly: true'));
    expect(source, contains('runExactIntent('));
    expect(source, isNot(contains('.forTest(')));
    final preparation = source.indexOf('await prepareSender(');
    expect(
      source.lastIndexOf('if (!claim.existsSync())', preparation),
      greaterThan(0),
    );
    expect(
      preparation,
      lessThan(source.indexOf('claim.create(exclusive: true)')),
    );
    expect(
      source,
      contains('refreshAuthentication: request.refreshSenderAuthentication'),
    );
    final harness = File(
      'lib/cloud_sync_v2_windows_harness.dart',
    ).readAsStringSync();
    expect(harness, contains('var users = refreshAuthentication'));
    expect(harness, contains('api.cloudSyncWindowsAuthenticateSender('));
    expect(
      harness,
      isNot(contains("File(path.join(fs.appDocDir.path, 'id.plist')).delete")),
    );
    expect(
      source.indexOf('claim.create(exclusive: true)'),
      lessThan(source.indexOf('await sendConfirmed(wire)')),
    );
    expect(
      source.indexOf('cloudSyncWindowsPreserveWriteCheckpoint('),
      lessThan(source.indexOf('final wire = await api.newMsg(')),
    );
    expect(
      source.indexOf('journal.saveSubmission('),
      lessThan(source.indexOf('await sendConfirmed(wire)')),
    );
    expect(
      source.indexOf('await sendConfirmed(wire)'),
      lessThan(source.indexOf('journal.recordNativeSendConfirmation(')),
    );
    expect(
      source.indexOf('await CloudSyncLocalSendSourceStaging('),
      lessThan(source.indexOf('await sendConfirmed(wire)')),
    );
    expect(source, contains('protectedSource: protectedSource'));
    final savedClaim = source.indexOf('if (claim.existsSync())');
    final upload = source.indexOf('await upload(file, fixture)');
    expect(upload, greaterThan(source.indexOf('} else {', savedClaim)));
    expect(
      upload,
      lessThan(source.indexOf('await claim.create(exclusive: true)')),
    );
    final launcher = File(
      'tooling/windows/run_cloud_sync_v2_dev.ps1',
    ).readAsStringSync();
    expect(launcher, contains(r'if ($LocalWrite)'));
    expect(
      launcher,
      isNot(contains('OPENBUBBLES_CLOUD_SYNC_V2_LOCAL_SEND_RUNTIME=true')),
    );
  });
}
