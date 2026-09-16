import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory(
      '${Directory.current.path}/.dart_tool',
    ).createTemp('live-restored-chat-routing-');
    Database.store = await openStore(directory: directory.path);
    Database.chats = Database.store.box<Chat>();
  });

  tearDownAll(() async {
    Database.store.close();
    await directory.delete(recursive: true);
  });

  setUp(() => Database.chats.removeAll());

  test(
    'live receive reuses a unique restored cloud GUID without creating',
    () async {
      final restored = Chat(guid: 'cloud-local-row', chatIdentifier: 'chat-42')
        ..cloudGuid = 'sender-group-42';
      Database.chats.put(restored);
      final found = await Chat.findByRust(
        api.ConversationData(
          participants: ['mailto:peer@example.com'],
          senderGuid: 'sender-group-42',
        ),
        'iMessage',
      );
      expect(found?.id, restored.id);
      expect(Database.chats.count(), 1);
      expect(Database.chats.get(restored.id!)?.guid, 'cloud-local-row');
      expect(Database.chats.get(restored.id!)?.guidRefs, ['cloud-local-row']);
    },
  );

  test('exact identifier and record aliases resolve, duplicates do not', () {
    final restored = Chat(guid: 'restored-row', chatIdentifier: 'exact-chat')
      ..ckRecordId = 'exact-record';
    Database.chats.put(restored);
    expect(Chat.findByRustGuid('exact-chat')?.id, restored.id);
    expect(Chat.findByRustGuid('exact-record')?.id, restored.id);
    Database.chats.put(Chat(guid: 'another-row')..cloudGuid = 'exact-chat');
    expect(Chat.findByRustGuid('exact-chat'), isNull);
    expect(Database.chats.count(), 2);
  });

  test('existing direct route wins without merging an already split group', () {
    final restored = Chat(guid: 'restored-row')..cloudGuid = 'live-guid';
    final live = Chat(guid: 'live-guid');
    Database.chats.putMany([restored, live]);
    expect(Chat.findByRustGuid('live-guid')?.id, live.id);
    expect(Database.chats.count(), 2);
    expect(Database.chats.get(restored.id!)?.cloudGuid, 'live-guid');
  });

  test('existing guidRefs route preserves its precedence', () {
    final referenced = Chat(guid: 'referenced', guidRefs: ['wire-guid']);
    Database.chats.putMany([
      referenced,
      Chat(guid: 'restored')..cloudGuid = 'wire-guid',
    ]);
    expect(Chat.findByRustGuid('wire-guid')?.id, referenced.id);
  });

  test('cloud fallback excludes SMS, routing stubs and deleted rows', () {
    Database.chats.putMany([
      Chat(guid: 'sms', isRpSms: true)..cloudGuid = 'sms-alias',
      Chat(guid: 'stub', isRoutingStub: true)..cloudGuid = 'stub-alias',
      Chat(guid: 'deleted')
        ..cloudGuid = 'deleted-alias'
        ..dateDeleted = DateTime(2026),
    ]);
    for (final alias in ['sms-alias', 'stub-alias', 'deleted-alias']) {
      expect(Chat.findByRustGuid(alias), isNull);
    }
  });

  test('cloud alias lookup is exact and can be disabled for non-iMessage', () {
    Database.chats.put(Chat(guid: 'restored')..cloudGuid = 'Exact-Alias');
    expect(Chat.findByRustGuid('exact-alias'), isNull);
    expect(Chat.findByRustGuid('iMessage;+;Exact-Alias'), isNull);
    expect(Chat.findByRustGuid(' Exact-Alias '), isNull);
    expect(Chat.findByRustGuid(''), isNull);
    expect(
      Chat.findByRustGuid('Exact-Alias', includeCloudAliases: false),
      isNull,
    );
  });
}
