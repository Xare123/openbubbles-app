import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'inspect_windows_write_proof.dart';

// Invoke only after the Windows harness has exited. Opens a disposable copy,
// never the retained database. No account initialization or native network API.
// Inspect writer proofs with the same compile gates as the producing runtime:
// --dart-define=OPENBUBBLES_CLOUDKIT_WRITER_OWNER=v2
// --dart-define=OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY=true
// Otherwise parent-authority validation correctly rejects the build owner.
void main() {
  test(
    'inspect the exact retained Windows test request without changing its store',
    () async {
      final profilePath =
          Platform.environment['OPENBUBBLES_WINDOWS_PROOF_PROFILE'];
      expect(profilePath, isNotNull);
      final profile = Directory(profilePath!).absolute;
      final source = File('${profile.path}/objectbox/data.mdb');
      final archivedRequestId =
          Platform.environment['OPENBUBBLES_WINDOWS_PROOF_REQUEST_ID'];
      if (archivedRequestId != null &&
          !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(archivedRequestId)) {
        throw StateError('windows_write_proof_request_id_invalid');
      }
      final requestName = archivedRequestId == null
          ? 'windows-local-write-request.json'
          : 'windows-local-write-request-$archivedRequestId.json';
      final requestFile = File('${profile.path}/cloud-sync-v2/$requestName');
      final requestBytes = await requestFile.readAsString();
      final request = CloudSyncWindowsWriteRequest.fromJson(
        jsonDecode(requestBytes) as Map<String, dynamic>,
      );
      if (archivedRequestId != null && request.id != archivedRequestId) {
        throw StateError('windows_write_proof_request_id_mismatch');
      }
      final claimFile = File(
        '${profile.path}/cloud-sync-v2/windows-write-${request.id}.json',
      );
      final claimBytes = claimFile.existsSync()
          ? await claimFile.readAsString()
          : null;
      final parentClaimFile = request.reactionType == null
          ? null
          : File(
              '${profile.path}/cloud-sync-v2/windows-write-${request.existingChatFromRequestId}.json',
            );
      final parentClaimBytes = parentClaimFile == null
          ? null
          : await parentClaimFile.readAsString();
      final before = await sha256.bind(source.openRead()).first;
      final scratchRoot = Directory(
        r'C:\Codex\OpenBubblesReview\scratch',
      ).absolute;
      final staging = await scratchRoot.createTemp('windows-write-proof-');
      Store? store;
      try {
        final copied = await source.copy('${staging.path}/data.mdb');
        expect(await sha256.bind(copied.openRead()).first, before);
        expect(await sha256.bind(source.openRead()).first, before);
        store = await openStore(directory: staging.path);
        final report = inspectWindowsWriteProof(
          store,
          request,
          claimBytes == null
              ? null
              : jsonDecode(claimBytes) as Map<String, dynamic>,
          parentClaim: parentClaimBytes == null
              ? null
              : jsonDecode(parentClaimBytes) as Map<String, dynamic>,
        );
        store.close();
        store = null;
        expect(await sha256.bind(source.openRead()).first, before);
        expect(
          sha256.convert(await requestFile.readAsBytes()),
          sha256.convert(utf8.encode(requestBytes)),
        );
        expect(
          claimFile.existsSync()
              ? sha256.convert(await claimFile.readAsBytes())
              : null,
          claimBytes == null ? null : sha256.convert(utf8.encode(claimBytes)),
        );
        if (parentClaimFile != null) {
          expect(
            sha256.convert(await parentClaimFile.readAsBytes()),
            sha256.convert(utf8.encode(parentClaimBytes!)),
          );
        }
        // Only booleans, finite states and counters. No text, handles or raw IDs.
        // ignore: avoid_print
        print(
          'WINDOWS_WRITE_PROOF=${jsonEncode({...report, 'source_unchanged': true})}',
        );
      } finally {
        store?.close();
        // Only these two generated files can be discarded; unexpected content
        // is retained for parent review. Never recursively clean a profile.
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
