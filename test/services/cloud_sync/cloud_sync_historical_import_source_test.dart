import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_import_source.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_historical_import_controller_test.dart' as fixtures;

void main() {
  test('external selection pins frozen content without exposing its label', () {
    final snapshot = fixtures.historicalImportTestSnapshot(1);
    final source = CloudSyncHistoricalImportSource(
      snapshot: snapshot,
      label: 'Alpha history',
    );
    expect(source.identitySha256, snapshot.manifest.snapshotSha256);
    expect(source.label, 'Alpha history');
    expect(source.snapshot, same(snapshot));
    expect(source.toString(), 'CloudSyncHistoricalImportSource(redacted)');
    source.requireDestination(snapshot.account);
  });

  test(
    'source cannot be silently rebound to another account or installation',
    () {
      final snapshot = fixtures.historicalImportTestSnapshot(1);
      final source = CloudSyncHistoricalImportSource(
        snapshot: snapshot,
        label: 'Alpha history',
      );
      for (final account in [
        CloudSyncHistoricalAccountBinding(
          accountFingerprint: 'B' * 43,
          protectedStoreIdentity: snapshot.account.protectedStoreIdentity,
        ),
        CloudSyncHistoricalAccountBinding(
          accountFingerprint: snapshot.account.accountFingerprint,
          protectedStoreIdentity: 'obcs2.store.${'T' * 43}',
        ),
        const CloudSyncHistoricalAccountBinding(
          accountFingerprint: '',
          protectedStoreIdentity: '',
        ),
      ]) {
        expect(() => source.requireDestination(account), throwsStateError);
      }
      expect(source.snapshot.account, same(snapshot.account));
    },
  );

  test(
    'reopening the exact snapshot is accepted but different rows are not',
    () {
      final snapshot = fixtures.historicalImportTestSnapshot(1);
      final source = CloudSyncHistoricalImportSource(
        snapshot: snapshot,
        label: 'Alpha history',
      );
      final copy = CloudSyncHistoricalSnapshot.fromEncodedRows(
        encodedRows: snapshot.encodedRows,
        account: snapshot.account,
        accountHandles: snapshot.manifest.accountHandles,
        capturedAtMs: snapshot.manifest.capturedAtMs,
      );
      source.requireSameSnapshot(copy);
      expect(
        () => source.requireSameSnapshot(
          fixtures.historicalImportTestSnapshot(2),
        ),
        throwsStateError,
      );
    },
  );

  test('empty, multiline and unbounded source labels are rejected', () {
    final snapshot = fixtures.historicalImportTestSnapshot(1);
    for (final label in ['', '  ', 'a\nb', 'a\rb', 'a\x00b', 'a' * 121]) {
      expect(
        () => CloudSyncHistoricalImportSource(snapshot: snapshot, label: label),
        throwsStateError,
      );
    }
  });
}
