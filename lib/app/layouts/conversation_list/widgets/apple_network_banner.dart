import 'package:bluebubbles/services/rustpush/apple_network_health.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class AppleNetworkBanner extends StatelessWidget {
  const AppleNetworkBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final health = pushService.appleNetworkHealth.value;
      final (Color color, IconData icon, String message) = switch (health) {
        AppleNetworkHealth.fallback => (
            Colors.green.shade700,
            Icons.security,
            pushService.appleNetworkDetail.value ?? "Apple messaging connected through TCP 443 fallback",
          ),
        AppleNetworkHealth.reconnecting => (
            Colors.amber.shade800,
            Icons.sync,
            pushService.appleNetworkDetail.value ?? "Reconnecting to Apple messaging...",
          ),
        AppleNetworkHealth.blocked => (
            Colors.red.shade700,
            Icons.wifi_off,
            pushService.appleNetworkDetail.value ?? "This network may be blocking Apple messaging.",
          ),
        _ => (Colors.transparent, Icons.check, ""),
      };

      if (health != AppleNetworkHealth.fallback &&
          health != AppleNetworkHealth.reconnecting &&
          health != AppleNetworkHealth.blocked) {
        return const SizedBox.shrink();
      }

      return Material(
        color: color,
        child: Semantics(
          liveRegion: true,
          label: message,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
