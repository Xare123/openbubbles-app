import 'package:flat_buffers/flex_buffers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FlexBuffers grows beyond its 2048-byte default buffer', () {
    final oversizedMetadata = <String, dynamic>{
      'payload': List<String>.filled(3000, 'x').join(),
    };

    expect(() => Builder.buildFromObject(oversizedMetadata), returnsNormally);
  });
}
