import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_group_send_route.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Explicit offline inventory, never a send or account initialization. Caller
// must verify the Windows harness has exited before invoking this file.
void main() {
  test(
    'inventory only the approved restored group on a disposable copy',
    () async {
      final profile = Directory(
        Platform.environment['OPENBUBBLES_WINDOWS_PROOF_PROFILE']!,
      ).absolute;
      final members =
          (jsonDecode(
                    Platform
                        .environment['OPENBUBBLES_WINDOWS_GROUP_RECIPIENTS']!,
                  )
                  as List)
              .cast<String>()
            ..sort();
      expect(members.length, 2);
      expect(members.toSet().length, 2);
      expect(members.every(RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch), isTrue);
      final requestFile = File(
        '${profile.path}/cloud-sync-v2/windows-local-write-request.json',
      );
      final requestBytes = await requestFile.readAsBytes();
      final request = CloudSyncWindowsWriteRequest.fromJson(
        jsonDecode(utf8.decode(requestBytes)) as Map<String, dynamic>,
      );
      final source = File('${profile.path}/objectbox/data.mdb');
      final before = await sha256.bind(source.openRead()).first;
      final scratchRoot = Directory(
        r'C:\Codex\OpenBubblesReview\scratch',
      ).absolute;
      final staging = await scratchRoot.createTemp('windows-group-inventory-');
      Store? store;
      try {
        final copied = await source.copy('${staging.path}/data.mdb');
        expect(await sha256.bind(copied.openRead()).first, before);
        expect(await sha256.bind(source.openRead()).first, before);
        store = await openStore(directory: staging.path);
        final report = store.runInTransaction(TxMode.read, () {
          var recipientMatches = 0;
          var restoredRoutes = 0;
          var senderMatches = 0;
          var completeGroupIds = 0;
          final selectorHashes = <String>[];
          for (final chat in store!.box<Chat>().getAll()) {
            final addresses = chat.handles.map((h) => h.address).toList()
              ..sort();
            if (jsonEncode(addresses) != jsonEncode(members)) continue;
            recipientMatches++;
            final route = CloudSyncGroupSendRoute.capture(chat);
            if (route == null || route.provisional) continue;
            restoredRoutes++;
            if (route.sender != request.sender) continue;
            senderMatches++;
            if (route.groupId == null) continue;
            completeGroupIds++;
            selectorHashes.add(
              sha256.convert(utf8.encode(chat.guid)).toString(),
            );
          }
          return {
            'version': 1,
            'exact_recipient_matches': recipientMatches,
            'restored_routes': restoredRoutes,
            'sender_matches': senderMatches,
            'complete_group_ids': completeGroupIds,
            'selector_hashes': selectorHashes,
            'unique_eligible_group': completeGroupIds == 1,
          };
        });
        store.close();
        store = null;
        expect(await sha256.bind(source.openRead()).first, before);
        expect(
          sha256.convert(await requestFile.readAsBytes()),
          sha256.convert(requestBytes),
        );
        // No text, participant addresses, names, or raw group identifiers.
        // ignore: avoid_print
        print(
          'WINDOWS_GROUP_INVENTORY=${jsonEncode({...report, 'source_unchanged': true})}',
        );
      } finally {
        store?.close();
        expect(staging.parent.path, scratchRoot.path);
        final entries = await staging.list(followLinks: false).toList();
        expect(
          entries.every(
            (entry) =>
                entry is File &&
                const {
                  'data.mdb',
                  'lock.mdb',
                }.contains(entry.uri.pathSegments.last),
          ),
          isTrue,
        );
        for (final entry in entries) {
          await entry.delete();
        }
        await staging.delete();
      }
    },
  );
}
