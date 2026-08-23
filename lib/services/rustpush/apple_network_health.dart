enum AppleNetworkHealth {
  unknown,
  connected,
  fallback,
  reconnecting,
  blocked,
  offline,
}

AppleNetworkHealth classifyAppleNetworkHealth(
  String state,
  int? activePort,
) {
  return switch (state) {
    "connected" when activePort == 443 => AppleNetworkHealth.fallback,
    "connected" => AppleNetworkHealth.connected,
    "reconnecting" => AppleNetworkHealth.reconnecting,
    "blocked" || "closed" => AppleNetworkHealth.blocked,
    _ => AppleNetworkHealth.unknown,
  };
}
