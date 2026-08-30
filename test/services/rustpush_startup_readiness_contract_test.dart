import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('incoming push readiness excludes optional iCloud maintenance', () {
    final source = File('lib/services/rustpush/rustpush_service.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final barrierStart = source.indexOf('initFuture = (() async {');
    final barrierEnd = source.indexOf(
      '    })();\n    initSyncState();',
      barrierStart,
    );

    expect(barrierStart, greaterThanOrEqualTo(0));
    expect(barrierEnd, greaterThan(barrierStart));

    final readinessBarrier = source.substring(barrierStart, barrierEnd);
    expect(readinessBarrier, isNot(contains('syncPasswords(')));
    expect(readinessBarrier, isNot(contains('isInClique(')));
    expect(readinessBarrier, isNot(contains('doCloudKitSync(')));

    final readinessAwait = source.indexOf('    await initFuture;', barrierEnd);
    final maintenanceLaunch = source.indexOf(
      'unawaited(_runInitialICloudMaintenance(initializedState));',
      readinessAwait,
    );
    expect(readinessAwait, greaterThan(barrierEnd));
    expect(maintenanceLaunch, greaterThan(readinessAwait));
  });

  test('incoming pushes wait for native state and database readiness', () {
    final source = File('lib/services/rustpush/rustpush_service.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final receiveStart = source.indexOf(
      'Future recievedMsgPointer(String pointer, String retry) async {',
    );
    final receiveEnd = source.indexOf('\n  void doPoll(', receiveStart);

    expect(receiveStart, greaterThanOrEqualTo(0));
    expect(receiveEnd, greaterThan(receiveStart));

    final receive = source.substring(receiveStart, receiveEnd);
    final readinessAwait = receive.indexOf(
      'await waitForRustPushReceiveReadiness<api.SharedPushState>(',
    );
    final stateBarrier =
        receive.indexOf('nativeStateReady: initFuture,', readinessAwait);
    final databaseBarrier = receive.indexOf(
      'databaseReady: Database.waitForInit(),',
      readinessAwait,
    );
    final stateResolver =
        receive.indexOf('currentState: () => state,', readinessAwait);
    final handle = receive.indexOf('await handleMsg(message);');
    final stateChangeCheck = receive.indexOf(
      'if (!identical(state, initializedState))',
      handle,
    );
    final acknowledgement = receive.indexOf(
      'await markAsHandledAfter(pointer',
      handle,
    );
    expect(readinessAwait, greaterThanOrEqualTo(0));
    expect(stateBarrier, greaterThan(readinessAwait));
    expect(databaseBarrier, greaterThan(stateBarrier));
    expect(stateResolver, greaterThan(databaseBarrier));
    expect(handle, greaterThan(stateResolver));
    expect(stateChangeCheck, greaterThan(handle));
    expect(acknowledgement, greaterThan(stateChangeCheck));
    expect(
      receive.indexOf('try {'),
      lessThan(readinessAwait),
      reason: 'readiness failures must be logged and retried, not escape',
    );
  });

  test('optional startup probes are bounded', () {
    final source = File('lib/services/rustpush/rustpush_service.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final maintenanceStart = source.indexOf(
      'Future<void> _runInitialICloudMaintenance(',
    );
    final maintenanceEnd = source.indexOf('\n  @override', maintenanceStart);

    expect(maintenanceStart, greaterThanOrEqualTo(0));
    expect(maintenanceEnd, greaterThan(maintenanceStart));

    final maintenance = source.substring(maintenanceStart, maintenanceEnd);
    expect(
      '.timeout(_initialICloudMaintenanceTimeout)'
          .allMatches(maintenance)
          .length,
      2,
    );
  });
}
