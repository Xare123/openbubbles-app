import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/cloud_sync_v2_windows_findmy_probe.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Adversarial end-to-end tests for runWindowsFindMyProbe with synthetic
// native rows. No Apple, network, or device interaction: all reads are
// injected fakes. These pin the qualifier scoring contract from the product
// side: exact top-level keys, reconciled counts, stale-vs-absent separation,
// lane independence, fail-closed selection, and the redacted binding digest.
// Requires the CI lane to execute (no Flutter SDK on the authoring box).
void main() {
  const launchId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const buildId = '06c3ca5cf';
  final fixedNow = DateTime.utc(2026, 9, 14, 12, 0, 40);
  int msAgo(int ms) => fixedNow.millisecondsSinceEpoch - ms;

  String expectedDigest(String canonical) {
    final mac = Hmac(sha256, utf8.encode(launchId));
    return mac
        .convert(utf8.encode('$findMyProbeSelectedIdentityDomain:$canonical'))
        .toString();
  }

  api.Location freshLoc() => api.Location(
    altitude: 0,
    floorLevel: 0,
    horizontalAccuracy: 10,
    isInaccurate: false,
    latitude: 37.35,
    longitude: -122.0,
    secureLocationTs: msAgo(60000),
    timestamp: msAgo(60000),
    verticalAccuracy: 10,
  );

  api.Location staleLoc() => api.Location(
    altitude: 0,
    floorLevel: 0,
    horizontalAccuracy: 10,
    isInaccurate: false,
    latitude: 37.35,
    longitude: -122.0,
    secureLocationTs: msAgo(3600000),
    timestamp: msAgo(3600000),
    verticalAccuracy: 10,
    isOld: true,
  );

  api.Follow person({
    required String id,
    List<String> accepted = const [],
    List<String> from = const [],
    api.Location? location,
    bool? revoked,
  }) => api.Follow(
    createTimestamp: 0,
    expires: 0,
    id: id,
    invitationAcceptedHandles: accepted,
    invitationFromHandles: from,
    isFromMessages: false,
    onlyInEvent: false,
    personIdHash: 'synthetic',
    secureLocationsCapable: false,
    shallowOrLiveSecureLocationsCapable: false,
    source: 'synthetic',
    tkPermission: false,
    updateTimestamp: 0,
    optedNotToShare: revoked,
    lastLocation: location,
    locateInProgress: false,
  );

  Future<FindMyProbeRead<api.FoundDevice>> Function() deviceReader(
    List<api.FoundDevice> rows,
  ) =>
      () => Future.value(
        FindMyProbeRead<api.FoundDevice>(rows, freshRequestCompleted: true),
      );

  Future<FindMyProbeRead<api.Follow>> Function() followReader(
    List<api.Follow> rows,
  ) =>
      () => Future.value(
        FindMyProbeRead<api.Follow>(rows, freshRequestCompleted: true),
      );

  Future<FindMyProbeRead<api.Follow>> Function(String) selectReader(
    List<api.Follow> rows,
  ) =>
      (_) => Future.value(
        FindMyProbeRead<api.Follow>(rows, freshRequestCompleted: true),
      );

  Future<FindMyProbeRead<api.Follow>> Function() throwFollowing() =>
      () => Future<FindMyProbeRead<api.Follow>>.error(
        StateError('synthetic-follow-failure'),
      );

  Future<FindMyProbeRead<api.Follow>> Function(String) throwSelection() =>
      (_) => Future<FindMyProbeRead<api.Follow>>.error(
        StateError('synthetic-selection-failure'),
      );

  Future<FindMyProbeRead<api.FoundDevice>> Function() throwDevices() =>
      () => Future<FindMyProbeRead<api.FoundDevice>>.error(
        StateError('synthetic-device-failure'),
      );

  FindMyProbeReads reads({
    required Future<FindMyProbeRead<api.FoundDevice>> Function() devices,
    required Future<FindMyProbeRead<api.Follow>> Function() following,
    required Future<FindMyProbeRead<api.Follow>> Function(String) select,
  }) => FindMyProbeReads(
    refreshDevices: devices,
    refreshFollowing: following,
    selectFriend: select,
  );

  Future<Map<String, Object?>> run({
    required FindMyProbeRequest request,
    required FindMyProbeReads probeReads,
    Duration sectionTimeout = const Duration(seconds: 35),
  }) => runWindowsFindMyProbe(
    launchId: launchId,
    buildIdentifier: buildId,
    request: request,
    reads: probeReads,
    now: () => fixedNow,
    sectionTimeout: sectionTimeout,
  );

  test('report top-level keys match the qualifier contract exactly', () async {
    final report = await run(
      request: const FindMyProbeRequest(),
      probeReads: reads(
        devices: deviceReader([]),
        following: followReader([]),
        select: selectReader([]),
      ),
    );
    expect(report.keys.toSet(), {
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
    });
    expect(report['live_reads_admitted'], isTrue);
    final items = report['items']! as Map;
    expect(items['state'], 'not-tested');
  });

  test('bound fresh selection carries digest and hides raw identity', () async {
    const handle = 'bound-person@example.test';
    final target = person(
      id: 'native-row-7',
      accepted: const ['Bound-Person@Example.test'],
      location: freshLoc(),
    );
    final other = person(id: 'native-row-8');
    final report = await run(
      request: const FindMyProbeRequest(selectedHandle: handle),
      probeReads: reads(
        devices: throwDevices(),
        following: followReader([other, target]),
        select: selectReader([target]),
      ),
    );
    final people = report['people']! as Map;
    expect(people['state'], 'observed');
    expect(people['returned_count'], 2);
    final devices = report['devices']! as Map;
    expect(devices['state'], 'failed');
    expect(devices['failure_category'], 'generic');
    final selected = report['selected']! as Map;
    expect(selected['state'], 'observed');
    expect(selected['selected_match'], isTrue);
    expect(selected['location_found'], isTrue);
    expect(
      selected['selected_identity_digest'],
      expectedDigest('handle:$handle'),
    );
    final buckets = selected['location_age_buckets'] as Map;
    expect(buckets['within_5_minutes'], 1);
    final encoded = jsonEncode(report);
    expect(encoded.contains(handle), isFalse);
    expect(encoded.contains('native-row-7'), isFalse);
  });

  test('ambiguous roster match fails closed without digest', () async {
    const handle = 'shared@example.test';
    final report = await run(
      request: const FindMyProbeRequest(selectedHandle: handle),
      probeReads: reads(
        devices: deviceReader([]),
        following: followReader([
          person(id: 'native-row-1', accepted: const [handle]),
          person(id: 'native-row-2', from: const [handle]),
        ]),
        select: selectReader([]),
      ),
    );
    final selected = report['selected']! as Map;
    expect(selected['selected_match'], isFalse);
    expect(selected['selected_identity_digest'], isNull);
    expect(selected['reason'], 'unique_selected_match_not_found');
  });

  test('failed selection read resets match and digest', () async {
    const handle = 'shared@example.test';
    final target = person(
      id: 'native-row-1',
      accepted: const [handle],
      location: freshLoc(),
    );
    final report = await run(
      request: const FindMyProbeRequest(selectedHandle: handle),
      probeReads: reads(
        devices: deviceReader([]),
        following: followReader([target]),
        select: throwSelection(),
      ),
    );
    final selected = report['selected']! as Map;
    expect(selected['state'], 'failed');
    expect(selected['selected_match'], isFalse);
    expect(selected['location_found'], isFalse);
    expect(selected['selected_identity_digest'], isNull);
  });

  test('selection timeout resets match and digest', () async {
    const handle = 'shared@example.test';
    final target = person(
      id: 'native-row-1',
      accepted: const [handle],
      location: freshLoc(),
    );
    final report = await run(
      request: const FindMyProbeRequest(selectedHandle: handle),
      probeReads: reads(
        devices: deviceReader([]),
        following: followReader([target]),
        select: (_) => Completer<FindMyProbeRead<api.Follow>>().future,
      ),
      sectionTimeout: const Duration(milliseconds: 25),
    );
    final selected = report['selected']! as Map;
    expect(selected['state'], 'timeout');
    expect(selected['selected_match'], isFalse);
    expect(selected['selected_identity_digest'], isNull);
  });

  test('stale and absent selections stay distinct under one binding', () async {
    const handle = 'shared@example.test';
    Future<Map> selectedFor(api.Follow row) async {
      final report = await run(
        request: const FindMyProbeRequest(selectedHandle: handle),
        probeReads: reads(
          devices: deviceReader([]),
          following: followReader([row]),
          select: selectReader([row]),
        ),
      );
      return report['selected']! as Map;
    }

    final staleRow = person(
      id: 'native-row-1',
      accepted: const [handle],
      location: staleLoc(),
    );
    final stale = await selectedFor(staleRow);
    expect(stale['selected_match'], isTrue);
    expect(stale['location_found'], isTrue);
    expect((stale['location_age_buckets'] as Map)['older'], 1);
    expect((stale['location_age_buckets'] as Map)['within_5_minutes'], 0);
    expect(stale['selected_identity_digest'], expectedDigest('handle:$handle'));

    final absentRow = person(id: 'native-row-1', accepted: const [handle]);
    final absent = await selectedFor(absentRow);
    expect(absent['selected_match'], isTrue);
    expect(absent['location_found'], isFalse);
    expect((absent['location_age_buckets'] as Map)['absent'], 1);
    expect(
      absent['selected_identity_digest'],
      expectedDigest('handle:$handle'),
    );
  });

  test('present-but-sentinel coordinates are unavailable, not found', () async {
    const handle = 'shared@example.test';
    final row = person(
      id: 'native-row-1',
      accepted: const [handle],
      location: api.Location(
        altitude: 0,
        floorLevel: 0,
        horizontalAccuracy: 10,
        isInaccurate: false,
        latitude: 0,
        longitude: 0,
        secureLocationTs: msAgo(60000),
        timestamp: msAgo(60000),
        verticalAccuracy: 10,
      ),
    );
    final report = await run(
      request: const FindMyProbeRequest(selectedHandle: handle),
      probeReads: reads(
        devices: deviceReader([]),
        following: followReader([row]),
        select: selectReader([row]),
      ),
    );
    final selected = report['selected']! as Map;
    expect(selected['selected_match'], isTrue);
    expect(selected['location_found'], isFalse);
    expect((selected['location_age_buckets'] as Map)['within_5_minutes'], 1);
    expect(
      selected['selected_identity_digest'],
      expectedDigest('handle:$handle'),
    );
  });

  test('people failure does not erase devices or invent binding', () async {
    const handle = 'shared@example.test';
    final report = await run(
      request: const FindMyProbeRequest(selectedHandle: handle),
      probeReads: reads(
        devices: deviceReader([]),
        following: throwFollowing(),
        select: selectReader([]),
      ),
    );
    final people = report['people']! as Map;
    expect(people['state'], 'failed');
    final devices = report['devices']! as Map;
    expect(devices['state'], 'observed');
    expect(devices['returned_count'], 0);
    final selected = report['selected']! as Map;
    expect(selected['reason'], 'roster_unavailable');
    expect(selected['selected_match'], isFalse);
    expect(selected['selected_identity_digest'], isNull);
  });
  test('observed-but-empty follow-up clears a stale roster digest', () async {
    const handle = 'shared@example.test';
    final target = person(
      id: 'native-row-1',
      accepted: const [handle],
      location: freshLoc(),
    );
    final report = await run(
      request: const FindMyProbeRequest(selectedHandle: handle),
      probeReads: reads(
        devices: deviceReader([]),
        following: followReader([target]),
        select: selectReader([]),
      ),
    );
    final selected = report['selected']! as Map;
    expect(selected['state'], 'observed');
    expect(selected['selected_match'], isFalse);
    expect(selected['location_found'], isFalse);
    expect(selected['selected_identity_digest'], isNull);
  });
  test('observed different-row follow-up clears the digest', () async {
    const handle = 'shared@example.test';
    final target = person(
      id: 'native-row-1',
      accepted: const [handle],
      location: freshLoc(),
    );
    final stranger = person(
      id: 'native-row-9',
      accepted: const ['stranger@example.test'],
      location: freshLoc(),
    );
    final report = await run(
      request: const FindMyProbeRequest(selectedHandle: handle),
      probeReads: reads(
        devices: deviceReader([]),
        following: followReader([target]),
        select: selectReader([stranger]),
      ),
    );
    final selected = report['selected']! as Map;
    expect(selected['state'], 'observed');
    expect(selected['selected_match'], isFalse);
    expect(selected['location_found'], isFalse);
    expect(selected['selected_identity_digest'], isNull);
  });
}
