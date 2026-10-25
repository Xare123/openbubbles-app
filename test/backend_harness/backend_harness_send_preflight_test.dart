import 'package:bluebubbles/backend_harness/backend_harness_fixtures.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const first = '+16177106179';
const second = '+19079786948';
const sender = 'mailto:sender@example.invalid';

void main() {
  test(
    'preflight looks up approved recipients and the owned sender',
    () async {
      await BackendHarnessFixtures.preflightTargets(
        requested: [first, second],
        sender: sender,
        lookup: (targets, handle) async {
          expect(targets, ['tel:$first', 'tel:$second', sender]);
          expect(handle, sender);
          return targets.reversed.toList();
        },
      );
    },
  );

  test(
    'registration resource failure propagates before any fixture claim or send',
    () async {
      var calls = 0;
      await expectLater(
        BackendHarnessFixtures.preflightTargets(
          requested: [first],
          sender: sender,
          lookup: (_, _) async {
            calls++;
            throw StateError('synthetic_resource_6005');
          },
        ),
        throwsStateError,
      );
      expect(calls, 1);
    },
  );

  test('missing, extra or duplicate target keys refuse readiness', () async {
    for (final targets in <List<String>>[
      [],
      ['tel:$first'],
      ['tel:$first', 'tel:$first'],
      ['tel:$first', 'tel:$second', 'tel:other'],
    ]) {
      await expectLater(
        BackendHarnessFixtures.preflightTargets(
          requested: [first, second],
          sender: sender,
          lookup: (_, _) async => targets,
        ),
        throwsA(isA<BackendHarnessFailure>()),
      );
    }
  });

  test(
    'invalid recipients and sender refuse before directory access',
    () async {
      var calls = 0;
      for (final requested in <List<String>>[
        [],
        [first, first],
        ['+10000000000'],
        [first, second, first],
      ]) {
        await expectLater(
          BackendHarnessFixtures.preflightTargets(
            requested: requested,
            sender: sender,
            lookup: (_, _) async {
              calls++;
              return [];
            },
          ),
          throwsA(
            isA<BackendHarnessFailure>().having(
              (e) => e.effectNotEntered,
              'not entered',
              true,
            ),
          ),
        );
      }
      for (final from in ['', 'sender@example.invalid', 'tel:$first']) {
        await expectLater(
          BackendHarnessFixtures.preflightTargets(
            requested: [first],
            sender: from,
            lookup: (_, _) async {
              calls++;
              return [];
            },
          ),
          throwsA(isA<BackendHarnessFailure>()),
        );
      }
      expect(calls, 0);
    },
  );
}
