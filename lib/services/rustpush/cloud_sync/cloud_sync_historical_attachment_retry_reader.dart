import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_producer.dart';

/// One explicitly confirmed retry pass over the original immutable snapshot.
/// Keeps the snapshot's cursor/page boundaries, but presents only qualified
/// media sources whose owning journal still needs them. No new snapshot,
/// background worker, persistent-cursor reset or remote action occurs here.
final class CloudSyncHistoricalAttachmentRetryReader
    implements HistoricalRowReader {
  const CloudSyncHistoricalAttachmentRetryReader({
    required this.source,
    required this.manifest,
    required this.account,
    required this.validate,
    required this.needsRetryOrRecovery,
    this.nowMs,
  });

  final HistoricalRowReader source;
  final CloudSyncHistoricalSourceManifest manifest;
  final CloudSyncHistoricalAccountBinding account;
  final Future<void> Function() validate;
  final bool Function(CloudSyncHistoricalArchiveRequest) needsRetryOrRecovery;
  final int? nowMs;

  @override
  Future<HistoricalRowPage> readPage({
    String? cursor,
    required int limit,
  }) async {
    if (limit < 1 || limit > 500) {
      throw StateError('cloud_sync_historical_archive_budget_invalid');
    }
    await validate();
    final page = await source.readPage(cursor: cursor, limit: limit);
    await validate();
    if (page.views.length > limit ||
        (page.nextCursor != null && page.nextCursor == cursor)) {
      throw StateError('cloud_sync_historical_archive_page_invalid');
    }
    final retained = <CloudSyncHistoricalRowView>[];
    for (final view in page.views) {
      final assessed = assessHistoricalArchiveRow(
        view,
        manifest,
        account,
        nowMs: nowMs,
        includeMediaSource: true,
      );
      if (assessed is CloudSyncHistoricalArchiveEligible &&
          assessed.request.media != null &&
          needsRetryOrRecovery(assessed.request)) {
        retained.add(view);
      }
    }
    return HistoricalRowPage(
      views: List.unmodifiable(retained),
      nextCursor: page.nextCursor,
    );
  }
}
