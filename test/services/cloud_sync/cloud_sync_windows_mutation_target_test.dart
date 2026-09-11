import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Real ObjectBox selection with synthetic data. First-pristine-mutation only:
// chained edits, attachment parents and arbitrary personal history are excluded.
void main() {
  const guid = '11111111-1111-4111-8111-111111111111';
  const recipient = '+15555550100';
  const sender = 'mutation-sender@example.invalid';

  Map<String, dynamic> mutationRequest() => {
    'version': 6,
    'id': 'mutation-target-1',
    'allowSend': true,
    'recipient': recipient,
    'sender': sender,
    'existingChatFromRequestId': 'mutation-parent-1',
    'mutationType': 'edit',
    'mutationPart': 0,
    'text': 'Edited text',
  };

  group('mutation parent selection and payload', () {
    late Directory directory;
    late Store store;
    late Chat chat;
    late Message parent;
    late CloudSyncLocalSendIntentEntity intent;
    late Map<String, dynamic> claim;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'mutation-target-fixture-',
      );
      store = await openStore(directory: directory.path);
      final handle = Handle(
        address: recipient,
        service: 'iMessage',
        uniqueAddressAndService: '$recipient/iMessage',
      );
      store.box<Handle>().put(handle);
      chat = Chat(
        guid: 'iMessage;-;$recipient',
        chatIdentifier: recipient,
        style: 45,
        usingHandle: 'mailto:$sender',
        participants: [handle],
      );
      chat.handles.add(handle);
      store.box<Chat>().put(chat);
      parent = Message(
        guid: guid,
        text: 'Fixture',
        isFromMe: true,
        attributedBody: [AttributedBody.raw('Fixture')],
      );
      parent.chat.target = chat;
      store.box<Message>().put(parent);
      intent = CloudSyncLocalSendIntentEntity(
        intentKey: 'mutation-fixture',
        accountFingerprint: 'account',
        writerEpoch: 1,
        localMessageId: parent.id!,
        messageGuidHash: sha256
            .convert(
              utf8.encode(jsonEncode(['cloud-sync-local-send-guid-v1', guid])),
            )
            .toString(),
        sourceSha256: 'source',
        state: 2,
        admittedOperationId: 'operation',
        createdAtMs: 1,
        updatedAtMs: 2,
      );
      store.box<CloudSyncLocalSendIntentEntity>().put(intent);
      claim = {
        'version': 1,
        'guid': guid,
        'account': 'account',
        'binding': 'binding',
      };
    });

    tearDown(() async {
      store.close();
      await directory.delete(recursive: true);
    });

    test('selector returns the exact prior claimed plaintext parent', () {
      final req = CloudSyncWindowsWriteRequest.fromJson(mutationRequest());
      expect(
        cloudSyncWindowsMutationParent(store, claim, req, 'account').id,
        parent.id,
      );
    });

    test(
      'selector rejects wrong account, recipient, and unconfirmed intent',
      () {
        final req = CloudSyncWindowsWriteRequest.fromJson(mutationRequest());
        expect(
          () => cloudSyncWindowsMutationParent(store, claim, req, 'other'),
          throwsStateError,
        );
        final foreign = CloudSyncWindowsWriteRequest.fromJson({
          ...mutationRequest(),
          'recipient': '+15555550101',
        });
        expect(
          () =>
              cloudSyncWindowsMutationParent(store, claim, foreign, 'account'),
          throwsStateError,
        );
        intent.state = 0;
        store.box<CloudSyncLocalSendIntentEntity>().put(intent);
        expect(
          () => cloudSyncWindowsMutationParent(store, claim, req, 'account'),
          throwsStateError,
        );
      },
    );

    test('selector rejects any non-pristine parent', () {
      final req = CloudSyncWindowsWriteRequest.fromJson(mutationRequest());
      void reset() {
        parent
          ..isFromMe = true
          ..dateEdited = null
          ..dateDeleted = null
          ..dateScheduled = null
          ..verificationFailed = false
          ..hasAttachments = false
          ..subject = null
          ..messageSummaryInfo = []
          ..associatedMessageGuid = null
          ..associatedMessageType = null
          ..text = 'Fixture'
          ..attributedBody = [AttributedBody.raw('Fixture')];
        store.box<Message>().put(parent);
      }

      for (final mutate in <void Function()>[
        () => parent.isFromMe = false,
        () => parent.dateEdited = DateTime.utc(2026),
        () => parent.dateDeleted = DateTime.utc(2026),
        () => parent.dateScheduled = DateTime.utc(2026),
        () => parent.verificationFailed = true,
        () => parent.hasAttachments = true,
        () => parent.subject = 'synthetic subject',
        () => parent.messageSummaryInfo = [MessageSummaryInfo.empty()],
        // Reaction child or prior edit: chained edits are not qualified yet.
        () => parent.associatedMessageGuid = 'another-parent',
        () => parent.text = 'changed',
        () => parent.text = '   ',
      ]) {
        mutate();
        store.box<Message>().put(parent);
        expect(
          () => cloudSyncWindowsMutationParent(store, claim, req, 'account'),
          throwsStateError,
        );
        reset();
      }
      expect(
        cloudSyncWindowsMutationParent(store, claim, req, 'account').id,
        parent.id,
      );
    });

    test(
      'duplicate GUID is store-rejected; foreign chat is selector-rejected',
      () {
        final req = CloudSyncWindowsWriteRequest.fromJson(mutationRequest());
        // Message.guid carries a store-level unique index, so a second row
        // with the same GUID is rejected at put time and can never reach the
        // selector's multi-row guard through the public store API.
        final duplicate = Message(
          guid: guid,
          text: 'Other',
          isFromMe: true,
          attributedBody: [AttributedBody.raw('Other')],
        );
        duplicate.chat.target = chat;
        expect(() => store.box<Message>().put(duplicate), throwsException);
        final foreignHandle = Handle(
          address: '+15555550101',
          service: 'iMessage',
          uniqueAddressAndService: '+15555550101/iMessage',
        );
        store.box<Handle>().put(foreignHandle);
        final foreignChat = Chat(
          guid: 'iMessage;-;+15555550101',
          chatIdentifier: '+15555550101',
          style: 45,
          usingHandle: 'mailto:$sender',
          participants: [foreignHandle],
        );
        foreignChat.handles.add(foreignHandle);
        store.box<Chat>().put(foreignChat);
        parent.chat.target = foreignChat;
        store.box<Message>().put(parent);
        expect(
          () => cloudSyncWindowsMutationParent(store, claim, req, 'account'),
          throwsStateError,
        );
      },
    );

    test('non-mutation requests and parents are rejected', () {
      Map<String, dynamic> legacy(int version) => {
        'version': version,
        'id': 'mutation-legacy-1',
        'allowSend': true,
        'recipient': recipient,
        'sender': sender,
        'text': 'Legacy text',
      };
      final v1 = CloudSyncWindowsWriteRequest.fromJson(legacy(1));
      final v5 = CloudSyncWindowsWriteRequest.fromJson({
        ...legacy(5),
        'text': '',
        'reactionType': 'like',
        'reactionPart': 0,
        'existingChatFromRequestId': 'mutation-parent-1',
      });
      for (final req in [v1, v5]) {
        expect(
          () => cloudSyncWindowsMutationParent(store, claim, req, 'account'),
          throwsStateError,
        );
        expect(
          () => cloudSyncWindowsMutationPayload(req, parent),
          throwsStateError,
        );
      }
      final edit = CloudSyncWindowsWriteRequest.fromJson(mutationRequest());
      final guidless = Message(
        text: 'Fixture',
        isFromMe: true,
        attributedBody: [AttributedBody.raw('Fixture')],
      );
      expect(
        () => cloudSyncWindowsMutationPayload(edit, guidless),
        throwsStateError,
      );
    });

    test('payloads carry target UUID, part 0, and exact text', () {
      final edit = CloudSyncWindowsWriteRequest.fromJson(mutationRequest());
      final editPayload = cloudSyncWindowsMutationPayload(edit, parent);
      expect(editPayload, isA<api.Message_Edit>());
      final editBody = (editPayload as api.Message_Edit).field0;
      expect(editBody.tuuid, guid);
      expect(editBody.editPart, 0);
      expect(editBody.newParts.field0, hasLength(1));
      final part = editBody.newParts.field0.single;
      expect(part.idx, 0);
      expect(part.part_, isA<api.MessagePart_Text>());
      final replacement = part.part_ as api.MessagePart_Text;
      expect(replacement.field0, 'Edited text');
      expect(part.ext, isNull);
      final flags = (replacement.field1 as api.TextFormat_Flags).field0;
      expect([
        flags.bold,
        flags.italic,
        flags.underline,
        flags.strikethrough,
      ], everyElement(isFalse));
      final unsend = CloudSyncWindowsWriteRequest.fromJson({
        ...mutationRequest(),
        'id': 'mutation-target-2',
        'mutationType': 'unsend',
        'text': '',
      });
      final unsendPayload = cloudSyncWindowsMutationPayload(unsend, parent);
      expect(unsendPayload, isA<api.Message_Unsend>());
      final unsendBody = (unsendPayload as api.Message_Unsend).field0;
      expect(unsendBody.tuuid, guid);
      expect(unsendBody.editPart, 0);
    });
  });

  test('mutation composition cannot enter the initial-create writer', () {
    final source = File(
      'lib/cloud_sync_v2_windows_local_write.dart',
    ).readAsStringSync();
    final runStart = source.indexOf('Future<Map<String, Object?>> run()');
    final blocked = source.indexOf(
      'cloud_sync_windows_mutation_runtime_unavailable',
      runStart,
    );
    expect(blocked, greaterThan(runStart));
    expect(
      blocked,
      lessThan(source.indexOf('binding.ensureReadAuthentication(', runStart)),
    );
    expect(
      source.indexOf('return _runMutation(', runStart),
      lessThan(
        source.indexOf('late Map<String, dynamic> savedClaim;', runStart),
      ),
    );
    final mutation = source.substring(
      source.indexOf('Future<Map<String, Object?>> _runMutation('),
    );
    expect(mutation, contains('.submitConfirmed('));
    final harness = File('lib/cloud_sync_v2_windows_harness.dart').readAsStringSync();
    expect(harness, contains('sendMutationConfirmed: (message, context)'));
    expect(harness, contains('api.cloudSyncWindowsSendMutationConfirmed('));
    expect(mutation, contains('createJournal.readConfirmedParentDependency('));
    expect(
      mutation.indexOf('await claim.create(exclusive: true)'),
      lessThan(mutation.indexOf('.submitConfirmed(')),
    );
    expect(mutation, contains('CloudSyncNativeReceiptReplayBinding('));
    expect(mutation, contains("'cloudkit_update_enabled': false"));
    for (final forbidden in [
      'await sendConfirmed(',
      'runExactIntent(',
      'recordNativeSendConfirmation(',
      'cloudSyncAcknowledgeNativeSendReceipt(',
      'reflectConfirmed(',
    ]) {
      expect(mutation, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
