import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/services/rustpush/rustpush_service.dart',
  ).readAsStringSync();

  test('background sync waits for a UI status port and always cleans up', () {
    final entrypointStart = source.indexOf(
      'Future<void> backgroundSyncIsolate() async',
    );
    final entrypointEnd = source.indexOf(
      '// utils for communicating between dart and rustpush.',
      entrypointStart,
    );
    final entrypoint = source.substring(entrypointStart, entrypointEnd);

    expect(entrypoint, contains('final firstStatusPort = Completer<void>();'));
    expect(entrypoint, contains('firstStatusPort.complete()'));
    expect(entrypoint, contains('firstStatusPort.future.timeout('));
    expect(
      entrypoint.indexOf('firstStatusPort.future.timeout('),
      lessThan(entrypoint.indexOf('doCloudKitSyncPrivate()')),
    );
    expect(
      entrypoint.indexOf('try {'),
      lessThan(entrypoint.indexOf('StartupTasks.initIsolateServices()')),
    );
    expect(entrypoint, contains('removePortNameMapping("bg_sync")'));
    expect(entrypoint, contains('ownsPortMapping'));
    expect(
      entrypoint,
      contains('lookupPortByName("bg_sync") == receive.sendPort'),
    );
    expect(entrypoint, contains('await mcs.invokeMethod("exit")'));
  });

  test('UI reattaches safely and reset clears stale worker state', () {
    expect(source, isNot(contains('syncing!.send(port.sendPort)')));
    expect(
      source,
      contains(
        'message.send(pushService.isSyncing.value ?? "Starting Sync...")',
      ),
    );
    expect(source, contains('Joining active legacy CloudKit sync'));
    expect(source, contains('_attachLegacyCloudKitSyncPort(syncing)'));
    expect(source, contains('_closeLegacyCloudKitStatusPort()'));

    final resetStart = source.indexOf('Future<void> resetCloudKitSync() async');
    final resetEnd = source.indexOf('Rxn<String> isSyncing', resetStart);
    final reset = source.substring(resetStart, resetEnd);
    expect(reset, contains('lookupPortByName("bg_sync")'));
    expect(reset, contains('finally {'));
    expect(reset, contains('removePortNameMapping("bg_sync")'));
  });

  test('legacy CloudKit remains restore-only in every build', () {
    expect(
      source,
      contains('const bool _legacyCloudKitMutationsEnabled = false;'),
    );
    expect(source, isNot(contains('OPENBUBBLES_LEGACY_CLOUDKIT_MUTATIONS')));
  });
}
