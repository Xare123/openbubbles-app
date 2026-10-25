import 'dart:convert';

import 'package:bluebubbles/backend_harness/backend_harness_account.dart';
import 'package:bluebubbles/backend_harness/backend_harness_interactions.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/backend_harness/backend_harness_recovery_input.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

Matcher get refused => throwsA(isA<BackendHarnessFailure>());

void main() {
  test(
    'cached identity observation validates native tags without fresh authentication',
    () {
      final tag = List.filled(43, 'a').join();
      api.CloudSyncNativeAuthMetadata metadata({
        String? account,
        String? store,
        String? session,
      }) => api.CloudSyncNativeAuthMetadata(
        accountFingerprint: account ?? tag,
        protectedStoreIdentity: store ?? 'obcs2.store.$tag',
        nativeSessionId: session ?? tag,
      );
      expect(BackendHarnessAccount.validCachedIdentity(metadata()), isTrue);
      for (final invalid in [
        metadata(account: 'private@example.invalid'),
        metadata(store: tag),
        metadata(session: ''),
        metadata(session: '$tag\n'),
      ]) {
        expect(BackendHarnessAccount.validCachedIdentity(invalid), isFalse);
      }
    },
  );

  test(
    'retained relay resources are availability without starting services',
    () {
      final adapter = BackendHarnessAccount(BackendHarnessInteractions());
      expect(adapter.snapshot().flags['relay_ready'], isFalse);
      final retained = adapter.snapshot(retainedRelayResources: true);
      expect(retained.flags['relay_ready'], isTrue);
      expect(retained.flags.containsKey('auth_ready'), isFalse);
      expect(retained.flags.containsKey('registration_ready'), isFalse);
      expect(retained.phase, BackendHarnessPhase.needs_credentials);
    },
  );

  test(
    'setup operation waits work without a mounted consumer screen',
    () async {
      final adapter = BackendHarnessAccount(BackendHarnessInteractions());
      expect(
        await adapter.setupController.wrapPromise(Future.value(7), 'unused'),
        7,
      );
      await expectLater(
        adapter.setupController.wrapPromise(
          Future<int>.error(StateError('synthetic')),
          'unused',
        ),
        throwsStateError,
      );
      expect(adapter.setupController.success, isFalse);
    },
  );

  test(
    'SMS choice returns only a captured exact index without public labels',
    () async {
      final broker = BackendHarnessInteractions();
      final adapter = BackendHarnessAccount(broker);
      final choice = adapter.chooseSmsDestination([
        'private01',
        'private02',
      ], stillCurrent: () => true);
      final challenge = broker.pending!;
      expect(challenge.kind, BackendHarnessChallengeKind.smsDestination);
      expect(challenge.options, 2);
      expect(
        jsonEncode(adapter.snapshot().toJson()),
        isNot(contains('private')),
      );
      expect(
        () => adapter.answer({
          'challengeId': challenge.id,
          'destination': 'unknown',
        }),
        refused,
      );
      expect(broker.pending!.id, challenge.id);
      adapter.answer({'challengeId': challenge.id, 'destination': 'private02'});
      expect(await choice, 1);
      expect(adapter.setupController.success, isFalse);
      expect(
        () => adapter.answer({'challengeId': challenge.id, 'index': 0}),
        refused,
      );
    },
  );

  test('a changed native attempt cannot receive an SMS selection', () async {
    var current = true;
    final broker = BackendHarnessInteractions();
    final adapter = BackendHarnessAccount(broker);
    final choice = adapter.chooseSmsDestination([
      'private',
    ], stillCurrent: () => current);
    final id = broker.pending!.id;
    current = false;
    expect(() => adapter.answer({'challengeId': id, 'index': 0}), refused);
    expect(await choice, null);
    expect(broker.pending, null);
  });

  test('account and encryption answers cannot cross input channels', () async {
    final broker = BackendHarnessInteractions();
    final account = BackendHarnessAccount(broker);
    final recovery = BackendHarnessRecoveryInput(broker);
    final code = broker.secret(
      BackendHarnessChallengeKind.verificationCode,
      stillCurrent: () => true,
    );
    final id = broker.pending!.id;
    expect(
      () => recovery.answer({'challengeId': id, 'secret': '123456'}),
      refused,
    );
    expect(
      () => account.answer({'challengeId': id, 'secret': 'bad-code'}),
      refused,
    );
    expect(broker.pending!.id, id);
    account.answer({'challengeId': id, 'secret': '123456'});
    expect(await code, '123456');
    final pin = broker.secret(
      BackendHarnessChallengeKind.pin,
      stillCurrent: () => true,
    );
    final pinId = broker.pending!.id;
    expect(
      () => account.answer({'challengeId': pinId, 'secret': '123456'}),
      refused,
    );
    broker.cancel(pinId);
    expect(await pin, null);
  });

  test(
    'registration support returns a blocked result without setting success',
    () async {
      final adapter = BackendHarnessAccount(BackendHarnessInteractions());
      await expectLater(adapter.registrationSupportRequired(), refused);
      expect(adapter.phase, BackendHarnessPhase.blocked);
      expect(adapter.setupController.success, isFalse);
    },
  );

  test(
    'private input validation refuses alternate relays and extra effects',
    () {
      final relay = <String, Object?>{
        'host': 'https://registration-relay.beeper.com',
        'code': 'TEST-ONLY-TICK-ET00',
        'token': 'synthetic-token',
      };
      expect(BackendHarnessAccount.validRelay(relay), isTrue);
      expect(
        BackendHarnessAccount.validRelay({
          ...relay,
          'host': 'https://other.invalid',
        }),
        isFalse,
      );
      expect(
        BackendHarnessAccount.validRelay({...relay, 'reset': true}),
        isFalse,
      );
      expect(
        BackendHarnessAccount.validLogin({
          'appleId': 'synthetic@example.invalid',
          'password': 'synthetic',
        }),
        isTrue,
      );
      expect(
        BackendHarnessAccount.validLogin({
          'appleId': 'synthetic@example.invalid',
          'password': 'synthetic',
          'send': true,
        }),
        isFalse,
      );
    },
  );
}
