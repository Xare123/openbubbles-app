import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'repairs the captured legacy floor on a disposable ObjectBox copy',
    () async {
      final sourcePath =
          Platform.environment['OPENBUBBLES_OBJECTBOX_INSPECT_DIR'];
      expect(sourcePath, isNotNull, reason: 'inspection directory is required');
      final source = Directory(sourcePath!);
      expect(
        File('${source.path}${Platform.pathSeparator}data.mdb').existsSync(),
        isTrue,
      );

      final staging = await Directory.systemTemp.createTemp(
        'openbubbles-cloud-sync-recovery-',
      );
      try {
        await for (final entity in source.list(followLinks: false)) {
          if (entity is! File) continue;
          await entity.copy(
            '${staging.path}${Platform.pathSeparator}${entity.uri.pathSegments.last}',
          );
        }

        var objectBox = await openStore(directory: staging.path);
        final recoveryTime = DateTime.utc(2100);
        var store = ObjectBoxCloudSyncStore(
          store: objectBox,
          protector: const _OpaqueInspectionProtector(),
          clock: () => recoveryTime,
        );
        try {
          final checkpointBox = objectBox.box<CloudSyncCheckpointEntity>();
          var checkpoint = checkpointBox.getAll().singleWhere(
            (row) =>
                row.persistenceLane == CloudSyncPersistenceLane.semantic.name &&
                row.zone == 'chatManateeZone' &&
                row.fetchedSequence == 600 &&
                row.appliedSequence == 600,
          );
          final streamKind = CloudSyncStreamKind.values.singleWhere(
            (candidate) => candidate.name == checkpoint.streamKind,
          );
          final scope = CloudSyncScope(
            accountFingerprint: checkpoint.accountFingerprint,
            container: checkpoint.container,
            database: checkpoint.database,
            zone: checkpoint.zone,
            streamKind: streamKind,
            schemaVersion: checkpoint.schemaVersion,
            persistenceLane: CloudSyncPersistenceLane.semantic,
          );
          final tokenCiphertextBefore = checkpoint.fetchedTokenCiphertext;
          final generationBefore = checkpoint.generation;
          final inboxBox = objectBox.box<CloudInboxChangeEntity>();
          var rows =
              inboxBox
                  .getAll()
                  .where(
                    (row) =>
                        row.scopeKey == checkpoint.checkpointKey &&
                        row.generation == checkpoint.generation,
                  )
                  .toList()
                ..sort(
                  (left, right) =>
                      left.fetchSequence.compareTo(right.fetchSequence),
                );
          expect(rows, hasLength(600));
          expect(
            rows.where((row) => row.status == CloudInboxStatus.applied.index),
            hasLength(404),
          );
          expect(
            rows.where(
              (row) => row.status == CloudInboxStatus.retainedUnprojected.index,
            ),
            hasLength(123),
          );
          final legacyTombstones = rows
              .where((row) => row.status == CloudInboxStatus.quarantined.index)
              .toList();
          expect(legacyTombstones, hasLength(73));
          expect(
            legacyTombstones,
            everyElement(
              isA<CloudInboxChangeEntity>()
                  .having((row) => row.isTombstone, 'isTombstone', isTrue)
                  .having(
                    (row) => row.failureCategory,
                    'failureCategory',
                    CloudFailureCategory.conflict.name,
                  )
                  .having(
                    (row) => row.preflightCategory,
                    'preflightCategory',
                    isNull,
                  )
                  .having((row) => row.preflightCode, 'preflightCode', isNull),
            ),
          );
          final evidenceBefore = <int, String>{
            for (final row in legacyTombstones)
              row.fetchSequence: _evidenceFingerprint(row),
          };
          final canonicalCountsBefore = (
            chats: objectBox.box<Chat>().count(),
            messages: objectBox.box<Message>().count(),
            attachments: objectBox.box<Attachment>().count(),
            snapshots: objectBox.box<CloudSemanticSnapshotEntity>().count(),
            maps: objectBox.box<CloudRecordMapEntity>().count(),
            replays: objectBox.box<CloudSemanticReplayEntity>().count(),
            outbox: objectBox.box<CloudOutboxOperationEntity>().count(),
          );

          final fence = (await store.tryAcquireCoordinatorLease(
            scope,
            ownerId: 'captured-recovery-test',
            now: recoveryTime,
            leaseDuration: const Duration(days: 1),
          ))!;
          final recovered = await store.recoverRetainedInboxBarriers(
            scope,
            now: recoveryTime,
            maximumDeferredAttempts: 8,
            maximumDeferredAge: const Duration(days: 3),
            leaseFence: fence,
            allowLegacyReadOnlyTombstoneAcknowledgement: true,
          );

          expect(recovered.retainedUnprojected, 73);
          expect(recovered.tombstoneReadOnlyAcknowledged, 73);
          expect(recovered.previousAppliedSequence, 600);
          expect(recovered.recomputedAppliedSequence, 600);
          expect(recovered.legacyFloorInflated, isTrue);
          expect(recovered.recoveryComplete, isTrue);
          expect(recovered.firstUnresolvedSequence, isNull);

          checkpoint = checkpointBox.get(checkpoint.id)!;
          expect(checkpoint.fetchedTokenCiphertext, tokenCiphertextBefore);
          expect(checkpoint.generation, generationBefore);
          expect(checkpoint.fetchedSequence, 600);
          expect(checkpoint.appliedSequence, 600);
          expect(checkpoint.pendingBatchId, isNull);
          rows = inboxBox
              .getAll()
              .where(
                (row) =>
                    row.scopeKey == checkpoint.checkpointKey &&
                    row.generation == checkpoint.generation,
              )
              .toList();
          expect(
            rows.where((row) => row.status == CloudInboxStatus.applied.index),
            hasLength(404),
          );
          expect(
            rows.where(
              (row) => row.status == CloudInboxStatus.retainedUnprojected.index,
            ),
            hasLength(196),
          );
          expect(
            rows.where(
              (row) => row.status == CloudInboxStatus.quarantined.index,
            ),
            isEmpty,
          );
          expect(<int, String>{
            for (final row in rows.where(
              (row) => evidenceBefore.containsKey(row.fetchSequence),
            ))
              row.fetchSequence: _evidenceFingerprint(row),
          }, evidenceBefore);
          expect((
            chats: objectBox.box<Chat>().count(),
            messages: objectBox.box<Message>().count(),
            attachments: objectBox.box<Attachment>().count(),
            snapshots: objectBox.box<CloudSemanticSnapshotEntity>().count(),
            maps: objectBox.box<CloudRecordMapEntity>().count(),
            replays: objectBox.box<CloudSemanticReplayEntity>().count(),
            outbox: objectBox.box<CloudOutboxOperationEntity>().count(),
          ), canonicalCountsBefore);

          objectBox.close();
          objectBox = await openStore(directory: staging.path);
          store = ObjectBoxCloudSyncStore(
            store: objectBox,
            protector: const _OpaqueInspectionProtector(),
            clock: () => recoveryTime,
          );
          checkpoint = objectBox.box<CloudSyncCheckpointEntity>().get(
            checkpoint.id,
          )!;
          expect(checkpoint.fetchedTokenCiphertext, tokenCiphertextBefore);
          expect(checkpoint.appliedSequence, 600);
          final repeated = await store.recoverRetainedInboxBarriers(
            scope,
            now: recoveryTime,
            maximumDeferredAttempts: 8,
            maximumDeferredAge: const Duration(days: 3),
            leaseFence: fence,
            allowLegacyReadOnlyTombstoneAcknowledgement: true,
          );
          expect(repeated.retainedUnprojected, 0);
          expect(repeated.tombstoneReadOnlyAcknowledged, 0);
          expect(repeated.legacyFloorInflated, isFalse);
          expect(repeated.recomputedAppliedSequence, 600);
          expect(repeated.recoveryComplete, isTrue);
        } finally {
          if (!objectBox.isClosed()) objectBox.close();
        }
      } finally {
        if (staging.existsSync()) await staging.delete(recursive: true);
      }
    },
  );
}

String _evidenceFingerprint(CloudInboxChangeEntity row) {
  return sha256
      .convert(
        utf8.encode(
          jsonEncode(<Object?>[
            row.changeKey,
            row.changeIdHash,
            row.scopeKey,
            row.accountFingerprint,
            row.zone,
            row.serverRecordIdHash,
            row.etagHash,
            row.changeType,
            row.encryptedServerRecordId,
            row.protectedSystemFieldsRef,
            row.encryptedPayloadRef,
            row.payloadSha256,
            row.batchId,
            row.generation,
            row.fetchSequence,
            row.isTombstone,
            row.preflightCategory,
            row.preflightCode,
            row.failureCategory,
            row.retryCount,
            row.serverModifiedAtMs,
            row.createdAtMs,
          ]),
        ),
      )
      .toString();
}

final class _OpaqueInspectionProtector implements CloudSyncProtector {
  const _OpaqueInspectionProtector();

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) =>
      throw UnsupportedError('inspection-only');

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) => throw UnsupportedError('inspection-only');

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) => throw UnsupportedError('inspection-only');
}
