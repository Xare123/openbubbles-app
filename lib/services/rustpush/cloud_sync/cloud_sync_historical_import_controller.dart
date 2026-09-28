import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cloud_sync_historical_archive_coordinator.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_cursor_file.dart';
import 'cloud_sync_historical_producer.dart';
import 'cloud_sync_historical_snapshot.dart';
import 'cloud_sync_historical_staging.dart';

enum CloudSyncHistoricalImportPhase {
  idle,
  preparing,
  awaitingConfirmation,
  running,
  pausing,
  paused,
  scanComplete,
  needsAttention,
}

typedef CloudSyncHistoricalArchiveStep =
    Future<
      ({
        StagedHistoricalSource source,
        CloudSyncHistoricalArchiveDisposition disposition,
      })
    >
    Function(CloudSyncHistoricalArchiveRequest request, List<int> bytes);

/// Exact immutable source plus one currently authenticated destination. The
/// service supplies real native validation, an ARCHIVE cursor, and the existing
/// selected discovery/create/readback coordinator, never a stage-only callback.
/// Loading this plan must not perform any remote write or infer old-row ownership.
final class CloudSyncHistoricalImportPlan {
  CloudSyncHistoricalImportPlan({
    required this.snapshot,
    required this.accountLabel,
    this.sourceLabel = 'Messages on this device',
    required this.archiveCursors,
    required this.registry,
    required this.stillCurrent,
    required this.validateIdentity,
    required this.archive,
  }) {
    if (accountLabel.trim().isEmpty ||
        accountLabel.length > 512 ||
        sourceLabel.trim().isEmpty ||
        sourceLabel.length > 120 ||
        sourceLabel.contains(RegExp(r'[\r\n\x00]')) ||
        (archiveCursors is CloudSyncHistoricalCursorFile &&
            (archiveCursors as CloudSyncHistoricalCursorFile).mode !=
                CloudSyncHistoricalCursorMode.archive)) {
      throw StateError('cloud_sync_historical_import_plan_invalid');
    }
  }

  final CloudSyncHistoricalSnapshot snapshot;
  final String accountLabel;
  final String sourceLabel;
  final HistoricalCursorStore archiveCursors;
  final HistoricalOwnershipRegistry registry;
  final bool Function() stillCurrent;
  final Future<void> Function() validateIdentity;
  final CloudSyncHistoricalArchiveStep archive;

  Future<void> validate() async {
    if (!stillCurrent()) {
      throw StateError('cloud_sync_historical_import_identity_changed');
    }
    await validateIdentity();
    if (!stillCurrent()) {
      throw StateError('cloud_sync_historical_import_identity_changed');
    }
  }
}

/// Single-use, memory-only consent for the displayed source and destination.
/// The UI sees counts/account, not message bodies. It must discard this after
/// cancellation, navigation, restart or account change and obtain fresh consent.
final class CloudSyncHistoricalImportConfirmation {
  CloudSyncHistoricalImportConfirmation._(this._plan);
  final CloudSyncHistoricalImportPlan _plan;
  String get accountLabel => _plan.accountLabel;
  String get sourceLabel => _plan.sourceLabel;
  int get messageCount => _plan.snapshot.manifest.messageCount;
  DateTime get capturedAt =>
      DateTime.fromMillisecondsSinceEpoch(_plan.snapshot.manifest.capturedAtMs);

  @override
  String toString() => 'CloudSyncHistoricalImportConfirmation(redacted)';
}

/// Service-owned manual import lifecycle. Nothing runs at construction, on
/// prepare, or after restart without a fresh exact confirmation. The service
/// must retain its engine until [drain] completes before disposing native state.
/// Presentation counts reset per confirmed session; durable cursors/journals,
/// not these counters, own progress and remote outcome.
final class CloudSyncHistoricalImportController extends ChangeNotifier {
  CloudSyncHistoricalImportController({this.pageSize = 20}) {
    if (pageSize < 1 || pageSize > 20) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
  }

  /// Profile uses bounded bulk pages. A tightly budgeted operator run uses one
  /// row per page so a settled row's cursor persists before its budget pauses
  /// admission. This does not advance past failed or uncertain operations.
  final int pageSize;

  CloudSyncHistoricalImportPhase phase = CloudSyncHistoricalImportPhase.idle;
  String? failureCode;
  int sourceRows = 0;
  int assessed = 0;
  int handled = 0;
  int skippedOwned = 0;
  int retainedConflicts = 0;
  int confirmedCreates = 0;
  int readerHandoffs = 0;
  int deferredMissingMetadata = 0;
  Map<String, int> ineligibleByReason = const {};
  bool scanComplete = false;

  Future<void>? _pending;
  int _generation = 0;
  bool _pauseRequested = false;
  CloudSyncHistoricalImportConfirmation? _confirmation;
  final Set<String> _confirmedGuids = {};
  final Set<String> _readerGuids = {};
  final Set<String> _deferredGuids = {};
  bool get active => _pending != null;

  Future<T> _owned<T>(Future<T> Function() body) async {
    if (active) throw StateError('cloud_sync_historical_import_busy');
    final settled = Completer<void>();
    _pending = settled.future;
    try {
      return await body();
    } catch (error) {
      failureCode = _safeFailure(error);
      phase = CloudSyncHistoricalImportPhase.needsAttention;
      // Never propagate a native error containing captured message text.
      throw StateError(failureCode!);
    } finally {
      _pending = null;
      settled.complete();
      notifyListeners();
    }
  }

  Future<CloudSyncHistoricalImportConfirmation> prepare(
    Future<CloudSyncHistoricalImportPlan> Function() load,
  ) => _owned(() async {
    final generation = ++_generation;
    _confirmation = null;
    _pauseRequested = false;
    failureCode = null;
    phase = CloudSyncHistoricalImportPhase.preparing;
    notifyListeners();
    final plan = await load();
    await plan.validate();
    if (generation != _generation || _pauseRequested) {
      phase = CloudSyncHistoricalImportPhase.paused;
      throw StateError('cloud_sync_historical_import_confirmation_expired');
    }
    sourceRows = plan.snapshot.manifest.messageCount;
    final confirmation = CloudSyncHistoricalImportConfirmation._(plan);
    _confirmation = confirmation;
    phase = CloudSyncHistoricalImportPhase.awaitingConfirmation;
    return confirmation;
  });

  void cancel(CloudSyncHistoricalImportConfirmation confirmation) {
    if (!identical(_confirmation, confirmation)) return;
    _confirmation = null;
    phase = CloudSyncHistoricalImportPhase.idle;
    notifyListeners();
  }

  void pause() {
    _pauseRequested = true;
    if (active) {
      phase = CloudSyncHistoricalImportPhase.pausing;
      notifyListeners();
    }
  }

  /// Logout/identity replacement revokes consent and prevents the next row.
  /// It never kills an already-admitted Apple request or discards its evidence.
  void invalidate() {
    ++_generation;
    _confirmation = null;
    pause();
    if (!active) {
      phase = CloudSyncHistoricalImportPhase.idle;
      notifyListeners();
    }
  }

  Future<void> drain() async {
    pause();
    await _pending;
  }

  Future<void> confirm(
    CloudSyncHistoricalImportConfirmation confirmation,
  ) => _owned(() async {
    if (!identical(_confirmation, confirmation)) {
      throw StateError('cloud_sync_historical_import_confirmation_expired');
    }
    _confirmation = null; // Consume synchronously, before any await.
    final generation = _generation;
    final plan = confirmation._plan;
    _pauseRequested = false;
    failureCode = null;
    assessed = handled = skippedOwned = retainedConflicts = 0;
    confirmedCreates = readerHandoffs = deferredMissingMetadata = 0;
    _confirmedGuids.clear();
    _readerGuids.clear();
    _deferredGuids.clear();
    ineligibleByReason = const {};
    scanComplete = false;
    phase = CloudSyncHistoricalImportPhase.running;
    notifyListeners();
    bool admittedWindow() => !_pauseRequested && generation == _generation;
    try {
      while (admittedWindow()) {
        await plan.validate();
        if (!admittedWindow()) break;
        final baseAssessed = assessed;
        final baseHandled = handled;
        final baseOwned = skippedOwned;
        final baseConflicts = retainedConflicts;
        final baseIneligible = ineligibleByReason;
        void progress(HistoricalProducerSummary summary) {
          assessed = baseAssessed + summary.assessed;
          handled = baseHandled + summary.staged;
          skippedOwned = baseOwned + summary.skippedOwned;
          retainedConflicts = baseConflicts + summary.retainedConflict;
          final reasons = Map<String, int>.of(baseIneligible);
          for (final entry in summary.ineligibleByReason.entries) {
            reasons.update(
              entry.key,
              (v) => v + entry.value,
              ifAbsent: () => entry.value,
            );
          }
          ineligibleByReason = Map.unmodifiable(reasons);
          notifyListeners();
        }

        final output = await CloudSyncHistoricalProducer(
          reader: plan.snapshot,
          registry: plan.registry,
          cursors: plan.archiveCursors,
          manifest: plan.snapshot.manifest,
          account: plan.snapshot.account,
          readCurrentRow: (guid) async {
            await plan.validate();
            return plan.snapshot.readExact(guid);
          },
          stageAndAdopt: (request, bytes) async {
            await plan.validate();
            if (!admittedWindow()) throw const _HistoricalImportPaused();
            final result = await plan.archive(request, bytes);
            await plan.validate();
            if (result.source.key != request.sourceSha256 ||
                result.source.guid != request.guid ||
                result.source.byteLength != bytes.length ||
                result.source.sha256 != historicalBytesSha256(bytes)) {
              throw StateError('cloud_sync_historical_archive_source_changed');
            }
            switch (result.disposition) {
              case CloudSyncHistoricalArchiveDisposition.confirmedCreate:
                _confirmedGuids.add(request.guid);
                confirmedCreates = _confirmedGuids.length;
              case CloudSyncHistoricalArchiveDisposition.retainedByReader:
                _readerGuids.add(request.guid);
                readerHandoffs = _readerGuids.length;
              case CloudSyncHistoricalArchiveDisposition
                  .retainedMissingMetadata:
                _deferredGuids.add(request.guid);
                deferredMissingMetadata = _deferredGuids.length;
            }
            return result.source;
          },
          pageLimit: pageSize,
          maxPages: 1,
          shouldContinue: admittedWindow,
          onProgress: progress,
        ).run();
        progress(output.summary);
        // An invalidated session must not publish a stale success, even if the
        // exact in-flight operation was durably retained by its coordinator.
        await plan.validate();
        if (generation != _generation) break;
        if (output.summary.completed) {
          scanComplete = true;
          phase = CloudSyncHistoricalImportPhase.scanComplete;
          return;
        }
        // Yield to lifecycle/UI events between bounded pages, not a tight loop.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } on _HistoricalImportPaused {
      // Nothing was admitted after the pause. The unchanged cursor owns replay.
    }
    phase = CloudSyncHistoricalImportPhase.paused;
  });

  static String _safeFailure(Object error) {
    const known = {
      'cloud_sync_historical_import_confirmation_expired',
      'cloud_sync_historical_import_identity_changed',
      'cloud_sync_historical_import_plan_invalid',
      'cloud_sync_historical_import_owner_required',
      'cloud_sync_historical_import_reader_pending',
      'cloud_sync_historical_import_unavailable',
      'cloud_sync_historical_import_busy',
      'cloud_sync_historical_archive_confirmation_pending',
      'cloud_sync_historical_create_parent_not_ready',
      'cloud_sync_historical_import_source_invalid',
      'cloud_sync_historical_import_source_changed',
      'cloud_sync_historical_snapshot_empty',
      'cloud_sync_historical_snapshot_limit',
      'cloud_sync_historical_snapshot_invalid',
      'cloud_sync_historical_snapshot_storage_unavailable',
      'cloud_sync_historical_existing_origin_or_mutation',
      'cloud_sync_historical_cursor_concurrent_change',
    };
    return error is StateError && known.contains(error.message)
        ? error.message
        : 'cloud_sync_historical_import_failed';
  }

  @override
  void dispose() {
    if (active) throw StateError('cloud_sync_historical_import_drain_required');
    _confirmation = null;
    super.dispose();
  }
}

final class _HistoricalImportPaused implements Exception {
  const _HistoricalImportPaused();
}
