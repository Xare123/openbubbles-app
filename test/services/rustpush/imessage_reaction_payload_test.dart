import 'package:bluebubbles/services/rustpush/imessage_reaction_payload.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  api.ReactMessage build({
    int? part,
    bool enable = true,
    String guid = 'parent',
  }) =>
      (buildIMessageReactionPayload(
                parentGuid: guid,
                parentPart: part,
                parentText: 'parent text',
                reaction: const api.Reaction.like(),
                enable: enable,
              )
              as api.Message_React)
          .field0;

  test('partless tapback remains whole-message rather than part zero', () {
    final partless = build();
    final zero = build(part: 0);
    expect(partless.toPart, isNull);
    expect(zero.toPart, 0);
    expect(partless.toUuid, zero.toUuid);
    expect(partless.toText, 'parent text');
  });

  test('add and remove preserve the same exact parent and part', () {
    final add = build(part: 3);
    final remove = build(part: 3, enable: false);
    expect(remove.toUuid, add.toUuid);
    expect(remove.toPart, add.toPart);
    expect((add.reaction as api.ReactMessageType_React).enable, isTrue);
    expect((remove.reaction as api.ReactMessageType_React).enable, isFalse);
    expect(
      (remove.reaction as api.ReactMessageType_React).reaction,
      (add.reaction as api.ReactMessageType_React).reaction,
    );
  });

  test('invalid target fails without exposing the target in an error', () {
    expect(() => build(guid: ''), throwsStateError);
    expect(
      () => build(part: -1),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'safe error',
          'imessage_reaction_target_invalid',
        ),
      ),
    );
  });
}
