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

/// Exact-GUID ownership. Fixtures may supply sets; production overrides resolve
/// to query the current owning journals before each row. Neither skipOwned nor
/// an existing journal means that CloudKit has confirmed an upload.
abstract class HistoricalOwnershipRegistry {
  Set<String> get ownedGuids => const {};
  Set<String> get conflictGuids => const {};

  CloudSyncHistoricalDedupeVerdict resolve(
    CloudSyncHistoricalArchiveRequest request,
  ) => resolveHistoricalDedupe(
    guid: request.guid,
    ownedGuids: ownedGuids,
    conflictGuids: conflictGuids,
  );
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

/// Callback that durably stages and adopts one canonical source in the
/// native protected store before the producer cursor may advance past it.
/// A successful return means durably journaled with its native lease
/// committed, not remotely uploaded. Must be idempotent: re-presenting
/// identical canonical bytes is a no-op success, because a resumed scan
/// re-encodes and re-presents rows the journal already holds. Conflicting
/// bytes for an adopted key must throw. Production binds the native
/// stage-and-adopt path; tests bind a durable file-backed double.
typedef HistoricalStageAndAdopt =
    Future<StagedHistoricalSource> Function(
      CloudSyncHistoricalArchiveRequest request,
      List<int> canonicalBytes,
    );

/// Runs one bounded pass over historical rows. Durable staging happens
/// only behind the injected stage-and-adopt callback, which the parent
/// wires to native protected storage; this file never stores bytes itself.
class CloudSyncHistoricalProducer {
  const CloudSyncHistoricalProducer({
    required this.reader,
    required this.registry,
    required this.cursors,
    required this.manifest,
    required this.account,
    required this.readCurrentRow,
    required this.stageAndAdopt,
    this.pageLimit = 50,
    this.maxPages = 20,
    this.nowMs,
    this.shouldContinue,
    this.onProgress,
  });

  final HistoricalRowReader reader;
  final HistoricalOwnershipRegistry registry;
  final HistoricalCursorStore cursors;
  final CloudSyncHistoricalSourceManifest manifest;
  final CloudSyncHistoricalAccountBinding account;

  /// Re-reads the complete current row by GUID at stage time. The
  /// producer re-runs eligibility over this view and recomputes the
  /// canonical source binding, so any drift in route, time, origin,
  /// sender, direction, chat, or text throws instead of staging.
  final Future<CloudSyncHistoricalRowView?> Function(String guid)
  readCurrentRow;

  /// Single stage-and-adopt boundary. The byte-store/adoptStaged split is
  /// gone: native protected sources cannot reopen before their exact
  /// lease commits, so staging and durable adoption must happen together
  /// behind one callback whose result the producer validates.
  final HistoricalStageAndAdopt stageAndAdopt;

  final int pageLimit;
  final int maxPages;
  final int? nowMs;

  /// Pause at admission boundaries, never cancel an in-flight stage/readback.
  /// An interrupted page keeps its old cursor and replays idempotently later.
  final bool Function()? shouldContinue;

  /// Counts for this invocation only. They do not prove remote confirmation.
  final void Function(HistoricalProducerSummary)? onProgress;

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
    HistoricalProducerSummary summary() => HistoricalProducerSummary(
      assessed: assessed,
      staged: stagedCount,
      skippedOwned: skippedOwned,
      retainedConflict: retainedConflict,
      ineligibleByReason: Map.unmodifiable(ineligibleByReason),
      completed: completed,
    );
    scan:
    while (pages < maxPages) {
      if (shouldContinue?.call() == false) break;
      final page = await reader.readPage(cursor: cursor, limit: pageLimit);
      if (page.views.length > pageLimit ||
          (page.nextCursor != null && page.nextCursor == cursor)) {
        throw StateError('cloud_sync_historical_archive_page_invalid');
      }
      for (final view in page.views) {
        if (shouldContinue?.call() == false) break scan;
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
          onProgress?.call(summary());
          continue;
        }
        final request = assessment.request;
        if (stagedGuids.containsKey(request.guid)) {
          if (stagedGuids[request.guid] != request.sourceSha256) {
            throw StateError('cloud_sync_historical_archive_source_conflict');
          }
          skippedOwned++;
          onProgress?.call(summary());
          continue;
        }
        switch (registry.resolve(request)) {
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
            // Reading/validating the source can await native identity. A pause
            // requested during that await must not admit another operation.
            if (shouldContinue?.call() == false) {
              assessed--;
              break scan;
            }
            final encoded = encodeHistoricalSource(
              request: request,
              currentRow: current,
              manifest: manifest,
              account: account,
              nowMs: nowMs,
            );
            // Snapshot expectations before the injected callback runs. The
            // callback receives the same unmodifiable bytes but must never
            // be trusted to preserve them; validation below uses only these
            // pre-await values.
            final expectedSha256 = historicalBytesSha256(
              encoded.canonicalBytes,
            );
            final expectedLength = encoded.canonicalBytes.length;
            final sealed = await stageAndAdopt(request, encoded.canonicalBytes);
            _requireSealedMatches(
              request,
              expectedSha256,
              expectedLength,
              sealed,
            );
            staged.add(sealed);
            stagedGuids[request.guid] = request.sourceSha256;
            stagedCount++;
        }
        onProgress?.call(summary());
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
      summary: summary(),
      output: HistoricalProducerOutput(staged: staged),
    );
  }
}

void _requireSealedMatches(
  CloudSyncHistoricalArchiveRequest request,
  String expectedSha256,
  int expectedLength,
  StagedHistoricalSource sealed,
) {
  if (sealed.key != request.sourceSha256 ||
      sealed.guid != request.guid ||
      sealed.byteLength != expectedLength ||
      sealed.sha256 != expectedSha256) {
    throw StateError('cloud_sync_historical_archive_source_conflict');
  }
}
