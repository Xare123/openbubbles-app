import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/network/metadata_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudKit URL-balloon presentation', () {
    test('uses the projected URL when detector results are absent', () {
      final message = Message(
        guid: 'cloudkit-url-balloon',
        text: 'https://example.com/article',
        balloonBundleId: 'com.apple.messages.URLBalloonProvider',
        hasDdResults: false,
        isFromMe: false,
      );

      expect(message.isLegacyUrlPreview, isTrue);
      expect(message.isInteractive, isFalse);
      expect(message.url, 'https://example.com/article');
    });

    test('does not fabricate a preview target from invalid text', () {
      final message = Message(
        guid: 'cloudkit-url-balloon-invalid',
        text: 'not a link',
        balloonBundleId: 'com.apple.messages.URLBalloonProvider',
        hasDdResults: false,
        isFromMe: false,
      );

      expect(message.url, isNull);
      expect(message.isLegacyUrlPreview, isFalse);
      expect(message.isInteractive, isTrue);
    });

    test('recognizes a URL balloon containing multiple distinct links', () {
      final message = Message(
        guid: 'cloudkit-url-balloon-multiple',
        text: 'https://example.com/one+a https://example.com/two?value=a+b',
        balloonBundleId: 'com.apple.messages.URLBalloonProvider',
        hasDdResults: false,
        isFromMe: false,
      );

      expect(message.isLegacyUrlPreview, isTrue);
      expect(message.url, 'https://example.com/one+a');
      expect(
        message.buildMessageParts().single.url,
        'https://example.com/one+a',
      );
    });

    test('nullable legacy flags fail closed instead of throwing', () {
      final message = Message(
        guid: 'cloudkit-url-balloon-null-flags',
        text: 'not a link',
        balloonBundleId: 'com.apple.messages.URLBalloonProvider',
        hasDdResults: null,
        isFromMe: null,
      );

      expect(message.isLegacyUrlPreview, isFalse);
    });

    test('does not reclassify another balloon type from its text alone', () {
      final message = Message(
        guid: 'cloudkit-non-url-balloon',
        text: 'https://example.com/article',
        balloonBundleId: 'com.apple.messages.Handwriting.HandwritingProvider',
        hasDdResults: false,
        isFromMe: false,
      );

      expect(message.isLegacyUrlPreview, isFalse);
      expect(message.isInteractive, isTrue);
    });
  });

  test('fetchMetadata fails closed when the message has no URL', () async {
    final result = await MetadataHelper.fetchMetadata(
      Message(guid: 'metadata-no-url', text: 'This is not a link'),
    );

    expect(result, isNull);
  });

  test('fetchMetadata does not treat a multi-link body as one URL', () async {
    final result = await MetadataHelper.fetchMetadata(
      Message(guid: 'metadata-multi-link-body'),
      previewUrl: 'https://example.com/one https://example.com/two',
    );

    expect(result, isNull);
  });
}
