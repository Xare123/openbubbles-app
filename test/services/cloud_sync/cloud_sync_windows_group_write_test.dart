import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_selection.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> groupRequest() => {
  'version': 3,
  'id': 'group-qualification-1',
  'allowSend': true,
  'recipients': ['+15555550101', '+15555550100'],
  'sender': 'sender@example.com',
  'text': 'Synthetic group test',
  'restoredGroupGuid': 'iMessage;+;chat-synthetic-1',
};

void main() {
  test('group request binds all members and exact restored group identity', () {
    expect(cloudSyncWindowsWriteFailureCode(
      StateError('cloud_sync_windows_write_group_mismatch'),
    ), 'cloud_sync_windows_write_group_mismatch');
    final request = CloudSyncWindowsWriteRequest.fromJson(groupRequest());
    expect(request.isGroup, isTrue);
    expect(request.recipients, ['+15555550100', '+15555550101']);
    expect(() => request.recipient, throwsStateError);
    expect(
      () => request.recipients.add('+15555550102'),
      throwsUnsupportedError,
    );
    expect(
      request.binding,
      CloudSyncWindowsWriteRequest.fromJson({
        ...groupRequest(),
        'recipients': request.recipients,
      }).binding,
    );
    for (final delta in [
      {'restoredGroupGuid': 'iMessage;+;chat-synthetic-2'},
      {
        'recipients': ['+15555550100', '+15555550102'],
      },
      {'sender': 'other@example.com'},
      {'text': 'Changed'},
      {'id': 'group-qualification-2'},
      {'refreshSenderAuthentication': true},
    ]) {
      expect(
        request.binding,
        isNot(
          CloudSyncWindowsWriteRequest.fromJson({
            ...groupRequest(),
            ...delta,
          }).binding,
        ),
      );
    }
  });

  test(
    'group request rejects mixed formats, ambiguous or unbounded targets',
    () {
      for (final delta in [
        {'recipients': <String>[]},
        {
          'recipients': ['+15555550100'],
        },
        {
          'recipients': ['+15555550100', '+15555550100'],
        },
        {
          'recipients': ['+15555550100', 'other@example.com'],
        },
        {'recipients': List.generate(32, (i) => '+15555550${100 + i}')},
        {'recipient': '+15555550100'},
        {'existingChatFromRequestId': 'previous-1'},
        {'restoredGroupGuid': null},
        {'restoredGroupGuid': 'iMessage;-;+15555550100'},
        {'restoredGroupGuid': 'iMessage;+;'},
        {'restoredGroupGuid': 'iMessage;+;chat\n'},
        {'allowSend': false},
      ]) {
        expect(
          () => CloudSyncWindowsWriteRequest.fromJson({
            ...groupRequest(),
            ...delta,
          }),
          throwsStateError,
        );
      }
    },
  );

  test('adapter selection cannot switch groups, members, or direct mode', () {
    final members = ['+15555550101', '+15555550100'];
    final selection = CloudSyncLocalSendExactSelection.group(
      intentId: 1,
      expectedChatGuid: 'iMessage;+;chat-synthetic-1',
      expectedMembers: members,
      expectedSender: 'sender@example.com',
      expectedSourceSha256: 'a' * 64,
    );
    members.clear();
    expect(
      selection.matchesGroup(
        intentId: 1,
        expectedChatGuid: 'iMessage;+;chat-synthetic-1',
        expectedMembers: ['+15555550100', '+15555550101'],
        expectedSender: 'sender@example.com',
        expectedSourceSha256: 'a' * 64,
      ),
      isTrue,
    );
    expect(
      selection.matchesGroup(
        intentId: 1,
        expectedChatGuid: 'iMessage;+;chat-synthetic-1',
        expectedMembers: ['+15555550100', '+15555550102'],
        expectedSender: 'sender@example.com',
        expectedSourceSha256: 'a' * 64,
      ),
      isFalse,
    );
    expect(
      selection.matches(
        intentId: 1,
        expectedRecipient: '',
        expectedSourceSha256: 'a' * 64,
      ),
      isFalse,
    );
    expect(selection.toString(), 'CloudSyncLocalSendExactSelection(redacted)');
  });

  group('real ObjectBox restored-group routing', () {
    late Directory directory;
    late Store store;
    late Chat chat;
    setUp(() async {
      final root = Directory('build/windows-group-unit');
      await root.create(recursive: true);
      directory = await root.createTemp('fixture-');
      store = await openStore(directory: directory.path);
      final handles = ['+15555550100', '+15555550101']
          .map(
            (address) => Handle(
              address: address,
              service: 'iMessage',
              uniqueAddressAndService: '$address/iMessage',
            ),
          )
          .toList();
      store.box<Handle>().putMany(handles);
      chat = Chat(
        guid: 'iMessage;+;chat-synthetic-1',
        chatIdentifier: 'chat-synthetic-1',
        style: 43,
        usingHandle: 'mailto:sender@example.com',
        participants: handles,
      )..cloudGuid = 'raw-synthetic-group-id';
      chat.handles.addAll(handles);
      store.box<Chat>().put(chat);
    });
    tearDown(() async {
      store.close();
      final entries = await directory.list(followLinks: false).toList();
      expect(
        entries.every(
          (e) =>
              e is File &&
              const {'data.mdb', 'lock.mdb'}.contains(e.uri.pathSegments.last),
        ),
        isTrue,
      );
      for (final entry in entries) {
        await entry.delete();
      }
      await directory.delete();
    });
    test('selects only the exact restored group, without writes', () {
      final req = CloudSyncWindowsWriteRequest.fromJson(groupRequest());
      expect(cloudSyncWindowsRestoredGroupWriteChat(store, req).id, chat.id);
      expect(store.box<Chat>().count(), 1);
      expect(store.box<Message>().count(), 0);
      for (final delta in [
        {'restoredGroupGuid': 'iMessage;+;chat-synthetic-2'},
        {'sender': 'other@example.com'},
        {
          'recipients': ['+15555550100', '+15555550102'],
        },
      ]) {
        expect(
          () => cloudSyncWindowsRestoredGroupWriteChat(
            store,
            CloudSyncWindowsWriteRequest.fromJson({
              ...groupRequest(),
              ...delta,
            }),
          ),
          throwsStateError,
        );
      }
    });
    test('rejects incomplete group and conflicting duplicate GUID rows', () {
      final req = CloudSyncWindowsWriteRequest.fromJson(groupRequest());
      chat.cloudGuid = null;
      store.box<Chat>().put(chat);
      expect(
        () => cloudSyncWindowsRestoredGroupWriteChat(store, req),
        throwsStateError,
      );
      chat.cloudGuid = 'raw-synthetic-group-id';
      store.box<Chat>().put(chat);
      final duplicate = Chat(guid: chat.guid, style: 43);
      expect(() => store.box<Chat>().put(duplicate), throwsException);
      expect(cloudSyncWindowsRestoredGroupWriteChat(store, req).id, chat.id);
    });
  });
}
