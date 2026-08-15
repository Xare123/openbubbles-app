import 'dart:async';

import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Find My Play Sound eligibility', () {
    test('allows Apple-account devices with a non-empty identifier', () {
      expect(
        canPlayFindMySound(deviceId: 'device-id', isCloudManaged: true),
        isTrue,
      );
    });

    test('rejects missing and empty identifiers', () {
      expect(canPlayFindMySound(deviceId: null, isCloudManaged: true), isFalse);
      expect(canPlayFindMySound(deviceId: '', isCloudManaged: true), isFalse);
    });

    test('keeps beacon-backed accessories out of the cloud command', () {
      expect(
        canPlayFindMySound(deviceId: 'airtag-id', isCloudManaged: false),
        isFalse,
      );
    });

    test('allows cloud-managed accessories such as AirPods', () {
      expect(
        canPlayFindMySound(deviceId: 'airpods-id', isCloudManaged: true),
        isTrue,
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

    test('shows exact signal strength when the Android scan provides RSSI', () {
      expect(
        nearbyTrackerSignalLabel({'signal': 'strong', 'rssi': -47}),
        'Strong signal (-47 dBm)',
      );
      expect(nearbyTrackerSignalLabel({'signal': 'weak'}), 'Weak signal');
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
