import 'dart:io';

import 'package:bluebubbles/app/layouts/findmy/findmy_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

typedef NativeRow = ({String privateValue, bool location, bool locating});

void main() {
  const row = (
    privateValue: 'private-handle-token-body',
    location: true,
    locating: false,
  );

  void report(
    FindMyDiagnostics diagnostics,
    List<String> output, {
    Iterable<NativeRow> rows = const [row],
    Iterable<bool> projected = const [true],
  }) => diagnostics.people<NativeRow, bool>(
    phase: FindMyDiagnosticPhase.selected,
    rows: rows,
    projected: projected,
    hasNativeLocation: (row) => row.location,
    isLocating: (row) => row.locating,
    hasProjectedLocation: (value) => value,
    isSelected: (row) => row.privateValue == 'private-handle-token-body',
    emit: output.add,
  );

  test('default gate exactly follows the explicit Dart define', () {
    expect(
      FindMyDiagnostics().enabled,
      const String.fromEnvironment('OPENBUBBLES_FINDMY_VERBOSE_DIAGNOSTICS') ==
          'true',
    );
    final output = <String>[];
    report(FindMyDiagnostics(), output);
    expect(output.length, findMyVerboseDiagnostics ? 1 : 0);
    output.clear();
    FindMyDiagnostics().items(
      stage: FindMyItemsStage.beacons, outcome: FindMyItemsOutcome.succeeded,
      beacons: () => 1, emit: output.add,
    );
    expect(output.length, findMyVerboseDiagnostics ? 1 : 0);
  });

  test('Items disabled gate and exhausted shared budget never evaluate counts', () {
    void forbidden(FindMyDiagnostics diagnostics) => diagnostics.items(
      stage: FindMyItemsStage.publish, outcome: FindMyItemsOutcome.succeeded,
      beacons: () => throw StateError('count accessed'),
      uiItems: () => throw StateError('count accessed'),
      uiTotal: () => throw StateError('count accessed'),
      emit: (_) => fail('disabled/exhausted Items diagnostic emitted'),
    );
    forbidden(FindMyDiagnostics(enabled: false));
    final diagnostics = FindMyDiagnostics(enabled: true);
    final output = <String>[];
    for (var i = 0; i < 12; i++) { report(diagnostics, output); }
    forbidden(diagnostics);
    expect(output.length, 12);
  });

  test('Items count output is capped and missing observations are not zero', () {
    final diagnostics = FindMyDiagnostics(enabled: true);
    final output = <String>[];
    diagnostics.items(
      stage: FindMyItemsStage.publish, outcome: FindMyItemsOutcome.succeeded,
      beacons: () => 300, uiItems: () => 0, uiTotal: () => 256,
      emit: output.add,
    );
    expect(output.single,
      'Find My diagnostic service=items stage=publish outcome=succeeded '
      'limit=256 beacons=256 beacons_truncated=true ui_items=0 '
      'ui_items_truncated=false ui_total=256 ui_total_truncated=false');
    diagnostics.items(
      stage: FindMyItemsStage.beacons, outcome: FindMyItemsOutcome.failed,
      emit: output.add,
    );
    expect(output.last, contains('beacons=unobserved'));
    expect(output.last, contains('ui_items=unobserved'));
    expect(output.every((line) => line.length < 512), isTrue);
  });

  test('Items and People successes and failures consume the same 12 records', () {
    final diagnostics = FindMyDiagnostics(enabled: true);
    final output = <String>[];
    for (var i = 0; i < 6; i++) {
      diagnostics.items(
        stage: FindMyItemsStage.beacons, outcome: FindMyItemsOutcome.failed,
        emit: output.add,
      );
      report(diagnostics, output);
    }
    report(diagnostics, output);
    expect(output.length, 12);
  });

  test(
    'disabled path neither walks rows nor evaluates callbacks nor emits',
    () {
      Iterable<NativeRow> forbidden() sync* {
        throw StateError('disabled diagnostic walked private input');
      }

      final output = <String>[];
      final diagnostics = FindMyDiagnostics(enabled: false);
      report(diagnostics, output, rows: forbidden());
      diagnostics.failure(
        phase: FindMyDiagnosticPhase.init,
        stage: FindMyDiagnosticStage.fetch,
        emit: (_) => fail('disabled diagnostic emitted'),
      );
      expect(output, isEmpty);
    },
  );

  test('enabled output contains only phases counts and booleans', () {
    final output = <String>[];
    report(FindMyDiagnostics(enabled: true), output);
    expect(
      output.single,
      'Find My diagnostic phase=selected outcome=projected '
      'limit=256 roster_sample=1 native_locations=1 projected_rows_sample=1 '
      'projected_valid_locations=1 locating=0 native_truncated=false '
      'projected_truncated=false selected_sample_present=true selected_sample_has_location=true',
    );
    expect(output.single, isNot(contains('private')));
    expect(output.single.length, lessThan(1024));
  });

  test('native null and projection loss remain distinguishable', () {
    final output = <String>[];
    final diagnostics = FindMyDiagnostics(enabled: true);
    report(diagnostics, output, projected: const [false]);
    report(
      diagnostics,
      output,
      rows: const [
        (
          privateValue: 'private-handle-token-body',
          location: false,
          locating: true,
        ),
      ],
      projected: const [false],
    );
    expect(output[0], contains('native_locations=1'));
    expect(output[0], contains('projected_valid_locations=0'));
    expect(output[1], contains('native_locations=0'));
    expect(output[1], contains('selected_sample_has_location=false'));
  });

  test('row work is bounded even for infinite input and marks truncation', () {
    var visited = 0;
    Iterable<NativeRow> infinite() sync* {
      while (true) {
        visited++;
        yield row;
      }
    }

    final output = <String>[];
    report(
      FindMyDiagnostics(enabled: true),
      output,
      rows: infinite(),
      projected: List.filled(300, true),
    );
    expect(visited, 257);
    expect(output.single, contains('roster_sample=256 native_locations=256'));
    expect(
      output.single,
      contains('native_truncated=true projected_truncated=true'),
    );
  });

  test('success and failure share a 12-record budget then become inert', () {
    final diagnostics = FindMyDiagnostics(enabled: true);
    final output = <String>[];
    for (var i = 0; i < 6; i++) {
      report(diagnostics, output);
      diagnostics.failure(
        phase: FindMyDiagnosticPhase.refresh,
        stage: FindMyDiagnosticStage.projection,
        emit: output.add,
      );
    }
    Iterable<NativeRow> forbidden() sync* {
      throw StateError('budget exhausted');
    }

    report(diagnostics, output, rows: forbidden());
    diagnostics.failure(
      phase: FindMyDiagnosticPhase.refresh,
      stage: FindMyDiagnosticStage.fetch,
      emit: output.add,
    );
    expect(output.length, 12);
  });

  test('failure vocabulary is finite and cannot accept an exception', () {
    final output = <String>[];
    final diagnostics = FindMyDiagnostics(enabled: true);
    for (final stage in FindMyDiagnosticStage.values) {
      diagnostics.failure(
        phase: FindMyDiagnosticPhase.init,
        stage: stage,
        emit: output.add,
      );
    }
    expect(output, [
      'Find My diagnostic phase=init outcome=failed stage=fetch',
      'Find My diagnostic phase=init outcome=failed stage=projection',
    ]);
  });

  group('native and page source contracts (not native execution)', () {
    final native = File('rustpush/src/findmy.rs').readAsStringSync();
    final diagnostic = File(
      'rustpush/src/findmy/diagnostics.rs',
    ).readAsStringSync();
    final page = File(
      'lib/app/layouts/findmy/findmy_page.dart',
    ).readAsStringSync();

    test('native gate precedes sink budget and lazy snapshots', () {
      final start = diagnostic.substring(
        diagnostic.indexOf('pub(super) fn start('),
      );
      expect(
        start.indexOf('if !enabled'),
        lessThan(start.indexOf('log::log_enabled!')),
      );
      expect(
        start.indexOf('admit(enabled'),
        lessThan(start.indexOf('before: before()')),
      );
      expect(
        diagnostic,
        contains('option_env!("OPENBUBBLES_FINDMY_VERBOSE_DIAGNOSTICS")'),
      );
      expect(diagnostic, contains('const REQUEST_LIMIT: usize = 12;'));
      expect(diagnostic, contains('const ROW_LIMIT: usize = 256;'));
      for (final forbidden in [
        'std::env::var(',
        'set_max_level',
        'set_logger',
        'println!',
        '.send()',
        '.await',
      ]) {
        expect(diagnostic, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test(
      'native decode errors and original ID join are explicitly observed',
      () {
        expect(
          RegExp(
            r'let mut observation = diagnostics::Observation::start',
          ).allMatches(native).length,
          3,
        );
        expect(
          RegExp(
            r'diagnostics::body\(&mut observation, response.json\(\).await\)',
          ).allMatches(native).length,
          2,
        );
        expect(
          RegExp(
            r'diagnostics::Outcome::TypedDecodeFailed',
          ).allMatches(native).length,
          2,
        );
        expect(
          native,
          contains('record.join(false, location.location.is_some())'),
        );
        expect(
          native,
          contains('record.join(true, location.location.is_some())'),
        );
        expect(native, contains('find(|f| f.id == location.id)'));
        expect(native, contains('follow.last_location = location.location;'));
        expect(native, contains('self.devices = request.content;'));
        expect(
          diagnostic,
          contains('Shape::Absent => result.location_absent += 1'),
        );
        expect(
          diagnostic,
          contains('Shape::Null => result.location_null += 1'),
        );
        expect(
          diagnostic,
          contains('Shape::Object => result.location_object += 1'),
        );
      },
    );

    test(
      'page keeps direct projection and gates both diagnostic callbacks',
      () {
        final request = page.substring(
          page.indexOf('  Future<bool> requestPeople('),
          page.indexOf('  void publishPeople()'),
        );
        expect(request, contains('final visibleLocation = e.lastLocation;'));
        expect(
          request,
          contains('_findMyDiagnostics.people<api.Follow, FindMyFriend>'),
        );
        expect(request, contains('_findMyDiagnostics.failure('));
        expect(request, isNot(contains('error.runtimeType')));
        expect(request, isNot(contains('Logger.info(findMyPeopleSummary(')));
      },
    );

    test('Items native counts and outcomes are inside existing writer scope', () {
      final items = native.substring(native.indexOf('pub async fn sync_item_positions('),
          native.indexOf('pub async fn update_beacon_name('));
      expect(items.indexOf('diagnostics::Observation::start('),
          lessThan(items.indexOf('with_cloudkit_writer_operation(async {')));
      expect(items.indexOf('with_cloudkit_writer_operation(async {'),
          lessThan(items.indexOf('record.writer_gate = diagnostics::StepOutcome::Succeeded')));
      expect(items, contains('result.is_err() && record.writer_gate == diagnostics::StepOutcome::Pending'));
      expect(items, contains('diagnostics::Outcome::ItemsFailed'));
      final inventory = items.indexOf('record.inventory_owned =');
      expect(inventory, greaterThan(items.indexOf('self.sync_items(true).await?;')));
      expect(items.substring(inventory - 80, inventory), contains('diagnostics::items(observation)'));
      expect(items, contains('CappedCount::new(state.accessories.len())'));
      expect(items, contains('CappedCount::new(state.share_state.circles_member.len())'));
      final alignment = items.indexOf('let result = with_cloudkit_writer_operation(container.perform_operations_checked(');
      expect(alignment, greaterThan(items.indexOf('record.stage = diagnostics::ItemsStage::AlignmentWrite')));
      final publication = items.indexOf('for (device, local_alignment, alignment_update, newest_report) in pending_accessory_updates');
      expect(items.indexOf('result?;', alignment), lessThan(publication));
      expect(items, contains('diagnostics::StepOutcome::NotNeeded'));
      expect(diagnostic, contains('Service::Items => &ITEMS_REQUESTS'));
      expect(diagnostic, contains('rows: rows.min(ROW_LIMIT), truncated: rows > ROW_LIMIT'));
    });

    test('Items page observes returned beacons and already-published UI lengths only', () {
      final items = page.substring(page.indexOf('Future<void> refreshItems('),
          page.indexOf('void publishDevicesAndItems()'));
      expect(items, contains('final beacons = await api.getBeaconItems('));
      expect(items, contains('beacons: () => beacons.length'));
      expect(items, contains('return beacons;'));
      expect(items, contains('rethrow;'));
      final publish = page.substring(page.indexOf('void publishDevicesAndItems()'));
      final log = publish.indexOf('stage: FindMyItemsStage.publish');
      expect(log, greaterThan(publish.indexOf('this.devices = devices;')));
      expect(log, greaterThan(publish.indexOf('setState(() {')));
      expect(publish, contains('uiItems: () => this.devices.length - _devicesRefresh.value.length'));
      expect(publish, contains('uiTotal: () => this.devices.length'));
    });
  });
}
