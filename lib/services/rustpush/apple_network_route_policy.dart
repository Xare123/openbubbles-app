enum AppleNetworkRouteDecision {
  offline,
  waitForValidation,
  refresh,
}

AppleNetworkRouteDecision decideAppleNetworkRoute({
  required bool hasInternet,
  required bool validated,
}) {
  if (!hasInternet) return AppleNetworkRouteDecision.offline;
  if (!validated) return AppleNetworkRouteDecision.waitForValidation;
  return AppleNetworkRouteDecision.refresh;
}
