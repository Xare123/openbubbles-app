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
