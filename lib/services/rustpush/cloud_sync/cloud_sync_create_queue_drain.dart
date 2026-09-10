import 'cloud_sync_models.dart';

/// Drains ordered Chat/Message create queues inside the caller's existing
/// interlock. This grants no lock, permit, or account-wide settled proof.
/// Callback failures propagate; the caller performs global preflight afterward.
Future<bool> drainCloudSyncCreateQueues({
  required List<CloudSyncScope> scopes,
  required Future<List<CloudOutboxOperation>> Function(CloudSyncScope)
  readOutbox,
  required Future<void> Function(CloudSyncScope) recoverExpired,
  required Future<void> Function(CloudOutboxOperation) reconcileUnknown,
  required Future<void> Function(CloudSyncScope) flush,
  required Future<void> Function(CloudSyncScope, CloudOutboxOperation)
  acknowledgeConfirmed,
  required Future<void> Function() validateAccount,
  Future<bool> Function(CloudOutboxOperation)? isRetiredUnsubmittedChatCreate,
  Future<bool> Function(CloudOutboxOperation)? isRetainedPreproofPendingCreate,
}) async {
  final ordered = List<CloudSyncScope>.unmodifiable(scopes);
  const zones = ['chatManateeZone', 'messageManateeZone'];
  if (ordered.isEmpty || ordered.length > zones.length) {
    throw ArgumentError('cloud_sync_create_queue_scopes_invalid');
  }
  var previousZone = -1;
  for (final scope in ordered) {
    final zone = zones.indexOf(scope.zone);
    if (scope.accountFingerprint != ordered.first.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != 2 ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        zone <= previousZone) {
      throw ArgumentError('cloud_sync_create_queue_scopes_invalid');
    }
    previousZone = zone;
  }

  Future<T> checked<T>(Future<T> Function() action) async {
    final result = await action();
    await validateAccount();
    return result;
  }

  Future<List<CloudOutboxOperation>> read(CloudSyncScope scope) async {
    final entries = List<CloudOutboxOperation>.unmodifiable(
      await checked(() => readOutbox(scope)),
    );
    if (entries.any((operation) => operation.scope != scope)) {
      throw StateError('cloud_sync_create_queue_operation_scope_mismatch');
    }
    return entries;
  }

  await validateAccount();
  Future<bool> isHeld(CloudOutboxOperation operation) async =>
      operation.status == CloudOutboxStatus.pending &&
      operation.action == CloudOutboxAction.save &&
      isRetainedPreproofPendingCreate != null &&
      await checked(() => isRetainedPreproofPendingCreate(operation));
  // Recovery may expose an interrupted submission. Inspect every queue before
  // any reconciliation, flush, or receipt acknowledgement.
  for (final scope in ordered) {
    await checked(() => recoverExpired(scope));
  }
  final queues = <List<CloudOutboxOperation>>[];
  for (final scope in ordered) {
    queues.add(await read(scope));
  }
  final unknown = queues
      .expand((entries) => entries)
      .where(
        (operation) => operation.status == CloudOutboxStatus.unknownOutcome,
      )
      .toList();
  if (unknown.isNotEmpty) {
    if (unknown.length == 1) {
      await checked(() => reconcileUnknown(unknown.single));
    }
    return false;
  }

  for (var i = 0; i < ordered.length; i++) {
    final scope = ordered[i];
    var needsFlush = false;
    for (final operation in queues[i]) {
      if (operation.status != CloudOutboxStatus.confirmed &&
          operation.status != CloudOutboxStatus.quarantined &&
          !await isHeld(operation)) {
        needsFlush = true;
      }
    }
    if (needsFlush) {
      await checked(() => flush(scope));
    }
    final after = await read(scope);
    final confirmed = <CloudOutboxOperation>[];
    for (final operation in after) {
      if (operation.status == CloudOutboxStatus.confirmed) {
        confirmed.add(operation);
      } else if (await isHeld(operation)) {
        // Retain the original envelope. No lease, remote save or receipt ack.
        continue;
      } else if (operation.status != CloudOutboxStatus.quarantined ||
          isRetiredUnsubmittedChatCreate == null ||
          !await checked(() => isRetiredUnsubmittedChatCreate(operation))) {
        return false;
      }
    }
    // Retired rows retain their native adoption marker as audit evidence.
    // They are never submitted or acknowledged as successful receipts.
    for (final operation in confirmed) {
      if (operation.protectedLeaseReference != null) {
        await checked(() => acknowledgeConfirmed(scope, operation));
      }
    }
  }
  return true;
}
