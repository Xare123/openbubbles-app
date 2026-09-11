/// Narrow outgoing FaceTime acceptance gate.
///
/// A JoinEvent guid match alone does not prove the recipient joined: the
/// Rust 207 participant path stamps `active: Some(..)` even for our own
/// self-echo join and emits a JoinEvent with `ring: false`. Invitation alone
/// must not count either. Acceptance requires the refreshed exact-session
/// snapshot to show an active non-self participant associated with the call.
/// Missing session or absent local handles stay pending (return false).
bool shouldAcceptOutgoingFaceTimeJoin({
  required String? sessionGroupId,
  required String eventGuid,
  required String eventHandle,
  required Iterable<String> selfHandles,
  required Iterable<FaceTimeOutgoingParticipant> participants,
}) {
  if (sessionGroupId == null || sessionGroupId != eventGuid) return false;
  final knownSelf = selfHandles.where((handle) => handle.isNotEmpty).toSet();
  if (knownSelf.isEmpty) return false;
  if (eventHandle.isEmpty || knownSelf.contains(eventHandle)) return false;
  return participants.any((participant) =>
      participant.handle == eventHandle &&
      !knownSelf.contains(participant.handle) &&
      participant.active);
}

/// Plain participant view so the gate stays unit-testable without the
/// opaque Rust `ConversationParticipant` type.
class FaceTimeOutgoingParticipant {
  const FaceTimeOutgoingParticipant({
    required this.handle,
    required this.active,
  });

  final String handle;

  /// True only when the refreshed session snapshot reports this
  /// participant as actively joined (`FTParticipant.active != null`).
  final bool active;
}
