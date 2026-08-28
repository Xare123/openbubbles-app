import 'package:bluebubbles/services/rustpush/apple_network_route_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local-only network is treated as offline for Apple Push', () {
    expect(
      decideAppleNetworkRoute(hasInternet: false, validated: false),
      AppleNetworkRouteDecision.offline,
    );
  });

  test('unvalidated Internet waits without refreshing Apple Push', () {
    expect(
      decideAppleNetworkRoute(hasInternet: true, validated: false),
      AppleNetworkRouteDecision.waitForValidation,
    );
  });

  test('validated Internet requests an Apple Push refresh', () {
    expect(
      decideAppleNetworkRoute(hasInternet: true, validated: true),
      AppleNetworkRouteDecision.refresh,
    );
  });
}
