import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reply thread assembly', () {
    test('includes the originator when it loads before its replies', () {
      final messages = ChatMessages();
      final originator = Message(guid: 'thread-1', text: 'originator');
      final reply = Message(
        guid: 'reply-1',
        text: 'reply',
        threadOriginatorGuid: 'thread-1',
        threadOriginatorPart: '0',
      );

      // Normal ordering: the originator is older, so it loads first.
      messages.addMessages([originator]);
      messages.addMessages([reply]);

      expect(
        messages.threads('thread-1', 0).map((m) => m.guid),
        containsAll(<String>['thread-1', 'reply-1']),
      );
    });

    test('includes the originator when it loads after its replies', () {
      final messages = ChatMessages();
      final originator = Message(guid: 'thread-2', text: 'originator');
      final reply = Message(
        guid: 'reply-2',
        text: 'reply',
        threadOriginatorGuid: 'thread-2',
        threadOriginatorPart: '0',
      );

      messages.addMessages([reply]);
      messages.addMessages([originator]);

      expect(
        messages.threads('thread-2', 0).map((m) => m.guid),
        containsAll(<String>['thread-2', 'reply-2']),
      );
    });

    test('omits the originator when returnOriginator is false', () {
      final messages = ChatMessages();
      final originator = Message(guid: 'thread-3', text: 'originator');
      final reply = Message(
        guid: 'reply-3',
        text: 'reply',
        threadOriginatorGuid: 'thread-3',
        threadOriginatorPart: '0',
      );

      messages.addMessages([originator, reply]);

      final guids =
          messages.threads('thread-3', 0, returnOriginator: false).map((m) => m.guid).toList();
      expect(guids, contains('reply-3'));
      expect(guids, isNot(contains('thread-3')));
    });
  });

  group('normalizedThreadPart', () {
    test('parses a single digit part', () {
      expect(Message(guid: 'a', threadOriginatorPart: '3:0:0').normalizedThreadPart, 3);
    });

    test('parses a multi-digit part instead of truncating', () {
      expect(Message(guid: 'b', threadOriginatorPart: '12:0:0').normalizedThreadPart, 12);
    });

    test('defaults to 0 when the part is null', () {
      expect(Message(guid: 'c').normalizedThreadPart, 0);
    });

    test('does not throw on a non-numeric part', () {
      expect(Message(guid: 'd', threadOriginatorPart: 'x:0:0').normalizedThreadPart, 0);
    });
  });
}
