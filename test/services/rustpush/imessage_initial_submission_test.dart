import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/imessage_initial_submission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Chat chat;
  final sender = Handle(address: 'self@example.com', service: 'iMessage');
  const stableGuid = '11111111-1111-4111-8111-111111111111';

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('initial-message-save-');
    Database.store = await openStore(directory: directory.path);
    Database.messages = Database.store.box<Message>();
    Database.chats = Database.store.box<Chat>();
    Database.handles = Database.store.box<Handle>();
    chat = Chat(guid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA');
    Database.chats.put(chat);
  });
  tearDownAll(() async {
    Database.store.close();
    await directory.delete(recursive: true);
  });

  for (final normalized in [false, true]) {
    test('final reflection reuses the pending row, normalized=$normalized', () {
      Database.messages.removeAll(); // This test's synthetic store only.
      final pending = createPendingInitialIMessage(
        AttributedBody.raw('synthetic first text'),
        createdAt: DateTime.utc(2026, 9, 7, 10),
        sender: sender,
      )..stagingGuid = stableGuid;
      expect(pending.guid, matches(r'^temp-[A-Za-z0-9]{8}$'));
      pending.save(chat: chat, throwOnUniqueViolation: true);
      final originalId = pending.id;
      // Native confirmation may race the foreground return. In either case
      // the final reflected object must find the same row, by GUID or staging.
      if (normalized) {
        pending
          ..guid = stableGuid
          ..stagingGuid = null;
      }
      pending
        ..dateDelivered = DateTime.utc(2026, 9, 7, 10, 1)
        ..sendingServiceId = normalized ? null : 'synthetic-background-job';
      pending.save(
        chat: chat,
        updateSendingServiceId: true,
        throwOnUniqueViolation: true,
      );
      final reflected = Message(
        guid: stableGuid,
        text: pending.text,
        attributedBody: [AttributedBody.raw(pending.text!)],
        dateCreated: DateTime.utc(2026, 9, 7, 10, 0, 1),
        isFromMe: true,
        handle: sender,
      )..chat.target = chat;
      reflected.save(throwOnUniqueViolation: true);
      reflected.save(throwOnUniqueViolation: true);
      expect(reflected.id, originalId);
      expect(Database.messages.count(), 1);
      final saved = Database.messages.get(originalId!)!;
      expect(saved.chat.targetId, chat.id);
      expect(saved.guid, stableGuid);
      expect(saved.stagingGuid, isNull);
      expect(saved.text, 'synthetic first text');
      expect(saved.dateDelivered!.toUtc(), pending.dateDelivered!.toUtc());
      expect(
        saved.sendingServiceId,
        normalized ? isNull : 'synthetic-background-job',
      );
    });
  }
}
