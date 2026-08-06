/// A validated CloudKit reference to the local parent of an associated message.
///
/// Apple encodes the reference as `p:<part>/<message-guid>` when the reaction
/// targets a specific part, `bp:<part>/<message-guid>` for a bubble or tapback
/// message, and as a bare `<message-guid>` when it targets the message as a
/// whole. The raw envelope is accepted only at the parsing
/// boundary and is never retained. In particular, diagnostic rendering must not
/// reveal the message GUID.
final class CloudAssociatedMessageParentReference {
  const CloudAssociatedMessageParentReference._({
    required this.part,
    required this.localMessageGuid,
  });

  /// A conservative bound that prevents an untrusted CloudKit field from
  /// becoming an unbounded local identifier.
  static const int maximumGuidCodeUnits = 512;
  static const int _maximumPartDigits = 19;

  /// Null when Apple sent a bare GUID, meaning the reaction targets the whole
  /// message rather than one of its parts.
  final int? part;
  final String localMessageGuid;

  static CloudAssociatedMessageParentReference parse(String encoded) {
    const prefix = 'p:';
    const bubblePrefix = 'bp:';
    const separatorLength = 1;
    // Bound against the longer prefix so a maximal `bp:` value is not rejected
    // one code unit early.
    const maximumEncodedCodeUnits =
        bubblePrefix.length +
        _maximumPartDigits +
        separatorLength +
        maximumGuidCodeUnits;
    if (encoded.length > maximumEncodedCodeUnits) {
      throw const CloudAssociatedMessageParentReferenceFormatException();
    }

    // Apple uses `p:` for an ordinary message part and `bp:` for a bubble or
    // tapback message. Both name a parent GUID and a part, and this app's JSON
    // ingestion path has always stripped `bp:` for that reason. `bpdi:` is the
    // balloon payload reference and is deliberately not accepted.
    final matchedPrefix = encoded.startsWith(prefix)
        ? prefix
        : (encoded.startsWith(bubblePrefix) ? bubblePrefix : null);

    if (matchedPrefix == null) {
      // The partless form is a bare GUID. It must carry no structure of its
      // own, or a malformed wrapper such as `0/<guid>` or `bpdi:0/<guid>`
      // would be accepted whole as the parent identifier.
      if (encoded.contains('/') ||
          encoded.contains(':') ||
          !_isValidGuid(encoded)) {
        throw const CloudAssociatedMessageParentReferenceFormatException();
      }
      return CloudAssociatedMessageParentReference._(
        part: null,
        localMessageGuid: encoded,
      );
    }

    final separator = encoded.indexOf('/', matchedPrefix.length);
    if (separator == -1 ||
        encoded.indexOf('/', separator + 1) != -1 ||
        separator == matchedPrefix.length) {
      throw const CloudAssociatedMessageParentReferenceFormatException();
    }

    final encodedPart = encoded.substring(matchedPrefix.length, separator);
    // Reject a non-canonical part spelling. The native parser rejects leading
    // zeros, and accepting them here made `p:0003/<guid>` convert on one side
    // of the bridge and quarantine on the other.
    if (encodedPart.length > _maximumPartDigits ||
        !_isAsciiDecimal(encodedPart) ||
        (encodedPart.length > 1 && encodedPart.startsWith('0'))) {
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
