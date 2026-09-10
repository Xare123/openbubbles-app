import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/imessage_attachment_submission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('journaled attachment retry reuses exact MMCS material', () {
    final attachment = Attachment(guid: 'synthetic')
      ..metadata = {'rustpush': 'synthetic-original-descriptor'};
    expect(retainedAttachmentDescriptorForRetry(
      journaledSubmission: true, attachment: attachment,
    ), 'synthetic-original-descriptor');
    expect(retainedAttachmentDescriptorForRetry(
      journaledSubmission: false, attachment: attachment,
    ), isNull);
    for (final missing in [null, '', 12]) {
      attachment.metadata = {'rustpush': missing};
      expect(() => retainedAttachmentDescriptorForRetry(
        journaledSubmission: true, attachment: attachment,
      ), throwsStateError);
    }
  });

  final source = File(
    'lib/services/rustpush/rustpush_service.dart',
  ).readAsStringSync();
  final sendAttachment = source.substring(
    source.indexOf('Future<Message> sendAttachment('),
    source.indexOf('Future<Message> forwardMMSAttachment('),
  );

  test('V2 iMessage attachments reuse the tracked prepared-send path', () {
    expect(
      sendAttachment,
      contains('CloudKitWriterOwnership.v2MutationsEnabled'),
    );
    expect(
      sendAttachment,
      contains('CloudSyncDevGate.manualOutboundCanaryEnabled'),
    );
    expect(sendAttachment, contains('!chat.isRpSms'));
    expect(sendAttachment, contains('await _sendPreparedMessage('));
  });

  test('attachment retry rebuilds from persisted IDS metadata', () {
    expect(sendAttachment.indexOf('retainedAttachmentDescriptorForRetry('),
      lessThan(sendAttachment.indexOf('api.uploadAttachment(')));
    expect(sendAttachment, contains('if (retainedDescriptor != null)'));
    expect(sendAttachment, contains('CloudSyncLocalSendJournal.hasJournaledSubmission'));
    expect(sendAttachment, contains('final initialConversation ='));
    expect(sendAttachment, contains('final initialSender ='));
    expect(
      sendAttachment,
      contains('participants: List.of(initialConversation.participants)'),
    );
    expect(
      sendAttachment,
      contains('afterGuid: initialConversation.afterGuid'),
    );
    expect(sendAttachment, contains('att.metadata?["rustpush"]'));
    expect(
      sendAttachment,
      contains('api.restoreAttachment(data: retryAttachmentData)'),
    );
    expect(
      sendAttachment,
      contains('att.metadata?["rustpush"] != retryAttachmentData'),
    );
    expect(
      sendAttachment,
      contains("StateError('imessage_attachment_retry_source_missing')"),
    );
    expect(sendAttachment, contains('buildWireMessage: rebuildWireMessage'));
  });

  test(
    'prepared send preserves the pending GUID for attachment replacement',
    () {
      expect(sendAttachment, contains('final pendingMessageGuid = m.guid'));
      expect(sendAttachment, contains('if (identical(reflected, m))'));
      expect(
        sendAttachment,
        contains('Message.fromMap(m.toMap(includeObjects: true))'),
      );
      expect(sendAttachment, contains('m.guid = pendingMessageGuid'));
      expect(sendAttachment, contains('retainAttachmentSubmissionForRetry('));
      expect(
        sendAttachment,
        isNot(contains('finally {\n        m.guid = pendingMessageGuid')),
        reason: 'a failed prepared send must keep any stable retry identity',
      );
    },
  );

  test('legacy SMS and non-V2 submission remains after the V2 return', () {
    final v2Branch = sendAttachment.indexOf('await _sendPreparedMessage(');
    expect(v2Branch, greaterThanOrEqualTo(0));
    final legacy = sendAttachment.substring(v2Branch);
    expect(legacy, contains('if (m.stagingGuid != null)'));
    expect(legacy, contains('if (chat.isRpSms)'));
    expect(legacy, contains('await sendMsg(msg);'));
    expect(legacy, contains('m.save(chat: chat);'));
    expect(legacy, contains('reflectMessageDyn(msg)'));
  });

  group('successful prepared-send persistence', () {
    late Directory directory;
    late Chat chat;

    setUpAll(() async {
      directory = await Directory.systemTemp.createTemp(
        'attachment-submission-save-',
      );
      Database.store = await openStore(directory: directory.path);
      Database.messages = Database.store.box<Message>();
      Database.attachments = Database.store.box<Attachment>();
      Database.chats = Database.store.box<Chat>();
      Database.handles = Database.store.box<Handle>();
      chat = Chat(guid: 'synthetic-attachment-chat');
      Database.chats.put(chat);
    });

    tearDownAll(() async {
      Database.store.close();
      await directory.delete(recursive: true);
    });

    test(
      'stable row survives caller GUID restoration for attachment match',
      () {
        Database.messages.removeAll();
        Database.attachments.removeAll();
        const pendingGuid = 'temp-synthetic';
        const stableGuid = '11111111-1111-4111-8111-111111111111';
        final attachment = Attachment(
          guid: pendingGuid,
          isOutgoing: true,
          uti: 'public.data',
          transferName: 'synthetic.bin',
          mimeType: 'application/octet-stream',
          totalBytes: 1,
        );
        final pending = Message(
          guid: pendingGuid,
          text: '',
          dateCreated: DateTime.utc(2026, 9, 7),
          hasAttachments: true,
          attachments: [attachment],
          stagingGuid: stableGuid,
          sendingServiceId: 'synthetic-background-send',
        );
        pending.save(
          chat: chat,
          updateSendingServiceId: true,
          throwOnUniqueViolation: true,
        );
        attachment.save(pending, throwOnUniqueViolation: true);
        final messageId = pending.id;
        final attachmentId = attachment.id;

        // Mirrors successful prepared-send normalization, then the caller-only
        // GUID restoration used for ActionHandler's attachment lookup.
        pending
          ..guid = stableGuid
          ..stagingGuid = null;
        pending.save(chat: chat, throwOnUniqueViolation: true);
        final replacement = Message.fromMap(pending.toMap(includeObjects: true))
          ..chat.target = chat;
        pending.guid = pendingGuid;

        expect(replacement.guid, stableGuid);
        expect(Message.findOne(guid: stableGuid)?.id, messageId);
        expect(Message.findOne(guid: pendingGuid), isNull);
        expect(
          Database.messages.get(messageId!)!.sendingServiceId,
          'synthetic-background-send',
        );
        expect(Attachment.findOne(pending.guid!)?.id, attachmentId);
        expect(Database.attachments.count(), 1);
      },
    );

    test('stable staging GUID remains discoverable after a failed send', () {
      Database.messages.removeAll();
      const pendingGuid = 'temp-failed-synthetic';
      const stableGuid = '22222222-2222-4222-8222-222222222222';
      final pending = Message(
        guid: pendingGuid,
        text: '',
        dateCreated: DateTime.utc(2026, 9, 7),
        stagingGuid: stableGuid,
        sendingServiceId: 'synthetic-failed-send',
      );
      pending.save(
        chat: chat,
        updateSendingServiceId: true,
        throwOnUniqueViolation: true,
      );

      retainAttachmentSubmissionForRetry(
        chat: chat,
        message: pending,
        submittedGuid: stableGuid,
      );

      final retry = Message.findOne(guid: stableGuid);
      expect(retry?.id, pending.id);
      expect(retry?.guid, pendingGuid);
      expect(retry?.stagingGuid, stableGuid);
      expect(retry?.sendingServiceId, 'synthetic-failed-send');
    });

    test(
      'post-submission failure restores the same durable retry slot once',
      () {
        Database.messages.removeAll();
        const stableGuid = '33333333-3333-4333-8333-333333333333';
        final message = Message(
          guid: stableGuid,
          text: '',
          dateCreated: DateTime.utc(2026, 9, 7),
          isFromMe: true,
        );
        message.save(chat: chat, throwOnUniqueViolation: true);
        final rowId = message.id;
        for (var i = 0; i < 2; i++) {
          retainAttachmentSubmissionForRetry(
            chat: chat,
            message: message,
            submittedGuid: stableGuid,
          );
        }
        final retry = Message.findOne(guid: stableGuid)!;
        expect(retry.id, rowId);
        expect(retry.guid, stableGuid);
        expect(retry.stagingGuid, stableGuid);
        expect(Database.messages.count(), 1);
        expect(retry.ckSyncState, isNot(true));
      },
    );

    test('retry preservation cannot replace a different stable identity', () {
      Database.messages.removeAll();
      const stableGuid = '44444444-4444-4444-8444-444444444444';
      final message = Message(
        guid: stableGuid,
        text: '',
        dateCreated: DateTime.utc(2026, 9, 7),
      );
      message.save(chat: chat, throwOnUniqueViolation: true);
      retainAttachmentSubmissionForRetry(
        chat: chat,
        message: message,
        submittedGuid: '55555555-5555-4555-8555-555555555555',
      );
      expect(Database.messages.get(message.id!)!.stagingGuid, isNull);
      expect(Database.messages.get(message.id!)!.guid, stableGuid);
    });
  });
}
