import 'package:bluebubbles/database/models.dart';

/// A send can finish IDS submission before local reflection/forwarding fails.
/// Keep its already-selected ID in the retry slot, not a fresh generated ID.
/// This neither claims IDS success nor creates a CloudKit upload origin.
void retainAttachmentSubmissionForRetry({
  required Chat chat,
  required Message message,
  required String submittedGuid,
}) {
  if (message.guid != submittedGuid || message.stagingGuid != null) return;
  message.stagingGuid = submittedGuid;
  message.save(chat: chat, throwOnUniqueViolation: true);
}
