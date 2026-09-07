import 'package:bluebubbles/database/models.dart';

/// The first text needs an unsent local row before IDS can emit SendConfirm.
/// Do not reflect it before sending: reflection can perform account/chat work.
/// Preserve formatting as supplied; the journal decides what it can upload.
Message createPendingInitialIMessage(
  AttributedBody body, {
  required DateTime createdAt,
  required Handle sender,
}) {
  final snapshot = AttributedBody.fromMap(body.toMap());
  return Message(
    text: snapshot.string,
    attributedBody: [snapshot],
    dateCreated: createdAt,
    isFromMe: true,
    handle: sender,
  )..generateTempGuid();
}
