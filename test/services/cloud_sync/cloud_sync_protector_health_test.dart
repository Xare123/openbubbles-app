import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validates a non-persisted platform protector round trip', () async {
    final protector = _HealthProtector();

    expect(
      await CloudSyncProtectorHealthProbe(protector: protector).read(),
      isTrue,
    );
    expect(protector.protectedPlaintext, isNotEmpty);
    expect(protector.protectedPlaintext, protector.unprotectedPlaintext);
    expect(protector.scope?.accountFingerprint, isNot(contains('@')));
    expect(protector.kind, CloudSyncProtectedValueKind.rawRecord);
  });

  test('rejects plaintext masquerading as ciphertext', () async {
    final protector = _HealthProtector(returnPlaintextCiphertext: true);

    expect(
      await CloudSyncProtectorHealthProbe(protector: protector).read(),
      isFalse,
    );
    expect(protector.unprotectCalls, 0);
  });

  test('rejects a mismatched round trip', () async {
    final protector = _HealthProtector(roundTripOverride: 'wrong');

    expect(
      await CloudSyncProtectorHealthProbe(protector: protector).read(),
      isFalse,
    );
  });

  test('converts platform protection failures to a blocking false', () async {
    final protector = _HealthProtector(throwOnProtect: true);

    expect(
      await CloudSyncProtectorHealthProbe(protector: protector).read(),
      isFalse,
    );
  });
}

final class _HealthProtector implements CloudSyncProtector {
  _HealthProtector({
    this.returnPlaintextCiphertext = false,
    this.roundTripOverride,
    this.throwOnProtect = false,
  });

  final bool returnPlaintextCiphertext;
  final String? roundTripOverride;
  final bool throwOnProtect;
  String? protectedPlaintext;
  String? unprotectedPlaintext;
  CloudSyncScope? scope;
  CloudSyncProtectedValueKind? kind;
  int unprotectCalls = 0;

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async {
    if (throwOnProtect) throw StateError('secret platform failure');
    this.scope = scope;
    this.kind = kind;
    protectedPlaintext = plaintext;
    return returnPlaintextCiphertext ? plaintext : 'opaque-ciphertext';
  }

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    unprotectCalls++;
    unprotectedPlaintext = protectedPlaintext;
    return roundTripOverride ?? protectedPlaintext!;
  }

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) {
    throw UnimplementedError();
  }
}
