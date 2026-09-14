import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_presentation_repair.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

/// Newest-first catchup invariant (offline, deterministic).
///
/// Proves that a recent usable page can project before a historical backfill
/// page while the durable cursor/token and the denormalized chat latest-date
/// stay monotonic across duplicate replay and a coordinator restart.
void main() {
  test(
    'recent usable chats project before backfill with monotonic cursor token and latest-date',
    () async {
      final store = InMemoryCloudSyncStore();
      final scope = testScope();
      final t0 = testEpoch;
      final t1 = t0.add(const Duration(minutes: 1));
      final t2 = t1.add(const Duration(minutes: 1));
      final t3 = t2.add(const Duration(minutes: 1));
      final t4 = t3.add(const Duration(minutes: 1));

      // Deterministic change identities. Recent and historical pages use
      // disjoint indices so replay deduplication is exact.
      final recentChanges = [testChange(901), testChange(902)];
      final historicalChanges = [
        testChange(101),
        testChange(102),
        testChange(103, tombstone: true),
      ];

      final recentBatch = CloudFetchBatch(
        scope: scope,
        changes: recentChanges,
        batchId: 'newest-first-recent',
        generation: 1,
        nextToken: 'opaque-token-recent',
        hasMore: true,
      );
      final historicalBatch = CloudFetchBatch(
        scope: scope,
        changes: historicalChanges,
        batchId: 'newest-first-historical',
        generation: 1,
        nextToken: 'opaque-token-historical',
        hasMore: false,
      );

      // Fake semantic projection: changeId -> (chat guid, message date).
      // The tombstone has no usable chat projection but remains journalable.
      final recentDateA = DateTime.utc(2026, 9, 12, 10);
      final recentDateB = DateTime.utc(2026, 9, 12, 11);
      final oldDateA = DateTime.utc(2026, 8, 1, 10);
      final oldDateC = DateTime.utc(2026, 8, 2, 10);
      final projectionByChangeId = <String, ({String chatGuid, DateTime date})>{
        recentChanges[0].changeId: (chatGuid: 'chat-a', date: recentDateA),
        recentChanges[1].changeId: (chatGuid: 'chat-b', date: recentDateB),
        historicalChanges[0].changeId: (chatGuid: 'chat-a', date: oldDateA),
        historicalChanges[1].changeId: (chatGuid: 'chat-c', date: oldDateC),
      };

      final chats = <String, Chat>{
        'chat-a': Chat(guid: 'chat-a'),
        'chat-b': Chat(guid: 'chat-b'),
        'chat-c': Chat(guid: 'chat-c'),
      };

      Future<CloudCoordinatorLeaseFence> acquire(DateTime now) async {
        final fence = await store.tryAcquireCoordinatorLease(
          scope,
          ownerId: 'newest-first-test-owner',
          now: now,
          leaseDuration: const Duration(hours: 1),
        );
        expect(fence, isNotNull);
        return fence!;
      }

      Future<int> journal(
        CloudFetchBatch batch,
        CloudCoordinatorLeaseFence fence,
        DateTime now,
      ) async {
        final checkpoint = await store.readCheckpoint(scope);
        return store.journalFetchedBatch(
          batch,
          now: now,
          leaseFence: fence,
          expectedGeneration: checkpoint.generation,
          expectedFetchedToken: checkpoint.fetchedToken,
        );
      }

      Future<void> applySequence(
        int sequence,
        CloudCoordinatorLeaseFence fence,
        DateTime now,
      ) =>
          store.markInboxApplied(
            scope,
            sequence: sequence,
            now: now,
            leaseFence: fence,
          );

      void projectEntry(CloudInboxEntry entry) {
        final projection = projectionByChangeId[entry.change.changeId];
        if (projection == null) return;
        updateCloudSyncChatLatestMessageDate(
          chats[projection.chatGuid]!,
          projection.date,
        );
      }

      final fetchedTrace = <int>[];
      final appliedTrace = <int>[];
      final tokenTrace = <String?>[];
      Future<void> snapshotCursor() async {
        final checkpoint = await store.readCheckpoint(scope);
        fetchedTrace.add(checkpoint.fetchedSequence);
        appliedTrace.add(checkpoint.lastAppliedSequence);
        tokenTrace.add(checkpoint.fetchedToken);
      }

      void expectCursorMonotonic() {
        for (var i = 1; i < fetchedTrace.length; i++) {
          expect(
            fetchedTrace[i],
            greaterThanOrEqualTo(fetchedTrace[i - 1]),
            reason: 'fetchedSequence regressed',
          );
          expect(
            appliedTrace[i],
            greaterThanOrEqualTo(appliedTrace[i - 1]),
            reason: 'lastAppliedSequence regressed',
          );
        }
      }

      // Phase 1: journal + project the recent usable page first.
      var fence = await acquire(t0);
      expect(await journal(recentBatch, fence, t0), 2);
      var inbox = await store.inboxEntries(scope);
      expect(inbox.map((e) => e.sequence), [1, 2]);
      // Recent page is pending, so its token is held until terminal.
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      for (final entry in inbox) {
        projectEntry(entry);
        await applySequence(entry.sequence, fence, t1);
      }
      await snapshotCursor();
      final afterRecent = await store.readCheckpoint(scope);
      expect(afterRecent.fetchedToken, 'opaque-token-recent');
      expect(afterRecent.fetchedSequence, 2);
      expect(afterRecent.lastAppliedSequence, 2);
      // Recent usable chats are projected before any backfill exists.
      expect(chats['chat-a']!.dbOnlyLatestMessageDate, recentDateA);
      expect(chats['chat-b']!.dbOnlyLatestMessageDate, recentDateB);
      expect(chats['chat-c']!.dbOnlyLatestMessageDate, isNull);
      final projectedBeforeBackfill =
          chats['chat-a']!.dbOnlyLatestMessageDate == recentDateA &&
              chats['chat-b']!.dbOnlyLatestMessageDate == recentDateB;
      expect(projectedBeforeBackfill, isTrue);

      // Phase 2: duplicate replay of the recent page is idempotent.
      final recentCheckpointBefore = await store.readCheckpoint(scope);
      final chatABeforeDup = chats['chat-a']!.dbOnlyLatestMessageDate;
      final chatBBeforeDup = chats['chat-b']!.dbOnlyLatestMessageDate;
      expect(await journal(recentBatch, fence, t1), 0);
      inbox = await store.inboxEntries(scope);
      for (final entry in inbox.where((e) => e.sequence <= 2)) {
        projectEntry(entry);
        await applySequence(entry.sequence, fence, t1);
      }
      await snapshotCursor();
      final recentCheckpointAfterDup = await store.readCheckpoint(scope);
      expect(
        recentCheckpointAfterDup.fetchedToken,
        recentCheckpointBefore.fetchedToken,
      );
      expect(
        recentCheckpointAfterDup.fetchedSequence,
        recentCheckpointBefore.fetchedSequence,
      );
      expect(
        recentCheckpointAfterDup.lastAppliedSequence,
        recentCheckpointBefore.lastAppliedSequence,
      );
      expect(chats['chat-a']!.dbOnlyLatestMessageDate, chatABeforeDup);
      expect(chats['chat-b']!.dbOnlyLatestMessageDate, chatBBeforeDup);
      await store.releaseCoordinatorLease(scope, leaseFence: fence);

      // Phase 3: historical backfill journals after the recent page is
      // terminal, and its older dates must not move chat latest-dates back.
      fence = await acquire(t2);
      expect(await journal(historicalBatch, fence, t2), 3);
      inbox = await store.inboxEntries(scope);
      expect(inbox.map((e) => e.sequence), [1, 2, 3, 4, 5]);
      // Token stays on the recent value until the backfill is terminal.
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'opaque-token-recent',
      );
      for (final entry in inbox.where((e) => e.sequence >= 3)) {
        projectEntry(entry);
        await applySequence(entry.sequence, fence, t3);
      }
      await snapshotCursor();
      final afterBackfill = await store.readCheckpoint(scope);
      expect(afterBackfill.fetchedToken, 'opaque-token-historical');
      expect(afterBackfill.fetchedSequence, 5);
      expect(afterBackfill.lastAppliedSequence, 5);
      expect(chats['chat-a']!.dbOnlyLatestMessageDate, recentDateA);
      expect(chats['chat-b']!.dbOnlyLatestMessageDate, recentDateB);
      expect(chats['chat-c']!.dbOnlyLatestMessageDate, oldDateC);
      await store.releaseCoordinatorLease(scope, leaseFence: fence);

      // Phase 4: simulated restart resumes from the durable checkpoint and
      // duplicate replay stays monotonic.
      final restartSnapshot = await store.readCheckpoint(scope);
      final restartChatA = chats['chat-a']!.dbOnlyLatestMessageDate;
      final restartChatB = chats['chat-b']!.dbOnlyLatestMessageDate;
      final restartChatC = chats['chat-c']!.dbOnlyLatestMessageDate;
      fence = await acquire(t4);
      final resumed = await store.readCheckpoint(scope);
      expect(resumed.fetchedToken, restartSnapshot.fetchedToken);
      expect(resumed.fetchedSequence, restartSnapshot.fetchedSequence);
      expect(resumed.lastAppliedSequence, restartSnapshot.lastAppliedSequence);
      expect(await journal(historicalBatch, fence, t4), 0);
      inbox = await store.inboxEntries(scope);
      for (final entry in inbox) {
        projectEntry(entry);
        await applySequence(entry.sequence, fence, t4);
      }
      await snapshotCursor();
      final afterRestartDup = await store.readCheckpoint(scope);
      expect(afterRestartDup.fetchedToken, restartSnapshot.fetchedToken);
      expect(afterRestartDup.fetchedSequence, restartSnapshot.fetchedSequence);
      expect(
        afterRestartDup.lastAppliedSequence,
        restartSnapshot.lastAppliedSequence,
      );
      expect(chats['chat-a']!.dbOnlyLatestMessageDate, restartChatA);
      expect(chats['chat-b']!.dbOnlyLatestMessageDate, restartChatB);
      expect(chats['chat-c']!.dbOnlyLatestMessageDate, restartChatC);
      await store.releaseCoordinatorLease(scope, leaseFence: fence);

      expectCursorMonotonic();
      expect(tokenTrace, [
        'opaque-token-recent',
        'opaque-token-recent',
        'opaque-token-historical',
        'opaque-token-historical',
      ]);
    },
  );
}
