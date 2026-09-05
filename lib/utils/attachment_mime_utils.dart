import 'package:mime_type/mime_type.dart';

const Map<String, String> _documentMimeTypesByUti = <String, String>{
  'com.adobe.pdf': 'application/pdf',
  'public.pdf': 'application/pdf',
  'org.openxmlformats.wordprocessingml.document':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'com.microsoft.word.doc': 'application/msword',
  'com.microsoft.word.dot': 'application/msword',
  'org.openxmlformats.spreadsheetml.sheet':
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'com.microsoft.excel.xls': 'application/vnd.ms-excel',
  'com.microsoft.excel.xlw': 'application/vnd.ms-excel',
  'org.openxmlformats.presentationml.presentation':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'com.microsoft.powerpoint.ppt': 'application/vnd.ms-powerpoint',
  'com.microsoft.powerpoint.pps': 'application/vnd.ms-powerpoint',
  'public.plain-text': 'text/plain',
  'public.rtf': 'application/rtf',
  'public.zip-archive': 'application/zip',
};

const Map<String, String> _conciseAttachmentTypeLabels = <String, String>{
  'application/pdf': 'PDF',
  'application/msword': 'DOC',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'DOCX',
  'application/vnd.ms-excel': 'XLS',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'XLSX',
  'application/vnd.ms-powerpoint': 'PPT',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'PPTX',
  'application/rtf': 'RTF',
  'application/zip': 'ZIP',
  'text/plain': 'TXT',
};

String? resolveAttachmentMimeType(
  String name,
  String? path, {
  String? uti,
  String? declaredMimeType,
}) {
  final declared = declaredMimeType?.trim();
  final inferredFromFile = mime(name) ?? (path == null ? null : mime(path));
  final normalizedUti = uti?.trim().toLowerCase();
  final inferredFromUti = normalizedUti == null || normalizedUti.isEmpty
      ? null
      : _documentMimeTypesByUti[normalizedUti];
  if (declared != null &&
      declared.isNotEmpty &&
      declared.toLowerCase() != 'application/octet-stream') {
    return declared;
  }
  return inferredFromFile ?? inferredFromUti ?? (declared?.isEmpty ?? true ? null : declared);
}

String conciseAttachmentTypeLabel(String name, String? mimeType) {
  final mimeLabel = _conciseAttachmentTypeLabels[mimeType?.toLowerCase()];
  if (mimeLabel != null) return mimeLabel;
  final separator = name.lastIndexOf(RegExp(r'[/\\]'));
  final dot = name.lastIndexOf('.');
  if (dot > separator && dot < name.length - 1) {
    final extension = name.substring(dot + 1);
    if (RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(extension)) {
      return extension.toUpperCase();
    }
  }
  return 'FILE';
}
