import 'package:bluebubbles/services/rustpush/cloud_sync/legacy_cloud_chat_repair.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'scans from the beginning and stops after all references resolve',
    () async {
      final resolved = <String>{};
      final requestedTokens = <List<int>?>[];

      final unresolved = await LegacyCloudChatRepair.recover<String>(
        unresolvedReferences: {'chat-a', 'chat-b'},
        isResolved: resolved.contains,
        fetchPage: (token) async {
          requestedTokens.add(token);
          if (token == null) {
            return const LegacyCloudChatRepairPage(
              continuationToken: [1],
              items: {'record-a': 'chat-a'},
              state: 1,
            );
          }
          return const LegacyCloudChatRepairPage(
            continuationToken: [2],
            items: {'record-b': 'chat-b'},
            state: 1,
          );
        },
        applyRecord: (_, value) async => resolved.add(value),
      );

      expect(unresolved, isEmpty);
      expect(requestedTokens, [
        null,
        [1],
      ]);
    },
  );

  test(
    'returns unresolved references at the terminal chat-zone state',
    () async {
      final unresolved = await LegacyCloudChatRepair.recover<String>(
        unresolvedReferences: {'missing-chat'},
        isResolved: (_) => false,
        fetchPage: (_) async => const LegacyCloudChatRepairPage(
          continuationToken: [9],
          items: {},
          state: 3,
        ),
        applyRecord: (_, __) async {},
      );

      expect(unresolved, {'missing-chat'});
    },
  );

  test('rejects a nonterminal page whose token does not progress', () async {
    var calls = 0;

    await expectLater(
      LegacyCloudChatRepair.recover<String>(
        unresolvedReferences: {'missing-chat'},
        isResolved: (_) => false,
        fetchPage: (_) async {
          calls++;
          return const LegacyCloudChatRepairPage(
            continuationToken: [7],
            items: {},
            state: 1,
          );
        },
        applyRecord: (_, __) async {},
      ),
      throwsA(isA<StateError>()),
    );
    expect(calls, 2);
  });

  test('does not fetch when every reference is already resolved', () async {
    var fetched = false;

    final unresolved = await LegacyCloudChatRepair.recover<String>(
      unresolvedReferences: {'chat-a'},
      isResolved: (_) => true,
      fetchPage: (_) async {
        fetched = true;
        return const LegacyCloudChatRepairPage(
          continuationToken: [],
          items: {},
          state: 3,
        );
      },
      applyRecord: (_, __) async {},
    );

    expect(unresolved, isEmpty);
    expect(fetched, isFalse);
  });
}
