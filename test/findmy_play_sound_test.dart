import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Find My Play Sound eligibility', () {
    test('allows Apple-account devices with a non-empty identifier', () {
      expect(
        canPlayFindMySound(deviceId: 'device-id', isAccessory: false),
        isTrue,
      );
    });

    test('rejects missing and empty identifiers', () {
      expect(canPlayFindMySound(deviceId: null, isAccessory: false), isFalse);
      expect(canPlayFindMySound(deviceId: '', isAccessory: false), isFalse);
    });

    test('keeps accessories out of the remote Apple-account command', () {
      expect(
        canPlayFindMySound(deviceId: 'airtag-id', isAccessory: true),
        isFalse,
      );
    });

    test('allows nearby accessory sound only on Android', () {
      expect(
        canPlayNearbyFindMySound(isAccessory: true, isAndroid: true),
        isTrue,
      );
      expect(
        canPlayNearbyFindMySound(isAccessory: true, isAndroid: false),
        isFalse,
      );
      expect(
        canPlayNearbyFindMySound(isAccessory: false, isAndroid: true),
        isFalse,
      );
    });
  });
}
