import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_create_selection.dart';
import 'cloud_sync_historical_discovery_adapter.dart';
import 'cloud_sync_historical_producer.dart';
import 'cloud_sync_historical_stage_adapter.dart';
import 'cloud_sync_historical_staging.dart';
import 'cloud_sync_local_send_consumer.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_production_sampler_adapter.dart';
import 'objectbox_cloud_sync_store.dart';

enum CloudSyncHistoricalArchiveDisposition { retainedByReader, confirmedCreate }

/// Connects one qualified source to the real exact-discovery/create queue.
/// Use [call] as the producer's stageAndAdopt callback with an ARCHIVE cursor,
/// never a completed staging-only cursor. A return means reader ownership or
/// confirmed protected readback, not merely a locally sealed source. Unknown
/// outcomes throw without advancing the producer; retry reopens exact ownership.
/// Snapshot/account qualification and scheduling remain caller responsibilities.
final class CloudSyncHistoricalArchiveCoordinator {
  CloudSyncHistoricalArchiveCoordinator({
    required this.store,
    required this.journal,
    required this.durable,
    required this.stage,
    required this.validate,
    required this.discover,
    required this.consume,
    this.onDisposition,
  });

  factory CloudSyncHistoricalArchiveCoordinator.production({
    required Store store,
    required CloudSyncHistoricalStageAdapter staging,
    required ObjectBoxCloudSyncStore durable,
    required String privateStorageDirectory,
    required Object? Function() readActiveClient,
    required bool Function() stillCurrent,
    required Future<void> Function() validate,
    void Function(CloudSyncHistoricalArchiveDisposition)? onDisposition,
  }) => CloudSyncHistoricalArchiveCoordinator(
    store: store,
    journal: staging.staging.journal,
    durable: durable,
    stage: staging.call,
    validate: validate,
    discover: (intent) => retainCloudSyncDiscoveredHistoricalFound(
      intent: intent,
      privateStorageDirectory: privateStorageDirectory,
      readActiveClient: readActiveClient,
      stillCurrent: stillCurrent,
    ),
    consume: (selection) => CloudSyncProductionLocalSendAdapter(
      readActiveClient: readActiveClient,
      privateStorageDirectory: privateStorageDirectory,
      stillCurrent: stillCurrent,
    ).runHistoricalRequest(selection),
    onDisposition: onDisposition,
  );

  final Store store;
  final CloudSyncHistoricalArchiveJournal journal;
  final ObjectBoxCloudSyncStore durable;
  final HistoricalStageAndAdopt stage;
  final Future<void> Function() validate;
  final Future<bool> Function(CloudSyncHistoricalArchiveIntent) discover;
  final Future<CloudSyncLocalSendConsumerResult> Function(
    CloudSyncHistoricalCreateSelection,
  )
  consume;
  final void Function(CloudSyncHistoricalArchiveDisposition)? onDisposition;
  bool _running = false;

  CloudSyncScope get _scope => CloudSyncScope(
    accountFingerprint: journal.accountFingerprint,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );

  void _requireScope(CloudSyncHistoricalArchiveRequest request) {
    if (!journal.isBoundToStore(store) ||
        !durable.isBoundToStore(store) ||
        request.accountFingerprint != journal.accountFingerprint ||
        request.protectedStoreIdentity != journal.protectedStoreIdentity ||
        request.snapshotSha256 != journal.snapshotSha256) {
      throw StateError('cloud_sync_historical_archive_binding_missing');
    }
  }

  CloudSyncHistoricalArchiveIntent _retained(
    CloudSyncHistoricalArchiveRequest request,
    StagedHistoricalSource sealed,
  ) {
    _requireScope(request);
    final intent = journal.read(
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
    );
    if (intent == null ||
        !intent.sourceLeaseCommitted ||
        sealed.key != request.sourceSha256 ||
        sealed.guid != request.guid ||
        sealed.sha256 != intent.source.payloadSha256 ||
        sealed.byteLength != intent.source.payloadLength) {
      throw StateError('cloud_sync_historical_archive_stage_unverified');
    }
    return intent;
  }

  int _localChatId(
    CloudSyncHistoricalArchiveRequest request,
    CloudSyncHistoricalArchiveIntent intent,
  ) {
    if (intent.admittedOperationId case final operationId?) {
      final operation = durable.readHistoricalArchiveOperation(
        _scope,
        operationId,
      );
      final source = operation == null
          ? null
          : durable.readHistoricalArchiveSource(operation);
      if (source == null ||
          source.intentId != intent.id ||
          source.source.encode() != intent.source.encode()) {
        throw StateError('cloud_sync_historical_admitted_operation_changed');
      }
      return source.localChatId;
    }
    // Exact canonical GUID only. Matching a contact/recipient is not enough to
    // create a parent or select a different conversation in the destination.
    final query =
        store.box<Chat>().query(Chat_.guid.equals(request.chatGuid)).build()
          ..limit = 2;
    try {
      final chats = query.find();
      if (chats.length != 1 || chats.single.id == null) {
        throw StateError('cloud_sync_historical_create_parent_not_ready');
      }
      return chats.single.id!;
    } finally {
      query.close();
    }
  }

  bool _confirmed(CloudSyncHistoricalArchiveIntent intent) {
    final operationId = intent.admittedOperationId;
    final operation = operationId == null
        ? null
        : durable.readHistoricalArchiveOperation(_scope, operationId);
    return operation != null &&
        operation.status == CloudOutboxStatus.confirmed &&
        operation.confirmedAt != null &&
        operation.protectedLeaseReference == null &&
        operation.leaseId == null &&
        operation.leaseExpiresAt == null &&
        operation.nextEligibleAt == null &&
        operation.lastFailure == null;
  }

  Future<StagedHistoricalSource> call(
    CloudSyncHistoricalArchiveRequest request,
    List<int> canonicalBytes,
  ) async {
    if (_running) throw StateError('cloud_sync_historical_archive_busy');
    _running = true;
    try {
      _requireScope(request);
      if (canonicalBytes.isEmpty ||
          canonicalBytes.length > cloudSyncHistoricalMaxSourceBytes) {
        throw StateError('cloud_sync_historical_archive_source_changed');
      }
      final bytes = List<int>.unmodifiable(canonicalBytes);
      final expectedHash = historicalBytesSha256(bytes);
      await validate();
      final sealed = await stage(request, bytes);
      await validate();
      if (sealed.sha256 != expectedHash || sealed.byteLength != bytes.length) {
        throw StateError('cloud_sync_historical_archive_source_changed');
      }
      var intent = _retained(request, sealed);
      if (intent.admittedOperationId == null && intent.readerChangeId == null) {
        final found = await discover(intent);
        await validate();
        intent = _retained(request, sealed);
        if (found != (intent.readerChangeId != null) ||
            intent.admittedOperationId != null) {
          throw StateError('cloud_sync_historical_reader_source_changed');
        }
      }
      if (intent.readerChangeId != null) {
        onDisposition?.call(
          CloudSyncHistoricalArchiveDisposition.retainedByReader,
        );
        return sealed;
      }
      if (_confirmed(intent)) {
        onDisposition?.call(
          CloudSyncHistoricalArchiveDisposition.confirmedCreate,
        );
        return sealed;
      }
      final result = await consume(
        CloudSyncHistoricalCreateSelection(
          request: request,
          intentId: intent.id,
          localChatId: _localChatId(request, intent),
        ),
      );
      await validate();
      final retained = _retained(request, sealed);
      if (result.outboxBlocked ||
          result.chatReadbackPending ||
          !_confirmed(retained)) {
        throw StateError('cloud_sync_historical_archive_confirmation_pending');
      }
      onDisposition?.call(
        CloudSyncHistoricalArchiveDisposition.confirmedCreate,
      );
      return sealed;
    } finally {
      _running = false;
    }
  }
}
