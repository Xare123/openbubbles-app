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
    String? challenge,
  }) => {
    'action': action,
    'seq': seq,
    'confirm': confirm,
    if (challenge != null) 'challenge': challenge,
    'originPackage': origin,
  };

  Map<String, Object> preflight() => const {
    'setup_finished': true,
    'developer_mode': true,
    'legacy_sync_enabled': false,
    'legacy_sync_active': false,
    'logout_active': false,
    'semantic_pull_compiled': true,
    'semantic_pull_active': false,
    'semantic_pull_quiescing': false,
    'auth_ready': true,
    'ui_ready': true,
    'coordinator_active': false,
    'outbox_state': 'empty',
    'semantic_pull_available': true,
  };

  group('gate and command', () {
    test('control defaults off and requires compile plus debug', () {
      expect(CanaryAdbControlGate.compiledIn, isFalse);
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
    });

    test('allowlist is exact and contains no outbound action', () {
      expect(CanaryAdbControlGate.allowedActions, {
        'ping',
        'status',
        'query_route',
        'open_developer_settings',
        'open_cloud_sync_v2',
        'semantic_pull_status',
        'semantic_pull_start',
      });
      expect(CanaryAdbControlGate.allowedActions, isNot(contains('send')));
    });

    test('parser binds confirm challenge action sequence and origin', () {
      const challenge = 'c_abcdefghijklmnopqrstuvwxyz0';
      final command = CanaryAdbCommand.parse(
        args(
          'semantic_pull_start',
          seq: 'run-9',
          confirm: true,
          challenge: challenge,
        ),
      );
      expect(command.action, 'semantic_pull_start');
      expect(command.seq, 'run-9');
      expect(command.confirm, isTrue);
      expect(command.challenge, challenge);
      expect(command.originPackage, origin);
    });

    test(
      'parser rejects unknown action, unsafe sequence and foreign origin',
      () {
        expect(
          () => CanaryAdbCommand.parse(args('send_message')),
          throwsStateError,
        );
        expect(
          () => CanaryAdbCommand.parse(args('ping', seq: '../x')),
          throwsStateError,
        );
        expect(
          () => CanaryAdbCommand.parse({
            'action': 'status',
            'seq': '1',
            'originPackage': 'com.bluebubbles.messaging.alpha',
          }),
          throwsStateError,
        );
      },
    );
  });

  group('short-lived challenge', () {
    test('is one-use and bound to action and sequence', () {
      final store = CanaryAdbChallengeStore();
      final now = DateTime.utc(2026, 9, 8);
      const token = 'c_abcdefghijklmnopqrstuvwxyz0';
      store.issue(
        action: 'semantic_pull_start',
        seq: '7',
        now: now,
        token: token,
      );
      expect(
        store.consume(
          action: 'semantic_pull_start',
          seq: 'wrong',
          token: token,
          now: now,
        ),
        CanaryAdbChallengeConsumption.invalid,
      );
      expect(
        store.consume(
          action: 'semantic_pull_start',
          seq: '7',
          token: token,
          now: now,
        ),
        CanaryAdbChallengeConsumption.invalid,
      );
    });

    test('expires and is consumed at 20 seconds', () {
      final store = CanaryAdbChallengeStore();
      final now = DateTime.utc(2026, 9, 8);
      const token = 'c_abcdefghijklmnopqrstuvwxyz0';
      store.issue(
        action: 'semantic_pull_start',
        seq: '7',
        now: now,
        token: token,
      );
      expect(
        store.consume(
          action: 'semantic_pull_start',
          seq: '7',
          token: token,
          now: now.add(const Duration(seconds: 20)),
        ),
        CanaryAdbChallengeConsumption.expired,
      );
    });
  });

  group('closed result schemas', () {
    test(
      'accepts exact status, preflight, accepted and completion schemas',
      () {
        expect(
          CanaryAdbResult(
            seq: '1',
            action: 'status',
            ok: true,
            code: 'adb_status',
            data: preflight(),
          ).toSafeMap(),
          isNotEmpty,
        );
        expect(
          CanaryAdbResult(
            seq: '1b',
            action: 'semantic_pull_start',
            ok: false,
            code: 'adb_semantic_unavailable',
            data: {...preflight(), 'semantic_pull_available': false},
          ).toSafeMap(),
          isNotEmpty,
        );
        expect(
          CanaryAdbResult(
            seq: '2',
            action: 'semantic_pull_start',
            ok: false,
            code: 'adb_semantic_preflight',
            data: {
              ...preflight(),
              'challenge': 'c_abcdefghijklmnopqrstuvwxyz0',
            },
          ).toSafeMap(),
          isNotEmpty,
        );
        expect(
          const CanaryAdbResult(
            seq: '3',
            action: 'semantic_pull_start',
            ok: true,
            code: 'adb_semantic_accepted',
            data: {'pull_state': 'running'},
          ).toSafeMap(),
          isNotEmpty,
        );
        expect(
          CanaryAdbResult(
            seq: '4',
            action: 'semantic_pull_status',
            ok: true,
            code: 'adb_semantic_status',
            data: {
              ...preflight(),
              'pull_state': 'complete',
              'outcome': 'partial',
              'failure': 'none',
              'passes': 4,
              'remote_drained': false,
              'reached_pass_limit': true,
              'diagnostic_code': 'none',
              'diagnostic_zone': 'none',
            },
          ).toSafeMap(),
          isNotEmpty,
        );
      },
    );

    test('rejects plaintext, phone, email, GUID, and dynamic routes', () {
      for (final injected in <MapEntry<String, Object>>[
        const MapEntry('note', 'hello world'),
        const MapEntry('phone', '+16177106179'),
        const MapEntry('email', 'person@example.com'),
        const MapEntry('guid', '123e4567-e89b-12d3-a456-426614174000'),
      ]) {
        expect(
          () => CanaryAdbResult(
            seq: '1',
            action: 'status',
            ok: true,
            code: 'adb_status',
            data: {...preflight(), injected.key: injected.value},
          ).toSafeMap(),
          throwsStateError,
        );
      }
      expect(
        () => const CanaryAdbResult(
          seq: '1',
          action: 'query_route',
          ok: true,
          code: 'adb_route',
          data: {
            'route': '/chat/private-guid',
            'foreground': true,
            'last_nav': 'none',
          },
        ).toSafeMap(),
        throwsStateError,
      );
      expect(
        () => const CanaryAdbResult(
          seq: '1',
          action: 'ping',
          ok: false,
          code: 'adb_pong',
          data: {'semantic_pull_compiled': true},
        ).toSafeMap(),
        throwsStateError,
      );
    });

    test('rejects unrecognized report diagnostics', () {
      expect(
        () => CanaryAdbResult(
          seq: '1',
          action: 'semantic_pull_status',
          ok: true,
          code: 'adb_semantic_status',
          data: {
            ...preflight(),
            'pull_state': 'failed',
            'outcome': 'none',
            'failure': 'report_invalid',
            'passes': 0,
            'remote_drained': false,
            'reached_pass_limit': false,
            'diagnostic_code': 'record_identifier_123',
            'diagnostic_zone': 'messages',
          },
        ).toSafeMap(),
        throwsStateError,
      );
    });
  });

  group('native and host scoping', () {
    test('receiver is canaryDebug-only and shell permission protected', () {
      final manifest = File(
        'android/app/src/canaryDebug/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('CanaryAdbControlReceiver'));
      expect(manifest, contains('android:exported="true"'));
      expect(manifest, contains('android.permission.DUMP'));
      final main = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(main, isNot(contains('CanaryAdb')));
    });

    test('receiver never launches activity and logs fixed phrases', () {
      final receiver = File(
        'android/app/src/canaryDebug/java/com/bluebubbles/messaging/'
        'CanaryAdbControlReceiver.kt',
      ).readAsStringSync();
      expect(receiver, isNot(contains('startActivity')));
      expect(receiver, contains('MainActivity.engine_ready'));
      expect(receiver, contains('command_acknowledged'));
      expect(receiver, isNot(contains('e.message')));
      expect(receiver, isNot(contains('seq=" +')));
    });

    test('host launches only navigation and has no fixed startup sleep', () {
      final host = File('tooling/canary_adb_control.ps1').readAsStringSync();
      expect(
        host,
        contains("if (\$Action -eq 'open-dev' -or \$Action -eq 'open-sync')"),
      );
      expect(host, contains('Wait-DartReady'));
      expect(host, isNot(contains('Start-Sleep -Seconds')));
      expect(host, contains('Pull accepted asynchronously'));
    });
  });
}
