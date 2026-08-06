// Apple represents an attachment owned by a message as `at_<part>_<message
// guid>`, and OpenBubbles stores the same identity locally as
// `<message guid>_<part>`.
//
// A message GUID can itself contain underscores, so neither direction may split
// on every separator: the part is the single segment next to the `at_` prefix
// and the whole remaining suffix belongs to the GUID. Anything that does not
// match that exact shape is returned unchanged rather than throwing, because
// these run inside the CloudKit download path where one malformed identifier
// must not abort a message.

/// The two halves of an `at_<part>_<message guid>` identifier.
class AppleOwnedAttachmentGuid {
  const AppleOwnedAttachmentGuid({
    required this.part,
    required this.messageGuid,
  });

  final String part;
  final String messageGuid;
}

/// Splits Apple's `at_<part>_<message guid>` form.
///
/// Returns null when [guid] is not an owned-attachment identifier, so a
/// standalone attachment is never given an invented owner.
AppleOwnedAttachmentGuid? parseAppleOwnedAttachmentGuid(String guid) {
  const prefix = 'at_';
  if (!guid.startsWith(prefix)) return null;
  final remainder = guid.substring(prefix.length);
  final separator = remainder.indexOf('_');
  if (separator <= 0 || separator >= remainder.length - 1) return null;
  final part = remainder.substring(0, separator);
  if (!_isCanonicalDecimal(part)) return null;
  return AppleOwnedAttachmentGuid(
    part: part,
    messageGuid: remainder.substring(separator + 1),
  );
}

bool _isCanonicalDecimal(String value) {
  if (value.isEmpty) return false;
  for (final unit in value.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  // Reject a leading zero so one part cannot have two spellings.
  return value == '0' || value.codeUnitAt(0) != 0x30;
}

/// Converts Apple's `at_<part>_<message guid>` form to `<message guid>_<part>`.
///
/// Returns [guid] unchanged when it is not an owned-attachment identifier.
String convertAppleAttachmentGuid(String guid) {
  final owned = parseAppleOwnedAttachmentGuid(guid);
  if (owned == null) return guid;
  return '${owned.messageGuid}_${owned.part}';
}

/// Converts `<message guid>_<part>` back to Apple's `at_<part>_<message guid>`.
///
/// Returns [guid] unchanged when it carries no trailing decimal part.
String unconvertAppleAttachmentGuid(String guid) {
  final separator = guid.lastIndexOf('_');
  if (separator <= 0 || separator >= guid.length - 1) return guid;
  final part = guid.substring(separator + 1);
  if (!_isCanonicalDecimal(part)) return guid;
  return 'at_${part}_${guid.substring(0, separator)}';
}
