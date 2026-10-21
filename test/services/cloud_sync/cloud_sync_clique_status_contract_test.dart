import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_pcs_operation.dart';
import 'package:flutter_test/flutter_test.dart';

String _service() => File('lib/services/rustpush/rustpush_service.dart')
    .readAsStringSync().replaceAll('\r\n', '\n');

String _between(String source, String start, String end) {
  final a = source.indexOf(start), b = source.indexOf(end, source.indexOf(start));
  expect(a, greaterThanOrEqualTo(0));
  expect(b, greaterThan(a));
  return source.substring(a, b);
}

void main() {
  test('settled busy status does not poison the uncancellable-operation fence', () async {
    var poisoned = false;
    await expectLater(
      awaitCloudSyncPcsOperation<bool>(
        Future<bool>.error(StateError('cloud_sync_v2_pcs_status_busy')),
        const Duration(seconds: 30),
        poisonUntilProcessRestart: () => poisoned = true,
      ),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
        'cloud_sync_v2_pcs_status_busy')),
    );
    expect(poisoned, isFalse);
  });

  test('CloudKit consumers use checked status while other clients retain legacy API', () {
    final source = _service();
    expect(source, isNot(contains('api.isInClique(')));
    expect(source, contains('api.cloudSyncCheckClique(keychain: keychain)'));
    final maintenance = _between(source, 'Future<void> _runICloudMaintenance(',
      '@override\n  Future<void> onInit()');
    expect(maintenance, contains(': () => _checkCloudSyncCliqueStatus(keychain)'));
    final native = File('rust/src/api/api.rs').readAsStringSync();
    final checked = _between(native, 'pub async fn cloud_sync_check_clique(',
      'pub async fn join_clique_with_bottle(');
    expect(checked, contains('keychain: &Arc<KeychainClient'));
    expect(checked, contains('try_acquire_cloudkit_operation'));
    expect(checked, contains('permit.run(keychain.checked_is_in_clique())'));
    expect(checked, isNot(contains('unwrap_or(false)')));
    expect(native, contains('pub async fn is_in_clique('));
  });

  test('cache publishes only a conclusive result for the same service state', () {
    final check = _between(_service(), 'Future<bool> checkClique()',
      'Future<bool> joinClique()');
    final probe = check.indexOf('await _checkCloudSyncCliqueStatus(keychain)');
    final current = check.indexOf('if (!identical(state, checkedState))');
    final publish = check.indexOf('cachedInClique = isInClique');
    expect(probe, greaterThanOrEqualTo(0));
    expect(current, greaterThan(probe));
    expect(publish, greaterThan(current));
    expect(check, isNot(contains('catch')));
  });

  test('legacy sync can disable only after a successful false trust check', () {
    final legacy = _between(_service(), 'Future<void> _doCloudKitSyncPrivateUnlocked()',
      'List<(String, String)> downloadPfPics');
    final check = legacy.indexOf('await _checkCloudSyncCliqueStatus(');
    final conclusiveFalse = legacy.indexOf('if (!isInClique)');
    final disable = legacy.indexOf('cloudSyncingEnabled.value = false');
    expect(check, greaterThanOrEqualTo(0));
    expect(conclusiveFalse, greaterThan(check));
    expect(disable, greaterThan(conclusiveFalse));
    expect(legacy, isNot(contains('catch')));
  });

  test('PCS retains the real timeout fence and exact busy outcome at both checks', () {
    final pcs = _between(_service(), 'Future<CloudSyncV2PcsPreparationOutcome> _prepareCloudSyncV2Pcs(',
      'Future<api.ViableBottle?> _promptCloudSyncV2BottleChoice(');
    expect('_checkCloudSyncCliqueStatus(keychain)'.allMatches(pcs).length, 2);
    expect('cloudSyncV2CliqueStatusFailureForNativeCode('.allMatches(pcs).length, 2);
    expect(pcs, contains('on CloudSyncPcsRestartRequired'));
    expect(pcs, contains('poisonUntilProcessRestart: interlock.poisonUntilProcessRestart'));
  });
}
