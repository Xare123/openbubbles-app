import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:path/path.dart' as path;

/// Dedicated Find My path. Retained-account auth refresh is allowed; no CloudKit
/// or IDS client, item client, account migration, or sharing writer is started.
/// Native reads have 15s cancellation deadlines; Dart includes initialization
/// and refresh in one 35s section, with a process watchdog as the outer bound.
const findMyProbeRequestFile = 'windows-findmy-probe-request.json';
const findMyProbeVersion = 'windows-findmy-probe-v1';
const findMyProbeSectionTimeout = Duration(seconds: 35);

// Only the native bridge's exact, finite marker protocol can add error evidence.
// Never stringify arbitrary exceptions or copy their message into the report.
({String category, int? httpStatus}) _readFailure(Object error) {
  if (error is! AnyhowException) return (category: 'generic', httpStatus: null);
  final message = error.message;
  final category = switch (message) {
    'findmy_probe_native_timeout' => 'timeout',
    'findmy_probe_native_decode' => 'decode',
    'findmy_probe_native_transport' => 'transport',
    _ => 'generic',
  };
  final status = RegExp(
    r'^findmy_probe_native_http_([1-9][0-9]{2})$',
  ).firstMatch(message);
  if (status != null && status.end == message.length) {
    return (category: 'http', httpStatus: int.parse(status.group(1)!));
  }
  return (category: category, httpStatus: null);
}

Future<FindMyProbeReads> prepareWindowsFindMyProbeReads(
  Directory profile, {
  Future<void> Function(String stage)? onStage,
}) async {
  if (!Platform.isWindows ||
      Platform.environment['OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE'] !=
          '1') {
    throw StateError('findmy_probe_process_mode_required');
  }
  // readHardware's native probe guard checks completed postdata, retained APS
  // keys/token and identity before any connection/authentication.
  await onStage?.call('findmy-probe-retained-hardware');
  final hardware = api.readHardware(path: profile.path);
  if (hardware == null) {
    throw StateError('findmy_probe_retained_state_required');
  }
  final identity = api.decodeIdentity(identity: hardware.identity);
  final config = hardware.osConfig;
  await onStage?.call('findmy-probe-aps');
  final push = await api
      .setupPush(
        config: config,
        identity: identity,
        state: hardware.push,
        statePath: profile.path,
      )
      .timeout(const Duration(seconds: 10));
  if (push.$2 != null) throw StateError('findmy_probe_aps_failed');
  final connection = push.$1;
  await onStage?.call('findmy-probe-anisette');
  final anisette = await api
      .makeAnisette(path: profile.path, config: config, conn: connection)
      .timeout(const Duration(seconds: 5));
  await onStage?.call('findmy-probe-retained-account');
  final account = await api
      .restoreAccount(
        path: profile.path,
        anisette: anisette,
        config: config,
        conn: connection,
      )
      .timeout(const Duration(seconds: 5));
  if (account == null) {
    throw StateError('findmy_probe_retained_account_required');
  }
  final provider = api.makeTokenProvider(account: account, config: config);
  return bindWindowsFindMyNativeReads(
    makeDevices: () => api.makeFindMyPhone(
      path: profile.path,
      config: config,
      aps: connection,
      anisette: anisette,
      provider: provider,
    ),
    makePeople: () => api.makeFindMyFriends(
      path: profile.path,
      config: config,
      aps: connection,
      anisette: anisette,
      provider: provider,
    ),
    refreshDevices: (client) =>
        api.refreshDevices(config: config, client: client),
    refreshFollowing: (client) =>
        api.refreshFollowing(config: config, client: client),
    selectFriend: (client, id) =>
        api.selectFriend(config: config, client: client, friend: id),
  );
}

/// This is the production binding, also exercised with typed injected native
/// callbacks in tests. Constructors are lazy and independent. Cached getters
/// are deliberately absent: success requires awaiting the actual refresh call.
FindMyProbeReads bindWindowsFindMyNativeReads<D, P>({
  required Future<D> Function() makeDevices,
  required Future<P> Function() makePeople,
  required Future<List<api.FoundDevice>> Function(D) refreshDevices,
  required Future<List<api.Follow>> Function(P) refreshFollowing,
  required Future<List<api.Follow>> Function(P, String) selectFriend,
  Duration initializationBudget = findMyProbeSectionTimeout,
}) {
  P? people;
  Future<T> initialize<T>(Future<T> Function() create) =>
      Future.sync(create).timeout(initializationBudget);
  return FindMyProbeReads(
    refreshDevices: () async {
      final client = await initialize(makeDevices);
      return FindMyProbeRead(
        await refreshDevices(client),
        freshRequestCompleted: true,
      );
    },
    refreshFollowing: () async {
      final client = await initialize(makePeople);
      final rows = await refreshFollowing(client);
      people =
          client; // Selection is admitted only after roster refresh succeeds.
      return FindMyProbeRead(rows, freshRequestCompleted: true);
    },
    selectFriend: (id) async {
      final client = people;
      if (client == null) throw StateError('findmy_probe_roster_required');
      return FindMyProbeRead(
        await selectFriend(client, id),
        freshRequestCompleted: true,
      );
    },
  );
}

final class FindMyProbeRequest {
  const FindMyProbeRequest({this.selectedPersonId, this.selectedHandle});
  final String? selectedPersonId;
  final String? selectedHandle;
  bool get hasSelection => selectedPersonId != null || selectedHandle != null;
  bool matches(api.Follow row) => selectedPersonId != null
      ? row.id == selectedPersonId
      : selectedHandle != null &&
            [
              ...row.invitationAcceptedHandles,
              ...row.invitationFromHandles,
            ].any(
              (handle) => handle.toLowerCase() == selectedHandle!.toLowerCase(),
            );

  static FindMyProbeRequest parse(String encoded) {
    const invalid = 'findmy_probe_request_invalid';
    try {
      if (utf8.encode(encoded).length > 4096) throw const FormatException();
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value.keys.any(
            (key) => !{
              'version',
              'selectedPersonId',
              'selectedHandle',
            }.contains(key),
          )) {
        throw const FormatException();
      }
      if (value.containsKey('selectedPersonId') &&
          value.containsKey('selectedHandle')) {
        throw const FormatException();
      }
      final selected = value['selectedPersonId'] ?? value['selectedHandle'];
      if ((value.containsKey('selectedPersonId') ||
              value.containsKey('selectedHandle')) &&
          (selected is! String ||
              selected.isEmpty ||
              selected.length > 512 ||
              selected.trim() != selected ||
              selected.codeUnits.any((c) => c < 32 || c == 127))) {
        throw const FormatException();
      }
      return FindMyProbeRequest(
        selectedPersonId: value['selectedPersonId'] as String?,
        selectedHandle: value['selectedHandle'] as String?,
      );
    } catch (_) {
      throw StateError(invalid); // Never echo private request contents.
    }
  }

  static Future<FindMyProbeRequest> read(Directory profile) async {
    final control = Directory(path.join(profile.path, 'cloud-sync-v2'));
    if (await control.exists() &&
        !path.equals(
          await control.resolveSymbolicLinks(),
          path.join(await profile.resolveSymbolicLinks(), 'cloud-sync-v2'),
        )) {
      throw StateError('findmy_probe_request_invalid');
    }
    final file = File(path.join(control.path, findMyProbeRequestFile));
    if (!await file.exists()) return const FindMyProbeRequest();
    if (!path.isWithin(
          await profile.resolveSymbolicLinks(),
          await file.resolveSymbolicLinks(),
        ) ||
        await file.length() > 4096) {
      throw StateError('findmy_probe_request_invalid');
    }
    // Bound the actual read too, even if a local file grows after length().
    final bytes = await file
        .openRead(0, 4097)
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    return parse(utf8.decode(bytes));
  }
}

/// Explicit provenance: a cached getter must never be dressed up as a refresh.
/// The native adapter must attest completion of a request made by THIS
/// callback invocation, not merely receipt of a prior cached native view.
final class FindMyProbeRead<T> {
  FindMyProbeRead(Iterable<T> rows, {required this.freshRequestCompleted})
    : rows = List<T>.unmodifiable(rows);
  final List<T> rows;
  final bool freshRequestCompleted;
}

final class FindMyProbeReads {
  const FindMyProbeReads({
    required this.refreshDevices,
    required this.refreshFollowing,
    required this.selectFriend,
  });
  final Future<FindMyProbeRead<api.FoundDevice>> Function() refreshDevices;
  final Future<FindMyProbeRead<api.Follow>> Function() refreshFollowing;
  final Future<FindMyProbeRead<api.Follow>> Function(String id) selectFriend;
}

Map<String, Object?> _unavailable(String reason) => {
  'state': 'not-tested',
  'reason': reason,
  'fresh_request_completed': false,
  'returned_count': null,
};

/// Completion describes this bounded pass, not continuous location availability.
(String, String) windowsFindMyProbeTerminal(Map<String, Object?> report) {
  bool observed(String section) =>
      (report[section] as Map)['state'] == 'observed';
  final selected = report['selected'] as Map;
  if (observed('devices') &&
      observed('people') &&
      (selected['requested'] == false || observed('selected'))) {
    return ('finished', 'findmy-probe-complete');
  }
  if (observed('devices') || observed('people')) {
    return ('finished', 'findmy-probe-partial');
  }
  return ('failed', 'findmy-probe-reads-failed');
}

/// Device and people deadlines run independently; selection follows only a
/// successful roster request and a unique exact ID match. No retries or loops.
Future<Map<String, Object?>> runWindowsFindMyProbe({
  required String launchId,
  required String buildIdentifier,
  FindMyProbeRequest request = const FindMyProbeRequest(),
  FindMyProbeReads? reads,
  Duration sectionTimeout = findMyProbeSectionTimeout,
  DateTime Function()? now,
}) async {
  if ((request.selectedPersonId != null && request.selectedHandle != null) ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(launchId) ||
      !RegExp(
        r'^[a-f0-9]{7,40}(?:-dirty-[a-f0-9]{12})?$',
      ).hasMatch(buildIdentifier) ||
      sectionTimeout <= Duration.zero ||
      sectionTimeout > findMyProbeSectionTimeout) {
    throw StateError('findmy_probe_contract_invalid');
  }
  final clock = now ?? DateTime.now;
  final started = clock().toUtc();
  var devices = _unavailable('safe_authenticated_session_unavailable');
  var people = _unavailable('safe_authenticated_session_unavailable');
  var selected = <String, Object?>{
    ..._unavailable(
      !request.hasSelection
          ? 'selection_not_requested'
          : 'safe_authenticated_session_unavailable',
    ),
    'requested': request.hasSelection,
    'selected_match': false,
    'location_found': false,
  };

  Future<List<T>?> readSection<T>(
    Future<FindMyProbeRead<T>> Function() fetch,
    void Function(Map<String, Object?>) publish,
    Map<String, Object?> Function(List<T>) summarize,
  ) async {
    try {
      final result = await Future.sync(fetch).timeout(sectionTimeout);
      if (!result.freshRequestCompleted) {
        publish(_unavailable('fresh_request_not_proven'));
        return null;
      }
      publish({
        'state': 'observed',
        'fresh_request_completed': true,
        'returned_count': result.rows.length,
        ...summarize(result.rows),
      });
      return result.rows;
    } on TimeoutException {
      publish({
        'state': 'timeout',
        'fresh_request_completed': false,
        'returned_count': null,
        'reason': 'section_deadline_exceeded',
        'failure_category': 'timeout',
      });
    } catch (error) {
      final failure = _readFailure(error);
      publish({
        'state': failure.category == 'timeout' ? 'timeout' : 'failed',
        'fresh_request_completed': false,
        'returned_count': null,
        'reason': 'section_read_failed',
        'failure_category': failure.category,
        if (failure.httpStatus != null) 'http_status': failure.httpStatus,
      });
    }
    return null;
  }

  if (reads != null) {
    await Future.wait([
      readSection(reads.refreshDevices, (value) => devices = value, (rows) {
        final classes = <String, int>{};
        for (final row in rows) {
          // Native strings are untrusted. Never output names or unknown classes.
          final value = row.deviceClass?.toLowerCase();
          final bucket =
              const {
                'iphone',
                'ipad',
                'mac',
                'watch',
                'airpods',
                'ipod',
                'accessory',
              }.contains(value)
              ? value!
              : 'other';
          classes.update(bucket, (count) => count + 1, ifAbsent: () => 1);
        }
        return {
          'classes': classes,
          ..._locations(rows.map((row) => row.location), clock()),
          'native_family_share_true_count': rows
              .where((r) => r.fmlyShare == true)
              .length,
        };
      }),
      () async {
        final roster = await readSection(
          reads.refreshFollowing,
          (value) => people = value,
          (rows) => _people(rows, clock()),
        );
        if (!request.hasSelection) return;
        final matches = roster?.where(request.matches).toList();
        if (matches == null || matches.length != 1) {
          selected = {
            ...selected,
            ..._unavailable(
              matches == null
                  ? 'roster_unavailable'
                  : 'unique_selected_match_not_found',
            ),
          };
          return;
        }
        final id = matches.single.id;
        selected['selected_match'] = true;
        await readSection(
          () => reads.selectFriend(id),
          (value) => selected = {...selected, ...value},
          (rows) {
            final matches = rows.where((row) => row.id == id).toList();
            return {
              'selected_match': matches.length == 1,
              'location_found':
                  matches.length == 1 && matches.single.lastLocation != null,
              ..._people(
                matches.length == 1 ? matches : <api.Follow>[],
                clock(),
              ),
            };
          },
        );
      }(),
    ]);
  }
  return {
    'version': findMyProbeVersion,
    'launch_id': launchId,
    'build_identifier': buildIdentifier,
    'started_utc': started.toIso8601String(),
    'completed_utc': clock().toUtc().toIso8601String(),
    'mode': 'bounded-findmy-read-only-probe',
    'live_reads_admitted': reads != null,
    'location_meaning':
        'native_view_after_request_not_proof_of_new_location_sample',
    'sharing_meaning':
        'native_fields_only_absence_does_not_establish_stopped_sharing',
    'freshness_meaning': 'native_timestamp_ms_age_bucket_not_live_tracking',
    'devices': devices,
    'people': people,
    'selected': selected,
    'items': _unavailable(
      'native_items_initialization_requires_unreviewed_side_effects',
    ),
  };
}

Map<String, Object?> _people(List<api.Follow> rows, DateTime now) => {
  ..._locations(rows.map((row) => row.lastLocation), now),
  'native_opted_not_to_share_true_count': rows
      .where((r) => r.optedNotToShare == true)
      .length,
  'native_opted_not_to_share_false_count': rows
      .where((r) => r.optedNotToShare == false)
      .length,
  'native_opted_not_to_share_unknown_count': rows
      .where((r) => r.optedNotToShare == null)
      .length,
  'native_tk_permission_true_count': rows.where((r) => r.tkPermission).length,
  'native_locate_in_progress_count': rows
      .where((r) => r.locateInProgress)
      .length,
};

Map<String, Object?> _locations(Iterable<api.Location?> rows, DateTime now) {
  final buckets = <String, int>{
    'absent': 0,
    'unknown': 0,
    'future': 0,
    'within_5_minutes': 0,
    'older': 0,
  };
  var present = 0;
  var valid = 0;
  var nativeOld = 0;
  for (final row in rows) {
    var bucket = 'absent';
    if (row != null) {
      present++;
      if (row.latitude.isFinite &&
          row.longitude.isFinite &&
          row.latitude.abs() <= 90 &&
          row.longitude.abs() <= 180 &&
          (row.latitude != 0 || row.longitude != 0)) {
        valid++;
      }
      if (row.isOld == true) nativeOld++;
      final timestamp = row.timestamp.toInt();
      final age = now.millisecondsSinceEpoch - timestamp;
      bucket = timestamp <= 0
          ? 'unknown'
          : age < 0
          ? 'future'
          : age <= 300000
          ? 'within_5_minutes'
          : 'older';
    }
    buckets[bucket] = buckets[bucket]! + 1;
  }
  return {
    'native_location_present_count': present,
    'valid_coordinate_pair_count': valid,
    'native_is_old_true_count': nativeOld,
    'location_age_buckets': buckets,
  };
}
