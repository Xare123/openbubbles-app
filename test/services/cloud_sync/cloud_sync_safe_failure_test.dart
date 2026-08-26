import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_report_file.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
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

  test('preserves a reviewed writer authority failure code', () {
    expect(
      cloudSyncV2SafeFailureCode(
        const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_identity_changed',
        ),
      ),
      'cloudkit_writer_identity_changed',
    );
  });

  test('preserves reviewed outbound canary and candidate state codes', () {
    expect(
      cloudSyncV2SafeFailureCode(
        StateError('cloud_sync_outbound_canary_recovery_invalid'),
      ),
      'cloud_sync_outbound_canary_recovery_invalid',
    );
    expect(
      cloudSyncV2SafeFailureCode(
        StateError('cloud_sync_outbound_canary_unavailable'),
      ),
      'cloud_sync_outbound_canary_unavailable',
    );
    expect(
      cloudSyncV2SafeFailureCode(
        StateError('cloud_sync_outbound_candidate_selection_failed'),
      ),
      'cloud_sync_outbound_candidate_selection_failed',
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

  test('exposes reviewed shadow stage codes', () {
    const codes = <String>{
      'cloud_sync_shadow_auth_capture_failed',
      'cloud_sync_shadow_auth_revalidation_failed',
      'cloud_sync_shadow_cleanup_failed',
      'cloud_sync_shadow_observer_flush_failed',
      'cloud_sync_shadow_observer_open_failed',
      'cloud_sync_shadow_preflight_read_failed',
      'cloud_sync_shadow_quiescence_failed',
      'cloud_sync_shadow_store_open_failed',
      'cloud_sync_shadow_synchronize_failed',
      'cloud_sync_shadow_transport_open_failed',
    };
    for (final code in codes) {
      expect(cloudSyncV2SafeFailureCode(StateError(code)), code);
    }
  });
}
