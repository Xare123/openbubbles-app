import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/cloud_sync_v2_windows_findmy_probe.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

import 'findmy_windows_live_test.dart' as host;

const launch = '0123456789abcdef0123456789abcdef';
const build = 'abcdef0123456789';
const privateId = 'synthetic-private-id';
const privateHandle = 'synthetic-private-handle';

api.Follow person(String id, {List<String> handles = const []}) => api.Follow(
  createTimestamp: 0,
  expires: 0,
  id: id,
  invitationAcceptedHandles: handles,
  invitationFromHandles: const [],
  isFromMessages: false,
  onlyInEvent: false,
  personIdHash: 'synthetic-hash',
  secureLocationsCapable: true,
  shallowOrLiveSecureLocationsCapable: false,
  source: 'synthetic-source',
  tkPermission: false,
  updateTimestamp: 0,
  optedNotToShare: true,
  locateInProgress: false,
);

FindMyProbeRead<T> fresh<T>(List<T> rows) =>
    FindMyProbeRead(rows, freshRequestCompleted: true);

class Pass {
  int rosterCalls = 0;
  int deviceCalls = 0;
  final selectedIds = <String>[];
  final Future<FindMyProbeRead<api.Follow>> Function() roster;
  final Future<FindMyProbeRead<api.Follow>> Function(String)? selected;
  Pass(this.roster, {this.selected});

  Future<Map<String, Object?>> run({
    bool enabled = true,
    FindMyProbeRequest request = const FindMyProbeRequest(),
  }) => host.runFindMyTestHostProbe(
    launchId: launch,
    buildIdentifier: build,
    request: request,
    selectSolePerson: enabled,
    sectionTimeout: const Duration(milliseconds: 20),
    reads: FindMyProbeReads(
      refreshDevices: () async {
        deviceCalls++;
        return fresh(<api.FoundDevice>[]);
      },
      refreshFollowing: () {
        rosterCalls++;
        return roster();
      },
      selectFriend: (id) async {
        selectedIds.add(id);
        return selected == null ? fresh([person(id)]) : await selected!(id);
      },
    ),
  );
}

Map<String, Object?> section(Map<String, Object?> report, String key) =>
    report[key]! as Map<String, Object?>;

void main() {
  test(
    'opt-in selects exact sole ID using one same-pass roster; output stays private',
    () async {
      final pass = Pass(
        () async => fresh([
          person(privateId, handles: [privateHandle]),
        ]),
      );
      final report = await pass.run();
      expect(pass.rosterCalls, 1);
      expect(pass.deviceCalls, 1);
      expect(pass.selectedIds, [privateId]);
      expect(section(report, 'people')['returned_count'], 1);
      expect(section(report, 'selected')['state'], 'observed');
      expect(section(report, 'selected')['selected_match'], true);
      expect(section(report, 'selected')['location_found'], false);
      expect(jsonEncode(report), isNot(contains(privateId)));
      expect(jsonEncode(report), isNot(contains(privateHandle)));
    },
  );

  test('default does not select a sole person', () async {
    final pass = Pass(() async => fresh([person(privateId)]));
    final report = await pass.run(enabled: false);
    expect(pass.rosterCalls, 1);
    expect(pass.selectedIds, isEmpty);
    expect(section(report, 'selected')['requested'], false);
  });

  for (final request in [
    const FindMyProbeRequest(selectedPersonId: 'explicit-id'),
    const FindMyProbeRequest(selectedHandle: privateHandle),
  ]) {
    test(
      'explicit ${request.selectedPersonId == null ? 'handle' : 'ID'} takes precedence',
      () async {
        final pass = Pass(
          () async => fresh([
            person(privateId),
            person('explicit-id', handles: [privateHandle]),
          ]),
        );
        await pass.run(request: request);
        expect(pass.rosterCalls, 1);
        expect(pass.selectedIds, ['explicit-id']);
      },
    );
  }
  test(
    'unmatched explicit selection never falls back to the sole row',
    () async {
      final pass = Pass(() async => fresh([person(privateId)]));
      final report = await pass.run(
        request: const FindMyProbeRequest(selectedPersonId: 'absent'),
      );
      expect(pass.selectedIds, isEmpty);
      expect(section(report, 'selected')['state'], 'not-tested');
    },
  );

  for (final count in [0, 2]) {
    test('$count fresh rows do not choose the first person', () async {
      final pass = Pass(
        () async => fresh(List.generate(count, (i) => person('synthetic-$i'))),
      );
      final report = await pass.run();
      expect(pass.rosterCalls, 1);
      expect(pass.selectedIds, isEmpty);
      expect(section(report, 'selected')['state'], 'not-tested');
      expect(
        section(report, 'selected')['reason'],
        'sole_person_requires_exactly_one_row',
      );
      expect(windowsFindMyProbeTerminal(report).$2, 'findmy-probe-partial');
    });
  }
  test('cached singleton is not fresh selection authority', () async {
    final pass = Pass(
      () async =>
          FindMyProbeRead([person(privateId)], freshRequestCompleted: false),
    );
    final report = await pass.run();
    expect(pass.selectedIds, isEmpty);
    expect(section(report, 'people')['state'], 'not-tested');
    expect(section(report, 'selected')['state'], 'not-tested');
  });
  test(
    'failed roster is replayed as failure, not refetched or disclosed',
    () async {
      final pass = Pass(() async => throw StateError(privateId));
      final report = await pass.run();
      expect(pass.rosterCalls, 1);
      expect(pass.deviceCalls, 1);
      expect(pass.selectedIds, isEmpty);
      expect(section(report, 'people')['state'], 'failed');
      expect(section(report, 'selected')['state'], 'not-tested');
      expect(jsonEncode(report), isNot(contains(privateId)));
    },
  );
  test('timed-out roster cannot select on late completion', () async {
    final pending = Completer<FindMyProbeRead<api.Follow>>();
    final pass = Pass(() => pending.future);
    final report = await pass.run();
    final before = jsonEncode(report);
    pending.complete(fresh([person(privateId)]));
    await Future<void>.delayed(Duration.zero);
    expect(pass.rosterCalls, 1);
    expect(pass.deviceCalls, 1);
    expect(pass.selectedIds, isEmpty);
    expect(section(report, 'people')['state'], 'timeout');
    expect(jsonEncode(report), before);
  });
  test(
    'selected callback stays bounded, with roster evidence retained',
    () async {
      final pending = Completer<FindMyProbeRead<api.Follow>>();
      final pass = Pass(
        () async => fresh([person(privateId)]),
        selected: (_) => pending.future,
      );
      final report = await pass.run();
      expect(pass.rosterCalls, 1);
      expect(pass.selectedIds, [privateId]);
      expect(section(report, 'people')['state'], 'observed');
      expect(section(report, 'selected')['state'], 'timeout');
      pending.complete(fresh([person(privateId)]));
    },
  );
  test(
    'invalid sole ID stays not-tested without losing fresh roster',
    () async {
      final pass = Pass(() async => fresh([person('')]));
      final report = await pass.run();
      expect(pass.rosterCalls, 1);
      expect(pass.selectedIds, isEmpty);
      expect(section(report, 'people')['state'], 'observed');
      expect(section(report, 'selected')['reason'], 'sole_person_id_invalid');
    },
  );
}
