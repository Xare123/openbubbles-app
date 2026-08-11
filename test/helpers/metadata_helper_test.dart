import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/network/metadata_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
