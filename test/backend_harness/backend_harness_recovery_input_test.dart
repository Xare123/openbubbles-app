import 'dart:convert';

import 'package:bluebubbles/backend_harness/backend_harness_interactions.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/backend_harness/backend_harness_recovery_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'private exact device name selects only its captured native index',
    () async {
      final broker = BackendHarnessInteractions();
      final adapter = BackendHarnessRecoveryInput(broker);
      final selected = adapter.input.chooseDevice([
        'Private A',
        'Private B',
      ], () => true);
      final challenge = broker.pending!;
      expect(jsonEncode(challenge.toJson()), isNot(contains('Private')));
      adapter.answer({'challengeId': challenge.id, 'deviceName': 'Private B'});
      expect(await selected, 1);
      expect(broker.pending, null);
    },
  );

  test(
    'ambiguous or missing device names leave the native selection pending',
    () async {
      final broker = BackendHarnessInteractions();
      final adapter = BackendHarnessRecoveryInput(broker);
      final selected = adapter.input.chooseDevice(['Same', 'Same'], () => true);
      final id = broker.pending!.id;
      for (final name in ['Same', 'Unknown']) {
        expect(
          () => adapter.answer({'challengeId': id, 'deviceName': name}),
          throwsA(isA<BackendHarnessFailure>()),
        );
        expect(broker.pending!.id, id);
      }
      adapter.answer({'challengeId': id, 'cancel': true});
      expect(await selected, null);
    },
  );

  test('password reaches only the currently selected live device', () async {
    var current = true;
    final broker = BackendHarnessInteractions();
    final adapter = BackendHarnessRecoveryInput(broker);
    final password = adapter.input.password('Private device', () => current);
    final id = broker.pending!.id;
    expect(
      () => adapter.answer({
        'challengeId': id,
        'secret': 'private-secret',
        'deviceName': 'Other device',
      }),
      throwsA(isA<BackendHarnessFailure>()),
    );
    expect(broker.pending!.id, id);
    current = false;
    expect(
      () => adapter.answer({
        'challengeId': id,
        'secret': 'private-secret',
        'deviceName': 'Private device',
      }),
      throwsA(isA<BackendHarnessFailure>()),
    );
    expect(await password, null);
    expect(broker.pending, null);
  });

  test(
    'valid private password is delivered without a readiness assertion',
    () async {
      final broker = BackendHarnessInteractions();
      final adapter = BackendHarnessRecoveryInput(broker);
      final password = adapter.input.password('Device', () => true);
      final challenge = broker.pending!;
      adapter.answer({
        'challengeId': challenge.id,
        'secret': 'private-secret',
        'deviceName': 'Device',
      });
      expect(await password, 'private-secret');
      expect(jsonEncode(challenge.toJson()), isNot(contains('private-secret')));
      expect(broker.pending, null);
    },
  );
}
