import 'package:bluebubbles/app/layouts/conversation_view/pages/transcript_pagination.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> applyInsertions(
  List<String> previous,
  List<TranscriptInsertion<String>> insertions,
) {
  final rendered = List<String>.from(previous);
  for (final insertion in insertions) {
    rendered.insert(insertion.index, insertion.item);
  }
  return rendered;
}

void main() {
  test(
      'older page items append at sorted indices without shifting the visible anchor',
      () {
    const previous = ['newest', 'anchor', 'loaded-boundary'];
    const next = [
      'newest',
      'anchor',
      'loaded-boundary',
      'older-1',
      'older-2',
    ];

    final insertions = transcriptInsertions<String>(
      previous: previous,
      next: next,
      identityOf: (item) => item,
    );

    expect(insertions.map((insertion) => insertion.index), [3, 4]);
    expect(
        insertions.map((insertion) => insertion.item), ['older-1', 'older-2']);
    expect(applyInsertions(previous, insertions), next);
    expect(next.indexOf('anchor'), previous.indexOf('anchor'));
  });

  test(
      'interleaved timestamps use authoritative indices and preserve message order',
      () {
    const previous = ['message-50', 'message-40', 'message-30'];
    const next = [
      'message-50',
      'message-45',
      'message-40',
      'message-30',
      'message-20',
    ];

    final insertions = transcriptInsertions<String>(
      previous: previous,
      next: next,
      identityOf: (item) => item,
    );

    expect(insertions.map((insertion) => insertion.index), [1, 4]);
    expect(applyInsertions(previous, insertions), next);
  });

  test('an existing identity with refreshed data is not inserted twice', () {
    const previous = [
      (id: 'message-2', revision: 1),
      (id: 'message-1', revision: 1),
    ];
    const next = [
      (id: 'message-2', revision: 2),
      (id: 'message-1', revision: 1),
      (id: 'message-0', revision: 1),
    ];

    final insertions = transcriptInsertions<({String id, int revision})>(
      previous: previous,
      next: next,
      identityOf: (item) => item.id,
    );

    expect(insertions, hasLength(1));
    expect(insertions.single.index, 2);
    expect(insertions.single.item.id, 'message-0');
  });
}
