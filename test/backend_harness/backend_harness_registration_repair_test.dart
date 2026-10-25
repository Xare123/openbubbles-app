import 'dart:async';

import 'package:bluebubbles/backend_harness/backend_harness_account.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

api.CloudSyncNativeAuthMetadata identity({
  String account = 'a',
  String store = 'b',
  String session = 'c',
}) => api.CloudSyncNativeAuthMetadata(
  accountFingerprint: List.filled(43, account).join(),
  protectedStoreIdentity: 'obcs2.store.${List.filled(43, store).join()}',
  nativeSessionId: List.filled(43, session).join(),
);

void main() {
  test(
    'fresh repair awaits the native refresh and never treats a cached state as completion',
    () async {
      final refresh = Completer<void>();
      final calls = <String>[];
      final result = BackendHarnessAccount.repairRetainedRegistration(
        stillCurrent: () => true,
        captureIdentity: () async {
          calls.add('identity');
          return identity();
        },
        refresh: () {
          calls.add('refresh');
          return refresh.future;
        },
        isRegistered: () async {
          calls.add('registered');
          return true;
        },
      );
      var completed = false;
      unawaited(
        result.then((_) {
          completed = true;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['identity', 'refresh']);
      expect(completed, false);
      refresh.complete();
      final payload = await result;
      expect(payload.flags['registration_refreshed'], true);
      expect(payload.flags['registration_ready'], true);
      expect(payload.flags.containsKey('send_resources_ready'), false);
      expect(calls, ['identity', 'refresh', 'registered', 'identity']);
    },
  );

  test('stale ownership refuses before entering native repair', () async {
    var refreshes = 0;
    await expectLater(
      BackendHarnessAccount.repairRetainedRegistration(
        stillCurrent: () => false,
        captureIdentity: () async => identity(),
        refresh: () async {
          refreshes++;
        },
        isRegistered: () async => true,
      ),
      throwsA(
        isA<BackendHarnessFailure>().having(
          (e) => e.effectNotEntered,
          'not entered',
          true,
        ),
      ),
    );
    expect(refreshes, 0);
  });

  test('missing identity refuses before entering native repair', () async {
    var refreshes = 0;
    await expectLater(
      BackendHarnessAccount.repairRetainedRegistration(
        stillCurrent: () => true,
        captureIdentity: () async => null,
        refresh: () async {
          refreshes++;
        },
        isRegistered: () async => true,
      ),
      throwsA(
        isA<BackendHarnessFailure>().having(
          (e) => e.effectNotEntered,
          'not entered',
          true,
        ),
      ),
    );
    expect(refreshes, 0);
  });

  test(
    'ownership changing during repair remains an entered unknown outcome',
    () async {
      var current = true;
      await expectLater(
        BackendHarnessAccount.repairRetainedRegistration(
          stillCurrent: () => current,
          captureIdentity: () async => identity(),
          refresh: () async {
            current = false;
          },
          isRegistered: () async => true,
        ),
        throwsA(
          isA<BackendHarnessFailure>().having(
            (e) => e.effectNotEntered,
            'not entered',
            false,
          ),
        ),
      );
    },
  );

  test(
    'changed account, store or native session cannot report repair success',
    () async {
      for (final changed in [
        identity(account: 'd'),
        identity(store: 'd'),
        identity(session: 'd'),
      ]) {
        var captures = 0;
        await expectLater(
          BackendHarnessAccount.repairRetainedRegistration(
            stillCurrent: () => true,
            captureIdentity: () async => captures++ == 0 ? identity() : changed,
            refresh: () async {},
            isRegistered: () async => true,
          ),
          throwsA(
            isA<BackendHarnessFailure>().having(
              (e) => e.code,
              'code',
              'backend_identity_changed',
            ),
          ),
        );
      }
    },
  );

  test('a completed refresh without Registered is still blocked', () async {
    await expectLater(
      BackendHarnessAccount.repairRetainedRegistration(
        stillCurrent: () => true,
        captureIdentity: () async => identity(),
        refresh: () async {},
        isRegistered: () async => false,
      ),
      throwsA(
        isA<BackendHarnessFailure>().having(
          (e) => e.code,
          'code',
          'backend_not_ready',
        ),
      ),
    );
  });

  test(
    'native registration failure is observed once and repeated request never reruns it',
    () async {
      var refreshes = 0;
      final engine = BackendHarnessEngine(
        enabled: true,
        source: List.filled(40, 'a').join(),
        package: 'com.bluebubbles.cloudsync.testhost',
        platform: 'windows',
        operations: {
          'auth.repair': BackendHarnessOperation(
            background: true,
            uncertainOnFailure: true,
            validate: (args) => args.isEmpty,
            handler: (_) => BackendHarnessAccount.repairRetainedRegistration(
              stillCurrent: () => true,
              captureIdentity: () async => identity(),
              refresh: () async {
                refreshes++;
                throw StateError('synthetic_resource_6005');
              },
              isRegistered: () async => true,
            ),
          ),
        },
      );
      final request = <String, Object?>{
        'protocol': 1,
        'requestId': 'one-repair',
        'action': 'auth.repair',
        'arguments': <String, Object?>{},
      };
      final accepted = await engine.execute(request);
      await engine.closeAdmissionAndDrain();
      final repeated = await engine.execute(request);
      expect(repeated['code'], 'backend_busy');
      expect(refreshes, 1);
      expect(engine.hasUncertainJobs, true);
      final observed = await engine.execute({
        'protocol': 1,
        'requestId': 'observe',
        'action': 'job.status',
        'arguments': {'jobId': accepted['jobId']},
      });
      expect(observed['state'], 'failed');
      expect(
        ((observed['data'] as Map)['flags'] as Map)['outcome_uncertain'],
        true,
      );
      expect(
        ((observed['data'] as Map)['flags'] as Map).containsKey(
          'registration_refreshed',
        ),
        false,
      );
    },
  );
}
