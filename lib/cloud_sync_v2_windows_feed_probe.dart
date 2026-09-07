import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/filesystem/cloud_sync_windows_dev_profile.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;
import 'package:path/path.dart' as path;

String cloudSyncWindowsFeedProbeSnapshot(Object? request) {
  if (request is! Map ||
      request['version'] != 1 ||
      request['snapshot'] is! String ||
      !RegExp(
        r'^windows-write-before-[a-zA-Z0-9-]{1,64}$',
      ).hasMatch(request['snapshot'] as String)) {
    throw StateError('cloud_sync_windows_feed_probe_request_invalid');
  }
  return request['snapshot'] as String;
}

/// Windows qualification only. Reads the same feed from two already-retained
/// checkpoints. Never journals, projects, commits a token, saves, or sends.
Future<Map<String, Object?>> cloudSyncWindowsProbeMessageFeed({
  required Directory profile,
  required rustlib.ArcCloudMessagesClientDefaultAnisetteProvider client,
}) async {
  if (!Platform.isWindows ||
      !CloudSyncDevGate.manualSemanticPullEnabled ||
      !CloudSyncWindowsDevProfile.compileEnabled ||
      !CloudSyncWindowsDevProfile.isExpectedDirectory(profile) ||
      !CloudSyncWindowsDevProfile.hasValidMarker(profile)) {
    throw StateError('cloud_sync_windows_feed_probe_disabled');
  }
  final control = Directory(path.join(profile.path, 'cloud-sync-v2'));
  final request = jsonDecode(
    await File(
      path.join(control.path, 'windows-feed-probe-request.json'),
    ).readAsString(),
  );
  final snapshotName = cloudSyncWindowsFeedProbeSnapshot(request);
  final source = File(
    path.join(control.path, snapshotName, 'objectbox', 'data.mdb'),
  );
  final resolvedControl = await control.resolveSymbolicLinks();
  final resolvedSource = await source.resolveSymbolicLinks();
  if (!path.isWithin(resolvedControl, resolvedSource)) {
    throw StateError('cloud_sync_windows_feed_probe_snapshot_invalid');
  }
  final operations = Database.store.box<CloudOutboxOperationEntity>().getAll();
  if (operations.isEmpty ||
      operations.any((row) => row.state != 2 || row.leaseIdHash != null)) {
    throw StateError('cloud_sync_windows_feed_probe_outbox_unsettled');
  }
  final messages = operations
      .where((row) => row.zone == 'messageManateeZone')
      .toList();
  if (messages.length != 1 || messages.single.serverRecordIdHash == null) {
    throw StateError('cloud_sync_windows_feed_probe_exact_message_required');
  }
  final message = messages.single;
  CloudSyncCheckpointEntity checkpoint(Store store) {
    final query = store
        .box<CloudSyncCheckpointEntity>()
        .query(
          CloudSyncCheckpointEntity_.zone
              .equals('messageManateeZone')
              .and(
                CloudSyncCheckpointEntity_.accountFingerprint.equals(
                  message.accountFingerprint,
                ),
              )
              .and(
                CloudSyncCheckpointEntity_.persistenceLane.equals('semantic'),
              ),
        )
        .build();
    try {
      final row = query.findUnique();
      if (row == null ||
          row.pendingBatchId != null ||
          row.fetchedTokenCiphertext == null ||
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

  final current = checkpoint(Database.store);
  late CloudSyncCheckpointEntity previous;
  // Open only a disposable copy of the quiescent pre-write rollback database.
  // No locks, schema metadata, or pages in the retained rollback are modified.
  final copy = await control.createTemp('.feed-probe-');
  try {
    await source.copy(path.join(copy.path, 'data.mdb'));
    final store = await openStore(directory: copy.path);
    try {
      previous = checkpoint(store);
    } finally {
      store.close();
    }
  } finally {
    await copy.delete(recursive: true);
  }
  if (previous.generation != current.generation ||
      previous.checkpointKey != current.checkpointKey ||
      previous.updatedAtMs >= message.confirmedAtMs) {
    throw StateError('cloud_sync_windows_feed_probe_snapshot_mismatch');
  }
  final scope = CloudSyncScope(
    accountFingerprint: current.accountFingerprint,
    container: current.container,
    database: current.database,
    zone: current.zone,
    streamKind: CloudSyncStreamKind.messages,
    schemaVersion: current.schemaVersion,
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final protector = RustCloudSyncProtector(storageDirectory: profile.path);
  final binding = FrbCloudSyncNativeAuthBinding();
  await binding.ensureReadAuthentication(
    cloudMessagesClient: client,
    privateStorageDirectory: profile.path,
  );
  final auth = await binding.capture(
    cloudMessagesClient: client,
    privateStorageDirectory: profile.path,
  );
  if (auth.accountFingerprint != message.accountFingerprint) {
    throw StateError('cloud_sync_windows_feed_probe_account_mismatch');
  }
  final pause = FrbCloudSyncNativeWriterPause();
  final pauseToken = await pause.pause();
  final results = <Map<String, Object?>>[];
  Map<String, dynamic>? wireProbe;
  try {
    await binding.warmReadAuthenticationUnderWriterPause(
      cloudMessagesClient: client,
      pauseToken: pauseToken as BigInt,
    );
    for (final entry in {
      'before_write': previous,
      'current': current,
    }.entries) {
      final reference = await protector.unprotect(
        scope: scope,
        kind: CloudSyncProtectedValueKind.checkpointToken,
        ciphertext: entry.value.fetchedTokenCiphertext!,
      );
      final result = await api.cloudSyncFetchProtectedPageUnderWriterPause(
        cloudMessagesClient: client,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: profile.path,
        expectedAccountFingerprint: auth.accountFingerprint,
        stream: 'messages',
        generation: BigInt.from(current.generation),
        previousCheckpointReference: reference,
        maximumChanges: 200,
      );
      final page = result.page;
      if (page == null) {
        results.add({
          'checkpoint': entry.key,
          'failed': true,
          'failure': result.failure?.safeCode.name,
        });
        continue;
      }
      try {
        results.add({
          'checkpoint': entry.key,
          'failed': false,
          'changes': page.changes.length,
          'terminal': page.complete,
          'target_matches': page.changes
              .where(
                (change) => change.recordIdHash == message.serverRecordIdHash,
              )
              .length,
        });
      } finally {
        final rollback = api.cloudSyncRollbackProtectedPageLease(
          storageDirectory: profile.path,
          pageLeaseReference: page.pageLeaseReference,
        );
        if (rollback.failure != null) {
          throw StateError('cloud_sync_windows_feed_probe_rollback_failed');
        }
      }
    }
    final reference = await protector.unprotect(
      scope: scope,
      kind: CloudSyncProtectedValueKind.checkpointToken,
      ciphertext: current.fetchedTokenCiphertext!,
    );
    wireProbe =
        jsonDecode(
              await api.cloudSyncWindowsProbeMessageFeed(
                cloudMessagesClient: client,
                nativeWriterPauseToken: pauseToken,
                storageDirectory: profile.path,
                expectedAccountFingerprint: auth.accountFingerprint,
                generation: BigInt.from(current.generation),
                checkpointReference: reference,
                expectedRecordIdHash: message.serverRecordIdHash!,
              ),
            )
            as Map<String, dynamic>;
  } finally {
    await pause.resume(pauseToken);
  }
  final after = checkpoint(Database.store);
  if (after.fetchedTokenCiphertext != current.fetchedTokenCiphertext ||
      after.fetchedSequence != current.fetchedSequence ||
      after.generation != current.generation ||
      after.pendingBatchId != null) {
    throw StateError('cloud_sync_windows_feed_probe_checkpoint_changed');
  }
  return {
    'checkpoint_unchanged': true,
    'reads': results,
    'wire_probe': wireProbe,
  };
}
