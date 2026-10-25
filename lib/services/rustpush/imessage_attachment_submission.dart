import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

/// Preserve a supported single-attachment body on both initial submission and
/// retry. The caller snapshots the body once and supplies fresh native-owned
/// attachment material for each attempt. This helper performs no native calls.
api.MessageParts buildIMessageAttachmentParts({
  required AttributedBody? body,
  required String attachmentGuid,
  required api.Attachment wireAttachment,
  required api.TextFormat Function(Attributes) textFormat,
}) {
  if (body == null || (body.string.isEmpty && body.runs.isEmpty)) {
    return api.MessageParts(field0: [
      api.IndexedMessagePart(part_: api.MessagePart.attachment(wireAttachment)),
    ]);
  }
  var cursor = 0;
  var attachments = 0;
  final parts = <api.IndexedMessagePart>[];
  for (final run in body.runs) {
    final attributes = run.attributes;
    if (attributes == null || run.range.length != 2 ||
        run.range.first != cursor || run.range.last <= 0 ||
        cursor + run.range.last > body.string.length) {
      throw StateError('imessage_attachment_body_invalid');
    }
    final text = body.string.substring(cursor, cursor + run.range.last);
    if (run.isAttachment) {
      if (++attachments != 1 || attributes.attachmentGuid != attachmentGuid ||
          run.range.last != 1 || (text != '\uFFFC' && text != ' ')) {
        throw StateError('imessage_attachment_body_invalid');
      }
      parts.add(api.IndexedMessagePart(part_: api.MessagePart.attachment(wireAttachment)));
    } else {
      parts.add(api.IndexedMessagePart(part_: run.hasMention
          ? api.MessagePart.mention(attributes.mention!, text)
          : api.MessagePart.text(text, textFormat(attributes))));
    }
    cursor += run.range.last;
  }
  if (cursor != body.string.length || attachments != 1) {
    throw StateError('imessage_attachment_body_invalid');
  }
  return api.MessageParts(field0: parts);
}

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
