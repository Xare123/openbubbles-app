import 'dart:convert';

import 'cloud_sync_models.dart';

/// Content-free reason a read-only shadow journal refused more records.
///
/// These values are safe to expose in diagnostics. They reveal neither Apple
/// record identifiers nor message content.
enum CloudShadowJournalBlockReason {
  maximumAge,
  maximumEntries,
  maximumEstimatedBytes,
}

/// Deterministic, per-scope usage of pending read-only shadow records.
class CloudShadowJournalUsage {
  CloudShadowJournalUsage({
    required this.pendingEntries,
    required this.estimatedBytes,
    this.oldestPendingAt,
  }) {
    if (pendingEntries < 0) {
      throw ArgumentError('cloud_shadow_usage_entries_invalid');
    }
    if (estimatedBytes < 0) {
      throw ArgumentError('cloud_shadow_usage_bytes_invalid');
    }
    if (pendingEntries == 0 && oldestPendingAt != null) {
      throw ArgumentError('cloud_shadow_usage_oldest_invalid');
    }
  }

  static final empty = CloudShadowJournalUsage(
    pendingEntries: 0,
    estimatedBytes: 0,
  );

  final int pendingEntries;
  final int estimatedBytes;
  final DateTime? oldestPendingAt;

  CloudShadowJournalUsage add({
    required int entries,
    required int bytes,
    DateTime? oldestAt,
  }) {
    if (entries < 0) {
      throw ArgumentError('cloud_shadow_usage_added_entries_invalid');
    }
    if (bytes < 0) {
      throw ArgumentError('cloud_shadow_usage_added_bytes_invalid');
    }
    final currentOldest = oldestPendingAt;
    final nextOldest = currentOldest == null
        ? oldestAt
        : oldestAt == null || !oldestAt.isBefore(currentOldest)
        ? currentOldest
        : oldestAt;
    return CloudShadowJournalUsage(
      pendingEntries: pendingEntries + entries,
      estimatedBytes: estimatedBytes + bytes,
      oldestPendingAt: nextOldest,
    );
  }
}

/// Atomic result of trying to journal one read-only shadow page.
class CloudShadowJournalAdmission {
  CloudShadowJournalAdmission({
    required this.insertedEntries,
    required this.rejectedEntries,
    required this.usage,
    this.blockReason,
  }) {
    if (insertedEntries < 0) {
      throw ArgumentError('cloud_shadow_admission_inserted_invalid');
    }
    if (rejectedEntries < 0) {
      throw ArgumentError('cloud_shadow_admission_rejected_invalid');
    }
    if (blockReason != null && insertedEntries != 0) {
      throw ArgumentError('cloud_shadow_admission_blocked_insert_invalid');
    }
  }

  final int insertedEntries;
  final int rejectedEntries;
  final CloudShadowJournalUsage usage;
  final CloudShadowJournalBlockReason? blockReason;

  bool get admitted => blockReason == null;
}

/// Hard admission limits for Phase 1 read-only shadow sampling.
///
/// The policy never deletes inbox rows. Once a scope reaches a limit, the
/// engine stops fetching before the next request where possible, and rejects
/// an oversized fetched page atomically without advancing its checkpoint.
/// Existing pending records therefore remain available for a future semantic
/// migration or an explicit, separately reviewed shadow-sample reset.
class CloudShadowJournalBudget {
  static const int maximumAllowedEntriesPerScope = 16 * 1024;
  static const int maximumAllowedEstimatedBytesPerScope = 128 * 1024 * 1024;
  static const Duration maximumAllowedPendingAge = Duration(days: 30);

  CloudShadowJournalBudget({
    this.maximumEntriesPerScope = 4096,
    this.maximumEstimatedBytesPerScope = 32 * 1024 * 1024,
    this.maximumPendingAge = const Duration(days: 7),
  }) {
    validate();
  }

  /// Two full default pull runs. This is a client safety limit, not an Apple
  /// service quota.
  final int maximumEntriesPerScope;

  /// Conservative journal-row estimate, not payload or ObjectBox file size.
  final int maximumEstimatedBytesPerScope;
  final Duration maximumPendingAge;

  /// Runtime validation keeps release builds fail-closed even though the
  /// constructor remains const for feature-flag configuration.
  void validate() {
    if (maximumEntriesPerScope <= 0 ||
        maximumEntriesPerScope > maximumAllowedEntriesPerScope) {
      throw ArgumentError('cloud_shadow_budget_entries_invalid');
    }
    if (maximumEstimatedBytesPerScope <= 0 ||
        maximumEstimatedBytesPerScope > maximumAllowedEstimatedBytesPerScope) {
      throw ArgumentError('cloud_shadow_budget_bytes_invalid');
    }
    if (maximumPendingAge.inMicroseconds <= 0 ||
        maximumPendingAge > maximumAllowedPendingAge) {
      throw ArgumentError('cloud_shadow_budget_age_invalid');
    }
  }

  /// Returns a deterministic reason in age, entry, then byte precedence.
  CloudShadowJournalBlockReason? blockReasonForCurrentUsage(
    CloudShadowJournalUsage usage, {
    required DateTime now,
  }) {
    final oldest = usage.oldestPendingAt;
    if (oldest != null &&
        now.isAfter(oldest) &&
        now.difference(oldest) > maximumPendingAge) {
      return CloudShadowJournalBlockReason.maximumAge;
    }
    if (usage.pendingEntries >= maximumEntriesPerScope) {
      return CloudShadowJournalBlockReason.maximumEntries;
    }
    if (usage.estimatedBytes >= maximumEstimatedBytesPerScope) {
      return CloudShadowJournalBlockReason.maximumEstimatedBytes;
    }
    return null;
  }

  /// Checks a projected atomic page. Exact entry and byte limits are allowed;
  /// only a value over either limit is rejected.
  CloudShadowJournalBlockReason? blockReasonForProjectedUsage(
    CloudShadowJournalUsage projected, {
    required DateTime now,
  }) {
    final oldest = projected.oldestPendingAt;
    if (oldest != null &&
        now.isAfter(oldest) &&
        now.difference(oldest) > maximumPendingAge) {
      return CloudShadowJournalBlockReason.maximumAge;
    }
    if (projected.pendingEntries > maximumEntriesPerScope) {
      return CloudShadowJournalBlockReason.maximumEntries;
    }
    if (projected.estimatedBytes > maximumEstimatedBytesPerScope) {
      return CloudShadowJournalBlockReason.maximumEstimatedBytes;
    }
    return null;
  }

  /// Stable upper-bound estimate of one inbox row's journal footprint.
  ///
  /// The original change ID is intentionally excluded because production
  /// stores persist a fixed-width scoped SHA-256 digest instead. No plaintext
  /// or identifier is emitted by this calculation.
  int estimateEntryBytes({
    required CloudSyncScope scope,
    required String batchId,
    required CloudFetchedChange change,
  }) {
    const fixedRowAndIndexOverhead = 256;
    const scopedDigestBytes = 64;
    return fixedRowAndIndexOverhead +
        scopedDigestBytes +
        _utf8Length(scope.accountFingerprint) +
        _utf8Length(scope.zone) +
        _utf8Length(batchId) +
        _utf8Length(change.recordIdHash) +
        _utf8Length(change.etagHash) +
        _utf8Length(change.type.name) +
        _utf8Length(change.encryptedServerRecordId) +
        _utf8Length(change.protectedSystemFieldsReference) +
        _utf8Length(change.encryptedPayloadReference) +
        _utf8Length(change.payloadSha256);
  }

  int _utf8Length(String? value) =>
      value == null ? 0 : utf8.encode(value).length;
}
