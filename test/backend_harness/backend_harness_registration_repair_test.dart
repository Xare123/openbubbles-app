import 'dart:async';

import 'package:bluebubbles/backend_harness/backend_harness_account.dart';
import 'package:bluebubbles/backend_harness/backend_harness_controller.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
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
  test('persisted fresh credentials require restart before registration proof', () async {
    var observedOldRegistration = false;
    final result = await BackendHarnessAccount.repairRetainedRegistration(
      stillCurrent: () => true,
      captureIdentity: () async => identity(),
      refresh: () async {},
      isRegistered: () async {
        observedOldRegistration = true;
        return true;
      },
      restartAfterRefresh: true,
    );
    expect(observedOldRegistration, false);
    expect(result.phase, BackendHarnessPhase.blocked);
    expect(result.flags['credentials_refreshed'], true);
    expect(result.flags['restart_required'], true);
    expect(result.flags['registration_ready'], false);
    expect(result.flags.containsKey('registration_refreshed'), false);
    expect(result.flags.containsKey('send_resources_ready'), false);
    expect(result.toJson()['flags'], result.flags);
  });

  test('a fresh repair with changed ownership cannot report saved credentials', () async {
    var captures = 0;
    await expectLater(
      BackendHarnessAccount.repairRetainedRegistration(
        stillCurrent: () => true,
        captureIdentity: () async => captures++ == 0 ? identity() : identity(store: 'd'),
        refresh: () async {},
        isRegistered: () async => true,
        restartAfterRefresh: true,
      ),
      throwsA(isA<BackendHarnessFailure>().having(
        (failure) => failure.code, 'identity fence', 'backend_identity_changed')),
    );
  });

  test('only the trusted credential-entry marker can clear repair uncertainty', () async {
    for (final entered in [false, true]) {
      await expectLater(
        BackendHarnessAccount.repairRetainedRegistration(
          stillCurrent: () => true,
          captureIdentity: () async => identity(),
          refresh: () async => throw StateError('synthetic_repair_failure'),
          isRegistered: () async => false,
          restartAfterRefresh: true,
          credentialsEffectEntered: () => entered,
        ),
        entered
            ? throwsStateError
            : throwsA(isA<BackendHarnessFailure>().having(
                (failure) => failure.effectNotEntered, 'no credential entry', true)),
      );
    }
  });

  test('entered credential failure retains uncertainty and fences later effects', () async {
    var restartRequired = false;
    var repairs = 0;
    var sends = 0;
    var observations = 0;
    BackendHarnessOperation fenced(String action, BackendHarnessOperation operation) =>
        backendHarnessRegistrationLifetimeOperation(action, operation,
          restartRequired: () => restartRequired);
    final engine = BackendHarnessEngine(
      enabled: true,
      source: List.filled(40, 'a').join(),
      package: 'com.bluebubbles.cloudsync.testhost',
      platform: 'windows',
      operations: {
        'auth.repair': fenced('auth.repair', BackendHarnessOperation(
          background: true, uncertainOnFailure: true,
          validate: (args) => args.isEmpty,
          handler: (_) => BackendHarnessAccount.repairRetainedRegistration(
            stillCurrent: () => true,
            captureIdentity: () async => identity(),
            refresh: () async {
              repairs++;
              restartRequired = true;
              throw StateError('synthetic_alias_changed_before_id_persistence');
            },
            isRegistered: () async => true,
            restartAfterRefresh: true,
          ),
        )),
        'fixture.send': fenced('fixture.send', BackendHarnessOperation(
          background: true, uncertainOnFailure: true,
          validate: (args) => args.isEmpty,
          handler: (_) async {
            sends++;
            return const BackendHarnessPayload();
          },
        )),
        'auth.status': fenced('auth.status', BackendHarnessOperation(
          validate: (args) => args.isEmpty,
          handler: (_) async {
            observations++;
            return const BackendHarnessPayload(flags: {'restart_required': true});
          },
        )),
      },
    );
    Future<Map<String, Object?>> request(String id, String action) => engine.execute({
      'protocol': 1, 'requestId': id, 'action': action,
      'arguments': <String, Object?>{},
    });
    final original = await request('fresh-credentials', 'auth.repair');
    await Future<void>.delayed(Duration.zero);
    final later = await request('different-repair', 'auth.repair');
    await Future<void>.delayed(Duration.zero);
    final send = await request('no-send', 'fixture.send');
    await Future<void>.delayed(Duration.zero);
    final status = await request('observe', 'auth.status');
    expect((status['data'] as Map)['flags'], {'restart_required': true});
    expect(repairs, 1);
    expect(sends, 0);
    expect(observations, 1);
    for (final accepted in [later, send]) {
      final observed = await engine.execute({
        'protocol': 1, 'requestId': 'inspect-${accepted['jobId']}',
        'action': 'job.status', 'arguments': {'jobId': accepted['jobId']},
      });
      expect(observed['code'], 'backend_restart_required');
      expect(((observed['data'] as Map)['flags'] as Map)['outcome_uncertain'], isNot(true));
    }
    await engine.closeAdmissionAndDrain();
    expect(engine.hasUncertainJobs, true);
    final recovery = engine.drainedRecoverySnapshot();
    expect(recovery.toString(), contains(original['jobId']));
    expect(recovery.toString(), isNot(contains('synthetic_alias')));
  });

  test(
    'resource status exposes fixed rejection and retry facts without its native error',
    () {
      final rejected = BackendHarnessAccount.registrationObservation(
        const api.RegisterState.failed(
          error: 'Registration Error Bad authentication (6005) private-account',
        ),
      );
      expect(rejected, {
        'registration_ready': false,
        'registration_resource_failed': true,
        'registration_rejected': true,
        'registration_retry_available': false,
      });
      final retryable = BackendHarnessAccount.registrationObservation(
        api.RegisterState.failed(
          error: 'private transport details',
          retryWait: BigInt.from(30),
        ),
      );
      expect(retryable['registration_retry_available'], true);
      expect(retryable['registration_rejected'], false);
      expect(
        BackendHarnessPayload(flags: rejected).toJson().toString(),
        isNot(contains('private-account')),
      );
      expect(
        BackendHarnessAccount.registrationObservation(
          const api.RegisterState.registering(),
        )['registration_resource_failed'],
        false,
      );
    },
  );
  test(
    'registration rejection is a fixed diagnostic with retained uncertainty',
    () {
      final error = BackendHarnessAccount.classifyRegistrationFailure(
        StateError(
          'Registration Error Bad authentication (6005) private-account',
        ),
      );
      expect(error?.code, 'backend_registration_rejected');
      expect(error?.effectNotEntered, false);
      expect(
        BackendHarnessAccount.classifyRegistrationFailure(
          StateError('unrelated 6005'),
        ),
        null,
      );
    },
  );
  test('only known interlock refusals establish no registration entry', () {
    final busy = BackendHarnessAccount.classifyRegistrationFailure(
      const CloudKitOperationInterlockException('cloudkit_interlock_busy'),
    );
    expect(busy?.code, 'backend_busy');
    expect(busy?.effectNotEntered, true);
    final lost = BackendHarnessAccount.classifyRegistrationFailure(
      const CloudKitOperationInterlockException(
        'cloudkit_interlock_fence_lost',
      ),
    );
    expect(lost?.code, 'backend_not_ready');
    expect(lost?.effectNotEntered, false);
    expect(
      BackendHarnessAccount.classifyRegistrationFailure(
        BackendHarnessFailure('backend_identity_changed'),
      ),
      null,
    );
  });
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
