import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_background_read_preference.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_background_registration.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncBackgroundReadPreferences preferences({
  String scope = 'a',
  bool enabled = true,
  bool Function()? stillCurrent,
  Future<void> Function()? reload,
}) => CloudSyncBackgroundReadPreferences(
  captureIdentity: () async => CloudSyncBackgroundReadIdentity(
    scopeHash: scope * 64,
    protectedStoreIdentity: 'obcs2.store.${'s' * 43}',
  ),
  stillCurrent: stillCurrent ?? () => true,
  reload: reload ?? () async {},
  read: (_) => enabled,
  write: (_, __) async => true,
  developerDefault: () => false,
);

void main() {
  test(
    'local invalidation fences a late success before native setup is available',
    () async {
      final registration = CloudSyncBackgroundRegistration();
      final entered = Completer<void>();
      final response = Completer<bool>();
      final old = registration.configure(
        preferences: preferences(),
        configureNative: (_) {
          entered.complete();
          return response.future;
        },
        disableNative: () async => true,
      );
      await entered.future;
      registration.invalidate();
      response.complete(true);
      expect(await old, CloudSyncBackgroundRegistrationOutcome.stale);
      expect(registration.registered, isFalse);
    },
  );

  test('old success cannot register a rejected replacement', () async {
    final registration = CloudSyncBackgroundRegistration();
    final entered = Completer<void>();
    final response = Completer<bool>();
    final old = registration.configure(
      preferences: preferences(),
      configureNative: (_) {
        entered.complete();
        return response.future;
      },
      disableNative: () async => true,
    );
    await entered.future;
    await registration.configure(
      preferences: preferences(scope: 'b'),
      configureNative: (_) async => false,
      disableNative: () async => true,
    );
    response.complete(true);
    expect(await old, CloudSyncBackgroundRegistrationOutcome.stale);
    expect(registration.registered, isFalse);
  });

  test(
    'A B A configurations do not reuse an old operation even with the same scope',
    () async {
      final registration = CloudSyncBackgroundRegistration();
      final entered = Completer<void>();
      final response = Completer<bool>();
      final oldA = registration.configure(
        preferences: preferences(),
        configureNative: (_) {
          entered.complete();
          return response.future;
        },
        disableNative: () async => true,
      );
      await entered.future;
      for (final scope in ['b', 'a']) {
        await registration.configure(
          preferences: preferences(scope: scope),
          configureNative: (_) async => true,
          disableNative: () async => true,
        );
      }
      response.complete(false);
      expect(await oldA, CloudSyncBackgroundRegistrationOutcome.stale);
      expect(registration.registered, isTrue);
    },
  );

  test(
    'accepted current configuration registers only its captured scope',
    () async {
      final registration = CloudSyncBackgroundRegistration();
      final scopes = <String>[];
      final outcome = await registration.configure(
        preferences: preferences(),
        configureNative: (scope) async {
          scopes.add(scope);
          return true;
        },
        disableNative: () async => throw StateError('unexpected disable'),
      );
      expect(outcome, CloudSyncBackgroundRegistrationOutcome.registered);
      expect(scopes, ['a' * 64]);
      expect(registration.registered, isTrue);
    },
  );

  for (final lateResult in [true, false, null]) {
    test(
      'late configure result $lateResult cannot overwrite a newer account',
      () async {
        final registration = CloudSyncBackgroundRegistration();
        final entered = Completer<void>();
        final response = Completer<bool>();
        final old = registration.configure(
          preferences: preferences(),
          configureNative: (_) {
            entered.complete();
            return response.future;
          },
          disableNative: () async => true,
        );
        await entered.future;
        expect(
          await registration.configure(
            preferences: preferences(scope: 'b'),
            configureNative: (_) async => true,
            disableNative: () async => true,
          ),
          CloudSyncBackgroundRegistrationOutcome.registered,
        );
        if (lateResult == null) {
          response.completeError(StateError('old registration failed'));
        } else {
          response.complete(lateResult);
        }
        expect(await old, CloudSyncBackgroundRegistrationOutcome.stale);
        expect(registration.registered, isTrue);
      },
    );
  }

  test('disable immediately fences an outstanding success', () async {
    final registration = CloudSyncBackgroundRegistration();
    final entered = Completer<void>();
    final response = Completer<bool>();
    final old = registration.configure(
      preferences: preferences(),
      configureNative: (_) {
        entered.complete();
        return response.future;
      },
      disableNative: () async => true,
    );
    await entered.future;
    expect(
      await registration.disable(disableNative: () async => true),
      CloudSyncBackgroundRegistrationOutcome.disabled,
    );
    response.complete(true);
    expect(await old, CloudSyncBackgroundRegistrationOutcome.stale);
    expect(registration.registered, isFalse);
  });

  test('late disabled preference cannot revoke a newer account', () async {
    final registration = CloudSyncBackgroundRegistration();
    final loading = Completer<void>();
    final resume = Completer<void>();
    var disables = 0;
    final old = registration.configure(
      preferences: preferences(
        enabled: false,
        reload: () {
          loading.complete();
          return resume.future;
        },
      ),
      configureNative: (_) async => throw StateError('unexpected configure'),
      disableNative: () async {
        disables++;
        return true;
      },
    );
    await loading.future;
    await registration.configure(
      preferences: preferences(scope: 'b'),
      configureNative: (_) async => true,
      disableNative: () async => true,
    );
    resume.complete();
    expect(await old, CloudSyncBackgroundRegistrationOutcome.stale);
    expect(disables, 0);
    expect(registration.registered, isTrue);
  });

  test(
    'account change during preference load dispatches no native command',
    () async {
      final registration = CloudSyncBackgroundRegistration();
      var current = true;
      var commands = 0;
      final outcome = await registration.configure(
        preferences: preferences(
          stillCurrent: () => current,
          reload: () async {
            current = false;
          },
        ),
        configureNative: (_) async {
          commands++;
          return true;
        },
        disableNative: () async {
          commands++;
          return true;
        },
      );
      expect(outcome, CloudSyncBackgroundRegistrationOutcome.stale);
      expect(commands, 0);
      expect(registration.registered, isFalse);
    },
  );

  test(
    'account change during native response does not register stale identity',
    () async {
      final registration = CloudSyncBackgroundRegistration();
      var current = true;
      final outcome = await registration.configure(
        preferences: preferences(stillCurrent: () => current),
        configureNative: (_) async {
          current = false;
          return true;
        },
        disableNative: () async => true,
      );
      expect(outcome, CloudSyncBackgroundRegistrationOutcome.stale);
      expect(registration.registered, isFalse);
    },
  );

  test(
    'late disable failure cannot clear a newer accepted registration',
    () async {
      final registration = CloudSyncBackgroundRegistration();
      final response = Completer<bool>();
      final disabled = registration.disable(
        disableNative: () => response.future,
      );
      await registration.configure(
        preferences: preferences(scope: 'b'),
        configureNative: (_) async => true,
        disableNative: () async => true,
      );
      response.completeError(StateError('old disable failed'));
      expect(await disabled, CloudSyncBackgroundRegistrationOutcome.stale);
      expect(registration.registered, isTrue);
    },
  );

  test(
    'current rejected and failed configuration remain unregistered',
    () async {
      for (final failed in [false, true]) {
        final registration = CloudSyncBackgroundRegistration();
        final outcome = await registration.configure(
          preferences: preferences(),
          configureNative: (_) async {
            if (failed) throw StateError('native unavailable');
            return false;
          },
          disableNative: () async => true,
        );
        expect(
          outcome,
          failed
              ? CloudSyncBackgroundRegistrationOutcome.unavailable
              : CloudSyncBackgroundRegistrationOutcome.rejected,
        );
        expect(registration.registered, isFalse);
      }
    },
  );
}
