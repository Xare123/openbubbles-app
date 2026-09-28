import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_snapshot.dart';

/// A separately acquired, immutable source for an explicit historical import.
/// The caller qualifies its provenance before constructing this selection.
/// Content hashes select storage; they do not prove account ownership or consent.
final class CloudSyncHistoricalImportSource {
  CloudSyncHistoricalImportSource({
    required this.snapshot,
    required this.label,
  }) {
    if (label.trim().isEmpty ||
        label.length > 120 ||
        label.contains(RegExp(r'[\r\n\x00]'))) {
      throw StateError('cloud_sync_historical_import_source_invalid');
    }
  }

  final CloudSyncHistoricalSnapshot snapshot;
  final String label;
  String get identitySha256 => snapshot.manifest.snapshotSha256;

  void requireDestination(CloudSyncHistoricalAccountBinding account) {
    if (!account.hasValidShape ||
        snapshot.account.accountFingerprint != account.accountFingerprint ||
        snapshot.account.protectedStoreIdentity !=
            account.protectedStoreIdentity) {
      throw StateError('cloud_sync_historical_import_identity_changed');
    }
  }

  void requireSameSnapshot(CloudSyncHistoricalSnapshot retained) {
    requireDestination(retained.account);
    if (retained.manifest.snapshotSha256 != identitySha256) {
      throw StateError('cloud_sync_historical_import_source_changed');
    }
  }

  @override
  String toString() => 'CloudSyncHistoricalImportSource(redacted)';
}
