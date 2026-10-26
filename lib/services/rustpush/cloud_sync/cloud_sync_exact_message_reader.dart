import 'package:bluebubbles/database/models.dart' show Store;
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;
import 'package:bluebubbles/utils/logger/logger.dart';

import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_protector.dart';
import 'cloud_sync_store.dart';
import 'native_protected_cloud_sync_transport.dart';
import 'objectbox_cloud_sync_store.dart';

enum CloudSyncExactMessageReadDisposition {
  projected,
  retained,
  absent,
  unresolved,
}

/// Keep the complete, settled outbox snapshot pinned around one exact read.
/// Audit retention is not upload permission; changed or uncertain rows refuse.
Future<T> withCloudSyncExactReadOutbox<T>({
  required CloudSyncShadowPreflightReader readPreflight,
  required bool Function() stillCurrent,
  required Future<T> Function() read,
}) async {
  final before = await readPreflight();
  if (!before.allowsSemanticRead) {
    throw StateError('cloud_sync_exact_read_outbox_unsettled');
  }
  final result = await read();
  final after = await readPreflight();
  if (!stillCurrent() || !before.hasSameSettledOutboxAs(after)) {
    throw StateError('cloud_sync_semantic_remote_write_tripwire');
  }
  return result;
}

/// Adopts the actual native fetched bytes without inventing a sent, received or
/// historical source. Success means retained reader work, not projection/head.
Future<void> adoptCloudSyncExactMessageFound({
  required api.CloudSyncExactMessageFound result,
  required CloudSyncScope scope,
  required int generation,
  required CloudCoordinatorLeaseFence coordinator,
  required ObjectBoxCloudSyncStore durable,
  required CloudProtectedPageLeaseLifecycle lifecycle,
  required Future<void> Function() validate,
  required bool Function() stillCurrent,
}) async {
  var adopted = false;
  final raw = result.change;
  final page = CloudFetchBatch(
    scope: scope,
    changes: const [],
    batchId: result.batchId,
    generation: generation,
    nextToken: null,
    hasMore: false,
    protectedPageLeaseReference: result.leaseReference,
  );
  try {
    if (result.generation.toInt() != generation ||
        raw.kind != api.CloudSyncProtectedChangeKind.save ||
        raw.isTombstone ||
        raw.preflightCode != null) {
      throw StateError('cloud_sync_exact_read_record_mismatch');
    }
    final change = CloudFetchedChange(
      changeId: raw.changeId,
      recordIdHash: raw.recordIdHash,
      etagHash: raw.etagHash,
      type: CloudChangeType.save,
      encryptedServerRecordId: raw.protectedRecordIdentityReference,
      encryptedPayloadReference: raw.protectedRawEnvelopeReference,
      payloadSha256: raw.payloadSha256,
      serverModifiedAt: raw.serverModifiedAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              raw.serverModifiedAtMillis!.toInt(),
              isUtc: true,
            ),
    );
    await validate();
    final owned = durable.journalExactReadFound(
      scope: scope,
      change: change,
      generation: generation,
      batchId: result.batchId,
      leaseReference: result.leaseReference,
      leaseFence: coordinator,
      stillCurrent: stillCurrent,
    );
    adopted = true;
    if (!owned) {
      await lifecycle.rollbackUnjournaledPage(page);
      return;
    }
    await lifecycle.commitJournaledPage(
      CloudFetchBatch(
        scope: scope,
        changes: [change],
        batchId: result.batchId,
        generation: generation,
        nextToken: null,
        hasMore: false,
        protectedPageLeaseReference: result.leaseReference,
      ),
      previousCheckpointReference: null,
    );
  } catch (_) {
    // Once the durable inbox owns a lease, only normal recovery may finish it.
    if (!adopted) {
      try {
        await lifecycle.rollbackUnjournaledPage(page);
      } catch (_) {}
    }
    rethrow;
  }
}

/// Called inside an authenticated semantic read session. Exact lookup touches
/// no history cursor and never downloads assets or creates Chat metadata.
/// The ordinary reader still decides projection, dependencies and conflicts.
Future<CloudSyncExactMessageReadDisposition> retainCloudSyncKnownMessage({
  required String messageGuid,
  required CloudSyncNativeAuthSnapshot auth,
  required BigInt pauseToken,
  required Store objectBox,
  required String privateStorageDirectory,
  required CloudSyncNativeAuthSnapshotReader readCurrentBoundAuth,
  required bool Function() stillCurrent,
  required Future<CloudInboxApplyResult> Function(
    CloudInboxEntry entry,
    CloudCoordinatorLeaseFence coordinator,
  )
  apply,
}) async {
  final client = auth.cloudMessagesClient;
  if (client is! native.ArcCloudMessagesClientDefaultAnisetteProvider ||
      !stillCurrent()) {
    throw StateError('cloud_sync_exact_read_identity_changed');
  }
  final durable = ObjectBoxCloudSyncStore(
    store: objectBox,
    protector: RustCloudSyncProtector(
      storageDirectory: privateStorageDirectory,
    ),
  );
  final scope = CloudSyncScope(
    accountFingerprint: auth.accountFingerprint,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final checkpoint = await durable.readCheckpoint(scope);
  final transport = NativeProtectedCloudSyncTransport(
    cloudMessagesClient: client,
    storageDirectory: privateStorageDirectory,
    protectedStoreIdentity: auth.protectedStoreIdentity,
    nativeWriterPauseToken: pauseToken,
  );
  final lifecycle = CloudProtectedPageLeaseLifecycle(
    store: durable,
    transport: transport,
  );
  CloudCoordinatorLeaseFence? coordinator;
  api.CloudSyncExactMessageFound? retainedFound;
  Future<void> validate() async {
    if (!stillCurrent() ||
        objectBox.isClosed() ||
        !auth.sameIdentity(await readCurrentBoundAuth())) {
      throw StateError('cloud_sync_exact_read_identity_changed');
    }
    final current = await durable.readCheckpoint(scope);
    if (!stillCurrent() ||
        current.generation != checkpoint.generation ||
        current.fetchedToken != checkpoint.fetchedToken ||
        current.pendingBatchId != checkpoint.pendingBatchId) {
      throw StateError('cloud_sync_exact_read_checkpoint_changed');
    }
  }

  try {
    await lifecycle.ensureRecoveredBeforeFetch();
    await validate();
    coordinator = await durable.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'exact-reader-${auth.nativeSessionId}',
      now: DateTime.now().toUtc(),
      leaseDuration: const Duration(minutes: 3),
    );
    if (coordinator == null) throw StateError('cloud_sync_exact_read_busy');
    final outcome = await transport.runProtectedStoreExclusive(
      () => transport.runLocalProtectedStoreExclusive(() async {
        await validate();
        final result = await api.cloudSyncFetchKnownMessageExact(
          cloudMessagesClient: client,
          nativeWriterPauseToken: pauseToken,
          storageDirectory: privateStorageDirectory,
          expectedAuth: api.CloudSyncNativeAuthMetadata(
            nativeSessionId: auth.nativeSessionId,
            accountFingerprint: auth.accountFingerprint,
            protectedStoreIdentity: auth.protectedStoreIdentity,
          ),
          messageGeneration: BigInt.from(checkpoint.generation),
          messageGuid: messageGuid,
        );
        final found = result.found;
        // A produced lease must reach adoption or rollback even if the account
        // changed while the native call returned. Validation happens in adoption.
        if (found != null) {
          if (result.absent || result.failure != null) {
            await lifecycle.rollbackUnjournaledPage(
              CloudFetchBatch(
                scope: scope,
                changes: const [],
                batchId: found.batchId,
                generation: checkpoint.generation,
                nextToken: null,
                hasMore: false,
                protectedPageLeaseReference: found.leaseReference,
              ),
            );
            throw StateError('cloud_sync_exact_read_record_mismatch');
          }
          await adoptCloudSyncExactMessageFound(
            result: found,
            scope: scope,
            generation: checkpoint.generation,
            coordinator: coordinator!,
            durable: durable,
            lifecycle: lifecycle,
            validate: validate,
            stillCurrent: stillCurrent,
          );
          await validate();
          retainedFound = found;
          return CloudSyncExactMessageReadDisposition.retained;
        }
        await validate();
        if (result.absent && result.failure == null) {
          return CloudSyncExactMessageReadDisposition.absent;
        }
        final failure = result.failure;
        if (failure != null) {
          // Only the existing closed enums are observable. Never log the
          // native exception, selector, protected reference, or record.
          Logger.warn('Cloud Sync V2 exact read unresolved '
              '${failure.category.name}/${failure.safeCode.name}');
        }
        return CloudSyncExactMessageReadDisposition.unresolved;
      }),
    );
    if (outcome != CloudSyncExactMessageReadDisposition.retained) {
      return outcome;
    }
    // Decode only after the protected-file staging locks are released. The
    // semantic interlock, native pause and exact coordinator still span apply.
    await validate();
    final entry = durable.readExactReadEntry(
      scope: scope,
      generation: checkpoint.generation,
      changeId: retainedFound!.change.changeId,
      leaseFence: coordinator,
    );
    if (entry?.status == CloudInboxStatus.applied) {
      return CloudSyncExactMessageReadDisposition.projected;
    }
    if (entry?.status == CloudInboxStatus.pending &&
        (entry!.nextEligibleAt == null ||
            !entry.nextEligibleAt!.isAfter(DateTime.now().toUtc()))) {
      final result = await apply(entry, coordinator);
      await validate();
      if (result.disposition == CloudInboxApplyDisposition.applied) {
        if (!result.inboxStatusPersisted) {
          await durable.markInboxApplied(
            scope,
            sequence: entry.sequence,
            now: DateTime.now().toUtc(),
            leaseFence: coordinator,
          );
        }
        return CloudSyncExactMessageReadDisposition.projected;
      }
    }
    // Dependencies, conflicts and unsupported data stay protected for the
    // normal reader. No forced success or terminal-state rewriting.
    return CloudSyncExactMessageReadDisposition.retained;
  } finally {
    try {
      await transport.quiesceNativeOperations();
    } finally {
      if (coordinator != null) {
        await durable.releaseCoordinatorLease(scope, leaseFence: coordinator);
      }
    }
  }
}
