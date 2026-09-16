// Explicit offline inspection of a hash-qualified Canary database copy.
// Only numeric sizes, fixed status values and timestamps are printed.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_source_resolver.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final input = Platform.environment['OPENBUBBLES_ATTACHMENT_INSPECT_DIR'];
  test(
    'inspect sizes of recent materialization attempts on an offline copy',
    () async {
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
      final copy = await scratch.createTemp('attachment-sizes-');
      Store? store;
      try {
        await source.copy('${copy.path}/data.mdb');
        store = await openStore(directory: copy.path);
        final result = <Map<String, Object?>>[];
        final counts = <String, int>{};
        final leases = <Map<String, Object?>>[];
        final checkpoints = <Map<String, Object?>>[];
        final restoreChecks = <Future<void> Function()>[];
        store.runInTransaction(TxMode.read, () {
          counts.addAll({
            'chats': store!.box<Chat>().count(),
            'messages': store.box<Message>().count(),
            'attachments': store.box<Attachment>().count(),
            'outbox': store.box<CloudOutboxOperationEntity>().count(),
          });
          final now = DateTime.now().millisecondsSinceEpoch;
          for (final lease in store.box<CloudSyncLeaseEntity>().getAll()) {
            leases.add({
              'operationFence':
                  lease.scopeKey == CloudKitOperationInterlock.fenceScopeKey,
              'generation': lease.generation,
              'ageSeconds': (now - lease.acquiredAtMs) ~/ 1000,
              'remainingSeconds': (lease.expiresAtMs - now) ~/ 1000,
              'durationSeconds':
                  (lease.expiresAtMs - lease.acquiredAtMs) ~/ 1000,
            });
          }
          for (final row in store.box<CloudSyncCheckpointEntity>().getAll()) {
            checkpoints.add({
              'zone':
                  const {
                    'chatManateeZone',
                    'messageManateeZone',
                    'attachmentManateeZone',
                  }.contains(row.zone)
                  ? row.zone
                  : 'other',
              'generation': row.generation,
              'fetchedSequence': row.fetchedSequence,
              'appliedSequence': row.appliedSequence,
              'pendingBatch': row.pendingBatchId != null,
              'pendingToken': row.pendingFetchedTokenCiphertext != null,
            });
          }
          final attempts =
              store.box<CloudAttachmentMaterializationEntity>().getAll()
                ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
          final snapshots = store.box<CloudSemanticSnapshotEntity>().getAll();
          final attachments = store.box<Attachment>().getAll();
          final resolver = CloudAttachmentSourceResolver(store: store);
          for (final attempt in attempts.take(12)) {
            final owners = snapshots.where((row) {
              if (row.accountFingerprint != attempt.accountFingerprint ||
                  row.zone != attempt.zone ||
                  row.generation != attempt.generation ||
                  row.entityKind != 'attachment' ||
                  row.logicalEntityKeyHash != attempt.logicalEntityKeyHash) {
                return false;
              }
              final scope = CloudSyncScope(
                accountFingerprint: row.accountFingerprint,
                container: row.container,
                database: row.database,
                zone: row.zone,
                streamKind: CloudSyncStreamKind.values.byName(row.streamKind),
                schemaVersion: row.schemaVersion,
                persistenceLane: CloudSyncPersistenceLane.semantic,
              );
              return sha256
                      .convert(
                        utf8.encode(
                          'cloud-sync-scope\u001f${scope.storageKey}',
                        ),
                      )
                      .toString() ==
                  attempt.scopeKey;
            }).toList();
            final details = <String, Object?>{
              'stage':
                  attempt.stage >= 0 &&
                      attempt.stage <
                          CloudAttachmentMaterializationStage.values.length
                  ? CloudAttachmentMaterializationStage
                        .values[attempt.stage]
                        .name
                  : 'invalid',
              'expectedBytes': attempt.expectedBytes,
              'verifiedBytes': attempt.verifiedBytes,
              'updatedAtUtc': DateTime.fromMillisecondsSinceEpoch(
                attempt.updatedAtMs,
                isUtc: true,
              ).toIso8601String(),
              'owners': owners.length,
            };
            if (owners.length == 1) {
              final owner = owners.single;
              final scope = CloudSyncScope(
                accountFingerprint: owner.accountFingerprint,
                container: owner.container,
                database: owner.database,
                zone: owner.zone,
                streamKind: CloudSyncStreamKind.values.byName(owner.streamKind),
                schemaVersion: owner.schemaVersion,
                persistenceLane: CloudSyncPersistenceLane.semantic,
              );
              restoreChecks.add(() async {
                final restored =
                    await ObjectBoxCloudAttachmentMaterializationStore(
                      store: store!,
                    ).read(
                      scope: scope,
                      generation: owner.generation,
                      logicalEntityKeyHash: attempt.logicalEntityKeyHash,
                    );
                expect(restored, isNotNull);
                details['persistedStateRestored'] = true;
                details['hasVerifiedNativeBodySize'] =
                    restored!.hasVerifiedNativeBodySize;
                details['materializedBytes'] = restored.materializedBytes;
              });
              final matches = attachments.where((attachment) {
                try {
                  return CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
                        scope: scope,
                        generation: owner.generation,
                        canonicalGuid: attachment.guid ?? '',
                      ) ==
                      owner.canonicalGuidLookupHash;
                } on ArgumentError {
                  return false;
                }
              }).toList();
              details['canonicalRows'] = matches.length;
              if (matches.length == 1) {
                final attachment = matches.single;
                details['canonicalBytes'] = attachment.totalBytes;
                details['type'] = switch (attachment.mimeType) {
                  'image/jpeg' => 'jpeg',
                  'image/png' => 'png',
                  'image/heic' => 'heic',
                  'image/gif' => 'gif',
                  'video/mp4' => 'mp4',
                  'video/quicktime' => 'mov',
                  _ => 'other',
                };
                try {
                  resolver.resolve(
                    scope: scope,
                    generation: owner.generation,
                    canonicalGuid: attachment.guid!,
                  );
                  details['source'] = 'resolved';
                } on CloudAttachmentSourceResolutionFailure catch (failure) {
                  details['source'] = failure.code.name;
                }
              }
            }
            result.add(details);
          }
        });
        for (final restore in restoreChecks) {
          await restore();
        }
        expect((await sha256.bind(source.openRead()).first).toString(), before);
        // ignore: avoid_print
        print(
          'ATTACHMENT_SIZE_REPORT=${jsonEncode({'sourceUnchanged': true, 'remoteCalls': 0, 'counts': counts, 'leases': leases, 'checkpoints': checkpoints, 'attempts': result})}',
        );
      } finally {
        store?.close();
        if (copy.parent.absolute.path != scratch.absolute.path ||
            !copy.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('attachment-sizes-')) {
          throw StateError('attachment_size_inspection_cleanup_target_invalid');
        }
        await copy.delete(recursive: true);
      }
    },
    skip: input == null,
  );
}
