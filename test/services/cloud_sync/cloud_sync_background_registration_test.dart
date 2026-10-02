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

CloudSyncBackgroundReadPreferences storedPreferences({
  String scope = 'a',
  Object? stored,
  bool developerDefault = false,
  bool Function()? stillCurrent,
  Future<void> Function()? reload,
}) => CloudSyncBackgroundReadPreferences(
  captureIdentity: () async => CloudSyncBackgroundReadIdentity(
    scopeHash: scope * 64,
    protectedStoreIdentity: 'obcs2.store.${'s' * 43}',
  ),
  stillCurrent: stillCurrent ?? () => true,
  reload: reload ?? () async {},
  read: (_) => stored,
  write: (_, __) async => true,
  developerDefault: () => developerDefault,
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
  test(
    'prepare runs after accepted local configure with explicit opt-in',
    () async {
      final order = <String>[];
      CloudSyncBackgroundReadPreference? seen;
      bool? seenCurrent;
      final registration = CloudSyncBackgroundRegistration();
      final outcome = await registration.configure(
        preferences: storedPreferences(stored: true),
        configureNative: (scope) async {
          order.add('configureNative');
          expect(scope, 'a' * 64);
          return true;
        },
        disableNative: () async => throw StateError('unexpected disable'),
        prepareNotifications: (preference, stillCurrent) async {
          order.add('prepare');
          seen = preference;
          seenCurrent = stillCurrent();
          return true;
        },
      );
      expect(outcome, CloudSyncBackgroundRegistrationOutcome.registered);
      expect(registration.registered, isTrue);
      expect(order, ['configureNative', 'prepare']);
      expect(registration.locallyRegistered, isTrue);
      expect(seen?.enabled, isTrue);
      expect(seen?.explicitlyEnabled, isTrue);
      expect(seenCurrent, isTrue);
    },
  );
  test(
    'developer default stays enabled but never presents explicit opt-in',
    () async {
      CloudSyncBackgroundReadPreference? seen;
      final registration = CloudSyncBackgroundRegistration();
      final outcome = await registration.configure(
        preferences: storedPreferences(stored: null, developerDefault: true),
        configureNative: (_) async => true,
        disableNative: () async => throw StateError('unexpected disable'),
        prepareNotifications: (preference, _) async {
          seen = preference;
          return true;
        },
      );
      expect(outcome, CloudSyncBackgroundRegistrationOutcome.registered);
      expect(registration.registered, isTrue);
      expect(seen?.enabled, isTrue);
      expect(seen?.explicitlyEnabled, isFalse);
    },
  );
  test('rejected local configure never invokes prepare', () async {
    var prepares = 0;
    final registration = CloudSyncBackgroundRegistration();
    final outcome = await registration.configure(
      preferences: storedPreferences(stored: true),
      configureNative: (_) async => false,
      disableNative: () async => throw StateError('unexpected disable'),
      prepareNotifications: (_, __) async {
        prepares++;
        return true;
      },
    );
    expect(outcome, CloudSyncBackgroundRegistrationOutcome.rejected);
    expect(prepares, 0);
    expect(registration.registered, isFalse);
    expect(registration.locallyRegistered, isFalse);
  });
  test(
    'disabled preference uses disable path and never invokes prepare',
    () async {
      var configures = 0;
      var disables = 0;
      var prepares = 0;
      final registration = CloudSyncBackgroundRegistration();
      final outcome = await registration.configure(
        preferences: storedPreferences(stored: false),
        configureNative: (_) async {
          configures++;
          return true;
        },
        disableNative: () async {
          disables++;
          return true;
        },
        prepareNotifications: (_, __) async {
          prepares++;
          return true;
        },
      );
      expect(outcome, CloudSyncBackgroundRegistrationOutcome.disabled);
      expect(configures, 0);
      expect(disables, 1);
      expect(prepares, 0);
      expect(registration.registered, isFalse);
      expect(registration.locallyRegistered, isFalse);
    },
  );
  test('failed local scheduling never invokes prepare', () async {
    var prepares = 0;
    final registration = CloudSyncBackgroundRegistration();
    final outcome = await registration.configure(
      preferences: storedPreferences(stored: true),
      configureNative: (_) async => throw StateError('native down'),
      disableNative: () async => throw StateError('unexpected disable'),
      prepareNotifications: (_, __) async {
        prepares++;
        return true;
      },
    );
    expect(outcome, CloudSyncBackgroundRegistrationOutcome.unavailable);
    expect(prepares, 0);
    expect(registration.registered, isFalse);
  });
  test('stale before preparation never invokes prepare', () async {
    var current = true;
    var prepares = 0;
    final registration = CloudSyncBackgroundRegistration();
    final outcome = await registration.configure(
      preferences: storedPreferences(stored: true, stillCurrent: () => current),
      configureNative: (_) async {
        current = false;
        return true;
      },
      disableNative: () async => throw StateError('unexpected disable'),
      prepareNotifications: (_, __) async {
        prepares++;
        return true;
      },
    );
    expect(outcome, CloudSyncBackgroundRegistrationOutcome.stale);
    expect(prepares, 0);
    expect(registration.registered, isFalse);
  });
  test(
    'prepare false keeps local wake admission while reporting unavailable',
    () async {
      final registration = CloudSyncBackgroundRegistration();
      final outcome = await registration.configure(
        preferences: storedPreferences(stored: true),
        configureNative: (_) async => true,
        disableNative: () async => throw StateError('unexpected disable'),
        prepareNotifications: (_, __) async => false,
      );
      expect(outcome, CloudSyncBackgroundRegistrationOutcome.unavailable);
      expect(registration.registered, isFalse);
      expect(registration.locallyRegistered, isTrue);
    },
  );
  test(
    'prepare error keeps local wake admission while reporting unavailable',
    () async {
      final registration = CloudSyncBackgroundRegistration();
      final outcome = await registration.configure(
        preferences: storedPreferences(stored: true),
        configureNative: (_) async => true,
        disableNative: () async => throw StateError('unexpected disable'),
        prepareNotifications: (_, __) async => throw StateError('notify down'),
      );
      expect(outcome, CloudSyncBackgroundRegistrationOutcome.unavailable);
      expect(registration.registered, isFalse);
      expect(registration.locallyRegistered, isTrue);
    },
  );
  test(
    'disable while prepare pending fences late success and closes stillCurrent',
    () async {
      final registration = CloudSyncBackgroundRegistration();
      final entered = Completer<void>();
      final reply = Completer<bool>();
      bool Function()? capturedStillCurrent;
      final pending = registration.configure(
        preferences: storedPreferences(stored: true),
        configureNative: (_) async => true,
        disableNative: () async => true,
        prepareNotifications: (_, stillCurrent) {
          capturedStillCurrent = stillCurrent;
          entered.complete();
          return reply.future;
        },
      );
      await entered.future;
      expect(capturedStillCurrent!(), isTrue);
      expect(registration.locallyRegistered, isTrue);
      expect(
        await registration.disable(disableNative: () async => true),
        CloudSyncBackgroundRegistrationOutcome.disabled,
      );
      expect(capturedStillCurrent!(), isFalse);
      expect(registration.locallyRegistered, isFalse);
      reply.complete(true);
      expect(await pending, CloudSyncBackgroundRegistrationOutcome.stale);
      expect(registration.registered, isFalse);
    },
  );
  test(
    'account replacement while prepare pending fences late success',
    () async {
      var current = true;
      final registration = CloudSyncBackgroundRegistration();
      final entered = Completer<void>();
      final reply = Completer<bool>();
      bool Function()? capturedStillCurrent;
      final pending = registration.configure(
        preferences: storedPreferences(
          stored: true,
          stillCurrent: () => current,
        ),
        configureNative: (_) async => true,
        disableNative: () async => true,
        prepareNotifications: (_, stillCurrent) {
          capturedStillCurrent = stillCurrent;
          entered.complete();
          return reply.future;
        },
      );
      await entered.future;
      expect(capturedStillCurrent!(), isTrue);
      current = false;
      expect(capturedStillCurrent!(), isFalse);
      reply.complete(true);
      expect(await pending, CloudSyncBackgroundRegistrationOutcome.stale);
      expect(registration.registered, isFalse);
    },
  );
  test('newer configure while prepare pending fences late reply', () async {
    final registration = CloudSyncBackgroundRegistration();
    final entered = Completer<void>();
    final reply = Completer<bool>();
    bool Function()? capturedStillCurrent;
    final old = registration.configure(
      preferences: storedPreferences(stored: true),
      configureNative: (_) async => true,
      disableNative: () async => true,
      prepareNotifications: (_, stillCurrent) {
        capturedStillCurrent = stillCurrent;
        entered.complete();
        return reply.future;
      },
    );
    await entered.future;
    expect(capturedStillCurrent!(), isTrue);
    expect(
      await registration.configure(
        preferences: storedPreferences(scope: 'b', stored: true),
        configureNative: (_) async => true,
        disableNative: () async => true,
        prepareNotifications: (_, __) async => true,
      ),
      CloudSyncBackgroundRegistrationOutcome.registered,
    );
    expect(registration.registered, isTrue);
    expect(capturedStillCurrent!(), isFalse);
    reply.complete(true);
    expect(await old, CloudSyncBackgroundRegistrationOutcome.stale);
    expect(registration.registered, isTrue);
  });
  test('late prepare error after newer configure stays stale', () async {
    final registration = CloudSyncBackgroundRegistration();
    final entered = Completer<void>();
    final reply = Completer<bool>();
    final old = registration.configure(
      preferences: storedPreferences(stored: true),
      configureNative: (_) async => true,
      disableNative: () async => true,
      prepareNotifications: (_, __) {
        entered.complete();
        return reply.future;
      },
    );
    await entered.future;
    expect(
      await registration.configure(
        preferences: storedPreferences(scope: 'b', stored: true),
        configureNative: (_) async => true,
        disableNative: () async => true,
        prepareNotifications: (_, __) async => true,
      ),
      CloudSyncBackgroundRegistrationOutcome.registered,
    );
    reply.completeError(StateError('late prepare failed'));
    expect(await old, CloudSyncBackgroundRegistrationOutcome.stale);
    expect(registration.registered, isTrue);
  });
}
