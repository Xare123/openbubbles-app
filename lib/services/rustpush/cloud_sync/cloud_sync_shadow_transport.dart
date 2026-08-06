import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';

typedef CloudSyncAccountFingerprintReader = Future<String?> Function();

/// Read-only transport guard for the developer shadow sampler.
///
/// Identity is checked immediately before and after every fetch. A change
/// causes the page to be rejected before the engine can journal it.
final class AccountBoundShadowTransport
    implements CloudSyncTransport, CloudProtectedPageLeaseTransportProvider {
  AccountBoundShadowTransport({
    required this._delegate,
    required this._readActiveFingerprint,
    required this._expectedFingerprint,
  });

  final CloudSyncTransport _delegate;
  final CloudSyncAccountFingerprintReader _readActiveFingerprint;
  final String _expectedFingerprint;

  @override
  CloudProtectedPageLeaseTransport? get protectedPageLeaseTransport {
    final delegate = _delegate;
    return delegate is CloudProtectedPageLeaseTransport
        ? delegate as CloudProtectedPageLeaseTransport
        : null;
  }

  @override
  Future<CloudFetchBatch> fetchChanges(
    CloudSyncScope scope, {
    required String? previousToken,
    required int generation,
    required int limit,
  }) async {
    await _requireSameAccount();
    final batch = await _delegate.fetchChanges(
      scope,
      previousToken: previousToken,
      generation: generation,
      limit: limit,
    );
    await _requireSameAccount();
    return batch;
  }

  Future<void> _requireSameAccount() async {
    if (await _readActiveFingerprint() != _expectedFingerprint) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: 'account_changed',
      );
    }
  }

  Never _rejectWrite() => throw CloudSyncFailure(
    category: CloudFailureCategory.authorization,
    safeCode: 'cloud_sync_shadow_write_tripwire',
  );

  @override
  Future<CloudPushBatchResult> pushOperations(
    CloudSyncScope scope, {
    required List<CloudOutboxOperation> operations,
  }) async => _rejectWrite();

  @override
  Future<CloudRecordMapEntry> allocateServerRecordMapping(
    CloudSyncScope scope, {
    required String logicalEntityKeyHash,
  }) async => _rejectWrite();

  @override
  Future<CloudServerConflictResolution> reconcileServerRecordChanged(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) async => _rejectWrite();

  @override
  Future<bool> refreshAuthentication(CloudSyncScope scope) async =>
      _rejectWrite();

  @override
  Future<bool> refreshPcsAccess(CloudSyncScope scope) async => _rejectWrite();
}

final class RejectingShadowInboxApplier implements CloudInboxApplier {
  const RejectingShadowInboxApplier();

  @override
  Future<CloudInboxApplyResult> apply(
    CloudInboxEntry entry, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) {
    throw CloudSyncFailure(
      category: CloudFailureCategory.authorization,
      safeCode: 'cloud_sync_shadow_apply_tripwire',
    );
  }
}
