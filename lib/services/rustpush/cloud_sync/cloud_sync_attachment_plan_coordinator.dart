/// Bounded production coordinator for attachment PLAN rows only.
///
/// Connects native original-source inventory to staged plans:
/// inventory -> find existing plan by full inventory -> stage only missing
/// randomized plans -> journal.adoptPlan -> commit plan lease.
/// It never uploads bytes and never touches the parent message dispatch.
///
/// Caller holds the CloudKit interlock and the protected-store exclusion
/// across [ensurePlans]. Exactly one [ensurePlans] per intent may run at a
/// time. Diagnostics carry safe codes only, never message content, keys,
/// guids, references, or digests.
// ignore_for_file: prefer_initializing_formals
library;

import 'package:bluebubbles/database/models.dart';
import 'cloud_sync_attachment_upload_journal.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_historical_attachment_source.dart';
import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_outbound_staging.dart';

/// One native original-source inventory entry. Identifiers are native
/// authoritative values: the reflected guid is `<messageGuid>_<part>` and the
/// original guid may be non-UUID, so both are validated as bounded nonempty
/// control-free identifiers rather than UUIDs.
final class CloudSyncAttachmentPlanInventoryItem {
  const CloudSyncAttachmentPlanInventoryItem({
    required this.originalAttachmentGuid,
    required this.reflectedAttachmentGuid,
    required this.logicalEntityKeyHash,
  });
  final String originalAttachmentGuid;
  final String reflectedAttachmentGuid;
  final String logicalEntityKeyHash;
  @override
  String toString() => 'CloudSyncAttachmentPlanInventoryItem(redacted)';
}

/// Resolve only the validated message's durable attachment relation. The UI's
/// transient attachment list is empty after ObjectBox reload and is not source
/// authority. Original and reflected GUIDs are aliases, not separate sources.
Attachment cloudSyncAttachmentPlanLocalSource(
  Message message,
  CloudSyncAttachmentPlanInventoryItem item,
) {
  final matches = message.dbAttachments.where((attachment) =>
      attachment.guid == item.originalAttachmentGuid ||
      attachment.guid == item.reflectedAttachmentGuid).toList(growable: false);
  if (matches.length != 1) {
    throw StateError('cloud_sync_attachment_plan_source_unavailable');
  }
  return matches.single;
}

/// Callbacks receive the pinned source and live auth so inventory and staging
/// bind to the validated origin instead of an accidental wrong closure.
typedef CloudSyncAttachmentPlanInventoryReader =
    Future<List<CloudSyncAttachmentPlanInventoryItem>> Function(
      CloudSyncLocalSendSourceBinding pinnedSource,
      CloudSyncNativeAuthSnapshot liveAuth,
    );

typedef CloudSyncAttachmentPlanStager =
    Future<CloudSyncProtectedOutboundStageData> Function(
      CloudSyncAttachmentPlanInventoryItem item,
      CloudSyncLocalSendSourceBinding pinnedSource,
      CloudSyncNativeAuthSnapshot liveAuth,
    );

final class CloudSyncAttachmentPlanCoordinator {
  CloudSyncAttachmentPlanCoordinator({
    required Store store,
    required CloudSyncLocalSendJournal localSends,
    required CloudSyncAttachmentUploadJournal uploads,
    required CloudSyncNativeAuthSnapshotReader readLiveAuth,
    required CloudSyncOutboundStagingTransport staging,
    required CloudSyncAttachmentPlanInventoryReader readInventory,
    required CloudSyncAttachmentPlanStager stagePlan,
    DateTime Function()? clock,
  }) : _store = store,
       _localSends = localSends,
       _uploads = uploads,
       _readLiveAuth = readLiveAuth,
       _staging = staging,
       _readInventory = readInventory,
       _stagePlan = stagePlan,
       _clock = clock ?? DateTime.now {
    if (!localSends.isBoundToStore(store) ||
        !uploads.isBoundTo(store, uploads.scope)) {
      throw StateError('cloud_sync_attachment_plan_store_invalid');
    }
  }

  final Store _store;
  final CloudSyncLocalSendJournal _localSends;
  final CloudSyncAttachmentUploadJournal _uploads;
  final CloudSyncNativeAuthSnapshotReader _readLiveAuth;
  final CloudSyncOutboundStagingTransport _staging;
  final CloudSyncAttachmentPlanInventoryReader _readInventory;
  final CloudSyncAttachmentPlanStager _stagePlan;
  final DateTime Function() _clock;
  final Set<int> _active = <int>{};

  static final RegExp _token = RegExp(r'^[A-Za-z0-9_-]{43}$');

  /// Check the complete historical inventory before creating any new plan or
  /// Chat. Existing attempts are recovered first, including uploaded results
  /// not yet adopted into the record queue. Missing files never waive that
  /// readback obligation. A false result retains the WHOLE message for retry;
  /// it does not remove inventory parts or authorize a partial parent.
  Future<bool> historicalSourcesAvailable({
    required int historicalIntentId,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
    required Future<List<CloudSyncAttachmentPlanInventoryItem>> Function(
      CloudSyncHistoricalProtectedSourceBinding, CloudSyncNativeAuthSnapshot) readInventory,
    required Future<String?> Function(CloudSyncAttachmentPlanInventoryItem) resolveSource,
    required Future<void> Function(CloudAttachmentUploadSnapshot, Set<String>) recoverExisting,
    required Future<bool> Function() drainExisting,
    Future<bool> Function(String)? probeSource,
  }) async {
    if (historicalIntentId <= 0 || !historicalJournal.isBoundToStore(_store)) {
      throw StateError('cloud_sync_attachment_plan_store_invalid');
    }
    if (!_active.add(historicalIntentId)) throw StateError('cloud_sync_attachment_plan_busy');
    try {
      final auth = await _liveAuth();
      final source = historicalJournal.requireHistoricalAttachmentOrigin(
        intentId: historicalIntentId, currentAuth: auth).source;
      Future<void> validate() async {
        final current = await _liveAuth();
        if (!auth.sameIdentity(current) ||
            historicalJournal.requireHistoricalAttachmentOrigin(
              intentId: historicalIntentId, currentAuth: current).source.encode() != source.encode()) {
          throw StateError('cloud_sync_attachment_plan_origin_changed');
        }
      }
      late final List<CloudSyncAttachmentPlanInventoryItem> inventory;
      late final Set<String> keys;
      CloudAttachmentUploadSnapshot? read(CloudSyncAttachmentPlanInventoryItem item) =>
        _uploads.findHistoricalForAttachment(historicalIntentId: historicalIntentId,
          logicalEntityKeyHash: item.logicalEntityKeyHash, sourceAttachmentKeys: keys,
          historicalJournal: historicalJournal);
      await _staging.runOutboundAdmissionExclusive(() async {
        inventory = List<CloudSyncAttachmentPlanInventoryItem>.unmodifiable(
          await readInventory(source, auth));
        _validateInventory(inventory);
        await validate();
        keys = Set<String>.unmodifiable(inventory.map((item) => item.logicalEntityKeyHash));
        for (final item in inventory) {
          final old = read(item);
          if (old == null) continue;
          if (old.state == CloudAttachmentUploadState.prepared) {
            // Adoption can survive a failed commit. Reestablish the exact native
            // lease before treating this retained plan as clean, unattempted work.
            await _staging.commitOutboundLease(old.plan.leaseReference,
              old.plan.protectedEnvelopeReference);
          } else {
            await recoverExisting(old, keys);
          }
          await validate();
        }
      });
      // Record-save timeout recovery quiesces native work. It must not wait on
      // the preparation exclusion held by this same operation.
      if (!await drainExisting()) {
        throw StateError('cloud_sync_attachment_parent_upload_unresolved');
      }
      await validate();
      final pinned = <String, CloudAttachmentUploadSnapshot?>{};
      final needsSource = <String>{};
      for (final item in inventory) {
        final old = read(item);
        pinned[item.logicalEntityKeyHash] = old;
        if (old == null || _uploads.historicalUploadNeedsLocalSource(old.id, historicalJournal)) {
          needsSource.add(item.logicalEntityKeyHash);
        }
      }
      var available = true;
      for (final item in inventory) {
        if (!needsSource.contains(item.logicalEntityKeyHash)) continue;
        final path = await resolveSource(item);
        await validate();
        // Do not short-circuit on the first missing part: a later ambiguous
        // source is a real error, not permission to skip the whole message.
        if (path == null || !await (probeSource ?? cloudSyncHistoricalAttachmentSourceAvailable)(path)) {
          available = false;
        }
        await validate();
      }
      for (final item in inventory) {
        final before = pinned[item.logicalEntityKeyHash];
        final after = read(item);
        if (before?.id != after?.id || before?.state != after?.state ||
            before?.attemptId != after?.attemptId ||
            before?.plan.leaseReference != after?.plan.leaseReference ||
            before?.plan.protectedEnvelopeReference != after?.plan.protectedEnvelopeReference) {
          throw StateError('cloud_sync_attachment_upload_inventory_changed');
        }
        if (after != null) _uploads.historicalUploadNeedsLocalSource(after.id, historicalJournal);
      }
      await validate();
      return available;
    } finally {
      _active.remove(historicalIntentId);
    }
  }

  /// Historical origins use the same adopt/commit/reuse mechanics, but never
  /// pass through IDS eligibility. Native inventory is reopened before plans.
  Future<List<CloudAttachmentUploadSnapshot>> ensureHistoricalPlans({
    required int historicalIntentId,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
    required Future<List<CloudSyncAttachmentPlanInventoryItem>> Function(
      CloudSyncHistoricalProtectedSourceBinding, CloudSyncNativeAuthSnapshot) readInventory,
    required Future<CloudSyncProtectedOutboundStageData> Function(
      CloudSyncAttachmentPlanInventoryItem, CloudSyncHistoricalProtectedSourceBinding,
      CloudSyncNativeAuthSnapshot) stagePlan,
  }) async {
    if (historicalIntentId <= 0 || !historicalJournal.isBoundToStore(_store)) {
      throw StateError('cloud_sync_attachment_plan_store_invalid');
    }
    if (!_active.add(historicalIntentId)) throw StateError('cloud_sync_attachment_plan_busy');
    try {
      final auth = await _liveAuth();
      final source = historicalJournal.requireHistoricalAttachmentOrigin(
        intentId: historicalIntentId, currentAuth: auth).source;
      Future<void> validate() async {
        final current = await _liveAuth();
        if (!auth.sameIdentity(current) ||
            historicalJournal.requireHistoricalAttachmentOrigin(
              intentId: historicalIntentId, currentAuth: current).source.encode() != source.encode()) {
          throw StateError('cloud_sync_attachment_plan_origin_changed');
        }
      }
      final inventory = List<CloudSyncAttachmentPlanInventoryItem>.unmodifiable(
        await readInventory(source, auth));
      _validateInventory(inventory);
      await validate();
      final keys = inventory.map((item) => item.logicalEntityKeyHash).toSet();
      final existing = <String, CloudAttachmentUploadSnapshot>{};
      for (final item in inventory) {
        final found = _uploads.findHistoricalForAttachment(
          historicalIntentId: historicalIntentId, logicalEntityKeyHash: item.logicalEntityKeyHash,
          sourceAttachmentKeys: keys, historicalJournal: historicalJournal);
        if (found != null) existing[item.logicalEntityKeyHash] = found;
      }
      for (final item in inventory) {
        final old = existing[item.logicalEntityKeyHash];
        if (old != null) {
          if (old.state == CloudAttachmentUploadState.prepared) {
            await _staging.commitOutboundLease(old.plan.leaseReference, old.plan.protectedEnvelopeReference);
            await validate();
          }
          continue;
        }
        await validate();
        final staged = await stagePlan(item, source, auth);
        try {
          if (staged.logicalEntityKeyHash != item.logicalEntityKeyHash) {
            throw StateError('cloud_sync_attachment_plan_stage_invalid');
          }
          await validate();
        } catch (_) {
          await _rollbackBestEffort(staged);
          rethrow;
        }
        // Ambiguous adoption or commit keeps the lease, exactly like IDS plans.
        final adopted = _uploads.adoptHistoricalPlan(
          historicalIntentId: historicalIntentId, plan: staged, now: _clock(),
          historicalJournal: historicalJournal);
        await _staging.commitOutboundLease(adopted.plan.leaseReference,
          adopted.plan.protectedEnvelopeReference);
        await validate();
        existing[item.logicalEntityKeyHash] = adopted;
      }
      return List.unmodifiable(inventory.map((item) => existing[item.logicalEntityKeyHash]!));
    } finally { _active.remove(historicalIntentId); }
  }

  /// Bounded nonempty control-free identifier. Native guids are authoritative
  /// and may be non-UUID (`<messageGuid>_<part>`), so only length and control
  /// characters are bounded here, mirroring the source limits.
  static bool _isIdentifier(String value) {
    if (value.isEmpty || value.length > 512) return false;
    for (final unit in value.codeUnits) {
      if (unit <= 0x20 ||
          (unit >= 0x7f && unit <= 0x9f) ||
          unit == 0x2028 ||
          unit == 0x2029) {
        return false;
      }
    }
    return true;
  }

  /// Ensures one journal plan per inventory entry, in inventory order.
  ///
  /// Reuses retained rows (prepared/started/uploaded/unknown/adopted) and
  /// commits an existing prepared plan lease when a prior commit failed.
  /// Stages only missing entries. A staged-but-unadopted lease is rolled
  /// back only when adoption provably never ran; an ambiguous adopt or
  /// commit failure retains the lease for retry and never deletes it here.
  Future<List<CloudAttachmentUploadSnapshot>> ensurePlans({
    required int localSendIntentId,
  }) => _ensurePlans(localSendIntentId: localSendIntentId, existingOnly: false);

  /// Resume the original inventory after authority recovery. This path cannot
  /// stage a missing randomized plan. Its source comes from an actual retained
  /// upload, while the caller separately requires current mutation authority.
  Future<List<CloudAttachmentUploadSnapshot>> resumeExistingPlans({
    required int localSendIntentId,
  }) => _ensurePlans(localSendIntentId: localSendIntentId, existingOnly: true);

  /// An earlier confirmed send can have no plan, or only some of its plans,
  /// when another upload advances authority. Reuse every existing plan and
  /// stage only genuinely missing inventory entries under a current permit.
  Future<List<CloudAttachmentUploadSnapshot>> ensureRetainedPlans({
    required int localSendIntentId,
  }) => _ensurePlans(localSendIntentId: localSendIntentId,
      existingOnly: false, retainedOrigin: true);

  Future<List<CloudAttachmentUploadSnapshot>> _ensurePlans({
    required int localSendIntentId,
    required bool existingOnly,
    bool retainedOrigin = false,
  }) async {
    if (localSendIntentId <= 0) {
      throw StateError('cloud_sync_attachment_plan_input_invalid');
    }
    if (!_active.add(localSendIntentId)) {
      throw StateError('cloud_sync_attachment_plan_busy');
    }
    try {
      int? retainedUploadId;
      if (existingOnly) {
        final query = _store.box<CloudAttachmentUploadEntity>().query(
          CloudAttachmentUploadEntity_.localSendIntentId.equals(localSendIntentId),
        ).build();
        try {
          retainedUploadId = query.findFirst()?.id;
        } finally {
          query.close();
        }
        if (retainedUploadId == null) {
          throw StateError('cloud_sync_attachment_plan_inventory_incomplete');
        }
      }
      var auth = await _liveAuth();
      final pinned = _requireOrigin(localSendIntentId, auth, retainedUploadId,
          retainedOrigin: retainedOrigin);
      final inventory = List<CloudSyncAttachmentPlanInventoryItem>.unmodifiable(
        await _readInventory(pinned.source, auth),
      );
      _validateInventory(inventory);
      auth = await _revalidate(localSendIntentId, auth, pinned, retainedUploadId,
          retainedOrigin: retainedOrigin);
      final keys = <String>{
        for (final item in inventory) item.logicalEntityKeyHash,
      };
      // Inspect every retained row against the complete inventory BEFORE
      // any new staging. A stale or mismatched row throws here, so no new
      // plan is staged for a changed inventory.
      final existing = <String, CloudAttachmentUploadSnapshot>{};
      for (final item in inventory) {
        final found = _uploads.findForAttachment(
          localSendIntentId: localSendIntentId,
          logicalEntityKeyHash: item.logicalEntityKeyHash,
          sourceAttachmentKeys: keys,
        );
        if (found != null) existing[item.logicalEntityKeyHash] = found;
      }
      if (existingOnly && existing.length != inventory.length) {
        throw StateError('cloud_sync_attachment_plan_inventory_incomplete');
      }
      // Retry commits for retained prepared plans before staging anything
      // new. All other states are preserved untouched.
      for (final item in inventory) {
        final snapshot = existing[item.logicalEntityKeyHash];
        if (snapshot != null &&
            snapshot.state == CloudAttachmentUploadState.prepared) {
          await _staging.commitOutboundLease(
            snapshot.plan.leaseReference,
            snapshot.plan.protectedEnvelopeReference,
          );
          auth = await _revalidate(localSendIntentId, auth, pinned, retainedUploadId,
              retainedOrigin: retainedOrigin);
        }
      }
      for (final item in inventory) {
        if (existing.containsKey(item.logicalEntityKeyHash)) continue;
        auth = await _revalidate(localSendIntentId, auth, pinned, retainedUploadId,
            retainedOrigin: retainedOrigin);
        final staged = await _stagePlan(item, pinned.source, auth);
        if (staged.logicalEntityKeyHash != item.logicalEntityKeyHash) {
          await _rollbackBestEffort(staged);
          throw StateError('cloud_sync_attachment_plan_stage_invalid');
        }
        try {
          auth = await _revalidate(localSendIntentId, auth, pinned, retainedUploadId,
              retainedOrigin: retainedOrigin);
        } on Object {
          await _rollbackBestEffort(staged);
          rethrow;
        }
        // adoptPlan may throw ambiguously; a possibly adopted lease is
        // never rolled back here.
        final adopted = _uploads.adoptPlan(
          localSendIntentId: localSendIntentId,
          plan: staged,
          now: _clock(),
          retainedSourceAttachmentKeys: retainedOrigin ? keys : null,
        );
        // The plan lease is now journal-owned: a commit failure retains
        // it for retry and never rolls back here.
        await _staging.commitOutboundLease(
          adopted.plan.leaseReference,
          adopted.plan.protectedEnvelopeReference,
        );
        auth = await _revalidate(localSendIntentId, auth, pinned, retainedUploadId,
            retainedOrigin: retainedOrigin);
        existing[item.logicalEntityKeyHash] = adopted;
      }
      return List<CloudAttachmentUploadSnapshot>.unmodifiable([
        for (final item in inventory) existing[item.logicalEntityKeyHash]!,
      ]);
    } finally {
      _active.remove(localSendIntentId);
    }
  }

  void _validateInventory(List<CloudSyncAttachmentPlanInventoryItem> items) {
    if (items.isEmpty || items.length > 64) {
      throw StateError('cloud_sync_attachment_plan_inventory_invalid');
    }
    final originals = <String>{};
    final reflected = <String>{};
    final hashes = <String>{};
    for (final item in items) {
      if (!_isIdentifier(item.originalAttachmentGuid) ||
          !_isIdentifier(item.reflectedAttachmentGuid) ||
          !_token.hasMatch(item.logicalEntityKeyHash) ||
          !originals.add(item.originalAttachmentGuid) ||
          !reflected.add(item.reflectedAttachmentGuid) ||
          !hashes.add(item.logicalEntityKeyHash)) {
        throw StateError('cloud_sync_attachment_plan_inventory_invalid');
      }
    }
  }

  ({int writerEpoch, String code, CloudSyncLocalSendSourceBinding source})
  _requireOrigin(int intentId, CloudSyncNativeAuthSnapshot auth,
      int? retainedUploadId, {bool retainedOrigin = false}) {
    if (retainedUploadId != null &&
        _uploads.read(retainedUploadId).localSendIntentId != intentId) {
      throw StateError('cloud_sync_attachment_plan_origin_changed');
    }
    if (retainedOrigin) {
      _localSends.requireCurrentAttachmentWriteAuthority(_store);
    }
    final origin = retainedOrigin
        ? _localSends.requireRetainedAttachmentUploadOrigin(
            transactionStore: _store, intentId: intentId, currentAuth: auth)
        : retainedUploadId == null
        ? _localSends.requireConfirmedAttachmentUploadOrigin(
            transactionStore: _store, intentId: intentId, currentAuth: auth)
        : _localSends.readConfirmedOriginForExistingUpload(
            transactionStore: _store, uploadId: retainedUploadId, currentAuth: auth);
    return (
      writerEpoch: origin.writerEpoch,
      code: origin.source.encode(),
      source: origin.source,
    );
  }

  Future<CloudSyncNativeAuthSnapshot> _revalidate(
    int intentId,
    CloudSyncNativeAuthSnapshot before,
    ({int writerEpoch, String code, CloudSyncLocalSendSourceBinding source})
    pinned, int? retainedUploadId, {bool retainedOrigin = false}
  ) async {
    final live = await _liveAuth();
    if (!before.sameIdentity(live)) {
      throw StateError('cloud_sync_attachment_plan_auth_changed');
    }
    final origin = _requireOrigin(intentId, live, retainedUploadId,
        retainedOrigin: retainedOrigin);
    if (origin.writerEpoch != pinned.writerEpoch ||
        origin.source.encode() != pinned.code) {
      throw StateError('cloud_sync_attachment_plan_origin_changed');
    }
    return live;
  }

  Future<CloudSyncNativeAuthSnapshot> _liveAuth() async {
    final auth = await _readLiveAuth();
    if (auth == null) {
      throw StateError('cloud_sync_attachment_plan_auth_changed');
    }
    return auth;
  }

  Future<void> _rollbackBestEffort(
    CloudSyncProtectedOutboundStageData? stage,
  ) async {
    final lease = stage?.leaseReference;
    if (lease == null) return;
    try {
      await _staging.rollbackOutboundLease(lease);
    } on Object {
      // Best effort only; the original failure stays authoritative.
    }
  }
}
