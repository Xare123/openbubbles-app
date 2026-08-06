import 'cloud_sync_models.dart';
import 'cloud_sync_protector.dart';

/// Exercises the platform protection boundary without retaining protected
/// material or using an Apple account identifier.
///
/// The probe uses a fixed synthetic scope and plaintext. A successful
/// round-trip proves that the current process can reach Android Keystore or
/// Windows DPAPI before a manual CloudKit shadow fetch is admitted.
final class CloudSyncProtectorHealthProbe {
  const CloudSyncProtectorHealthProbe({required this.protector});

  static final CloudSyncScope _scope = CloudSyncScope(
    accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    container: 'com.openbubbles.cloud-sync-v2-health',
    database: 'local',
    zone: 'protector',
  );
  static const String _plaintext = 'cloud-sync-v2-protector-health-v1';

  final CloudSyncProtector protector;

  /// Returns false for every protection, validation, or platform failure.
  ///
  /// Neither the ciphertext nor an exception is returned to diagnostics.
  Future<bool> read() async {
    try {
      final ciphertext = await protector.protect(
        scope: _scope,
        kind: CloudSyncProtectedValueKind.rawRecord,
        plaintext: _plaintext,
      );
      if (ciphertext.isEmpty || ciphertext == _plaintext) return false;
      final roundTrip = await protector.unprotect(
        scope: _scope,
        kind: CloudSyncProtectedValueKind.rawRecord,
        ciphertext: ciphertext,
      );
      return roundTrip == _plaintext;
    } catch (_) {
      return false;
    }
  }
}
