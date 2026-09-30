import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_android_background.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_background_read_preference.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, Object?> disk;
  late Map<String, Object?> cache;
  late CloudSyncBackgroundReadIdentity identity;
  late bool current;
  late bool developer;
  late bool writeSucceeds;
  late int writes;
  late Future<void> Function() afterReload;
  late Future<void> Function() afterWrite;
  late CloudSyncBackgroundReadPreferences preferences;

  setUp(() {
    disk = {};
    cache = {};
    identity = CloudSyncBackgroundReadIdentity(
      scopeHash: 'a' * 64,
      protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
    );
    current = true;
    developer = false;
    writeSucceeds = true;
    writes = 0;
    afterReload = () async {};
    afterWrite = () async {};
    preferences = CloudSyncBackgroundReadPreferences(
      captureIdentity: () async => identity,
      stillCurrent: () => current,
      reload: () async {
        cache = Map.of(disk);
        await afterReload();
      },
      read: (key) => cache[key],
      write: (key, value) async {
        writes++;
        if (writeSucceeds) disk[key] = value;
        await afterWrite();
        return writeSucceeds;
      },
      developerDefault: () => developer,
    );
  });

  test('normal account defaults off and reading never writes', () async {
    final result = await preferences.load();
    expect(result.enabled, isFalse);
    expect(writes, 0);
    expect(disk, isEmpty);
  });

  test('accepts the real native protected-store identity format', () {
    final auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'N' * 43,
      accountFingerprint: 'A' * 43,
      protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
      cloudMessagesClient: Object(),
    );
    final actual = CloudSyncBackgroundReadIdentity(
      scopeHash: CloudSyncAndroidBackgroundPolicy.scopeHash(
        CloudSyncAndroidBackgroundPolicy.semanticMessageScope(
          auth.accountFingerprint,
        ),
      ),
      protectedStoreIdentity: auth.protectedStoreIdentity,
    );
    expect(actual.preferenceKey, startsWith('cloudSyncV2BackgroundRead.v1.'));
    expect(actual.preferenceKey, isNot(contains(auth.protectedStoreIdentity)));
  });

  test('unset preference preserves developer qualification default', () async {
    developer = true;
    expect((await preferences.load()).enabled, isTrue);
    expect(writes, 0);
  });

  test(
    'explicit off overrides developer default and survives a reload',
    () async {
      developer = true;
      final saved = await preferences.setEnabled(
        await preferences.load(),
        false,
      );
      expect(saved.enabled, isFalse);
      expect((await preferences.load()).enabled, isFalse);
      expect(disk, {identity.preferenceKey: false});
      expect(writes, 1);
    },
  );

  test('explicit opt-in works without Developer Mode', () async {
    final saved = await preferences.setEnabled(await preferences.load(), true);
    expect(saved.enabled, isTrue);
    expect((await preferences.load()).enabled, isTrue);
    expect(developer, isFalse);
    expect(disk, {identity.preferenceKey: true});
  });

  for (final invalid in ['true', 1, <String, Object?>{}]) {
    test('malformed stored choice fails closed: $invalid', () async {
      developer = true;
      disk[identity.preferenceKey] = invalid;
      expect((await preferences.load()).enabled, isFalse);
      expect(writes, 0);
    });
  }

  test('headless reader refreshes cached opt-in before admission', () async {
    disk[identity.preferenceKey] = true;
    expect((await preferences.load()).enabled, isTrue);
    disk[identity.preferenceKey] = false;
    expect(cache[identity.preferenceKey], isTrue);
    expect((await preferences.load()).enabled, isFalse);
    expect(writes, 0);
  });

  for (final replaceStore in [false, true]) {
    test(
      'consent is isolated by ${replaceStore ? 'store' : 'account scope'}',
      () async {
        final preview = await preferences.load();
        await preferences.setEnabled(preview, true);
        identity = CloudSyncBackgroundReadIdentity(
          scopeHash: (replaceStore ? 'a' : 'c') * 64,
          protectedStoreIdentity:
              'obcs2.store.${(replaceStore ? 'C' : 'B') * 43}',
        );
        expect((await preferences.load()).enabled, isFalse);
        await expectLater(
          preferences.setEnabled(preview, true),
          throwsStateError,
        );
        expect(writes, 1);
        expect(disk.containsKey(identity.preferenceKey), isFalse);
      },
    );
  }

  test(
    'replacement while preferences reload cannot authorize a read',
    () async {
      disk[identity.preferenceKey] = true;
      afterReload = () async {
        identity = CloudSyncBackgroundReadIdentity(
          scopeHash: 'c' * 64,
          protectedStoreIdentity: 'obcs2.store.${'D' * 43}',
        );
      };
      await expectLater(preferences.load(), throwsStateError);
      expect(writes, 0);
    },
  );

  test('lost service identity after reload prevents a write', () async {
    final preview = await preferences.load();
    afterReload = () async => current = false;
    await expectLater(preferences.setEnabled(preview, true), throwsStateError);
    expect(writes, 0);
  });

  test('failed persistence is not presented as a saved opt-in', () async {
    final preview = await preferences.load();
    writeSucceeds = false;
    await expectLater(preferences.setEnabled(preview, true), throwsStateError);
    expect(disk, isEmpty);
  });

  test(
    'account replacement during write never opts in the replacement',
    () async {
      final preview = await preferences.load();
      afterWrite = () async {
        identity = CloudSyncBackgroundReadIdentity(
          scopeHash: 'c' * 64,
          protectedStoreIdentity: 'obcs2.store.${'D' * 43}',
        );
      };
      await expectLater(
        preferences.setEnabled(preview, true),
        throwsStateError,
      );
      expect(disk, {preview.identity.preferenceKey: true});
      expect((await preferences.load()).enabled, isFalse);
    },
  );

  test('missing native identity does not grant scheduling', () async {
    final unavailable = CloudSyncBackgroundReadPreferences(
      captureIdentity: () async => null,
      stillCurrent: () => true,
      reload: () async {},
      read: (_) => true,
      write: (_, _) async => throw StateError('unexpected write'),
      developerDefault: () => true,
    );
    await expectLater(unavailable.load(), throwsStateError);
  });

  test('preference keys contain only versioned hashes', () {
    expect(
      identity.preferenceKey,
      matches(RegExp(r'^cloudSyncV2BackgroundRead\.v1\.[a-f0-9]{64}$')),
    );
    for (final bad in ['', 'A' * 64, 'a' * 63, 'account@example.com']) {
      expect(
        () => CloudSyncBackgroundReadIdentity(
          scopeHash: bad,
          protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
        ),
        throwsStateError,
      );
    }
  });

  test('replaced consent identity makes the old durable wake stale', () {
    expect(
      CloudSyncAndroidBackgroundPolicy.classifyFailure(
        StateError('cloud_sync_background_preference_identity_changed'),
      ),
      CloudSyncAndroidBackgroundOutcome.stale,
    );
  });

  test(
    'Profile integrates the preference without exposing automatic uploads',
    () {
      final profile = File(
        'lib/app/layouts/settings/pages/profile/profile_panel.dart',
      ).readAsStringSync();
      expect(
        profile,
        contains('if (pushService.cloudSyncV2BackgroundReadVisible)'),
      );
      expect(
        profile,
        contains('onLoad: pushService.readCloudSyncV2BackgroundReadPreference'),
      );
      expect(
        profile,
        contains(
          'onChanged: pushService.setCloudSyncV2BackgroundReadPreference',
        ),
      );
      final source = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final start = source.indexOf(
        'bool get _cloudSyncV2AndroidBackgroundRuntimeAllowed',
      );
      final end = source.indexOf('bool get cloudSyncV2AutomaticArchiveVisible', start);
      final scheduling = source.substring(start, end);
      expect(
        scheduling,
        contains('CloudSyncDevGate.androidBackgroundReadEnabled'),
      );
      expect(
        scheduling,
        contains('CloudSyncDevGate.manualSemanticPullEnabled'),
      );
      expect(scheduling, contains('_cloudSyncV2CanaryRuntimeAllowed'));
      expect(
        scheduling,
        contains('developerDefault: () => _cloudSyncV2DeveloperRuntimeAllowed'),
      );
      expect(scheduling, contains('if (!preference.enabled)'));
      expect(scheduling, contains('write: ss.prefs.setBool'));
      expect(scheduling, isNot(contains('ensureWriterOwned(')));
      expect(scheduling, isNot(contains('_queueCloudSyncV2LocalSends(')));
      expect(scheduling, isNot(contains('runCloudSyncV2Outbound')));
      final automatic = source.substring(
        end,
        source.indexOf('/// Local-only receive capture', end),
      );
      expect(automatic, contains('preferences.isGranted(consent)'));
      expect(automatic, contains('automaticArchiveIdentity: consent.identity'));
      expect(automatic, isNot(contains('developerDefault:')));
      expect(automatic, contains('CloudSyncDevGate.localSendRuntimeEnabled'));
    },
  );
}
