/// A validated CloudKit reference to the local parent of an associated message.
///
/// Apple encodes the reference as `p:<part>/<message-guid>`. The raw envelope
/// is accepted only at the parsing boundary and is never retained. In
/// particular, diagnostic rendering must not reveal the message GUID.
final class CloudAssociatedMessageParentReference {
  const CloudAssociatedMessageParentReference._({
    required this.part,
    required this.localMessageGuid,
  });

  /// A conservative bound that prevents an untrusted CloudKit field from
  /// becoming an unbounded local identifier.
  static const int maximumGuidCodeUnits = 512;
  static const int _maximumPartDigits = 19;

  final int part;
  final String localMessageGuid;

  static CloudAssociatedMessageParentReference parse(String encoded) {
    const prefix = 'p:';
    const separatorLength = 1;
    const maximumEncodedCodeUnits =
        prefix.length +
        _maximumPartDigits +
        separatorLength +
        maximumGuidCodeUnits;
    if (encoded.length > maximumEncodedCodeUnits ||
        !encoded.startsWith(prefix)) {
      throw const CloudAssociatedMessageParentReferenceFormatException();
    }

    final separator = encoded.indexOf('/', prefix.length);
    if (separator == -1 ||
        encoded.indexOf('/', separator + 1) != -1 ||
        separator == prefix.length) {
      throw const CloudAssociatedMessageParentReferenceFormatException();
    }

    final encodedPart = encoded.substring(prefix.length, separator);
    if (encodedPart.length > _maximumPartDigits ||
        !_isAsciiDecimal(encodedPart)) {
      throw const CloudAssociatedMessageParentReferenceFormatException();
    }
    final part = int.tryParse(encodedPart);
    if (part == null || part < 0) {
      throw const CloudAssociatedMessageParentReferenceFormatException();
    }

    final guid = encoded.substring(separator + 1);
    if (!_isValidGuid(guid)) {
      throw const CloudAssociatedMessageParentReferenceFormatException();
    }

    return CloudAssociatedMessageParentReference._(
      part: part,
      localMessageGuid: guid,
    );
  }

  static bool _isAsciiDecimal(String value) {
    for (final codeUnit in value.codeUnits) {
      if (codeUnit < 0x30 || codeUnit > 0x39) return false;
    }
    return value.isNotEmpty;
  }

  static bool _isValidGuid(String value) {
    if (value.isEmpty || value.length > maximumGuidCodeUnits) return false;
    for (final codeUnit in value.codeUnits) {
      if (codeUnit <= 0x20 ||
          (codeUnit >= 0x7f && codeUnit <= 0x9f) ||
          codeUnit == 0x2028 ||
          codeUnit == 0x2029) {
        return false;
      }
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is CloudAssociatedMessageParentReference &&
      other.part == part &&
      other.localMessageGuid == localMessageGuid;

  @override
  int get hashCode => Object.hash(part, localMessageGuid);

  @override
  String toString() => 'CloudAssociatedMessageParentReference(redacted)';
}

/// A deliberately redacted parse failure.
///
/// A single safe code is used for every rejected shape so logs cannot expose
/// either the raw CloudKit value or which portion of it was accepted.
final class CloudAssociatedMessageParentReferenceFormatException
    implements FormatException {
  const CloudAssociatedMessageParentReferenceFormatException();

  static const String safeCode = 'invalid_associated_message_parent_reference';

  @override
  String get message => safeCode;

  @override
  int? get offset => null;

  @override
  Object? get source => null;

  @override
  String toString() =>
      'CloudAssociatedMessageParentReferenceFormatException($safeCode)';
}
