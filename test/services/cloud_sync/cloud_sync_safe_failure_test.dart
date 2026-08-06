import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_report_file.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exposes only reviewed state failure codes', () {
    expect(
      cloudSyncV2SafeFailureCode(StateError('legacy_sync_active')),
      'legacy_sync_active',
    );
    expect(
      cloudSyncV2SafeFailureCode(
        StateError('account-secret@example.com should never be shown'),
      ),
      'cloud_sync_unknown_failure',
    );
  });

  test('exposes reviewed report and interlock codes', () {
    expect(
      cloudSyncV2SafeFailureCode(
        const CloudSyncShadowReportFileException(
          'cloud_sync_report_retention_failed',
        ),
      ),
      'cloud_sync_report_retention_failed',
    );
    expect(
      cloudSyncV2SafeFailureCode(
        const CloudKitOperationInterlockException('cloudkit_interlock_busy'),
      ),
      'cloudkit_interlock_busy',
    );
  });

  test('collapses arbitrary exception text', () {
    expect(
      cloudSyncV2SafeFailureCode(
        Exception('token=private-value account=user@example.com'),
      ),
      'cloud_sync_unknown_failure',
    );
  });
}
