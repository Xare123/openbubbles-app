import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_import_source.dart';
import 'cloud_sync_historical_snapshot.dart';
import 'cloud_sync_historical_snapshot_codec.dart';

/// One explicitly selected historical received row for Windows compatibility
/// qualification. This is not a general permission to create received records.
/// Profile never constructs this object. Ordinary account, parent, fresh-absence,
/// outbox and protected-readback checks remain in the shared archive path.
final class CloudSyncHistoricalReceivedEndpointTrial {
  CloudSyncHistoricalReceivedEndpointTrial._(
    this.source,
    this._row,
    this._request,
  );

  final CloudSyncHistoricalImportSource source;
  final CloudSyncHistoricalRowView _row;
  final CloudSyncHistoricalArchiveRequest _request;

  /// Select from an already qualified immutable source. A one-row snapshot
  /// prevents an operator budget from accidentally archiving a different row
  /// before reaching the intended candidate. Its own digest must be previewed
  /// and confirmed; confirmation of the full source does not authorize it.
  static Future<CloudSyncHistoricalReceivedEndpointTrial> select({
    required CloudSyncHistoricalImportSource source,
    required String guid,
  }) async {
    final row = await source.snapshot.readExact(guid);
    if (row == null) throw StateError('cloud_sync_historical_trial_invalid');
    final selected = CloudSyncHistoricalSnapshot.fromEncodedRows(
      encodedRows: [encodeHistoricalSnapshotRow(row)],
      account: source.snapshot.account,
      accountHandles: source.snapshot.manifest.accountHandles,
      capturedAtMs: source.snapshot.manifest.capturedAtMs,
    );
    final selectedRow = (await selected.readExact(guid))!;
    final assessment = assessHistoricalArchiveRow(
      selectedRow,
      selected.manifest,
      selected.account,
    );
    if (assessment is! CloudSyncHistoricalArchiveEligible ||
        assessment.request.origin !=
            CloudSyncHistoricalArchiveOrigin.historicalReceived ||
        assessment.request.isFromMe ||
        assessment.request.groupMetadata != null) {
      throw StateError('cloud_sync_historical_trial_invalid');
    }
    return CloudSyncHistoricalReceivedEndpointTrial._(
      CloudSyncHistoricalImportSource(snapshot: selected, label: source.label),
      selectedRow,
      assessment.request,
    );
  }

  void requireSource(CloudSyncHistoricalImportSource? candidate) {
    if (candidate == null ||
        candidate.snapshot.manifest.messageCount != 1 ||
        candidate.identitySha256 != source.identitySha256 ||
        candidate.snapshot.account.accountFingerprint !=
            _request.accountFingerprint ||
        candidate.snapshot.account.protectedStoreIdentity !=
            _request.protectedStoreIdentity) {
      throw StateError('cloud_sync_historical_trial_invalid');
    }
  }

  bool permits(CloudSyncHistoricalArchiveRequest candidate) =>
      candidate.origin == CloudSyncHistoricalArchiveOrigin.historicalReceived &&
      !candidate.isFromMe &&
      candidate.guid == _request.guid &&
      candidate.snapshotSha256 == _request.snapshotSha256 &&
      candidate.accountFingerprint == _request.accountFingerprint &&
      candidate.protectedStoreIdentity == _request.protectedStoreIdentity &&
      candidate.sourceSha256 == _request.sourceSha256 &&
      historicalArchiveRowMatchesRequest(_row, candidate);

  @override
  String toString() => 'CloudSyncHistoricalReceivedEndpointTrial(redacted)';
}
