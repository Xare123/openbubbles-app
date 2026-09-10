import 'package:bluebubbles/database/models.dart';

/// A new MMCS upload chooses new encryption material. A journaled retry must
/// preserve its original descriptor even when the local file still exists.
String? retainedAttachmentDescriptorForRetry({
  required bool journaledSubmission,
  required Attachment attachment,
}) {
  if (!journaledSubmission) return null;
  final descriptor = attachment.metadata?['rustpush'];
  if (descriptor is! String || descriptor.isEmpty) {
    throw StateError('imessage_attachment_retry_source_missing');
  }
  return descriptor;
}

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
