import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_create_selection.dart';
import 'cloud_sync_historical_discovery_adapter.dart';
import 'cloud_sync_historical_producer.dart';
import 'cloud_sync_historical_received_trial.dart';
import 'cloud_sync_historical_stage_adapter.dart';
import 'cloud_sync_historical_staging.dart';
import 'cloud_sync_local_send_consumer.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_production_sampler_adapter.dart';
import 'objectbox_cloud_sync_store.dart';

enum CloudSyncHistoricalArchiveDisposition {
  retainedByReader,
  confirmedCreate,

  /// The exact encrypted source remains in its journal, without a write. Old
  /// received rows lack their original receiving endpoint. Future policy can
  /// revisit them; do not guess an address or block later supported rows.
  retainedMissingMetadata,
}

/// Connects one qualified source to the real exact-discovery/create queue.
/// Use [call] as the producer's stageAndAdopt callback with an ARCHIVE cursor,
/// never a completed staging-only cursor. A return means reader ownership or
/// confirmed protected readback, or an explicitly reported metadata deferral.
/// A deferral retains its exact source and grants no remote-write authority. Unknown
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
    this.receivedEndpointTrial,
    this.settleParentReader,
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
    CloudSyncHistoricalReceivedEndpointTrial? receivedEndpointTrial,
    Future<void> Function()? settleParentReader,
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
    receivedEndpointTrial: receivedEndpointTrial,
    settleParentReader: settleParentReader,
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
  final CloudSyncHistoricalReceivedEndpointTrial? receivedEndpointTrial;
  final Future<void> Function()? settleParentReader;
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

  int? _localChatId(
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
    // A historical parent may retain its original lineage while the destination
    // uses a canonical GUID, including a provisional one-to-one chat. Match only
    // that exact captured identifier, never members or a title.
    // The native parent proof subsequently verifies both IDs against the
    // decrypted record. Ambiguous candidates are not resolved by preference.
    var predicate = Chat_.guid.equals(request.chatGuid);
    if (request.groupMetadata != null || request.parentState != null) {
      predicate = predicate.or(
        Chat_.cloudGuid.equals(request.groupMetadata?.cloudGuid ?? request.parentState?.cloudGuid ?? request.chatGuid),
      );
    }
    final query =
        store.box<Chat>().query(predicate).build()
          ..limit = 2;
    try {
      final chats = query.find();
      if (chats.isEmpty && request.parentState != null) {
        return null; // Historical parent path, never a fabricated local Chat.
      }
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
      if (request.origin ==
              CloudSyncHistoricalArchiveOrigin.historicalReceived &&
          intent.admittedOperationId == null &&
          !(receivedEndpointTrial?.permits(request) ?? false)) {
        // Exact discovery had no reader handoff. This source cannot currently
        // be projected for create because its original endpoint was never saved.
        // The isolated Windows trial can qualify one exact source; Profile
        // keeps this default until independent Apple-client proof exists.
        // Preserve the committed source for a later policy, and allow supported
        // rows behind it to proceed. Never skip a submitted/uncertain operation.
        onDisposition?.call(
          CloudSyncHistoricalArchiveDisposition.retainedMissingMetadata,
        );
        return sealed;
      }
      var result = await consume(
        CloudSyncHistoricalCreateSelection(
          request: request,
          intentId: intent.id,
          localChatId: _localChatId(request, intent),
        ),
      );
      await validate();
      if (result.chatReadbackPending && !result.outboxBlocked && settleParentReader != null) {
        // The writer has quiesced and released its interlock. Let the ordinary
        // reader project this confirmed Chat before this same Message resumes.
        // Never run a read over an unknown save or loop a stalled cursor here.
        await settleParentReader!();
        await validate();
        intent = _retained(request, sealed);
        result = await consume(CloudSyncHistoricalCreateSelection(
          request: request, intentId: intent.id,
          localChatId: _localChatId(request, intent)));
        await validate();
      }
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
