import 'package:bluebubbles/helpers/ui/message_widget_helpers.dart';
import 'package:bluebubbles/database/global/message_part.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuple/tuple.dart';

void main() {
  group('safeMessageSubstring', () {
    test('rejects missing text and malformed ranges', () {
      expect(safeMessageSubstring(null, [0, 1]), isNull);
      expect(safeMessageSubstring('hello', []), isNull);
      expect(safeMessageSubstring('hello', [3]), isNull);
    });

    test('clamps cloud annotation ranges to available text', () {
      expect(safeMessageSubstring('hello', [-4, 2]), 'he');
      expect(safeMessageSubstring('hello', [3, 20]), 'lo');
      expect(safeMessageSubstring('hello', [5, 20]), isNull);
      expect(safeMessageSubstring('hello', [4, 2]), isNull);
    });

    test('returns valid annotated text', () {
      expect(safeMessageSubstring('hello world', [6, 11]), 'world');
    });
  });

  group('messageUrlMatches', () {
    test('keeps characters after a literal plus in the clickable URL', () {
      const url = 'https://example.com/path?query=alpha+beta&next=1';

      final matches = messageUrlMatches('Open $url please');

      expect(matches, hasLength(1));
      expect(matches.single.group(0), url);
    });

    test('keeps separate same-host URLs intact when both contain pluses', () {
      const first = 'https://example.com/a?value=one+two';
      const second = 'https://example.com/b?value=three+four';

      final matches = messageUrlMatches('$first and $second');

      expect(matches.map((match) => match.group(0)), [first, second]);
    });

    test('keeps all standard URI sub-delimiters inside the link', () {
      const url =
          r"https://example.com/path!$&'()*+,;=value?q=one+two%2Bthree";

      final matches = messageUrlMatches('Open $url please');

      expect(matches, hasLength(1));
      expect(matches.single.group(0), url);
    });

    test('accepts modern top-level domains longer than six characters', () {
      const url = 'https://example.technology/path';

      final matches = messageUrlMatches(url);

      expect(matches, hasLength(1));
      expect(matches.single.group(0), url);
    });

    test('keeps the full URL clickable when ML Kit returns a shorter range',
        () {
      const url = 'https://example.com/path?query=alpha+beta&next=1';
      final plusIndex = url.indexOf('+');
      final annotations = [Annotation(range: [0, url.length])];

      markEnrichedMessageRange(
          annotations, const Tuple3('link', [0, url.length], null));
      markEnrichedMessageRange(
          annotations, Tuple3('link', [0, plusIndex], null));
      annotations.sort((a, b) => a.range[0].compareTo(b.range[0]));

      expect(annotations.map((annotation) => annotation.range), [
        [0, plusIndex],
        [plusIndex, url.length],
      ]);
      expect(
        annotations.every(
          (annotation) => annotation.renderExtras.first.item1 == 'link',
        ),
        isTrue,
      );
    });
  });
}
