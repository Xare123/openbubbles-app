import 'package:bluebubbles/services/rustpush/cloud_sync/legacy_cloud_chat_repair.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects owners whose normalized identities overlap', () {
    final conflicted = LegacyCloudChatRepair.findConflictedOwners({
      'record-a': {'iMessage;+;shared-chat', 'shared-chat'},
      'record-b': {'shared-chat'},
      'record-c': {'independent-chat'},
    });

    expect(conflicted, {'record-a', 'record-b'});
  });

  test('selects the sole exact candidate over normalized alternatives', () {
    final selected = LegacyCloudChatRepair.selectUniqueCandidate(
      const ['normalized', 'exact'],
      isExact: (candidate) => candidate == 'exact',
    );

    expect(selected, 'exact');
  });

  test('rejects multiple exact candidates', () {
    final selected = LegacyCloudChatRepair.selectUniqueCandidate(
      const ['exact-one', 'exact-two', 'normalized'],
      isExact: (candidate) => candidate.startsWith('exact-'),
    );

    expect(selected, isNull);
  });

  test('rejects multiple normalized candidates when none is exact', () {
    final selected = LegacyCloudChatRepair.selectUniqueCandidate(
      const ['normalized-one', 'normalized-two'],
      isExact: (_) => false,
    );

    expect(selected, isNull);
  });

  test(
    'scans from the beginning and stops after all references resolve',
    () async {
      final resolved = <String>{};
      final requestedTokens = <List<int>?>[];

      final unresolved = await LegacyCloudChatRepair.recover<String>(
        unresolvedCount: () => 2 - resolved.length,
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

      expect(unresolved, 0);
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
        unresolvedCount: () => 1,
        fetchPage: (_) async => const LegacyCloudChatRepairPage(
          continuationToken: [9],
          items: {},
          state: 3,
        ),
        applyRecord: (_, __) async {},
      );

      expect(unresolved, 1);
    },
  );

  test('rejects a nonterminal page whose token does not progress', () async {
    var calls = 0;

    await expectLater(
      LegacyCloudChatRepair.recover<String>(
        unresolvedCount: () => 1,
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
      unresolvedCount: () => 0,
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

    expect(unresolved, 0);
    expect(fetched, isFalse);
  });
}
