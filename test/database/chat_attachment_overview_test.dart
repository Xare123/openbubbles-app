import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Chat chat;

  setUpAll(() async {
    directory = await Directory('${Directory.current.path}/.dart_tool')
        .createTemp('chat-attachment-overview-');
    Database.store = await openStore(directory: directory.path);
    Database.chats = Database.store.box<Chat>();
    Database.messages = Database.store.box<Message>();
    Database.attachments = Database.store.box<Attachment>();
  });

  tearDownAll(() async {
    Database.store.close();
    await directory.delete(recursive: true);
  });

  setUp(() {
    // Only the synthetic database created above, never a device database.
    Database.messages.removeAll();
    Database.attachments.removeAll();
    Database.chats.removeAll();
    chat = Chat(guid: 'synthetic-chat');
    Database.chats.put(chat);
  });

  Attachment attachment(String? name, {String? mimeType}) => Attachment(
        guid: 'attachment-${name ?? 'unnamed'}',
        transferName: name,
        mimeType: mimeType,
        totalBytes: 123,
      );

  Message addMessage(List<Attachment> attachments, {int minute = 0}) {
    final message = Message(
      guid: 'synthetic-message-$minute',
      dateCreated: DateTime.utc(2026, 9, 6, 0, minute),
      hasAttachments: true,
    )..chat.target = chat;
    Database.messages.put(message);
    for (final item in attachments) {
      item.message.target = message;
      Database.attachments.put(item);
    }
    message.dbAttachments.addAll(attachments);
    Database.messages.put(message);
    return message;
  }

  Future<ChatAttachmentOverview> overview({int documentLimit = 20}) async =>
      GetChatAttachmentOverview([chat.id!, documentLimit, 20, 200]).run();

  for (final name in [
    'A.pluginPayloadAttachment',
    'B.PLUGINPAYLOADATTACHMENT',
  ]) {
    test('internal $name is not a document and is not deleted', () async {
      final payload = attachment(name, mimeType: 'application/octet-stream');
      final message = addMessage([payload]);

      final result = await overview();

      expect(result.documents, isEmpty);
      expect(result.locations, isEmpty);
      expect(Database.attachments.count(), 1);
      expect(Database.attachments.get(payload.id!)!.transferName, name);
      expect(Database.messages.get(message.id!)!.dbAttachments.single.guid,
          payload.guid);
    });
  }

  test('payload filtering keeps real files from the same message', () async {
    final pdf = attachment('report.pdf', mimeType: 'application/pdf');
    final docx = attachment('report.docx', mimeType:
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    addMessage([
      attachment('P.pluginPayloadAttachment'),
      pdf,
      docx,
      attachment('photo.jpg', mimeType: 'image/jpeg'),
      attachment('video.mp4', mimeType: 'video/mp4'),
      attachment('place.loc', mimeType: 'application/location'),
    ]);

    final result = await overview();

    expect(result.documents.map((a) => a.transferName),
        ['report.pdf', 'report.docx']);
    expect(result.locations.single.transferName, 'place.loc');
    expect(Database.attachments.count(), 6);
  });

  test('unknown files and substring lookalikes remain accessible', () async {
    final names = <String?>[
      'notes.pluginPayloadAttachment.pdf',
      'pluginPayloadAttachment-notes',
      'pluginPayloadAttachment',
      'unknown.custom',
      null,
    ];
    addMessage(names.map((name) => attachment(name)).toList());

    expect((await overview()).documents.map((a) => a.transferName), names);
    expect(Database.attachments.count(), names.length);
  });

  test('payloads do not consume the bounded document slots', () async {
    addMessage([attachment('older.pdf', mimeType: 'application/pdf')]);
    addMessage([attachment('P.pluginPayloadAttachment')], minute: 1);
    addMessage([attachment('newer.pdf', mimeType: 'application/pdf')], minute: 2);

    expect((await overview(documentLimit: 2)).documents
        .map((a) => a.transferName), ['newer.pdf', 'older.pdf']);
    expect(Database.attachments.count(), 3);
  });
}
