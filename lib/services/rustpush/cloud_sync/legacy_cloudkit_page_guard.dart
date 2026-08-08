import 'dart:convert';

/// Validates a legacy CloudKit page before its opaque continuation token is
/// committed. A failed item must keep the old token so the page can be replayed
/// instead of permanently skipping that record.
class LegacyCloudKitPageGuard {
  static const int maxPagesPerZone = 10000;

  static String validate({
    required String zone,
    required String? previousToken,
    required List<int> nextToken,
    required int state,
    required bool hadItemFailure,
    required int page,
  }) {
    if (page > maxPagesPerZone) {
      throw StateError(
        'Stopped $zone CloudKit sync after $maxPagesPerZone pages',
      );
    }
    if (hadItemFailure) {
      throw StateError(
        'Not advancing $zone CloudKit token because at least one item failed',
      );
    }

    final encoded = base64Encode(nextToken);
    if (state != 3 && encoded == previousToken) {
      throw StateError(
        'Stopped $zone CloudKit sync because its token made no progress',
      );
    }
    return encoded;
  }
}
