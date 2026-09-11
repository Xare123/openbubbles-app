import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bridge = _EncodingBridge();
  setUpAll(() => RustLib.initMock(api: bridge));
  tearDownAll(RustLib.dispose);

  for (final sample in [
    (name: 'italic only', italic: true, strike: null),
    (name: 'strikethrough only', italic: null, strike: true),
    (name: 'italic with explicit no strike', italic: true, strike: false),
    (name: 'strike with explicit no italic', italic: false, strike: true),
  ]) {
    test('attributed encoding keeps flags independent: ${sample.name}', () {
      final body = AttributedBody(
        string: 'A😀B',
        runs: [
          Run(
            range: [0, 4],
            attributes: Attributes(
              messagePart: 0,
              italic: sample.italic,
              strikethrough: sample.strike,
            ),
          ),
        ],
      );

      Message().encodeAttributedBody([body], false);

      final encoded = bridge.encoded.single;
      expect(encoded.text, body.string);
      expect(encoded.ranges, hasLength(1));
      expect(encoded.ranges.single.$1, 4);
      final attributes = encoded.ranges.single.$2.field0.map(
        (key, value) => MapEntry(key, (value as _EncodedValue).value),
      );
      expect(attributes, {
        '__kIMMessagePartAttributeName': 0,
        if (sample.italic != null)
          '__kIMTextItalicAttributeName': sample.italic! ? 1 : 0,
        if (sample.strike != null)
          '__kIMTextStrikethroughAttributeName': sample.strike! ? 1 : 0,
      });
    });
  }
}

// Capture the real Dart serializer's native-boundary arguments, not a mock
// implementation of its attribute mapping. No native library is loaded.
class _EncodingBridge implements RustLibApi {
  List<api.NSAttributedString> encoded = [];

  @override
  api.StCollapsedValue crateApiApiNsNumberEncode({required api.NSNumber that}) =>
      _EncodedValue(that.field0);

  @override
  api.StCollapsedValue crateApiApiNsAttributedStringEncode({
    required api.NSAttributedString that,
  }) => _EncodedValue(that);

  @override
  Uint8List crateApiApiNscoderEncode({
    required List<api.StCollapsedValue> value,
  }) {
    encoded = value
        .map((item) => (item as _EncodedValue).value as api.NSAttributedString)
        .toList();
    return Uint8List(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EncodedValue implements api.StCollapsedValue {
  _EncodedValue(this.value);
  final Object value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
