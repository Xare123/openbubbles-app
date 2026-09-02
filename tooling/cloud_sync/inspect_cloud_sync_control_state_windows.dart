import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'inspect_cloud_sync_control_state.dart';

/// Windows entry point for the redacted, read-only ObjectBox inspector.
///
/// The normal Dart command-line compiler cannot load every Flutter/FFI
/// dependency in this application. Building this tiny Flutter target lets the
/// existing signed Windows development toolchain inspect an offline database
/// copy without launching OpenBubbles or contacting Apple.
Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.length != 2) {
    exitCode = 64;
    return;
  }

  final sourceDirectory = Directory(arguments[0]).absolute;
  final outputFile = File(arguments[1]).absolute;
  if (!sourceDirectory.existsSync() || outputFile.existsSync()) {
    exitCode = 64;
    return;
  }

  try {
    final report = await inspectCloudSyncControlState(sourceDirectory);
    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    exit(0);
  } catch (_) {
    exit(70);
  }
}
