import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  final scope = CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: 'com.apple.messages.cloudkit',
    database: 'private',
    zone: 'Messages',
    streamKind: CloudSyncStreamKind.messages,
    schemaVersion: 2,
  );

  test(
    'forwards every scope component and purpose to Rust protection',
    () async {
      final bindings = _RecordingBindings();
      final protector = RustCloudSyncProtector(
        storageDirectory: r'C:\private-app-support',
        bindings: bindings,
      );

      expect(
        await protector.protect(
          scope: scope,
          kind: CloudSyncProtectedValueKind.systemFields,
          plaintext: 'opaque-system-fields',
        ),
        'protected',
      );

      expect(bindings.protectCall, {
        'storageDirectory': r'C:\private-app-support',
        'accountFingerprint': testAccountFingerprintA,
        'container': 'com.apple.messages.cloudkit',
        'database': 'private',
        'zone': 'Messages',
        'streamKind': 'messages',
        'schemaVersion': 2,
        'purpose': 'systemFields',
        'plaintext': 'opaque-system-fields',
      });
    },
  );

  test(
    'forwards the requested unprotect context without weakening it',
    () async {
      final bindings = _RecordingBindings();
      final protector = RustCloudSyncProtector(
        storageDirectory: '/private/app-support',
        bindings: bindings,
      );

      expect(
        await protector.unprotect(
          scope: scope,
          kind: CloudSyncProtectedValueKind.checkpointToken,
          ciphertext: 'obcs2.android.ciphertext',
        ),
        'plaintext',
      );
      expect(bindings.unprotectCall?['purpose'], 'checkpointToken');
      expect(bindings.unprotectCall?['zone'], 'Messages');
      expect(bindings.unprotectCall?['ciphertext'], 'obcs2.android.ciphertext');
    },
  );

  test('passes a raw account identifier only to the HMAC boundary', () async {
    final bindings = _RecordingBindings();
    final protector = RustCloudSyncProtector(
      storageDirectory: '/private/app-support',
      bindings: bindings,
    );

    expect(
      await protector.fingerprintAccount('raw-dsid'),
      testAccountFingerprintB,
    );
    expect(bindings.fingerprintCall, {
      'storageDirectory': '/private/app-support',
      'rawAccountIdentifier': 'raw-dsid',
    });
  });

  test('rejects an empty storage directory before reaching native code', () {
    expect(
      () => RustCloudSyncProtector(
        storageDirectory: '  ',
        bindings: _RecordingBindings(),
      ),
      throwsArgumentError,
    );
  });
}

final class _RecordingBindings implements RustCloudSyncProtectionBindings {
  Map<String, Object?>? protectCall;
  Map<String, Object?>? unprotectCall;
  Map<String, Object?>? fingerprintCall;

  @override
  Future<String> protect({
    required String storageDirectory,
    required String accountFingerprint,
    required String container,
    required String database,
    required String zone,
    required String streamKind,
    required int schemaVersion,
    required String purpose,
    required String plaintext,
  }) async {
    protectCall = {
      'storageDirectory': storageDirectory,
      'accountFingerprint': accountFingerprint,
      'container': container,
      'database': database,
      'zone': zone,
      'streamKind': streamKind,
      'schemaVersion': schemaVersion,
      'purpose': purpose,
      'plaintext': plaintext,
    };
    return 'protected';
  }

  @override
  Future<String> unprotect({
    required String storageDirectory,
    required String accountFingerprint,
    required String container,
    required String database,
    required String zone,
    required String streamKind,
    required int schemaVersion,
    required String purpose,
    required String ciphertext,
  }) async {
    unprotectCall = {
      'storageDirectory': storageDirectory,
      'accountFingerprint': accountFingerprint,
      'container': container,
      'database': database,
      'zone': zone,
      'streamKind': streamKind,
      'schemaVersion': schemaVersion,
      'purpose': purpose,
      'ciphertext': ciphertext,
    };
    return 'plaintext';
  }

  @override
  Future<String> fingerprintAccount({
    required String storageDirectory,
    required String rawAccountIdentifier,
  }) async {
    fingerprintCall = {
      'storageDirectory': storageDirectory,
      'rawAccountIdentifier': rawAccountIdentifier,
    };
    return testAccountFingerprintB;
  }
}
