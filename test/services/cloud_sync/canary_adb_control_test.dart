import 'dart:io';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_canary_adb_control.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const origin = CloudSyncDevGate.androidCanaryPackageName;

  Map<String, dynamic> args(
    String action, {
    String seq = '7',
    bool confirm = false,
  }) => {
    'action': action,
    'seq': seq,
    'confirm': confirm,
    'originPackage': origin,
  };

  group('CanaryAdbControlGate', () {
    test('control is compiled out by default (kill switch default-off)', () {
      expect(CanaryAdbControlGate.compiledIn, isFalse);
    });

    test('active requires both compile flag and debug mode', () {
      expect(
        CanaryAdbControlGate.active(
          compiledInOverride: true,
          debugOverride: true,
        ),
        isTrue,
      );
      expect(
        CanaryAdbControlGate.active(
          compiledInOverride: true,
          debugOverride: false,
        ),
        isFalse,
      );
      expect(
        CanaryAdbControlGate.active(
          compiledInOverride: false,
          debugOverride: true,
        ),
        isFalse,
      );
    });

    test('allowlist has exactly the documented safe actions', () {
      expect(CanaryAdbControlGate.allowedActions, {
        'ping',
        'status',
        'query_route',
        'open_developer_settings',
        'open_cloud_sync_v2',
        'semantic_pull_status',
        'semantic_pull_start',
      });
    });
  });

  group('CanaryAdbCommand.parse', () {
    test('accepts every allowlisted action', () {
      for (final action in CanaryAdbControlGate.allowedActions) {
        final command = CanaryAdbCommand.parse(args(action));
        expect(command.action, action);
        expect(command.seq, '7');
        expect(command.confirm, isFalse);
      }
    });

    test('rejects unknown, missing, and non-string actions', () {
      expect(
        () => CanaryAdbCommand.parse(args('send_message')),
        throwsStateError,
      );
      expect(
        () => CanaryAdbCommand.parse(args('delete_all')),
        throwsStateError,
      );
      expect(
        () => CanaryAdbCommand.parse({'seq': '1', 'originPackage': origin}),
        throwsStateError,
      );
      expect(() => CanaryAdbCommand.parse(null), throwsStateError);
    });

    test('rejects bad sequence tokens', () {
      expect(
        () => CanaryAdbCommand.parse(args('ping', seq: '')),
        throwsStateError,
      );
      expect(
        () => CanaryAdbCommand.parse(args('ping', seq: 'a b')),
        throwsStateError,
      );
      expect(
        () => CanaryAdbCommand.parse(args('ping', seq: '../x')),
        throwsStateError,
      );
    });

    test('rejects foreign origin packages', () {
      expect(
        () => CanaryAdbCommand.parse({
          'action': 'status',
          'seq': '1',
          'originPackage': 'com.bluebubbles.messaging.alpha',
        }),
        throwsStateError,
      );
      expect(
        () => CanaryAdbCommand.parse({'action': 'status', 'seq': '1'}),
        throwsStateError,
      );
    });

    test('reads the two-step confirm flag', () {
      expect(
        CanaryAdbCommand.parse(args('semantic_pull_start')).confirm,
        isFalse,
      );
      expect(
        CanaryAdbCommand.parse(
          args('semantic_pull_start', confirm: true),
        ).confirm,
        isTrue,
      );
    });
  });

  group('CanaryAdbResult', () {
    test('safe maps round-trip and pass the scanner', () {
      final map = const CanaryAdbResult(
        seq: '9',
        action: 'status',
        ok: true,
        code: 'adb_status',
        data: {'developer_mode': true, 'passes': 3, 'route': 'unknown'},
      ).toSafeMap();
      CanaryAdbResult.assertSafeForTest(map);
      expect(map['code'], 'adb_status');
    });

    test('rejects identifier-like keys and free-form values', () {
      expect(
        () => const CanaryAdbResult(
          seq: '1',
          action: 'status',
          ok: true,
          code: 'x',
          data: {'chatGuid': 'abc'},
        ).toSafeMap(),
        throwsStateError,
      );
      expect(
        () => const CanaryAdbResult(
          seq: '1',
          action: 'status',
          ok: true,
          code: 'x',
          data: {'note': 'hello@example.com'},
        ).toSafeMap(),
        throwsStateError,
      );
      expect(
        () => CanaryAdbResult(
          seq: '1',
          action: 'status',
          ok: true,
          code: 'x',
          data: {'note': 'a' * 300},
        ).toSafeMap(),
        throwsStateError,
      );
    });
  });

  group('canaryDebug manifest scoping', () {
    test('receiver is exported with the shell-only DUMP permission', () {
      final manifest = File(
        'android/app/src/canaryDebug/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('CanaryAdbControlReceiver'));
      expect(manifest, contains('android:exported="true"'));
      expect(manifest, contains('android.permission.DUMP'));
    });

    test('main manifest has no trace of the debug receiver', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest.contains('CanaryAdb'), isFalse);
    });
  });
}
