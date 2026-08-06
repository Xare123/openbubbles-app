import 'dart:collection';

import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';

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

class FakeCloudSyncTransport implements CloudSyncTransport {
  final Queue<Object> _fetchResponses = Queue();
  final Queue<Object> _pushResponses = Queue();

  CloudFetchHandler? fetchHandler;
  CloudPushHandler? pushHandler;
  CloudAuthenticationRefreshHandler? authenticationRefreshHandler;
  CloudPcsRefreshHandler? pcsRefreshHandler;
  CloudRecordMappingHandler? recordMappingHandler;
  CloudConflictHandler? conflictHandler;

  int fetchCallCount = 0;
  int pushCallCount = 0;
  int authenticationRefreshCallCount = 0;
  int pcsRefreshCallCount = 0;
  int recordMappingCallCount = 0;
  int conflictCallCount = 0;
  final List<String?> observedFetchTokens = [];
  final List<List<String>> observedPushOperationIds = [];

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
