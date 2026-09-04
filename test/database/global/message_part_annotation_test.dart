import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Annotation.toMap formatting flags', () {
    test('bold serializes independently', () {
      final annotation = Annotation(bold: true, range: [0, 4]);
      final map = annotation.toMap();
      expect(map['bold'], isTrue);
      expect(map.containsKey('italic'), isFalse);
      expect(map.containsKey('strikethrough'), isFalse);
      expect(map.containsKey('underline'), isFalse);
      final roundTripped = Annotation.fromMap(map);
      expect(roundTripped.bold, isTrue);
      expect(roundTripped.italic ?? false, isFalse);
    });
    test('italic serializes its own value, not bold', () {
      final annotation = Annotation(italic: true, range: [0, 4]);
      final map = annotation.toMap();
      expect(map['italic'], isTrue);
      expect(map.containsKey('bold'), isFalse);
      final roundTripped = Annotation.fromMap(map);
      expect(roundTripped.italic, isTrue);
      expect(roundTripped.bold ?? false, isFalse);
    });
    test('strikethrough serializes its own value, not bold', () {
      final annotation = Annotation(strikethrough: true, range: [0, 4]);
      final map = annotation.toMap();
      expect(map['strikethrough'], isTrue);
      expect(map.containsKey('bold'), isFalse);
      final roundTripped = Annotation.fromMap(map);
      expect(roundTripped.strikethrough, isTrue);
      expect(roundTripped.bold ?? false, isFalse);
    });
    test('underline serializes its own value, not bold', () {
      final annotation = Annotation(underline: true, range: [0, 4]);
      final map = annotation.toMap();
      expect(map['underline'], isTrue);
      expect(map.containsKey('bold'), isFalse);
      final roundTripped = Annotation.fromMap(map);
      expect(roundTripped.underline, isTrue);
      expect(roundTripped.bold ?? false, isFalse);
    });
    test('combined flags round-trip together', () {
      final annotation = Annotation(
        bold: true,
        italic: true,
        strikethrough: true,
        underline: true,
        range: [2, 7],
      );
      final map = annotation.toMap();
      expect(map['bold'], isTrue);
      expect(map['italic'], isTrue);
      expect(map['strikethrough'], isTrue);
      expect(map['underline'], isTrue);
      final roundTripped = Annotation.fromMap(map);
      expect(roundTripped.bold, isTrue);
      expect(roundTripped.italic, isTrue);
      expect(roundTripped.strikethrough, isTrue);
      expect(roundTripped.underline, isTrue);
      expect(roundTripped.range, [2, 7]);
    });
  });
}
