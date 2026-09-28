import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_chat_origin.dart';
import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'objectbox_cloud_sync_preflight.dart';
import 'objectbox_cloud_sync_store.dart';

/// One explicit historical request, never permission to drain other origins.
/// The source journal is durable; this in-memory selection only narrows a pass.
final class CloudSyncHistoricalCreateSelection {
  CloudSyncHistoricalCreateSelection({
    required this.request,
    required this.intentId,
    required this.localChatId,
  }) {
    if (intentId < 1 || (localChatId != null && localChatId! < 1)) {
      throw StateError('cloud_sync_historical_selection_invalid');
    }
  }

  final CloudSyncHistoricalArchiveRequest request;
  final int intentId;
  final int? localChatId;
  String? _operationId;
  String? _chatOperationId;
  int? _messageLocalChatId;
  CloudOutboxOperation? _chatOperation;
  CloudOutboxOperation? get chatOperation => _chatOperation;
  Store? _boundStore;
  String? _sourceBinding;
  final Map<String, String> _inertAuditRows = {};

  bool matches(CloudSyncHistoricalCreateSelection other) =>
      intentId == other.intentId &&
      localChatId == other.localChatId &&
      request.guid == other.request.guid &&
      request.guidHash == other.request.guidHash &&
      request.sourceSha256 == other.request.sourceSha256 &&
      request.snapshotSha256 == other.request.snapshotSha256 &&
      request.accountFingerprint == other.request.accountFingerprint &&
      request.protectedStoreIdentity == other.request.protectedStoreIdentity &&
      request.origin == other.request.origin &&
      request.isFromMe == other.request.isFromMe &&
      request.chatGuid == other.request.chatGuid &&
      request.dateCreatedMs == other.request.dateCreatedMs &&
      request.textSha256 == other.request.textSha256 &&
      request.senderAddress == other.request.senderAddress &&
      request.peerAddress == other.request.peerAddress;

  /// Reopen exact ownership before and after every asynchronous queue boundary.
  /// Mutable visible messages are deliberately not a veto on retained readback.
  CloudOutboxOperation? validate({
    required Store store,
    required CloudSyncScope scope,
    required CloudSyncHistoricalArchiveJournal journal,
    required ObjectBoxCloudSyncStore durable,
    required CloudSyncNativeAuthSnapshot auth,
    CloudSyncLocalSendJournal? localSendJournal,
  }) => store.runInTransaction(TxMode.read, () {
    if ((_boundStore != null && !identical(_boundStore, store)) ||
        !journal.isBoundToStore(store) ||
        !durable.isBoundToStore(store) ||
        (localSendJournal != null && !localSendJournal.isBoundToStore(store))) {
      throw StateError('cloud_sync_historical_selection_changed');
    }
    final intent = journal.read(
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
    );
    if (intent == null ||
        intent.id != intentId ||
        !intent.sourceLeaseCommitted ||
        intent.readerChangeId != null ||
        auth.accountFingerprint != request.accountFingerprint ||
        auth.protectedStoreIdentity != request.protectedStoreIdentity ||
        scope.accountFingerprint != auth.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'messageManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != 2 ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw StateError('cloud_sync_historical_selection_changed');
    }
    intent.source.requireOrigin(
      accountFingerprint: request.accountFingerprint,
      protectedStoreIdentity: request.protectedStoreIdentity,
      snapshotSha256: request.snapshotSha256,
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
    );
    final sourceBinding = intent.source.encode();
    if (_sourceBinding != null && _sourceBinding != sourceBinding) {
      throw StateError('cloud_sync_historical_selection_changed');
    }
    final operationId = intent.admittedOperationId;
    if (_operationId != null && _operationId != operationId) {
      throw StateError('cloud_sync_historical_selection_changed');
    }
    CloudOutboxOperation? operation;
    if (operationId != null) {
      operation = durable.readHistoricalArchiveOperation(scope, operationId);
      final source = operation == null
          ? null
          : durable.readHistoricalArchiveSource(operation);
      if (source == null ||
          source.intentId != intentId ||
          (localChatId != null && source.localChatId != localChatId) ||
          (_messageLocalChatId != null && source.localChatId != _messageLocalChatId) ||
          source.source.encode() != sourceBinding) {
        throw StateError('cloud_sync_historical_selection_changed');
      }
      _messageLocalChatId ??= source.localChatId;
    }

    // Scope filtering is not authority: the queue leases at scope level. Pin
    // every unrelated row in the whole store, and reject active or new work
    // before lease, submission and recovery transactions can change anything.
    // Retained pre-proof sends remain untouched, never promoted or reconciled.
    final inert = <String, String>{};
    CloudOutboxOperation? chatOperation;
    for (final row in store.box<CloudOutboxOperationEntity>().getAll()) {
      if (row.operationId == operationId) continue;
      final encoded = row.localChatOrigin;
      if (encoded != null && isCloudSyncHistoricalChatOrigin(encoded)) {
        final parent = CloudSyncHistoricalChatOrigin.decode(encoded);
        if (parent.intentId == intentId && parent.source.encode() == sourceBinding) {
          if (chatOperation != null) {
            throw StateError('cloud_sync_historical_selection_changed');
          }
          final chatScope = CloudSyncScope(accountFingerprint: scope.accountFingerprint,
            container: scope.container, database: scope.database, zone: 'chatManateeZone',
            streamKind: scope.streamKind, schemaVersion: scope.schemaVersion,
            persistenceLane: scope.persistenceLane);
          chatOperation = durable.readHistoricalChatCreate(chatScope, parent);
          if (chatOperation == null || chatOperation.operationId != row.operationId) {
            throw StateError('cloud_sync_historical_selection_changed');
          }
          continue;
        }
      }
      final fingerprint =
          ObjectBoxCloudSyncPreflightReader.settledAuditFingerprint([row]) ??
          (localSendJournal == null
              ? null
              : ObjectBoxCloudSyncPreflightReader.retainedPreproofAuditFingerprint(
                  row,
                  journal: localSendJournal,
                ));
      if (fingerprint == null) {
        throw StateError('cloud_sync_historical_unrelated_outbox');
      }
      if (_boundStore != null &&
          _inertAuditRows[row.operationId] != fingerprint) {
        throw StateError('cloud_sync_historical_selection_changed');
      }
      inert[row.operationId] = fingerprint;
    }
    if (_boundStore != null && inert.length != _inertAuditRows.length) {
      throw StateError('cloud_sync_historical_selection_changed');
    }
    if (_chatOperationId != null && _chatOperationId != chatOperation?.operationId) {
      throw StateError('cloud_sync_historical_selection_changed');
    }
    _boundStore ??= store;
    _sourceBinding ??= sourceBinding;
    _inertAuditRows
      ..clear()
      ..addAll(inert);
    _operationId = operationId;
    _chatOperationId = chatOperation?.operationId;
    _chatOperation = chatOperation;
    return operation;
  });

  bool owns(CloudOutboxOperation operation) =>
      ((operation.scope.zone == 'messageManateeZone' && _operationId != null &&
        operation.operationId == _operationId) ||
       (operation.scope.zone == 'chatManateeZone' && _chatOperationId != null &&
        operation.operationId == _chatOperationId)) &&
      operation.scope.accountFingerprint == request.accountFingerprint &&
      operation.scope.container == 'com.apple.messages.cloud' &&
      operation.scope.database == 'private' &&
      operation.scope.streamKind == CloudSyncStreamKind.messages &&
      operation.scope.schemaVersion == 2 &&
      operation.scope.persistenceLane == CloudSyncPersistenceLane.semantic;

  /// The existing writer leases a scope, so filtering its view is insufficient.
  /// Before it can run, every other operation must be pinned inert evidence.
  /// Unknown and active work require their separate recovery. Call validate
  /// again at each database/network boundary; this filter grants no authority.
  bool canDrain(Iterable<CloudOutboxOperation> operations) =>
      _boundStore != null &&
      operations.every(
        (operation) =>
            owns(operation) ||
            _inertAuditRows.containsKey(operation.operationId),
      );
}
