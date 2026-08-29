import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'inspect_cloud_sync_control_state.dart' as inspector;

void main() {
  test('prints a redacted report from an offline ObjectBox copy', () async {
    final source = Platform.environment['OPENBUBBLES_OBJECTBOX_INSPECT_DIR'];
    expect(source, isNotNull, reason: 'inspection directory is required');
    final report = await inspector.inspectCloudSyncControlState(
      Directory(source!),
    );
    // This tooling-only test is invoked explicitly and the report contains
    // only closed-set control metadata and aggregate counts.
    // ignore: avoid_print
    print('CLOUD_SYNC_CONTROL_REPORT=${jsonEncode(report)}');
  });
}
