/// One page from a read-only legacy CloudKit chat recovery scan.
class LegacyCloudChatRepairPage<T> {
  const LegacyCloudChatRepairPage({
    required this.continuationToken,
    required this.items,
    required this.state,
  });

  final List<int> continuationToken;
  final Map<String, T?> items;
  final int state;
}

/// Replays the chat zone from its beginning when a message page references a
/// chat that is absent locally. The caller's persisted chat cursor is never
/// read or changed, so an interrupted repair remains safe to repeat.
class LegacyCloudChatRepair {
  static const int maxPages = 1000;

  static Future<Set<String>> recover<T>({
    required Set<String> unresolvedReferences,
    required bool Function(String reference) isResolved,
    required Future<LegacyCloudChatRepairPage<T>> Function(
      List<int>? continuationToken,
    )
    fetchPage,
    required Future<void> Function(String recordId, T value) applyRecord,
  }) async {
    final unresolved = Set<String>.of(unresolvedReferences)
      ..removeWhere(isResolved);
    List<int>? continuationToken;
    var state = 0;
    var pageNumber = 0;

    while (unresolved.isNotEmpty && state != 3) {
      pageNumber++;
      if (pageNumber > maxPages) {
        throw StateError(
          'Stopped legacy CloudKit chat repair after $maxPages pages',
        );
      }

      final page = await fetchPage(continuationToken);
      for (final item in page.items.entries) {
        final value = item.value;
        if (value != null) await applyRecord(item.key, value);
      }

      unresolved.removeWhere(isResolved);
      if (unresolved.isEmpty) return unresolved;

      if (page.state != 3 &&
          _tokensEqual(continuationToken, page.continuationToken)) {
        throw StateError(
          'Stopped legacy CloudKit chat repair because its token made no progress',
        );
      }
      continuationToken = page.continuationToken;
      state = page.state;
    }

    return unresolved;
  }

  static bool _tokensEqual(List<int>? left, List<int> right) {
    if (left == null || left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
