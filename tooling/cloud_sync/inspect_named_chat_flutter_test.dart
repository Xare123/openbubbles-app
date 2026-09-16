// Explicit offline inspection. Never prints names, participants or messages.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final input = Platform.environment['OPENBUBBLES_NAMED_CHAT_SOURCE'];
  final needle = Platform.environment['OPENBUBBLES_NAMED_CHAT_NEEDLE'];
  test('locate one named chat in a qualified offline snapshot', () async {
    expect(needle, isNotNull);
    expect(needle!.trim().length, inInclusiveRange(2, 80));
    final root = Directory(input!).absolute;
    final source = File('${root.path}/data.mdb');
    final qualification =
        jsonDecode(
              await File(
                '${root.path}/capture-qualification.json',
              ).readAsString(),
            )
            as Map;
    final before = (await sha256.bind(source.openRead()).first).toString();
    expect(qualification['stable'], isTrue);
    expect(qualification['databaseSha256'], before);
    final scratch = Directory(r'C:\Codex\OpenBubblesReview\scratch');
    final copy = await scratch.createTemp('named-chat-');
    Store? store;
    try {
      await source.copy('${copy.path}/data.mdb');
      store = await openStore(directory: copy.path);
      final report = store.runInTransaction(TxMode.read, () {
        final chats = store!.box<Chat>().getAll();
        final messages = store.box<Message>().getAll();
        final term = needle.trim().toLowerCase();
        bool matches(String? value) =>
            value?.toLowerCase().contains(term) ?? false;
        final textMatches = messages.where((m) => matches(m.text)).toList();
        final textChatIds = textMatches.map((m) => m.chat.targetId).toSet();
        final candidates = chats
            .where(
              (c) =>
                  matches(c.displayName) ||
                  matches(c.title) ||
                  matches(c.apnTitle) ||
                  textChatIds.contains(c.id),
            )
            .toList();
        return <String, Object?>{
          'chatCount': chats.length,
          'messageCount': messages.length,
          'nameMatchCount': chats
              .where(
                (c) =>
                    matches(c.displayName) ||
                    matches(c.title) ||
                    matches(c.apnTitle),
              )
              .length,
          'textMatchCount': textMatches.length,
          'candidateCount': candidates.length,
          'truncated': candidates.length > 20,
          'candidates': [
            for (final chat in candidates.take(20))
              () {
                final linked = messages
                    .where((m) => m.chat.targetId == chat.id)
                    .toList();
                final visible =
                    linked
                        .where(
                          (m) => m.dateDeleted == null && m.dateCreated != null,
                        )
                        .toList()
                      ..sort(
                        (a, b) => b.dateCreated!.compareTo(a.dateCreated!),
                      );
                return <String, Object?>{
                  'localChatId': chat.id,
                  'displayNameMatch': matches(chat.displayName),
                  'cachedTitleMatch': matches(chat.title),
                  'pushTitleMatch': matches(chat.apnTitle),
                  'messageTextMatch': textChatIds.contains(chat.id),
                  'service': chat.guid.startsWith('iMessage;')
                      ? 'iMessage'
                      : chat.guid.startsWith('SMS;')
                      ? 'SMS'
                      : 'other',
                  'style': chat.style,
                  'archived': chat.isArchived == true,
                  'deleted': chat.dateDeleted != null,
                  'routingStub': chat.isRoutingStub,
                  'rpSms': chat.isRpSms,
                  'participantCount': chat.handles.length,
                  'messages': linked.length,
                  'datedVisibleMessages': visible.length,
                  'latestVisibleUtc': visible.isEmpty
                      ? null
                      : visible.first.dateCreated!.toUtc().toIso8601String(),
                  'cachedLatestUtc': chat.dbOnlyLatestMessageDate
                      ?.toUtc()
                      .toIso8601String(),
                  'cloudRecordMapped': chat.ckRecordId != null,
                  'cloudGuidPresent': chat.cloudGuid != null,
                };
              }(),
          ],
        };
      });
      expect((await sha256.bind(source.openRead()).first).toString(), before);
      // ignore: avoid_print
      print(
        'NAMED_CHAT_REPORT=${jsonEncode({...report, 'sourceUnchanged': true, 'remoteCalls': 0})}',
      );
    } finally {
      store?.close();
      if (copy.parent.absolute.path != scratch.absolute.path ||
          !copy.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('named-chat-')) {
        throw StateError('named_chat_cleanup_target_invalid');
      }
      await copy.delete(recursive: true);
    }
  }, skip: input == null);
}
