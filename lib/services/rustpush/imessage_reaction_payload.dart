import 'package:bluebubbles/src/rust/api/api.dart' as api;

/// Builds the live IDS tapback payload without changing its target semantics.
/// A missing part targets the whole message; zero explicitly targets part zero.
api.Message buildIMessageReactionPayload({
  required String parentGuid,
  required int? parentPart,
  required String parentText,
  required api.Reaction reaction,
  required bool enable,
  api.ShareProfileMessage? embeddedProfile,
}) {
  if (parentGuid.isEmpty || (parentPart != null && parentPart < 0)) {
    throw StateError('imessage_reaction_target_invalid');
  }
  return api.Message.react(
    api.ReactMessage(
      toUuid: parentGuid,
      toPart: parentPart,
      toText: parentText,
      reaction: api.ReactMessageType.react(reaction: reaction, enable: enable),
      embeddedProfile: embeddedProfile,
    ),
  );
}
