import 'dart:async';

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:network_tools/network_tools.dart'
    if (dart.library.html) 'package:bluebubbles/models/html/network_tools.dart';

class NetworkTasks {
  static Future<void>? _configureNetworkToolsFuture;

  /// Isolates that should receive [HttpSvc.originOverride] syncs.
  /// Populated via [registerIsolate] — no hardcoded types here.
  static final List<GlobalIsolate> _isolateRegistry = [];

  static Future<void> onConnect() async {
    if (!SettingsSvc.settings.finishedSetup.value) return;
    Logger.info('[NetworkTasks] Handling onConnect tasks. Finished Setup: ${SettingsSvc.settings.finishedSetup.value}');

    if (kIsWeb) {
      if (ChatsSvc.isEmpty) {
        ChatsSvc.reset();
        await ChatsSvc.init();
      }
    }
  }

  static Future<void> detectLocalhost({bool createSnackbar = false}) async {
    final port = SettingsSvc.settings.localhostPort.value;
    if (port == null || kIsWeb) {
      HttpSvc.originOverride = null;
      return;
    }

    final status = await Connectivity().checkConnectivity();
    if (!status.contains(ConnectivityResult.wifi) && !status.contains(ConnectivityResult.ethernet)) {
      HttpSvc.originOverride = null;
      return;
    }

    // Reset any stale local override so serverInfo() queries the remote server
    // for fresh local IPs, and so the port-scan fallback isn't skipped if the
    // serverInfo call fails.
    HttpSvc.originOverride = null;

    // Phase 1: try the known local IPs reported by the server.
    try {
      final response = await HttpSvc.serverInfo();
      final data = response.data?['data'];
      final localIpv4s = ((data?['local_ipv4s'] ?? []) as List).cast<String>();
      final localIpv6s = ((data?['local_ipv6s'] ?? []) as List).cast<String>();

      // IPv6 addresses need brackets in URLs: [::1]
      final candidates = [
        if (SettingsSvc.settings.useLocalIpv6.value) ...localIpv6s.map((ip) => '[$ip]'),
        ...localIpv4s,
      ];

      HttpSvc.originOverride = await _probeAddresses(candidates, port);
    } catch (e) {
      Logger.warn('Could not fetch server info for localhost detection: $e', tag: 'NetworkTasks');
    }

    if (HttpSvc.originOverride != null) {
      Logger.debug('Localhost detected at ${HttpSvc.originOverride}', tag: 'NetworkTasks');
      if (createSnackbar) showSnackbar('Localhost Detected', 'Connected to ${HttpSvc.originOverride}');
      syncOriginOverrideToIsolate();
      return;
    }

    // Phase 2: fall back to a subnet port scan.
    // configureNetworkTools is cached because it makes an external API call to
    // fetch MAC vendor data. We don't want that on first boot.
    _configureNetworkToolsFuture ??= configureNetworkTools(FilesystemSvc.appDocDir.path, enableDebugging: kDebugMode);
    await _configureNetworkToolsFuture;

    Logger.debug('Falling back to port scanning', tag: 'NetworkTasks');
    final wifiIP = await NetworkInfo().getWifiIP();
    if (wifiIP == null) {
      HttpSvc.originOverride = null;
      return;
    }

    final subnet = wifiIP.substring(0, wifiIP.lastIndexOf('.'));
    final hosts = <ActiveHost>{};
    final completer = Completer<void>();
    HostScannerService.instance.scanDevicesForSinglePort(subnet, int.parse(port)).listen(
      (host) => hosts.add(host),
      onDone: () async {
        HttpSvc.originOverride = await _probeAddresses(hosts.map((h) => h.address).toList(), port);
        if (createSnackbar && HttpSvc.originOverride != null) {
          showSnackbar('Localhost Detected', 'Connected to ${HttpSvc.originOverride}');
        }
        completer.complete();
      },
      onError: (_, __) {
        HttpSvc.originOverride = null;
        completer.complete();
      },
    );
    await completer.future;
    syncOriginOverrideToIsolate();
  }

  /// Broadcasts the current [HttpSvc.originOverride] to [isolate], or — when
  /// called with no argument — to every registered isolate that is currently
  /// running (dormant isolates with idleTimeout=zero are skipped).
  static void syncOriginOverrideToIsolate([GlobalIsolate? isolate]) {
    if (kIsWeb) return;
    if (isolate != null) {
      isolate.broadcast(IsolateRequestType.setOriginOverride, HttpSvc.originOverride);
      return;
    }
    for (final candidate in _isolateRegistry) {
      if (candidate.isRunning) {
        candidate.broadcast(IsolateRequestType.setOriginOverride, HttpSvc.originOverride);
      }
    }
  }

  /// Registers [isolate] to receive [HttpSvc.originOverride] syncs.
  /// Also wires up a started callback so the override is re-synced
  /// automatically whenever the isolate (re)starts after an idle timeout.
  static void registerIsolate(GlobalIsolate isolate) {
    _isolateRegistry.add(isolate);
    isolate.addStartedCallback(() async {
      isolate.broadcast(IsolateRequestType.setOriginOverride, HttpSvc.originOverride);
    });
  }

  /// Probes [ips] on [port] with https then http, returning the first address
  /// that responds with "pong", or null if none respond.
  ///
  /// IPv6 addresses must already be bracket-formatted, e.g. `[::1]`.
  static Future<String?> _probeAddresses(List<String> ips, String port) async {
    for (final ip in ips) {
      for (final scheme in ['https', 'http']) {
        final addr = '$scheme://$ip:$port';
        try {
          final response = await HttpSvc.ping(customUrl: addr);
          if (response.data.toString().contains('pong')) return addr;
        } catch (_) {
          Logger.debug('Failed to connect to local address: $addr', tag: 'NetworkTasks');
        }
      }
    }
    return null;
  }
}
