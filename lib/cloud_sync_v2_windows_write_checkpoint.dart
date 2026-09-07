import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

CloudSyncCheckpointEntity cloudSyncWindowsMessageCheckpoint(
  Store store,
  String account,
) {
  final query = store
      .box<CloudSyncCheckpointEntity>()
      .query(
        CloudSyncCheckpointEntity_.zone
            .equals('messageManateeZone')
            .and(CloudSyncCheckpointEntity_.accountFingerprint.equals(account))
            .and(CloudSyncCheckpointEntity_.persistenceLane.equals('semantic')),
      )
      .build();
  try {
    final row = query.findUnique();
    if (row == null ||
        row.pendingBatchId != null ||
        row.pendingFetchedTokenCiphertext != null ||
        row.fetchedTokenCiphertext == null ||
        row.generation <= 0 ||
        row.streamKind != 'messages' ||
        row.container != 'com.apple.messages.cloud' ||
        row.database != 'private') {
      throw StateError('cloud_sync_windows_feed_probe_checkpoint_required');
    }
    return row;
  } finally {
    query.close();
  }
}

/// Private Windows qualification evidence only. Does not pin, restore, or
/// modify production tokens. Preserve the opaque native ciphertext before
/// normal checkpoint retirement; never decode or report Apple's raw cursor.
Future<void> cloudSyncWindowsPreserveWriteCheckpoint({
  required Store store,
  required Directory profile,
  required String requestId,
  required String requestBinding,
  required String accountFingerprint,
}) async {
  if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(requestId)) {
    throw StateError('cloud_sync_windows_write_request_invalid');
  }
  final row = cloudSyncWindowsMessageCheckpoint(store, accountFingerprint);
  final scope = CloudSyncScope(
    accountFingerprint: row.accountFingerprint,
    container: row.container,
    database: row.database,
    zone: row.zone,
    streamKind: CloudSyncStreamKind.messages,
    schemaVersion: row.schemaVersion,
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final reference = await RustCloudSyncProtector(storageDirectory: profile.path)
      .unprotect(
        scope: scope,
        kind: CloudSyncProtectedValueKind.checkpointToken,
        ciphertext: row.fetchedTokenCiphertext!,
      );
  if (!RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$').hasMatch(reference)) {
    throw StateError('cloud_sync_windows_write_checkpoint_reference_invalid');
  }
  final native = File(
    path.join(
      profile.path,
      'cloud_sync_v2_native_store',
      '${reference.substring('obcs2.ref.'.length)}.protected',
    ),
  );
  final root = await profile.resolveSymbolicLinks();
  if (!path.isWithin(root, await native.resolveSymbolicLinks()) ||
      await native.length() > 1024 * 1024) {
    throw StateError('cloud_sync_windows_write_checkpoint_file_invalid');
  }
  final bytes = await native.readAsBytes();
  if (bytes.isEmpty) {
    throw StateError('cloud_sync_windows_write_checkpoint_file_invalid');
  }
  final snapshot = Directory(
    path.join(profile.path, 'cloud-sync-v2', 'windows-write-before-$requestId'),
  );
  if (snapshot.existsSync()) {
    // An interrupted pre-send preparation is evidence, not permission to
    // overwrite the causal snapshot or silently start another send attempt.
    throw StateError('cloud_sync_windows_write_snapshot_already_exists');
  }
  await snapshot.create();
  if (!path.isWithin(root, await snapshot.resolveSymbolicLinks())) {
    throw StateError('cloud_sync_windows_write_checkpoint_file_invalid');
  }
  final encrypted = File(
    path.join(snapshot.path, 'native-checkpoint.protected'),
  );
  await encrypted.create(exclusive: true);
  await encrypted.writeAsBytes(bytes, flush: true);
  final metadata = File(path.join(snapshot.path, 'checkpoint.json'));
  await metadata.create(exclusive: true);
  await metadata.writeAsString(
    jsonEncode({
      'version': 1,
      'requestId': requestId,
      'requestBinding': requestBinding,
      'checkpointKey': row.checkpointKey,
      'accountFingerprint': row.accountFingerprint,
      'generation': row.generation,
      'schemaVersion': row.schemaVersion,
      'fetchedTokenCiphertext': row.fetchedTokenCiphertext,
      'fetchedSequence': row.fetchedSequence,
      'updatedAtMs': row.updatedAtMs,
      'capturedAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
      'nativeSha256': sha256.convert(bytes).toString(),
    }),
    flush: true,
  );
  final after = cloudSyncWindowsMessageCheckpoint(store, accountFingerprint);
  if (after.checkpointKey != row.checkpointKey ||
      after.generation != row.generation ||
      after.fetchedTokenCiphertext != row.fetchedTokenCiphertext ||
      after.fetchedSequence != row.fetchedSequence) {
    throw StateError('cloud_sync_windows_write_checkpoint_changed');
  }
}
