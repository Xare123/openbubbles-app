library;

import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_staging.dart';

/// Resumable bounded historical producer over assessed rows.
///
/// Reads one page of row views at a time, assesses each against the
/// manifest, dedupes exact GUIDs against caller-supplied ownership, stages
/// what proceeds, and advances an opaque cursor after every page. Restarting
/// with the same cursor store and registries stages nothing twice: cursors
/// bound progress while idempotent request digests make repeat staging a
/// no-op write of identical bytes. Ineligible rows are counted by reason
/// and retained by the caller; nothing here deletes, uploads, or sends.

/// One page of row views plus the cursor resuming after it, or null when
/// the scan is complete.
class HistoricalRowPage {
  const HistoricalRowPage({required this.views, required this.nextCursor});

  final List<CloudSyncHistoricalRowView> views;
  final String? nextCursor;
}

/// Reads row views in stable order. Production binds an ObjectBox query;
/// tests bind synthetic or fixture rows.
abstract class HistoricalRowReader {
  Future<HistoricalRowPage> readPage({String? cursor, required int limit});
}

/// Exact-GUID ownership known before this run. Production feeds the V2
/// record-map plus the local-send and received journals.
abstract class HistoricalOwnershipRegistry {
  Set<String> get ownedGuids;
  Set<String> get conflictGuids;
}

/// Scoped cursor record. Null means never started; done marks a completed
/// pass. The scope binds the manifest snapshot plus the authenticated
/// account and protected store, so a cursor from another snapshot, account,
/// or store can never resume this run silently. A foreign scope is retained
/// and rejected, so its progress and pending evidence are not overwritten.
class HistoricalProducerCursor {
  const HistoricalProducerCursor({
    required this.scope,
    required this.lastId,
    required this.done,
  });

  final String scope;
  final String? lastId;
  final bool done;
}

/// Durable cursor holder. Production binds existing durable storage;
/// tests use memory or temp files.
abstract class HistoricalCursorStore {
  Future<HistoricalProducerCursor?> load();
  Future<void> save(HistoricalProducerCursor? cursor);
}

/// In-memory cursor store for tests and dry runs.
class MemoryHistoricalCursorStore implements HistoricalCursorStore {
  HistoricalProducerCursor? _cursor;

  @override
  Future<HistoricalProducerCursor?> load() async => _cursor;

  @override
  Future<void> save(HistoricalProducerCursor? cursor) async {
    _cursor = cursor;
  }
}

/// Per-run summary. Counts only; carries no row content.
class HistoricalProducerSummary {
  const HistoricalProducerSummary({
    required this.assessed,
    required this.staged,
    required this.skippedOwned,
    required this.retainedConflict,
    required this.ineligibleByReason,
    required this.completed,
  });

  final int assessed;
  final int staged;
  final int skippedOwned;
  final int retainedConflict;
  final Map<String, int> ineligibleByReason;
  final bool completed;
}

/// Staged output of one run: requests plus their sealed sources.
class HistoricalProducerOutput {
  const HistoricalProducerOutput({required this.staged});

  final List<StagedHistoricalSource> staged;
}

/// Runs one bounded pass over historical rows.
class CloudSyncHistoricalProducer {
  const CloudSyncHistoricalProducer({
    required this.reader,
    required this.registry,
    required this.cursors,
    required this.bytes,
    required this.manifest,
    required this.account,
    required this.readCurrentRow,
    required this.adoptStaged,
    this.pageLimit = 50,
    this.maxPages = 20,
    this.nowMs,
  });

  final HistoricalRowReader reader;
  final HistoricalOwnershipRegistry registry;
  final HistoricalCursorStore cursors;
  final HistoricalByteStore bytes;
  final CloudSyncHistoricalSourceManifest manifest;
  final CloudSyncHistoricalAccountBinding account;

  /// Re-reads the complete current row by GUID at stage time. Staging
  /// re-runs eligibility over this view and recomputes the canonical
  /// source binding, so any drift in route, time, origin, sender,
  /// direction, chat, or text throws instead of staging.
  final Future<CloudSyncHistoricalRowView?> Function(String guid)
  readCurrentRow;

  /// Durably adopts one staged source before the cursor advances past it.
  /// A successful return means durably journaled, not remotely uploaded.
  /// Must be idempotent: re-adopting an identical key is a no-op success,
  /// because a resumed scan restages and re-presents rows the journal
  /// already holds. Conflicting bytes for an adopted key must throw.
  /// Production binds the journal intent writer; tests bind a durable map.
  final Future<void> Function(StagedHistoricalSource staged) adoptStaged;

  final int pageLimit;
  final int maxPages;
  final int? nowMs;

  /// Scope binding this run: snapshot, account, and protected store.
  String get scope => historicalArchiveScope(manifest, account);

  /// Current binding must be complete before any shortcut or scan.
  bool get _bindingValid =>
      manifest.hasValidShape(
        nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      ) &&
      manifest.accountFingerprint == account.accountFingerprint &&
      account.hasValidShape;

  Future<({HistoricalProducerSummary summary, HistoricalProducerOutput output})>
  run() async {
    if (!_bindingValid) {
      throw StateError('cloud_sync_historical_archive_binding_missing');
    }
    if (pageLimit < 1 || pageLimit > 500 || maxPages < 1 || maxPages > 100) {
      throw ArgumentError('cloud_sync_historical_archive_budget_invalid');
    }
    final saved = await cursors.load();
    if (saved != null && saved.scope != scope) {
      throw StateError('cloud_sync_historical_archive_scope_changed');
    }
    if (saved != null && saved.scope == scope && saved.done) {
      return (
        summary: const HistoricalProducerSummary(
          assessed: 0,
          staged: 0,
          skippedOwned: 0,
          retainedConflict: 0,
          ineligibleByReason: {},
          completed: true,
        ),
        output: const HistoricalProducerOutput(staged: []),
      );
    }
    String? cursor;
    if (saved != null && saved.scope == scope && !saved.done) {
      cursor = saved.lastId;
    }
    var assessed = 0;
    var stagedCount = 0;
    var skippedOwned = 0;
    var retainedConflict = 0;
    final ineligibleByReason = <String, int>{};
    final staged = <StagedHistoricalSource>[];
    final stagedGuids = <String, String>{};
    var completed = false;
    var pages = 0;
    while (pages < maxPages) {
      final page = await reader.readPage(cursor: cursor, limit: pageLimit);
      if (page.views.length > pageLimit ||
          (page.nextCursor != null && page.nextCursor == cursor)) {
        throw StateError('cloud_sync_historical_archive_page_invalid');
      }
      for (final view in page.views) {
        assessed++;
        final assessment = assessHistoricalArchiveRow(
          view,
          manifest,
          account,
          nowMs: nowMs,
        );
        if (assessment is! CloudSyncHistoricalArchiveEligible) {
          final reason =
              (assessment as CloudSyncHistoricalArchiveIneligible).reason;
          ineligibleByReason.update(reason, (n) => n + 1, ifAbsent: () => 1);
          continue;
        }
        final request = assessment.request;
        if (stagedGuids.containsKey(request.guid)) {
          if (stagedGuids[request.guid] != request.sourceSha256) {
            throw StateError('cloud_sync_historical_archive_source_conflict');
          }
          skippedOwned++;
          continue;
        }
        switch (resolveHistoricalDedupe(
          guid: request.guid,
          ownedGuids: registry.ownedGuids,
          conflictGuids: registry.conflictGuids,
        )) {
          case CloudSyncHistoricalDedupeVerdict.skipOwned:
            skippedOwned++;
          case CloudSyncHistoricalDedupeVerdict.retainConflict:
            retainedConflict++;
          case CloudSyncHistoricalDedupeVerdict.proceed:
            final current = await readCurrentRow(request.guid);
            if (current == null) {
              throw StateError(
                'cloud_sync_historical_archive_source_unavailable',
              );
            }
            final sealed = await stageHistoricalSource(
              store: bytes,
              request: request,
              currentRow: current,
              manifest: manifest,
              account: account,
              nowMs: nowMs,
            );
            await adoptStaged(sealed);
            staged.add(sealed);
            stagedGuids[request.guid] = request.sourceSha256;
            stagedCount++;
        }
      }
      cursor = page.nextCursor;
      await cursors.save(
        HistoricalProducerCursor(
          scope: scope,
          lastId: cursor,
          done: cursor == null,
        ),
      );
      pages++;
      if (cursor == null) {
        completed = true;
        break;
      }
    }
    return (
      summary: HistoricalProducerSummary(
        assessed: assessed,
        staged: stagedCount,
        skippedOwned: skippedOwned,
        retainedConflict: retainedConflict,
        ineligibleByReason: ineligibleByReason,
        completed: completed,
      ),
      output: HistoricalProducerOutput(staged: staged),
    );
  }
}
