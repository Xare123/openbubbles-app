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
  return describeOutgoingFaceTimeJoin(
    sessionGroupId: sessionGroupId,
    eventGuid: eventGuid,
    eventHandle: eventHandle,
    selfHandles: selfHandles,
    participants: participants,
  ) == FaceTimeOutgoingAcceptanceVerdict.accepted;
}

/// PII-free acceptance verdict for live diagnostics. Only the outcome and
/// participant counts may leave the call site; handles and UUIDs never do.
/// A rejected remote acceptance otherwise leaves no trace between JoinEvent
/// and the timeout cancel, which reads exactly like "remote ends on accept".
enum FaceTimeOutgoingAcceptanceVerdict {
  accepted,
  snapshotMissing,
  guidMismatch,
  noSelfHandles,
  eventFromSelf,
  noActiveRemote,
}

FaceTimeOutgoingAcceptanceVerdict describeOutgoingFaceTimeJoin({
  required String? sessionGroupId,
  required String eventGuid,
  required String eventHandle,
  required Iterable<String> selfHandles,
  required Iterable<FaceTimeOutgoingParticipant> participants,
}) {
  if (sessionGroupId == null) {
    return FaceTimeOutgoingAcceptanceVerdict.snapshotMissing;
  }
  if (sessionGroupId != eventGuid) {
    return FaceTimeOutgoingAcceptanceVerdict.guidMismatch;
  }
  final knownSelf = selfHandles.where((handle) => handle.isNotEmpty).toSet();
  if (knownSelf.isEmpty) {
    return FaceTimeOutgoingAcceptanceVerdict.noSelfHandles;
  }
  if (eventHandle.isEmpty || knownSelf.contains(eventHandle)) {
    return FaceTimeOutgoingAcceptanceVerdict.eventFromSelf;
  }
  final remoteActive = participants.any((participant) =>
      participant.handle == eventHandle &&
      !knownSelf.contains(participant.handle) &&
      participant.active);
  return remoteActive
      ? FaceTimeOutgoingAcceptanceVerdict.accepted
      : FaceTimeOutgoingAcceptanceVerdict.noActiveRemote;
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
