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

  static Set<K> findConflictedOwners<K, V>(
    Map<K, Iterable<V>> identitiesByOwner,
  ) {
    final identityOwners = <V, K>{};
    final conflicted = <K>{};
    for (final entry in identitiesByOwner.entries) {
      for (final identity in entry.value) {
        final previous = identityOwners[identity];
        if (previous == null) {
          identityOwners[identity] = entry.key;
        } else if (previous != entry.key) {
          conflicted.addAll([previous, entry.key]);
        }
      }
    }
    return conflicted;
  }

  static T? selectUniqueCandidate<T>(
    Iterable<T> candidates, {
    required bool Function(T candidate) isExact,
  }) {
    final all = candidates.toList(growable: false);
    final exact = all.where(isExact).toList(growable: false);
    final eligible = exact.isEmpty ? all : exact;
    return eligible.length == 1 ? eligible.single : null;
  }

  static Future<int> recover<T>({
    required int Function() unresolvedCount,
    required Future<LegacyCloudChatRepairPage<T>> Function(
      List<int>? continuationToken,
    )
    fetchPage,
    required Future<void> Function(String recordId, T value) applyRecord,
  }) async {
    var remaining = unresolvedCount();
    List<int>? continuationToken;
    var state = 0;
    var pageNumber = 0;

    while (remaining != 0 && state != 3) {
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

      remaining = unresolvedCount();
      if (remaining == 0) return 0;

      if (page.state != 3 &&
          _tokensEqual(continuationToken, page.continuationToken)) {
        throw StateError(
          'Stopped legacy CloudKit chat repair because its token made no progress',
        );
      }
      continuationToken = page.continuationToken;
      state = page.state;
    }

    return remaining;
  }

  static bool _tokensEqual(List<int>? left, List<int> right) {
    if (left == null || left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
