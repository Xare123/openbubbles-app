class TranscriptInsertion<T> {
  const TranscriptInsertion({
    required this.index,
    required this.item,
  });

  final int index;
  final T item;
}

/// Returns only the items newly present in [next], at their authoritative
/// indices in that already-sorted transcript.
///
/// The result is ordered by ascending index so it can be applied directly to
/// an AnimatedList. For the normal newest-first transcript case, older page
/// items remain tail insertions and do not shift the current reverse-scroll
/// anchor.
List<TranscriptInsertion<T>> transcriptInsertions<T>({
  required Iterable<T> previous,
  required List<T> next,
  required Object Function(T item) identityOf,
}) {
  final knownIdentities = previous.map(identityOf).toSet();
  final insertions = <TranscriptInsertion<T>>[];

  for (var index = 0; index < next.length; index++) {
    final item = next[index];
    if (knownIdentities.add(identityOf(item))) {
      insertions.add(TranscriptInsertion<T>(index: index, item: item));
    }
  }

  return List.unmodifiable(insertions);
}
