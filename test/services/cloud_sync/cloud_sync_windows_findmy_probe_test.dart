import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_findmy_probe.dart';
import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:flutter_test/flutter_test.dart';

const launch = '0123456789abcdef0123456789abcdef';
const build = '4388109691ce-dirty-0123456789ab';
const personId = 'synthetic-selected-person';
final instant = DateTime.utc(2026, 9, 10);

api.Location location({int? timestamp, bool? old}) => api.Location(
  altitude: 0,
  floorLevel: 0,
  horizontalAccuracy: 1,
  isInaccurate: false,
  latitude: 1,
  longitude: 1,
  secureLocationTs: 0,
  timestamp: timestamp ?? instant.millisecondsSinceEpoch,
  verticalAccuracy: 1,
  isOld: old,
);

api.Follow person({
  api.Location? point,
  bool? optedOut,
  List<String> handles = const [],
}) => api.Follow(
  createTimestamp: 0,
  expires: 0,
  id: personId,
  invitationAcceptedHandles: handles,
  invitationFromHandles: const [],
  isFromMessages: false,
  onlyInEvent: false,
  personIdHash: 'private-hash',
  secureLocationsCapable: true,
  shallowOrLiveSecureLocationsCapable: false,
  source: 'private-source',
  tkPermission: true,
  updateTimestamp: 0,
  optedNotToShare: optedOut,
  lastLocation: point,
  locateInProgress: false,
);

FindMyProbeRead<T> fresh<T>(List<T> rows) =>
    FindMyProbeRead(rows, freshRequestCompleted: true);

FindMyProbeReads reads({
  Future<FindMyProbeRead<api.FoundDevice>> Function()? devices,
  Future<FindMyProbeRead<api.Follow>> Function()? people,
  Future<FindMyProbeRead<api.Follow>> Function(String)? select,
}) => FindMyProbeReads(
  refreshDevices: devices ?? () async => fresh(<api.FoundDevice>[]),
  refreshFollowing: people ?? () async => fresh(<api.Follow>[]),
  selectFriend: select ?? (_) async => fresh(<api.Follow>[]),
);

Future<Map<String, Object?>> probe({
  FindMyProbeReads? callbacks,
  bool select = false,
  Duration timeout = const Duration(milliseconds: 50),
}) => runWindowsFindMyProbe(
  launchId: launch,
  buildIdentifier: build,
  now: () => instant,
  reads: callbacks,
  sectionTimeout: timeout,
  request: FindMyProbeRequest(selectedPersonId: select ? personId : null),
);

Map<String, Object?> section(Map<String, Object?> report, String key) =>
    report[key]! as Map<String, Object?>;

void main() {
  test(
    'private handle selects one native roster ID without reporting either selector',
    () async {
      final request = FindMyProbeRequest.parse(
        jsonEncode({'version': 1, 'selectedHandle': personId}),
      );
      final report = await runWindowsFindMyProbe(
        launchId: launch,
        buildIdentifier: build,
        request: request,
        now: () => instant,
        reads: reads(
          people: () async => fresh([
            person(handles: [personId.toUpperCase()]),
          ]),
          select: (id) async {
            expect(id, personId);
            return fresh([person(point: location())]);
          },
        ),
      );
      expect(section(report, 'selected')['location_found'], true);
      expect(jsonEncode(report), isNot(contains(personId)));
      expect(
        () => FindMyProbeRequest.parse(
          jsonEncode({
            'version': 1,
            'selectedHandle': personId,
            'selectedPersonId': personId,
          }),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'production native binding awaits constructors, refreshes and selected response',
    () async {
      final calls = <String>[];
      final bound = bindWindowsFindMyNativeReads<int, int>(
        makeDevices: () async {
          calls.add('make-device');
          return 1;
        },
        makePeople: () async {
          calls.add('make-people');
          return 2;
        },
        refreshDevices: (client) async {
          expect(client, 1);
          calls.add('refresh-device');
          return [const api.FoundDevice(features: {})];
        },
        refreshFollowing: (client) async {
          expect(client, 2);
          calls.add('refresh-people');
          return [person()];
        },
        selectFriend: (client, id) async {
          expect(client, 2);
          expect(id, personId);
          calls.add('select');
          return [person(point: location())];
        },
      );
      final report = await probe(callbacks: bound, select: true);
      expect(calls.toSet().length, 5);
      expect(
        calls.indexOf('refresh-device'),
        greaterThan(calls.indexOf('make-device')),
      );
      expect(
        calls.indexOf('refresh-people'),
        greaterThan(calls.indexOf('make-people')),
      );
      expect(calls.last, 'select');
      expect(section(report, 'selected')['location_found'], true);
      expect(windowsFindMyProbeTerminal(report), (
        'finished',
        'findmy-probe-complete',
      ));
    },
  );

  test(
    'native constructor failure is isolated, not an empty successful refresh',
    () async {
      var deviceRefresh = false;
      final report = await probe(
        callbacks: bindWindowsFindMyNativeReads<int, int>(
          makeDevices: () async =>
              throw StateError('private-constructor-error'),
          makePeople: () async => 2,
          refreshDevices: (_) async {
            deviceRefresh = true;
            return [];
          },
          refreshFollowing: (_) async => [],
          selectFriend: (_, __) async => [],
        ),
      );
      expect(deviceRefresh, false);
      expect(section(report, 'devices')['state'], 'failed');
      expect(section(report, 'people')['state'], 'observed');
      expect(windowsFindMyProbeTerminal(report), (
        'finished',
        'findmy-probe-partial',
      ));
      expect(jsonEncode(report), isNot(contains('private-constructor-error')));
    },
  );

  test('timed-out native initialization cannot start a late refresh', () async {
    final pending = Completer<int>();
    var refreshed = false;
    final report = await probe(
      callbacks: bindWindowsFindMyNativeReads<int, int>(
        makeDevices: () => pending.future,
        makePeople: () async => 2,
        refreshDevices: (_) async {
          refreshed = true;
          return [];
        },
        refreshFollowing: (_) async => [],
        selectFriend: (_, __) async => [],
        initializationBudget: const Duration(milliseconds: 5),
      ),
    );
    expect(section(report, 'devices')['state'], 'timeout');
    pending.complete(1);
    await Future<void>.delayed(Duration.zero);
    expect(refreshed, false);
  });

  test(
    'native timeout is classified without leaking bridge text; all failure is not finished',
    () async {
      final report = await probe(
        callbacks: reads(
          devices: () async =>
              throw AnyhowException('findmy_probe_native_timeout'),
          people: () async => throw StateError('private-body'),
        ),
      );
      expect(section(report, 'devices')['state'], 'timeout');
      expect(section(report, 'devices')['failure_category'], 'timeout');
      expect(section(report, 'people')['failure_category'], 'generic');
      expect(windowsFindMyProbeTerminal(report), (
        'failed',
        'findmy-probe-reads-failed',
      ));
      expect(jsonEncode(report), isNot(contains('private-body')));
    },
  );

  test(
    'HTTP status survives the real adapter without preventing people reads',
    () async {
      for (final status in [401, 429, 503]) {
        final callbacks = bindWindowsFindMyNativeReads<int, int>(
          makeDevices: () async => 1,
          makePeople: () async => 2,
          refreshDevices: (_) async =>
              throw AnyhowException('findmy_probe_native_http_$status'),
          refreshFollowing: (_) async => [person()],
          selectFriend: (_, _) async => [person()],
        );
        final report = await probe(callbacks: callbacks);
        expect(section(report, 'devices'), {
          'state': 'failed',
          'fresh_request_completed': false,
          'returned_count': null,
          'reason': 'section_read_failed',
          'failure_category': 'http',
          'http_status': status,
        });
        expect(section(report, 'people')['state'], 'observed');
      }
    },
  );

  test(
    'decode, transport and generic native failures expose only fixed categories',
    () async {
      for (final category in ['decode', 'transport', 'generic']) {
        final marker = category == 'generic' ? 'read_failed' : category;
        final report = await probe(
          callbacks: reads(
            people: () async =>
                throw AnyhowException('findmy_probe_native_$marker'),
          ),
        );
        expect(section(report, 'devices')['state'], 'observed');
        expect(section(report, 'people')['failure_category'], category);
        expect(section(report, 'people').containsKey('http_status'), false);
      }
    },
  );

  test(
    'only exact typed native markers are admitted, never substrings or bodies',
    () async {
      for (final error in [
        StateError('findmy_probe_native_timeout'),
        AnyhowException('private-url/findmy_probe_native_http_401'),
        AnyhowException('findmy_probe_native_http_401 private-body'),
        AnyhowException('findmy_probe_native_http_401\n'),
        AnyhowException('findmy_probe_native_http_099'),
        AnyhowException('findmy_probe_native_http_1000'),
        AnyhowException('findmy_probe_native_timeout private-body'),
        AnyhowException('private-body'),
      ]) {
        final report = await probe(
          callbacks: reads(devices: () async => throw error),
        );
        expect(section(report, 'devices')['state'], 'failed');
        expect(section(report, 'devices')['failure_category'], 'generic');
        expect(section(report, 'devices').containsKey('http_status'), false);
        expect(jsonEncode(report), isNot(contains('private-')));
      }
    },
  );

  test('Dart deadline remains timeout, with no invented HTTP status', () async {
    final report = await probe(
      callbacks: reads(
        devices: () => Completer<FindMyProbeRead<api.FoundDevice>>().future,
      ),
      timeout: const Duration(milliseconds: 1),
    );
    expect(section(report, 'devices')['failure_category'], 'timeout');
    expect(section(report, 'devices').containsKey('http_status'), false);
    expect(section(report, 'people')['state'], 'observed');
  });

  test(
    'report schema is an allowlist, including nested aggregate keys',
    () async {
      final report = await probe(
        select: true,
        callbacks: reads(
          devices: () async => fresh([
            const api.FoundDevice(features: {}, deviceClass: 'iPhone'),
          ]),
          people: () async => fresh([person()]),
          select: (_) async => fresh([person(point: location())]),
        ),
      );
      const allowed = {
        'version',
        'launch_id',
        'build_identifier',
        'started_utc',
        'completed_utc',
        'mode',
        'live_reads_admitted',
        'location_meaning',
        'sharing_meaning',
        'freshness_meaning',
        'devices',
        'people',
        'selected',
        'items',
        'state',
        'reason',
        'failure_category',
        'http_status',
        'fresh_request_completed',
        'returned_count',
        'requested',
        'selected_match',
        'location_found',
        'classes',
        'native_family_share_true_count',
        'native_location_present_count',
        'valid_coordinate_pair_count',
        'native_is_old_true_count',
        'location_age_buckets',
        'native_opted_not_to_share_true_count',
        'native_opted_not_to_share_false_count',
        'native_opted_not_to_share_unknown_count',
        'native_tk_permission_true_count',
        'native_locate_in_progress_count',
        'absent',
        'unknown',
        'future',
        'within_5_minutes',
        'older',
        'iphone',
        'ipad',
        'mac',
        'watch',
        'airpods',
        'ipod',
        'accessory',
        'other',
      };
      void check(Map value) {
        for (final entry in value.entries) {
          expect(allowed, contains(entry.key));
          if (entry.value is Map) check(entry.value as Map);
        }
      }

      check(report);
      check(
        await probe(
          callbacks: reads(
            devices: () async =>
                throw AnyhowException('findmy_probe_native_http_503'),
            people: () async =>
                throw AnyhowException('findmy_probe_native_decode'),
          ),
        ),
      );
    },
  );

  test(
    'default request never selects a person, empty selection response is not location evidence',
    () async {
      var calls = 0;
      final callbacks = reads(
        people: () async => fresh([person()]),
        select: (_) async {
          calls++;
          return fresh(<api.Follow>[]);
        },
      );
      final withoutSelection = await probe(callbacks: callbacks);
      expect(calls, 0);
      expect(section(withoutSelection, 'selected')['requested'], false);
      final selected = await probe(callbacks: callbacks, select: true);
      expect(calls, 1);
      expect(section(selected, 'selected')['selected_match'], false);
      expect(section(selected, 'selected')['location_found'], false);
      expect(section(selected, 'selected')['fresh_request_completed'], true);
    },
  );
  test(
    'no prepared session fails closed, never reports zero cloud rows',
    () async {
      final report = await probe(select: true);
      expect(report['live_reads_admitted'], false);
      expect(report['launch_id'], launch);
      expect(report['build_identifier'], build);
      for (final name in ['devices', 'people', 'selected', 'items']) {
        expect(section(report, name)['state'], 'not-tested');
        expect(section(report, name)['returned_count'], isNull);
        expect(section(report, name)['fresh_request_completed'], false);
      }
    },
  );

  test(
    'real orchestration refreshes both sections then consumes selection response',
    () async {
      final calls = <String>[];
      final report = await probe(
        select: true,
        callbacks: reads(
          devices: () async {
            calls.add('devices');
            return fresh([
              api.FoundDevice(
                features: const {},
                deviceClass: 'AirPods',
                location: location(),
                name: 'private-device-name',
                id: 'private-device-id',
              ),
            ]);
          },
          people: () async {
            calls.add('people');
            return fresh([person()]);
          },
          select: (id) async {
            expect(id, personId);
            calls.add('selection');
            return fresh([person(point: location(), optedOut: false)]);
          },
        ),
      );
      expect(calls, containsAll(['devices', 'people', 'selection']));
      expect(calls.indexOf('selection'), greaterThan(calls.indexOf('people')));
      expect(section(report, 'devices')['classes'], {'airpods': 1});
      expect(section(report, 'people')['native_location_present_count'], 0);
      expect(section(report, 'selected')['location_found'], true);
      expect(section(report, 'selected')['selected_match'], true);
      expect(
        section(report, 'selected')['native_opted_not_to_share_false_count'],
        1,
      );
      final encoded = jsonEncode(report);
      for (final secret in [
        personId,
        'private-device-name',
        'private-device-id',
        'private-hash',
        'private-source',
        'latitude',
        'longitude',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
    },
  );

  test(
    'cache-only callback is not successful cloud evidence and cannot select',
    () async {
      var selected = false;
      final report = await probe(
        select: true,
        callbacks: reads(
          people: () async =>
              FindMyProbeRead([person()], freshRequestCompleted: false),
          select: (_) async {
            selected = true;
            return fresh([person()]);
          },
        ),
      );
      expect(selected, false);
      expect(section(report, 'people')['reason'], 'fresh_request_not_proven');
      expect(section(report, 'selected')['reason'], 'roster_unavailable');
      expect(section(report, 'devices')['state'], 'observed');
      expect(section(report, 'devices')['returned_count'], 0);
    },
  );

  test(
    'device timeout cannot prevent people and selection; late completion cannot mutate report',
    () async {
      final pending = Completer<FindMyProbeRead<api.FoundDevice>>();
      final report = await probe(
        select: true,
        callbacks: reads(
          devices: () => pending.future,
          people: () async => fresh([person()]),
          select: (_) async => fresh([person(point: location())]),
        ),
      );
      expect(section(report, 'devices')['state'], 'timeout');
      expect(section(report, 'selected')['location_found'], true);
      final before = jsonEncode(report);
      pending.complete(fresh([const api.FoundDevice(features: {})]));
      await Future<void>.delayed(Duration.zero);
      expect(jsonEncode(report), before);
    },
  );

  test(
    'synchronous people failure does not prevent devices or leak exception',
    () async {
      final report = await probe(
        select: true,
        callbacks: reads(people: () => throw StateError('private-server-body')),
      );
      expect(section(report, 'devices')['state'], 'observed');
      expect(section(report, 'people')['state'], 'failed');
      expect(section(report, 'selected')['reason'], 'roster_unavailable');
      expect(jsonEncode(report), isNot(contains('private-server-body')));
    },
  );

  test(
    'people timeout leaves devices usable and selection unattempted',
    () async {
      var selected = false;
      final report = await probe(
        select: true,
        callbacks: reads(
          people: () => Completer<FindMyProbeRead<api.Follow>>().future,
          select: (_) async {
            selected = true;
            return fresh([person()]);
          },
        ),
      );
      expect(section(report, 'devices')['state'], 'observed');
      expect(section(report, 'people')['state'], 'timeout');
      expect(selected, false);
    },
  );

  test(
    'selection timeout preserves roster evidence and cannot imply stopped sharing',
    () async {
      final report = await probe(
        select: true,
        callbacks: reads(
          people: () async => fresh([person()]),
          select: (_) => Completer<FindMyProbeRead<api.Follow>>().future,
        ),
      );
      expect(section(report, 'people')['returned_count'], 1);
      expect(
        section(report, 'people')['native_opted_not_to_share_unknown_count'],
        1,
      );
      expect(section(report, 'selected')['state'], 'timeout');
      expect(section(report, 'selected')['location_found'], false);
      expect(report['sharing_meaning'], contains('absence_does_not_establish'));
    },
  );

  test(
    'missing and ambiguous selection never calls selected-person API',
    () async {
      for (final roster in [
        <api.Follow>[],
        [person(), person()],
      ]) {
        var calls = 0;
        final report = await probe(
          select: true,
          callbacks: reads(
            people: () async => fresh(roster),
            select: (_) async {
              calls++;
              return fresh([person()]);
            },
          ),
        );
        expect(calls, 0);
        expect(section(report, 'selected')['selected_match'], false);
      }
    },
  );

  test(
    'freshness and native old flag are independently qualified aggregate counts',
    () async {
      final report = await probe(
        callbacks: reads(
          devices: () async => fresh([
            const api.FoundDevice(
              features: {},
              deviceClass: 'private-unknown-class',
            ),
            api.FoundDevice(
              features: const {},
              location: location(timestamp: 0),
            ),
            api.FoundDevice(features: const {}, location: location(old: true)),
            api.FoundDevice(
              features: const {},
              location: location(timestamp: instant.millisecondsSinceEpoch + 1),
            ),
            api.FoundDevice(
              features: const {},
              location: location(
                timestamp: instant.millisecondsSinceEpoch - 300001,
              ),
            ),
          ]),
        ),
      );
      expect(section(report, 'devices')['location_age_buckets'], {
        'absent': 1,
        'unknown': 1,
        'future': 1,
        'within_5_minutes': 1,
        'older': 1,
      });
      expect(section(report, 'devices')['native_is_old_true_count'], 1);
      expect(section(report, 'devices')['classes'], {'other': 5});
      expect(jsonEncode(report), isNot(contains('private-unknown-class')));
    },
  );

  test(
    'private request and launch contracts reject extra modes, fields and unbounded inputs',
    () async {
      expect(
        FindMyProbeRequest.parse('{"version":1}').selectedPersonId,
        isNull,
      );
      expect(
        FindMyProbeRequest.parse(
          jsonEncode({'version': 1, 'selectedPersonId': personId}),
        ).selectedPersonId,
        personId,
      );
      for (final input in [
        '{}',
        '{"version":2}',
        '{"version":1.0}',
        '{"version":1,"ring":true}',
        '{"version":1,"selectedPersonId":null}',
        '{"version":1,"selectedPersonId":" "}',
        jsonEncode({'version': 1, 'selectedPersonId': 'x' * 5000}),
      ]) {
        expect(() => FindMyProbeRequest.parse(input), throwsStateError);
      }
      expect(
        CloudSyncV2WindowsHarnessOperation.parse([
          'probe-findmy',
          '--launch-id=$launch',
        ]),
        CloudSyncV2WindowsHarnessOperation.findMyProbe,
      );
      expect(
        () => CloudSyncV2WindowsHarnessOperation.parse([
          'probe-findmy',
          'local-write',
          '--launch-id=$launch',
        ]),
        throwsStateError,
      );
      await expectLater(
        runWindowsFindMyProbe(
          launchId: launch,
          buildIdentifier: build,
          sectionTimeout: const Duration(seconds: 36),
        ),
        throwsStateError,
      );
      await expectLater(
        runWindowsFindMyProbe(
          launchId: launch,
          buildIdentifier: '$build-local-write',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'production dispatch performs only the dedicated retained Find My bootstrap',
    () {
      final source = File(
        'lib/cloud_sync_v2_windows_harness.dart',
      ).readAsStringSync();
      final dispatch = source.indexOf('await _runWindowsFindMyProbe();');
      for (final call in [
        'await RustLib.init()',
        'await Logger.init()',
        'api.doFirstTimeInit(',
        'await Database.init(',
      ]) {
        expect(dispatch, greaterThan(0));
        expect(dispatch, lessThan(source.indexOf(call)));
      }
      final body = source.substring(
        source.indexOf('Future<void> _runWindowsFindMyProbe()'),
        source.indexOf(
          'Map<String, Object?> cloudSyncV2WindowsHarnessStatusPayload',
        ),
      );
      expect(body, contains('await api.doFirstTimeInit('));
      expect(body, contains('await prepareWindowsFindMyProbeReads('));
      expect(body, contains('runWindowsFindMyProbe('));
      expect(body, contains('reads: reads'));
      for (final forbidden in [
        '_activateCloudKitClient',
        '_rebuildSemanticRuntime',
        'Database.init',
        'Logger.init',
        'makeFindmy',
        'registerIds',
        'tryAuth',
      ]) {
        expect(body, isNot(contains(forbidden)));
      }
      final adapter = File(
        'lib/cloud_sync_v2_windows_findmy_probe.dart',
      ).readAsStringSync();
      for (final actualRead in [
        'api.makeFindMyPhone(',
        'api.makeFindMyFriends(',
        'api.refreshDevices(',
        'api.refreshFollowing(',
        'api.selectFriend(',
      ]) {
        expect(adapter, contains(actualRead));
      }
      for (final forbidden in [
        'api.getDevices(',
        'api.getFollowing(',
        'api.makeCloudkit(',
        'api.makeKeychain(',
        'api.registerIds(',
        'api.resetAnisette(',
        'api.makeFindmy(',
      ]) {
        expect(adapter, isNot(contains(forbidden)));
      }
      final launcher = File(
        'tooling/windows/run_cloud_sync_v2_dev.ps1',
      ).readAsStringSync();
      expect(launcher, contains("@('probe-findmy')"));
      expect(launcher, contains('-ExpectedBuildIdentifier'));
      expect(
        launcher,
        contains("@('findmy-probe-complete', 'findmy-probe-partial')"),
      );
      expect(
        launcher,
        contains('OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE'),
      );
    },
  );
}
