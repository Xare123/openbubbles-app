import 'dart:async';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> request(
  String id,
  String action, [
  Map<String, Object?> arguments = const {},
]) => {
  'protocol': 1,
  'requestId': id,
  'action': action,
  'arguments': arguments,
};

BackendHarnessEngine runner(Map<String, BackendHarnessOperation> operations) =>
    BackendHarnessEngine(
      enabled: true,
      source: List.filled(40, 'a').join(),
      package: 'com.bluebubbles.cloudsync.testhost',
      platform: 'windows',
      operations: operations,
    );

void main() {
  test(
    'shutdown retains an entered foreground call and refuses later handlers',
    () async {
      final completion = Completer<BackendHarnessPayload>();
      var calls = 0;
      final engine = runner({
        'status': BackendHarnessOperation(
          validate: (args) => args.isEmpty,
          handler: (_) {
            calls++;
            return completion.future;
          },
        ),
      });
      final entered = engine.execute(request('first', 'status'));
      var drained = false;
      final drain = engine.closeAdmissionAndDrain()
        ..then((_) => drained = true);
      expect(identical(drain, engine.closeAdmissionAndDrain()), isTrue);
      expect(
        (await engine.execute(request('later', 'status')))['code'],
        'backend_busy',
      );
      expect((await engine.execute(request('observe', 'hello')))['ok'], isTrue);
      expect(calls, 1);
      expect(drained, isFalse);
      completion.complete(const BackendHarnessPayload());
      expect((await entered)['ok'], isTrue);
      await drain;
      expect(drained, isTrue);
    },
  );

  test(
    'shutdown retains accepted background work and its terminal receipt',
    () async {
      final completion = Completer<BackendHarnessPayload>();
      var calls = 0;
      final engine = runner({
        'fixture.send': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: (args) => args.isEmpty,
          handler: (_) {
            calls++;
            return completion.future;
          },
        ),
      });
      final accepted = await engine.execute(
        request('original', 'fixture.send'),
      );
      var drained = false;
      final drain = engine.closeAdmissionAndDrain()
        ..then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(drained, isFalse);
      expect(
        (await engine.execute(request('replacement', 'fixture.send')))['code'],
        'backend_busy',
      );
      completion.complete(
        const BackendHarnessPayload(flags: {'setup_finished': true}),
      );
      await drain;
      final receipt = await engine.execute(
        request('receipt', 'job.status', {'jobId': accepted['jobId']}),
      );
      expect(receipt['state'], 'completed');
      expect(
        ((receipt['data'] as Map)['flags'] as Map)['setup_finished'],
        isTrue,
      );
      expect(engine.hasUncertainJobs, isFalse);
      expect(calls, 1);
    },
  );

  test(
    'drained failure retains uncertainty instead of proving release is safe',
    () async {
      final engine = runner({
        'fixture.send': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: (args) => args.isEmpty,
          handler: (_) async => throw StateError('synthetic_unknown_outcome'),
        ),
      });
      final accepted = await engine.execute(
        request('original', 'fixture.send'),
      );
      await engine.closeAdmissionAndDrain();
      expect(engine.hasUncertainJobs, isTrue);
      final receipt = await engine.execute(
        request('receipt', 'job.status', {'jobId': accepted['jobId']}),
      );
      expect(receipt['state'], 'failed');
      expect(
        ((receipt['data'] as Map)['flags'] as Map)['outcome_uncertain'],
        isTrue,
      );
    },
  );
}
