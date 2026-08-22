import 'dart:collection';

import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';
import 'cloud_sync_writer_authority.dart';
import 'cloudkit_operation_interlock.dart';

final class FakeCloudKitOperationExclusion
    implements CloudKitOperationExclusion {
  int runCallCount = 0;
  final List<CloudKitOperationKind> observedKinds = [];

  @override
  Future<T> runExclusive<T>({
    required CloudKitOperationKind kind,
    required CloudKitOperationBody<T> action,
  }) async {
    runCallCount++;
    observedKinds.add(kind);
    return action();
  }
}

/// Test authority that can deterministically revoke a writer between permit
/// issuance and transport invocation.
final class FakeCloudSyncWriterAuthority implements CloudSyncWriterAuthority {
  bool allowIssue = true;
  bool allowVerify = true;
  Future<void> Function(int call)? verifyHandler;
  int issueCallCount = 0;
  int verifyCallCount = 0;

  @override
  Future<CloudSyncWriterPermit> issue(CloudSyncScope scope) async {
    issueCallCount++;
    if (!allowIssue) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: 'test_writer_authority_denied',
      );
    }
    return _FakeCloudSyncWriterPermit(this);
  }
}

final class _FakeCloudSyncWriterPermit implements CloudSyncWriterPermit {
  const _FakeCloudSyncWriterPermit(this._authority);

  final FakeCloudSyncWriterAuthority _authority;

  @override
  Future<void> verify() async {
    _authority.verifyCallCount++;
    await _authority.verifyHandler?.call(_authority.verifyCallCount);
    if (!_authority.allowVerify) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: 'test_writer_permit_revoked',
      );
    }
  }
}

typedef CloudFetchHandler =
    Future<CloudFetchBatch> Function(
      CloudSyncScope scope,
      String? previousToken,
      int generation,
      int limit,
    );

typedef CloudPushHandler =
    Future<CloudPushBatchResult> Function(
      CloudSyncScope scope,
      List<CloudOutboxOperation> operations,
    );

typedef CloudAuthenticationRefreshHandler =
    Future<bool> Function(CloudSyncScope scope);

typedef CloudPcsRefreshHandler = Future<bool> Function(CloudSyncScope scope);

typedef CloudRecordMappingHandler =
    Future<CloudRecordMapEntry> Function(
      CloudSyncScope scope,
      String logicalEntityKeyHash,
    );

typedef CloudConflictHandler =
    Future<CloudServerConflictResolution> Function(
      CloudSyncScope scope,
      CloudOutboxOperation operation,
    );

typedef CloudUnknownOutcomeHandler =
    Future<CloudUnknownOutcomeResolution> Function(
      CloudSyncScope scope,
      CloudOutboxOperation operation,
    );

class FakeCloudSyncTransport implements CloudSyncTransport {
  final Queue<Object> _fetchResponses = Queue();
  final Queue<Object> _pushResponses = Queue();

  CloudFetchHandler? fetchHandler;
  CloudPushHandler? pushHandler;
  CloudAuthenticationRefreshHandler? authenticationRefreshHandler;
  CloudPcsRefreshHandler? pcsRefreshHandler;
  CloudRecordMappingHandler? recordMappingHandler;
  CloudConflictHandler? conflictHandler;
  CloudUnknownOutcomeHandler? unknownOutcomeHandler;

  int fetchCallCount = 0;
  int pushCallCount = 0;
  int authenticationRefreshCallCount = 0;
  int pcsRefreshCallCount = 0;
  int recordMappingCallCount = 0;
  int conflictCallCount = 0;
  int unknownOutcomeCallCount = 0;
  final List<String?> observedFetchTokens = [];
  final List<List<String>> observedPushOperationIds = [];
  final List<String> observedUnknownOutcomeOperationIds = [];

  void enqueueFetchBatch(CloudFetchBatch batch) => _fetchResponses.add(batch);

  void enqueueFetchFailure(CloudSyncFailure failure) =>
      _fetchResponses.add(failure);

  void enqueuePushResult(CloudPushBatchResult result) =>
      _pushResponses.add(result);

  void enqueuePushFailure(CloudSyncFailure failure) =>
      _pushResponses.add(failure);

  @override
  Future<CloudFetchBatch> fetchChanges(
    CloudSyncScope scope, {
    required String? previousToken,
    required int generation,
    required int limit,
  }) async {
    fetchCallCount++;
    observedFetchTokens.add(previousToken);
    if (fetchHandler != null) {
      return fetchHandler!(scope, previousToken, generation, limit);
    }
    if (_fetchResponses.isEmpty) {
      return CloudFetchBatch(
        scope: scope,
        changes: const [],
        batchId: 'fake-empty-batch-$fetchCallCount',
        generation: generation,
        nextToken: previousToken,
        hasMore: false,
      );
    }
    final response = _fetchResponses.removeFirst();
    if (response is CloudSyncFailure) throw response;
    return response as CloudFetchBatch;
  }

  @override
  Future<CloudPushBatchResult> pushOperations(
    CloudSyncScope scope, {
    required List<CloudOutboxOperation> operations,
  }) async {
    pushCallCount++;
    observedPushOperationIds.add(
      operations.map((operation) => operation.operationId).toList(),
    );
    if (pushHandler != null) return pushHandler!(scope, operations);
    if (_pushResponses.isEmpty) {
      return CloudPushBatchResult(outcomes: const []);
    }
    final response = _pushResponses.removeFirst();
    if (response is CloudSyncFailure) throw response;
    return response as CloudPushBatchResult;
  }

  @override
  Future<CloudUnknownOutcomeResolution> reconcileUnknownOutcome(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) async {
    unknownOutcomeCallCount++;
    observedUnknownOutcomeOperationIds.add(operation.operationId);
    final handler = unknownOutcomeHandler;
    if (handler != null) return handler(scope, operation);
    return const CloudUnknownOutcomeResolution.unresolved(
      failureCategory: CloudFailureCategory.network,
    );
  }

  @override
  Future<bool> refreshAuthentication(CloudSyncScope scope) async {
    authenticationRefreshCallCount++;
    final handler = authenticationRefreshHandler;
    if (handler == null) return false;
    return handler(scope);
  }

  @override
  Future<bool> refreshPcsAccess(CloudSyncScope scope) async {
    pcsRefreshCallCount++;
    final handler = pcsRefreshHandler;
    if (handler == null) return false;
    return handler(scope);
  }

  @override
  Future<CloudRecordMapEntry> allocateServerRecordMapping(
    CloudSyncScope scope, {
    required String logicalEntityKeyHash,
  }) async {
    recordMappingCallCount++;
    final handler = recordMappingHandler;
    if (handler != null) return handler(scope, logicalEntityKeyHash);
    return CloudRecordMapEntry(
      scope: scope,
      logicalEntityKeyHash: logicalEntityKeyHash,
      serverRecordIdHash: 'fake-random-record-hash-$recordMappingCallCount',
      encryptedServerRecordId:
          'protected:fake-random-record-$recordMappingCallCount',
      updatedAt: DateTime.utc(2026),
    );
  }

  @override
  Future<CloudServerConflictResolution> reconcileServerRecordChanged(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) async {
    conflictCallCount++;
    final handler = conflictHandler;
    if (handler != null) return handler(scope, operation);
    return const CloudServerConflictResolution.retryable(
      failureCategory: CloudFailureCategory.network,
    );
  }
}

typedef CloudInboxApplyHandler =
    Future<CloudInboxApplyResult> Function(CloudInboxEntry entry);

class FakeCloudInboxApplier implements CloudInboxApplier {
  FakeCloudInboxApplier({this._handler});

  CloudInboxApplyHandler? _handler;
  final Map<int, CloudInboxApplyResult> resultsBySequence = {};
  final List<int> appliedSequences = [];
  final List<CloudCoordinatorLeaseFence> appliedLeaseFences = [];

  set handler(CloudInboxApplyHandler value) => _handler = value;

  @override
  Future<CloudInboxApplyResult> apply(
    CloudInboxEntry entry, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    appliedSequences.add(entry.sequence);
    appliedLeaseFences.add(leaseFence);
    if (_handler != null) return _handler!(entry);
    return resultsBySequence[entry.sequence] ??
        const CloudInboxApplyResult.applied();
  }
}
