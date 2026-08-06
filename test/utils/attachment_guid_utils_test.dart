import 'package:bluebubbles/utils/attachment_guid_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseAppleOwnedAttachmentGuid', () {
    test('keeps the entire remaining suffix as the message GUID', () {
      final owned = parseAppleOwnedAttachmentGuid('at_12_GUID_WITH_UNDERSCORES');

      expect(owned, isNotNull);
      expect(owned!.part, '12');
      expect(owned.messageGuid, 'GUID_WITH_UNDERSCORES');
    });

    test('parses a single-segment message GUID', () {
      final owned = parseAppleOwnedAttachmentGuid('at_0_ABCD');

      expect(owned!.part, '0');
      expect(owned.messageGuid, 'ABCD');
    });

    test('returns null for shapes that are not owned attachments', () {
      // A standalone attachment must never be given an invented owner.
      for (final guid in <String>[
        'ABCD-1234',
        'atlas_1_ABCD', // "at" prefix without the separator
        'at_',
        'at_12',
        'at_12_',
        'at__ABCD', // empty part
        'at_x_ABCD', // non-decimal part
        'at_-1_ABCD',
        'at_007_ABCD', // non-canonical leading zero
      ]) {
        expect(
          parseAppleOwnedAttachmentGuid(guid),
          isNull,
          reason: 'expected $guid to be rejected',
        );
      }
    });

    test('does not throw on fewer than three underscore segments', () {
      // The previous split("_")[2] implementation raised a RangeError here.
      expect(() => parseAppleOwnedAttachmentGuid('at_12'), returnsNormally);
      expect(() => convertAppleAttachmentGuid('at_12'), returnsNormally);
    });
  });

  group('convertAppleAttachmentGuid', () {
    test('moves the part behind a GUID containing underscores', () {
      expect(
        convertAppleAttachmentGuid('at_12_GUID_WITH_UNDERSCORES'),
        'GUID_WITH_UNDERSCORES_12',
      );
    });

    test('leaves a non-owned identifier untouched', () {
      expect(convertAppleAttachmentGuid('ABCD-1234'), 'ABCD-1234');
      expect(convertAppleAttachmentGuid('at_x_ABCD'), 'at_x_ABCD');
    });
  });

  group('unconvertAppleAttachmentGuid', () {
    test('restores Apple form from a GUID containing underscores', () {
      expect(
        unconvertAppleAttachmentGuid('GUID_WITH_UNDERSCORES_12'),
        'at_12_GUID_WITH_UNDERSCORES',
      );
    });

    test('round-trips both directions', () {
      for (final apple in <String>[
        'at_0_ABCD',
        'at_12_GUID_WITH_UNDERSCORES',
        'at_3_A_B_C_D',
      ]) {
        expect(
          unconvertAppleAttachmentGuid(convertAppleAttachmentGuid(apple)),
          apple,
        );
      }
    });

    test('leaves an identifier with no trailing decimal part untouched', () {
      expect(unconvertAppleAttachmentGuid('ABCD'), 'ABCD');
      expect(unconvertAppleAttachmentGuid('ABCD_EFGH'), 'ABCD_EFGH');
      expect(unconvertAppleAttachmentGuid('ABCD_'), 'ABCD_');
    });
  });
}
