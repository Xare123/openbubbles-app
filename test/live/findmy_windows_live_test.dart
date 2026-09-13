// Parent-invoked only through tooling/windows/run_findmy_windows_live.ps1.
// No app bootstrap, ObjectBox, logger, sync coordinator, or writer imports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_findmy_probe.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/lib.dart' show ApsConnection;
import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

const nativeSha =
    'e2bdf775b8f9b9327c1a8278a034628f4efb382cbe2e2a9afe1f9aec2164f30a';
const liveEnable = 'OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE';
const solePersonEnable = 'OPENBUBBLES_FINDMY_SELECT_SOLE_PERSON';

bool liveEnabled(Map<String, String> env) => env[liveEnable] == '1';

void requireLaunchEnvironment(Map<String, String> env) {
  const allowed = {
    liveEnable,
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE',
    'OPENBUBBLES_FINDMY_LAUNCH_ID',
    'OPENBUBBLES_FINDMY_SOURCE_HEAD',
    'OPENBUBBLES_TEST_NATIVE_LIBRARY',
    solePersonEnable,
  };
  if (!liveEnabled(env) ||
      (env.containsKey(solePersonEnable) && env[solePersonEnable] != '1') ||
      env['OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE'] != '1' ||
      env['OPENBUBBLES_FINDMY_LAUNCH_ID']?.length != 32 ||
      env['OPENBUBBLES_FINDMY_SOURCE_HEAD']?.length != 40 ||
      !RegExp(
        r'^[a-f0-9]{32}$',
      ).hasMatch(env['OPENBUBBLES_FINDMY_LAUNCH_ID'] ?? '') ||
      !RegExp(
        r'^[a-f0-9]{40}$',
      ).hasMatch(env['OPENBUBBLES_FINDMY_SOURCE_HEAD'] ?? '') ||
      (env['OPENBUBBLES_TEST_NATIVE_LIBRARY'] ?? '').isEmpty ||
      env.keys.any(
        (key) => key.startsWith('OPENBUBBLES_') && !allowed.contains(key),
      )) {
    throw StateError('findmy_testhost_environment_rejected');
  }
}

/// Test-host-only fallback. Capture one bounded roster from this pass, then
/// replay that same result (or failure) to the unchanged aggregate orchestrator.
/// Explicit selectors bypass the fallback. No identifiers leave memory.
Future<Map<String, Object?>> runFindMyTestHostProbe({
  required String launchId,
  required String buildIdentifier,
  required FindMyProbeRequest request,
  required FindMyProbeReads reads,
  bool selectSolePerson = false,
  Duration sectionTimeout = findMyProbeSectionTimeout,
}) async {
  if (!selectSolePerson || request.hasSelection) {
    return runWindowsFindMyProbe(
      launchId: launchId,
      buildIdentifier: buildIdentifier,
      request: request,
      reads: reads,
      sectionTimeout: sectionTimeout,
    );
  }
  // Validate the existing contract before any callback. Also capture the real
  // start of this pass, which includes the roster used to choose the selector.
  final validation = await runWindowsFindMyProbe(
    launchId: launchId,
    buildIdentifier: buildIdentifier,
    sectionTimeout: sectionTimeout,
  );
  var selectedRequest = request;
  var reason = 'sole_person_fresh_roster_unavailable';
  late Future<FindMyProbeRead<api.Follow>> Function() capturedRoster;
  try {
    final roster = await Future.sync(
      reads.refreshFollowing,
    ).timeout(sectionTimeout);
    capturedRoster = () async => roster;
    if (roster.freshRequestCompleted) {
      reason = 'sole_person_requires_exactly_one_row';
      if (roster.rows.length == 1) {
        reason = 'sole_person_id_invalid';
        // Reuse the existing selector validation, entirely in memory.
        selectedRequest = FindMyProbeRequest.parse(
          jsonEncode({'version': 1, 'selectedPersonId': roster.rows.single.id}),
        );
      }
    }
  } catch (error, stack) {
    if (reason != 'sole_person_id_invalid') {
      capturedRoster = () => Future.error(error, stack);
    }
  }
  final report = await runWindowsFindMyProbe(
    launchId: launchId,
    buildIdentifier: buildIdentifier,
    request: selectedRequest,
    sectionTimeout: sectionTimeout,
    reads: FindMyProbeReads(
      refreshDevices: reads.refreshDevices,
      refreshFollowing: capturedRoster,
      selectFriend: reads.selectFriend,
    ),
  );
  report['started_utc'] = validation['started_utc'];
  if (!selectedRequest.hasSelection) {
    report['selected'] = {
      ...(report['selected']! as Map<String, Object?>),
      'requested': true,
      'reason': reason,
    };
  }
  return report;
}

Future<Map<String, dynamic>> readControl(File file) async {
  if (await file.length() > 8192) throw StateError('control_rejected');
  final bytes = await file
      .openRead(0, 8193)
      .fold<List<int>>([], (result, chunk) => result..addAll(chunk));
  if (bytes.length > 8192) throw StateError('control_rejected');
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}

bool admitted(Map<String, dynamic> value, String launch, int processId) =>
    value['launch_id'] == launch && value['process_id'] == processId;

Future<void> awaitParentAdmission(
  Directory directory,
  String launch, {
  Duration budget = const Duration(seconds: 15),
}) async {
  final admission = await readControl(File('${directory.path}/admission.json'));
  if (admission['version'] != 1 ||
      admission['launch_id'] != launch ||
      admission['native_sha256'] != nativeSha) {
    throw StateError('findmy_testhost_preflight_required');
  }
  await File('${directory.path}/ready.json').writeAsString(
    jsonEncode({'launch_id': launch, 'process_id': pid}),
    flush: true,
  );
  final deadline = DateTime.now().add(budget);
  final go = File('${directory.path}/go.json');
  while (DateTime.now().isBefore(deadline)) {
    if (await go.exists()) {
      try {
        if (admitted(await readControl(go), launch, pid)) return;
      } on FormatException {
        // The parent's small write may be in progress. Never admit partial JSON.
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('findmy_testhost_parent_admission_required');
}

void main() {
  test(
    'live admission requires exact opt-in and rejects inherited other modes',
    () {
      for (final value in ['', '0', 'true', '01', '1 ', ' 1']) {
        expect(liveEnabled({liveEnable: value}), isFalse);
      }
      final valid = {
        liveEnable: '1',
        'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE': '1',
        'OPENBUBBLES_FINDMY_LAUNCH_ID': 'a' * 32,
        'OPENBUBBLES_FINDMY_SOURCE_HEAD': 'b' * 40,
        'OPENBUBBLES_TEST_NATIVE_LIBRARY': r'C:\synthetic\native.dll',
      };
      expect(() => requireLaunchEnvironment(valid), returnsNormally);
      expect(
        () => requireLaunchEnvironment({...valid, solePersonEnable: '1'}),
        returnsNormally,
      );
      for (final value in ['', '0', 'true', '1 ']) {
        expect(
          () => requireLaunchEnvironment({...valid, solePersonEnable: value}),
          throwsStateError,
        );
      }
      for (final key in valid.keys) {
        expect(
          () => requireLaunchEnvironment({...valid}..remove(key)),
          throwsStateError,
        );
      }
      expect(
        () => requireLaunchEnvironment({
          ...valid,
          'OPENBUBBLES_RUN_LIVE_WINDOWS_HARNESS': '1',
        }),
        throwsStateError,
      );
      expect(
        () => requireLaunchEnvironment({
          ...valid,
          'OPENBUBBLES_FINDMY_LAUNCH_ID': '${'a' * 32}\n',
        }),
        throwsStateError,
      );
    },
  );
  test('parent admission is bound to this launch and exact test process', () {
    expect(admitted({'launch_id': 'a', 'process_id': 12}, 'a', 12), isTrue);
    expect(admitted({'launch_id': 'a', 'process_id': 12}, 'b', 12), isFalse);
    expect(admitted({'launch_id': 'a', 'process_id': 12}, 'a', 13), isFalse);
    expect(admitted({}, 'a', 12), isFalse);
  });
  test(
    'offline parent handshake times out without go and accepts exact go',
    () async {
      final root = await Directory('build').create(recursive: true);
      final directory = await root.createTemp('findmy-admission-synthetic-');
      const launch = '0123456789abcdef0123456789abcdef';
      try {
        await File('${directory.path}/admission.json').writeAsString(
          jsonEncode({
            'version': 1,
            'launch_id': launch,
            'native_sha256': nativeSha,
          }),
        );
        await expectLater(
          awaitParentAdmission(
            directory,
            launch,
            budget: const Duration(milliseconds: 5),
          ),
          throwsStateError,
        );
        final ready = await readControl(File('${directory.path}/ready.json'));
        expect(admitted(ready, launch, pid), isTrue);
        await File(
          '${directory.path}/go.json',
        ).writeAsString(jsonEncode(ready));
        await awaitParentAdmission(directory, launch);
      } finally {
        for (final name in ['admission.json', 'ready.json', 'go.json']) {
          final file = File('${directory.path}/$name');
          if (await file.exists()) await file.delete();
        }
        await directory.delete();
      }
    },
  );

  test(
    'bounded retained Windows FMIP and FMF service reads',
    () async {
      requireLaunchEnvironment(Platform.environment);
      if (!Platform.isWindows) {
        throw StateError('findmy_testhost_windows_required');
      }
      final env = Platform.environment;
      final launch = env['OPENBUBBLES_FINDMY_LAUNCH_ID']!;
      final profile = Directory(
        '${env['APPDATA']}/OpenBubbles/cloudkit-v2-dev',
      );
      final directory = Directory(
        '${profile.path}/cloud-sync-v2/findmy-testhost/$launch',
      );
      // No FFI or profile-state access before the parent holds the mutex, verifies
      // retained state and artifact, and records our process for eventual cleanup.
      await awaitParentAdmission(directory, launch);
      var stage = 'artifact';
      var bridgeInitialized = false;
      var closing = false;
      ApsConnection? connection;
      final output = <String, Object?>{
        'version': 'findmy-windows-testhost-v1',
        'launch_id': launch,
        'process_id': pid,
        'native_sha256': nativeSha,
        'mode': 'service-reads-with-authorized-local-and-auth-housekeeping',
        'abi_verified': false,
        'select_sole_person': env[solePersonEnable] == '1',
        'state': 'failed',
      };
      try {
        final library = File(env['OPENBUBBLES_TEST_NATIVE_LIBRARY']!);
        if ((await sha256.bind(library.openRead()).first).toString() !=
            nativeSha) {
          throw StateError('artifact_rejected');
        }
        final request = await FindMyProbeRequest.read(
          profile,
        ).timeout(const Duration(seconds: 2));
        stage = 'bridge';
        // FRB 2.3.0 checks runtime version/content hash before exposing APIs. No
        // override or skipped check. Generated executeRustInitializers is empty.
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(library.path),
        ).timeout(const Duration(seconds: 10));
        bridgeInitialized = true;
        output['abi_verified'] = true;
        stage = 'keystore';
        api.doFirstTimeInit(path: profile.path);
        stage = 'hardware';
        final hardware = api.readHardware(path: profile.path);
        if (hardware == null) throw StateError('retained_hardware_required');
        final identity = api.decodeIdentity(identity: hardware.identity);
        final config = hardware.osConfig;
        stage = 'aps';
        final push = await api
            .setupPush(
              config: config,
              identity: identity,
              state: hardware.push,
              statePath: profile.path,
            )
            .then((value) {
              connection = value.$1;
              if (closing) api.closeAps(aps: value.$1);
              return value;
            })
            .timeout(const Duration(seconds: 10));
        if (push.$2 != null) throw StateError('aps_failed');
        stage = 'anisette';
        final anisette = await api
            .makeAnisette(path: profile.path, config: config, conn: connection!)
            .timeout(const Duration(seconds: 5));
        stage = 'account';
        final account = await api
            .restoreAccount(
              path: profile.path,
              anisette: anisette,
              config: config,
              conn: connection!,
            )
            .timeout(const Duration(seconds: 5));
        if (account == null) throw StateError('retained_account_required');
        final provider = api.makeTokenProvider(
          account: account,
          config: config,
        );
        stage = 'reads';
        final report = await runFindMyTestHostProbe(
          launchId: launch,
          buildIdentifier: env['OPENBUBBLES_FINDMY_SOURCE_HEAD']!,
          request: request,
          selectSolePerson: env[solePersonEnable] == '1',
          reads: bindWindowsFindMyNativeReads(
            makeDevices: () => api.makeFindMyPhone(
              path: profile.path,
              config: config,
              aps: connection!,
              anisette: anisette,
              provider: provider,
            ),
            makePeople: () => api.makeFindMyFriends(
              path: profile.path,
              config: config,
              aps: connection!,
              anisette: anisette,
              provider: provider,
            ),
            refreshDevices: (client) =>
                api.refreshDevices(config: config, client: client),
            refreshFollowing: (client) =>
                api.refreshFollowing(config: config, client: client),
            selectFriend: (client, id) =>
                api.selectFriend(config: config, client: client, friend: id),
          ),
        );
        final terminal = windowsFindMyProbeTerminal(report);
        output.addAll({
          'state': terminal.$1,
          'stage': terminal.$2,
          'probe': report,
        });
      } catch (error) {
        output.addAll({
          'stage': stage,
          'failure_category': error is TimeoutException ? 'timeout' : 'generic',
        });
      } finally {
        closing = true;
        try {
          if (connection != null) api.closeAps(aps: connection!);
          if (bridgeInitialized) RustLib.dispose();
        } catch (_) {
          output.addAll({
            'state': 'failed',
            'stage': 'cleanup',
            'failure_category': 'generic',
          });
        }
        await File(
          '${directory.path}/report.json',
        ).writeAsString(jsonEncode(output), flush: true);
      }
      expect(
        output['state'],
        'finished',
        reason: 'findmy_testhost_read_failed',
      );
    },
    skip: !liveEnabled(Platform.environment),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
