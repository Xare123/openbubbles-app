import 'package:bluebubbles/services/rustpush/apple_network_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('distinguishes normal and HTTPS fallback APNs transports', () {
    expect(
      classifyAppleNetworkHealth('connected', 5223),
      AppleNetworkHealth.connected,
    );
    expect(
      classifyAppleNetworkHealth('connected', 443),
      AppleNetworkHealth.fallback,
    );
  });

  test('maps failed and closed transports to a blocked-network warning', () {
    expect(
      classifyAppleNetworkHealth('blocked', null),
      AppleNetworkHealth.blocked,
    );
    expect(
      classifyAppleNetworkHealth('closed', null),
      AppleNetworkHealth.blocked,
    );
  });

  test('keeps reconnecting distinct from a confirmed block', () {
    expect(
      classifyAppleNetworkHealth('reconnecting', null),
      AppleNetworkHealth.reconnecting,
    );
    expect(
      classifyAppleNetworkHealth('unexpected', null),
      AppleNetworkHealth.unknown,
    );
  });
}
