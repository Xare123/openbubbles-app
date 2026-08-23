import 'package:bluebubbles/database/models.dart';

/// Builds the ordered set of images and videos shown by the fullscreen viewer.
///
/// The selected attachment is retained even when it has not yet reached the
/// conversation's loaded-message cache. GUID-backed entries are deduplicated
/// without changing the conversation's existing media order.
List<Attachment> buildFullscreenMediaList(
  Iterable<Attachment> candidates,
  Attachment selected,
) {
  final media = <Attachment>[];
  final guids = <String>{};

  void add(Attachment attachment) {
    if (media.contains(attachment)) {
      return;
    }
    if (attachment.mimeStart != 'image' && attachment.mimeStart != 'video') {
      return;
    }
    final guid = attachment.guid;
    if (guid != null && !guids.add(guid)) {
      return;
    }
    media.add(attachment);
  }

  for (final attachment in candidates) {
    add(attachment);
  }
  add(selected);

  // A malformed or not-yet-hydrated MIME type must not make the attachment
  // that opened the viewer disappear.
  if (!media.contains(selected) &&
      (selected.guid == null || !media.any((attachment) => attachment.guid == selected.guid))) {
    media.add(selected);
  }
  return media;
}
