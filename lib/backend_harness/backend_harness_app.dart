import 'dart:io';

import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'backend_harness_controller.dart';
import 'backend_harness_protocol.dart';
import 'backend_harness_vm_service.dart';

BackendHarnessController? _controller;

/// This entry is for the separate agentDebug package. Normal app startup never
/// replaces the personal Canary or end-user home with this dashboard.
bool runBackendHarnessApp() {
  final platform = Platform.isAndroid
      ? 'android'
      : Platform.isWindows
      ? 'windows'
      : 'other';
  if (!BackendHarnessGate.allowed(
    compiled: BackendHarnessGate.compiledIn,
    debug: kDebugMode,
    platform: platform,
    package: fs.packageInfo.packageName,
    isolatedWindowsProfile: fs.cloudSyncV2WindowsDevProfileActive,
  )) {
    return false;
  }
  final controller = _controller ??= BackendHarnessController();
  registerBackendHarnessExtension(
    controller.engine,
    isolatedWindowsProfile: fs.cloudSyncV2WindowsDevProfileActive,
  );
  runApp(
    GetMaterialApp(
      navigatorKey: ns.key,
      title: 'OpenBubbles Backend Lab',
      home: _BackendHarnessDashboard(controller: controller),
    ),
  );
  return true;
}

final class _BackendHarnessDashboard extends StatefulWidget {
  const _BackendHarnessDashboard({required this.controller});
  final BackendHarnessController controller;
  @override
  State<_BackendHarnessDashboard> createState() =>
      _BackendHarnessDashboardState();
}

final class _BackendHarnessDashboardState
    extends State<_BackendHarnessDashboard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!StartupTasks.uiReady.isCompleted) StartupTasks.uiReady.complete();
      if (Platform.isAndroid) ls.createFakePort();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('OpenBubbles Backend Lab')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        'Compiled command interface\n'
        'Protocol: $backendHarnessProtocol\n'
        'Source: ${widget.controller.engine.source.isEmpty ? "missing build stamp" : widget.controller.engine.source}\n'
        'Control: $backendHarnessExtension\n\n'
        'Use hello to inspect implemented capabilities.\n'
        'Accepted operations return a job handle; query job.status for completion.\n'
        'This screen is a test console. Authentication and CloudKit readiness\n'
        'are reported independently by backend status.',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
      ),
    ),
  );
}
