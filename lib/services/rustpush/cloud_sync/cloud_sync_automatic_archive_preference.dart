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
  /// Each scope deliberately includes queued and future work. A future-only
  /// switch would require per-source admission AND dispatch proof.
  bool get enabled => _enabledVersion != null;

  /// Received text, including supported mirrored plain text. V1 remains
  /// sent-only; a V2 text grant never inherits received-media consent.
  bool get includesReceived => _enabledVersion == 2 || _enabledVersion == 3;

  /// Only an explicit V3 grant covers queued and future received media.
  bool get includesReceivedMedia => _enabledVersion == 3;

  /// Local received-text retention, independent of a foreground upload worker.
  /// Media requires [permitsReceivedMediaCapture] instead.
  /// The caller supplies actual native identity, durable ownership and the
  /// reloaded preference. This does not authorize any CloudKit operation.
  bool permitsReceivedCapture({
    required String accountFingerprint,
    required String protectedStoreIdentity,
    required int ownershipEpoch,
    required Object? currentStoredValue,
  }) =>
      includesReceived &&
      storedValue == currentStoredValue &&
      identity.matchesBinding(
        accountFingerprint: accountFingerprint,
        protectedStoreIdentity: protectedStoreIdentity,
        ownershipEpoch: ownershipEpoch,
      );

  /// Apply the same exact binding and reloaded-grant fence to media retention.
  /// Neither capture helper is a gate on reading or reconciling an upload that
  /// was already submitted. Revocation must preserve that exact readback path.
  bool permitsReceivedMediaCapture({
    required String accountFingerprint,
    required String protectedStoreIdentity,
    required int ownershipEpoch,
    required Object? currentStoredValue,
  }) =>
      includesReceivedMedia &&
      permitsReceivedCapture(
        accountFingerprint: accountFingerprint,
        protectedStoreIdentity: protectedStoreIdentity,
        ownershipEpoch: ownershipEpoch,
        currentStoredValue: currentStoredValue,
      );

  int? get _enabledVersion {
    if (identity.ownershipEpoch <= 0 || storedValue is! String) return null;
    try {
      final value = jsonDecode(storedValue! as String);
      return value is List &&
              value.length == 4 &&
              value[0] is int &&
              ((value[0] == 1 && value[1] == 'queued-and-future-local-sends') ||
                  (value[0] == 2 &&
                      value[1] ==
                          'queued-and-future-local-sends-and-receives') ||
                  (value[0] == 3 &&
                      value[1] ==
                          'queued-and-future-local-sends-and-received-text-and-media')) &&
              value[2] is int &&
              value[2] == identity.ownershipEpoch &&
              value[3] is String &&
              RegExp(r'^[a-f0-9]{32}$').hasMatch(value[3])
          ? value[0] as int
          : null;
    } catch (_) {
      return null;
    }
  }
}

/// A retained engineering host must acknowledge the actual saved grant again
/// each boot. Persisted consent alone cannot start that host's upload worker.
/// Native identity, ownership, preference revalidation and permits still apply.
final class CloudSyncArchiveSessionAcknowledgment {
  CloudSyncAutomaticArchivePreference? _saved;
  bool Function()? _stillGranted;
  bool get ready => _saved != null && _stillGranted?.call() == true;

  void saved(CloudSyncAutomaticArchivePreference value, {
    required bool Function() stillGranted,
  }) {
    _saved = value.enabled ? value : null;
    _stillGranted = value.enabled ? stillGranted : null;
  }

  bool allows(CloudSyncAutomaticArchivePreference value) {
    final saved = _saved;
    return ready && saved != null && value.enabled &&
        saved.identity.sameIdentity(value.identity) &&
        saved.storedValue == value.storedValue;
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

  bool isReceivedGranted(CloudSyncAutomaticArchivePreference expected) =>
      isGranted(expected) && expected.includesReceived;

  /// Fresh media admission/dispatch only. Exact readback of already-submitted
  /// work must remain available after this grant is revoked or narrowed.
  bool isReceivedMediaGranted(CloudSyncAutomaticArchivePreference expected) =>
      isGranted(expected) && expected.includesReceivedMedia;

  Future<CloudSyncAutomaticArchivePreference> setEnabled(
    CloudSyncAutomaticArchivePreference expected,
    bool enabled, {
    required bool acknowledgeQueuedUploads,
    bool includeReceived = false,
    bool includeReceivedMedia = false,
  }) async {
    // Reject before any setup or storage write. The UI must ask on every enable.
    if (enabled && !acknowledgeQueuedUploads) {
      throw StateError('cloud_sync_automatic_archive_confirmation_required');
    }
    if (enabled && includeReceivedMedia && !includeReceived) {
      throw StateError(
        'cloud_sync_automatic_archive_received_media_requires_text',
      );
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
              current.identity.ownershipEpoch !=
                  expected.identity.ownershipEpoch) ||
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
            includeReceivedMedia ? 3 : (includeReceived ? 2 : 1),
            includeReceivedMedia
                ? 'queued-and-future-local-sends-and-received-text-and-media'
                : (includeReceived
                      ? 'queued-and-future-local-sends-and-receives'
                      : 'queued-and-future-local-sends'),
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
    if (saved.storedValue != value ||
        saved.enabled != enabled ||
        saved.includesReceived != (enabled && includeReceived) ||
        saved.includesReceivedMedia != (enabled && includeReceivedMedia)) {
      throw StateError('cloud_sync_automatic_archive_save_failed');
    }
    return saved;
  }
}
