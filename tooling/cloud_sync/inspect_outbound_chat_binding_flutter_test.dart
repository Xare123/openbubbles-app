import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_binding.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('checks restored chat dependencies on a disposable offline copy', () async {
    final source = Platform.environment['OPENBUBBLES_OBJECTBOX_INSPECT_DIR'];
    expect(source, isNotNull, reason: 'offline inspection directory required');
    final sourceData = File('$source/data.mdb');
    expect(sourceData.existsSync(), isTrue);
    final sourceDigest = await sha256.bind(sourceData.openRead()).first;
    final scratch = Directory(r'C:\Codex\OpenBubblesReview\scratch');
    final staging = await scratch.createTemp('outbound-chat-check-');
    Store? store;
    try {
      await sourceData.copy('${staging.path}/data.mdb');
      store = await openStore(directory: staging.path);
      final checkpoints = store
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .where(
            (row) =>
                row.container == 'com.apple.messages.cloud' &&
                row.database == 'private' &&
                row.zone == 'messageManateeZone' &&
                row.streamKind == 'messages' &&
                row.persistenceLane == 'semantic',
          )
          .toList();
      expect(checkpoints, hasLength(1), reason: 'one scoped source required');
      final checkpoint = checkpoints.single;
      final scope = CloudSyncScope(
        accountFingerprint: checkpoint.accountFingerprint,
        container: checkpoint.container,
        database: checkpoint.database,
        zone: checkpoint.zone,
        streamKind: CloudSyncStreamKind.messages,
        schemaVersion: checkpoint.schemaVersion,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      var candidates = 0;
      var ready = 0;
      var notReady = 0;
      final bindings = <String>[];
      store.runInTransaction(TxMode.read, () {
        for (final chat in store!.box<Chat>().getAll()) {
          if (chat.style != 45 || chat.isRpSms || chat.isRoutingStub) continue;
          candidates++;
          // No body or address is read into the synthetic message or emitted.
          final message = Message()..chat.targetId = chat.id!;
          try {
            final binding = requireCloudSyncRestoredDirectChat(
              store: store,
              messageScope: scope,
              message: message,
            );
            bindings.add(binding);
            ready++;
          } on CloudSyncFailure catch (failure) {
            expect(failure.safeCode, 'cloud_sync_local_send_chat_not_ready');
            notReady++;
          }
        }
      });
      store.close();
      store = await openStore(directory: staging.path);
      var restartReady = 0;
      store.runInTransaction(TxMode.read, () {
        for (final binding in bindings) {
          requireCloudSyncAdoptedChatDependency(
            store: store!,
            messageScope: scope,
            binding: binding,
          );
          restartReady++;
        }
      });
      final sourceUnchanged =
          (await sha256.bind(sourceData.openRead()).first) == sourceDigest;
      expect(sourceUnchanged, isTrue);
      // ignore: avoid_print
      print(
        'OUTBOUND_CHAT_BINDING_REPORT=${jsonEncode({'directChatCandidates': candidates, 'restoredChatReady': ready, 'restartChatReady': restartReady, 'chatDependencyNotReady': notReady, 'remoteCalls': 0, 'sourceOpenedAsDatabase': false, 'sourceUnchanged': sourceUnchanged})}',
      );
      expect(
        ready,
        greaterThan(0),
        reason: 'real restored chat proof must pass',
      );
    } finally {
      store?.close();
      // This directory was created by this invocation, contains only its
      // disposable copy, and must remain directly under the known scratch root.
      if (staging.parent.absolute.path != scratch.absolute.path ||
          !staging.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('outbound-chat-check-')) {
        throw StateError('inspection_cleanup_target_invalid');
      }
      await staging.delete(recursive: true);
    }
  });
}
