// Focused classification tests for previous-upload check presentation.
// Pure logic: no ObjectBox, no native calls.
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('allowlisted StateError code is preserved', () {
    expect(cloudSyncPreviousUploadCheckLogCode(StateError('cloud_sync_receipt_check_lease_active')), 'cloud_sync_receipt_check_lease_active');
    expect(cloudSyncPreviousUploadCheckIsSetupUnavailable(StateError('cloud_sync_receipt_check_lease_active')), isFalse);
  });
  test('unknown StateError maps to generic', () {
    expect(cloudSyncPreviousUploadCheckLogCode(StateError('something_else')), 'cloud_sync_receipt_check_failed');
    expect(cloudSyncPreviousUploadCheckIsSetupUnavailable(StateError('something_else')), isFalse);
  });
  test('known native auth failure preserves code and setup', () {
    final error = CloudSyncFailure(category: CloudFailureCategory.authorization, safeCode: 'cloud_sync_outbound_native_auth_unavailable');
    expect(cloudSyncPreviousUploadCheckLogCode(error), 'cloud_sync_outbound_native_auth_unavailable');
    expect(cloudSyncPreviousUploadCheckIsSetupUnavailable(error), isTrue);
  });
  test('other CloudSyncFailure stays generic without setup', () {
    final error = CloudSyncFailure(category: CloudFailureCategory.server, safeCode: 'cloud_sync_outbound_native_prepare_failed');
    expect(cloudSyncPreviousUploadCheckLogCode(error), 'cloud_sync_receipt_check_failed');
    expect(cloudSyncPreviousUploadCheckIsSetupUnavailable(error), isFalse);
  });
  test('authority failure keeps generic log code with setup wording', () {
    const error = CloudKitWriterAuthorityFailure('cloudkit_writer_reconciliation_binding_missing');
    expect(cloudSyncPreviousUploadCheckLogCode(error), 'cloud_sync_receipt_check_failed');
    expect(cloudSyncPreviousUploadCheckIsSetupUnavailable(error), isTrue);
  });
  test('arbitrary exception never leaks into log code', () {
    expect(cloudSyncPreviousUploadCheckLogCode(Exception('sensitive account detail')), 'cloud_sync_receipt_check_failed');
    expect(cloudSyncPreviousUploadCheckIsSetupUnavailable(Exception('sensitive account detail')), isFalse);
  });
}
