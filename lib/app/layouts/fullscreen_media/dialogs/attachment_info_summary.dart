/// Allowlisted attachment information for the ordinary file-information UI.
///
/// Only filename, kind, size, dimensions and date are ever shown. Raw
/// metadata maps, keys, authorization data and signed download URLs are
/// never rendered here. Sizes describe the file; nothing here writes back
/// to a transport descriptor.
library;
class AttachmentInfoSummary {
  const AttachmentInfoSummary({
    this.filename,
    this.kindLabel,
    this.sizeLabel,
    this.dimensionsLabel,
    this.dateLabel,
  });
  final String? filename;
  final String? kindLabel;
  final String? sizeLabel;
  final String? dimensionsLabel;
  final String? dateLabel;
  bool get isEmpty =>
      filename == null &&
      kindLabel == null &&
      sizeLabel == null &&
      dimensionsLabel == null &&
      dateLabel == null;
}
const _kindByMime = <String, String>{
  'image/jpeg': 'JPEG image',
  'image/png': 'PNG image',
  'image/heic': 'HEIC image',
  'image/gif': 'GIF image',
  'image/webp': 'WebP image',
  'video/mp4': 'MP4 video',
  'video/quicktime': 'QuickTime video',
  'audio/mpeg': 'MP3 audio',
  'application/pdf': 'PDF document',
};
const _kindByUti = <String, String>{
  'public.jpeg': 'JPEG image',
  'public.png': 'PNG image',
  'public.heic': 'HEIC image',
  'com.apple.quicktime-movie': 'QuickTime video',
};
String attachmentKindLabel(String? mimeType, String? uti) {
  final mime = mimeType?.trim().toLowerCase();
  if (mime != null && mime.isNotEmpty) {
    final exact = _kindByMime[mime];
    if (exact != null) return exact;
    if (mime.startsWith('image/')) return 'Image';
    if (mime.startsWith('video/')) return 'Video';
    if (mime.startsWith('audio/')) return 'Audio';
    if (mime.startsWith('text/')) return 'Text';
  }
  final id = uti?.trim();
  if (id != null && id.isNotEmpty) {
    final exact = _kindByUti[id];
    if (exact != null) return exact;
  }
  return 'File';
}
String formatAttachmentBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
String formatAttachmentDate(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
AttachmentInfoSummary summarizeAttachment({
  String? transferName,
  String? mimeType,
  String? uti,
  int? advertisedBytes,
  int? localBytes,
  int? width,
  int? height,
  DateTime? dateCreated,
}) {
  final name = transferName?.trim();
  final size = localBytes ?? advertisedBytes;
  final hasDimensions = width != null && height != null && width > 0 && height > 0;
  return AttachmentInfoSummary(
    filename: name == null || name.isEmpty ? null : name,
    kindLabel: mimeType == null && uti == null ? null : attachmentKindLabel(mimeType, uti),
    sizeLabel: size == null || size < 0 ? null : formatAttachmentBytes(size),
    dimensionsLabel: hasDimensions ? '${width}x$height' : null,
    dateLabel: dateCreated == null ? null : formatAttachmentDate(dateCreated),
  );
}
List<MapEntry<String, String>> attachmentInfoRows(AttachmentInfoSummary summary) {
  final rows = <String, String?>{
    'File name': summary.filename,
    'Kind': summary.kindLabel,
    'Size': summary.sizeLabel,
    'Dimensions': summary.dimensionsLabel,
    'Date': summary.dateLabel,
  };
  final shown = <MapEntry<String, String>>[];
  for (final entry in rows.entries) {
    final value = entry.value;
    if (value != null) shown.add(MapEntry(entry.key, value));
  }
  return shown;
}
