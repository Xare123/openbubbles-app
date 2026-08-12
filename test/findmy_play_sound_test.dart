import 'dart:async';

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

    test('keeps the standalone nearby scan available without a cloud item', () {
      expect(canScanNearbyFindMyTrackers(isAndroid: true), isTrue);
      expect(canScanNearbyFindMyTrackers(isAndroid: false), isFalse);
    });

    test('explains an offline relay without exposing the bridge exception', () {
      expect(
        findMyCloudFailureMessage(Exception('Relay device offline!')),
        'Your relay device is offline. Cloud Find My will resume when it reconnects.',
      );
    });

    test('distinguishes cloud timeouts from other failures', () {
      expect(
        findMyCloudFailureMessage(TimeoutException('Future not completed')),
        'Cloud Find My timed out. Check the relay connection and try again.',
      );
      expect(
        findMyCloudFailureMessage(Exception('unexpected')),
        'Cloud Find My is unavailable right now.',
      );
    });
  });
}
