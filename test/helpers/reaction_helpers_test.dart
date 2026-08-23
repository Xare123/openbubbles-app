import 'package:bluebubbles/helpers/ui/reaction_helpers.dart';
import 'package:bluebubbles/database/io/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReactionTypes.fromAssociatedMessageType', () {
    test('maps every applied reaction index', () {
      final names = ReactionTypes.toList();
      for (var index = 0; index < names.length; index++) {
        expect(
          ReactionTypes.fromAssociatedMessageType(2000 + index),
          names[index],
        );
      }
    });

    test('maps every removed reaction index with a leading dash', () {
      final names = ReactionTypes.toList();
      for (var index = 0; index < names.length; index++) {
        expect(
          ReactionTypes.fromAssociatedMessageType(3000 + index),
          '-${names[index]}',
        );
      }
    });

    test('returns null instead of throwing on an unknown type', () {
      // Indexing ReactionTypes.toList() directly raised a RangeError for these,
      // which aborted the CloudKit download of the whole message.
      for (final associatedMessageType in <int>[
        2000 + 8,
        2999,
        3000 + 8,
        3999,
        0,
        1,
        1999,
        4000,
      ]) {
        expect(
          ReactionTypes.fromAssociatedMessageType(associatedMessageType),
          isNull,
          reason: 'expected $associatedMessageType to have no reaction name',
        );
      }
    });

    test('covers the full 2000-3999 range without throwing', () {
      for (var type = 2000; type < 4000; type++) {
        expect(
          () => ReactionTypes.fromAssociatedMessageType(type),
          returnsNormally,
          reason: 'associatedMessageType $type threw',
        );
      }
    });
  });

  group('getUniqueReactionMessages', () {
    test('ignores legacy rows with an unknown reaction type', () {
      final messages = <Message>[
        Message(
          guid: 'unknown-reaction',
          dateCreated: DateTime.utc(2026),
          isFromMe: true,
        ),
        Message(
          guid: 'known-reaction',
          dateCreated: DateTime.utc(2026, 1, 2),
          isFromMe: false,
          handleId: 1,
          associatedMessageType: ReactionTypes.LIKE,
        ),
      ];

      expect(
        getUniqueReactionMessages(messages).map((message) => message.guid),
        <String?>['known-reaction'],
      );
    });
  });
}
