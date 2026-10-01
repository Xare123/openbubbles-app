import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Local consent only. The ownership lineage survives routine reconciliations;
/// native identity, per-mutation writer permits and exact receipt checks remain
/// authoritative for every individual operation.
final class CloudSyncAutomaticArchiveIdentity {
  CloudSyncAutomaticArchiveIdentity({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.ownershipEpoch,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(accountFingerprint) ||
        !RegExp(
          r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(protectedStoreIdentity) ||
        ownershipEpoch < 0) {
      throw ArgumentError('cloud_sync_automatic_archive_identity_invalid');
    }
  }

  final String accountFingerprint;
  final String protectedStoreIdentity;
  // Zero means no proven V2 consent lineage. Reading settings creates none.
  final int ownershipEpoch;

  String get preferenceKey =>
      'cloudSyncV2AutomaticArchive.v1.${sha256.convert(utf8.encode(jsonEncode([accountFingerprint, protectedStoreIdentity])))}';

  bool sameAccountStore(CloudSyncAutomaticArchiveIdentity other) =>
      accountFingerprint == other.accountFingerprint &&
      protectedStoreIdentity == other.protectedStoreIdentity;

  bool sameIdentity(CloudSyncAutomaticArchiveIdentity other) =>
      sameAccountStore(other) && ownershipEpoch == other.ownershipEpoch;

  /// Match captured native account/store plus durable ownership lineage, never
  /// only a Dart client pointer or the transient mutation permit epoch.
  bool matchesBinding({
    required String accountFingerprint,
    required String protectedStoreIdentity,
    required int ownershipEpoch,
  }) =>
      this.ownershipEpoch > 0 &&
      this.accountFingerprint == accountFingerprint &&
      this.protectedStoreIdentity == protectedStoreIdentity &&
      this.ownershipEpoch == ownershipEpoch;
}

final class CloudSyncAutomaticArchivePreference {
  const CloudSyncAutomaticArchivePreference({
    required this.identity,
    required this.storedValue,
  });

  final CloudSyncAutomaticArchiveIdentity identity;
  final Object? storedValue;

  /// No migration from Developer Mode, a build flag, or another preference.
  /// The scope deliberately includes queued and future local-send work. A
  /// future-only switch would require per-source admission AND dispatch proof.
  bool get enabled {
    if (identity.ownershipEpoch <= 0 || storedValue is! String) return false;
    try {
      final value = jsonDecode(storedValue! as String);
      return value is List &&
          value.length == 4 &&
          value[0] == 1 &&
          value[0] is int &&
          value[1] == 'queued-and-future-local-sends' &&
          value[2] is int &&
          value[2] == identity.ownershipEpoch &&
          value[3] is String &&
          RegExp(r'^[a-f0-9]{32}$').hasMatch(value[3]);
    } catch (_) {
      return false;
    }
  }
}

/// Account-bound opt-in for the existing automatic worker, never a new queue.
/// Every enable requires explicit acknowledgment of pending uploads, including
/// those rediscovered by recovery. No wall-clock cutoffs infer authorization.
final class CloudSyncAutomaticArchivePreferences {
  CloudSyncAutomaticArchivePreferences({
    required this.captureIdentity,
    required this.currentOwnershipEpoch,
    required this.stillCurrent,
    required this.reload,
    required this.read,
    required this.write,
    required this.prepareWriter,
    String Function()? newGrant,
  }) : newGrant = newGrant ?? _randomGrant;

  final Future<CloudSyncAutomaticArchiveIdentity?> Function() captureIdentity;
  final int Function() currentOwnershipEpoch;
  final bool Function() stillCurrent;
  final Future<void> Function() reload;
  final Object? Function(String) read;
  final Future<bool> Function(String, String) write;
  final Future<void> Function() prepareWriter;
  final String Function() newGrant;

  static String _randomGrant() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _validateCurrent() {
    if (!stillCurrent()) {
      throw StateError('cloud_sync_automatic_archive_identity_changed');
    }
  }

  Future<CloudSyncAutomaticArchivePreference> load() async {
    _validateCurrent();
    final before = await captureIdentity();
    _validateCurrent();
    if (before == null) {
      throw StateError('cloud_sync_automatic_archive_unavailable');
    }
    await reload();
    _validateCurrent();
    final after = await captureIdentity();
    _validateCurrent();
    if (after == null || !before.sameIdentity(after)) {
      throw StateError('cloud_sync_automatic_archive_identity_changed');
    }
    return CloudSyncAutomaticArchivePreference(
      identity: before,
      storedValue: read(before.preferenceKey),
    );
  }

  bool isGranted(CloudSyncAutomaticArchivePreference expected) {
    try {
      return stillCurrent() &&
          expected.enabled &&
          currentOwnershipEpoch() == expected.identity.ownershipEpoch &&
          read(expected.identity.preferenceKey) == expected.storedValue;
    } catch (_) {
      return false;
    }
  }

  Future<CloudSyncAutomaticArchivePreference> setEnabled(
    CloudSyncAutomaticArchivePreference expected,
    bool enabled, {
    required bool acknowledgeQueuedUploads,
  }) async {
    // Reject before any setup or storage write. The UI must ask on every enable.
    if (enabled && !acknowledgeQueuedUploads) {
      throw StateError('cloud_sync_automatic_archive_confirmation_required');
    }
    var current = await load();
    if (!expected.identity.sameIdentity(current.identity) ||
        expected.storedValue != current.storedValue) {
      throw StateError('cloud_sync_automatic_archive_identity_changed');
    }
    if (enabled) {
      await prepareWriter();
      _validateCurrent();
      current = await load();
      // Only initialOwnerOnly provisioning may turn an absent owner into V2.
      // A replaced pre-existing epoch never inherits the confirmation.
      if (!expected.identity.sameAccountStore(current.identity) ||
          current.identity.ownershipEpoch <= 0 ||
          (expected.identity.ownershipEpoch > 0 &&
              current.identity.ownershipEpoch != expected.identity.ownershipEpoch) ||
          expected.storedValue != current.storedValue) {
        throw StateError('cloud_sync_automatic_archive_identity_changed');
      }
    }
    final grant = enabled ? newGrant() : null;
    if (enabled && !RegExp(r'^[a-f0-9]{32}$').hasMatch(grant!)) {
      throw StateError('cloud_sync_automatic_archive_grant_invalid');
    }
    final value = enabled
        ? jsonEncode([
            1,
            'queued-and-future-local-sends',
            current.identity.ownershipEpoch,
            grant,
          ])
        : jsonEncode([1, 'off']);
    final persisted = await write(current.identity.preferenceKey, value);
    _validateCurrent();
    if (!persisted) {
      throw StateError('cloud_sync_automatic_archive_save_failed');
    }
    final saved = await load();
    if (!current.identity.sameIdentity(saved.identity)) {
      throw StateError('cloud_sync_automatic_archive_identity_changed');
    }
    if (saved.storedValue != value || saved.enabled != enabled) {
      throw StateError('cloud_sync_automatic_archive_save_failed');
    }
    return saved;
  }
}
