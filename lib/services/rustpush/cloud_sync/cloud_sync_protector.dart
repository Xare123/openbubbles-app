import 'package:bluebubbles/src/rust/frb_generated.dart';

import 'cloud_sync_models.dart';

/// Purpose separation for Cloud Sync V2 protected values.
///
/// Platform implementations must bind the purpose and [CloudSyncScope] into
/// authenticated encryption so a ciphertext cannot be moved between accounts,
/// zones, or value types.
enum CloudSyncProtectedValueKind {
  checkpointToken,
  serverRecordId,
  systemFields,
  payloadReference,
  rawRecord,
}

/// Platform secret-storage boundary for Cloud Sync V2.
///
/// Android implementations use an AES-256-GCM key retained by Android
/// Keystore. Windows implementations protect values and the per-install HMAC
/// secret with current-user DPAPI on both ARM64 and x64. Implementations must
/// never log plaintext, ciphertext, raw account identifiers, or derived keys.
abstract interface class CloudSyncProtector {
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  });

  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  });

  /// Produces an application-scoped HMAC identifier.
  ///
  /// A plain hash of a low-entropy DSID is not sufficient because it can be
  /// guessed offline. The raw identifier must never be persisted or logged.
  Future<String> fingerprintAccount(String rawAccountIdentifier);
}

/// Narrow binding seam for the FRB Cloud Sync protection entry points.
///
/// Keeping this seam explicit allows the adapter to be tested without loading
/// the native library and avoids exposing protected values to diagnostics.
abstract interface class RustCloudSyncProtectionBindings {
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
  });

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
  });

  Future<String> fingerprintAccount({
    required String storageDirectory,
    required String rawAccountIdentifier,
  });
}

/// Production [CloudSyncProtector] backed by the platform Rust bridge.
///
/// [storageDirectory] must be the existing private application-support
/// directory. The adapter never creates a profile, starts CloudKit work, or
/// enables sync writes.
final class RustCloudSyncProtector implements CloudSyncProtector {
  RustCloudSyncProtector({
    required String storageDirectory,
    RustCloudSyncProtectionBindings? bindings,
  }) : _storageDirectory = _validatedStorageDirectory(storageDirectory),
       _bindings = bindings ?? FrbCloudSyncProtectionBindings();

  final String _storageDirectory;
  final RustCloudSyncProtectionBindings _bindings;

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) {
    return _bindings.protect(
      storageDirectory: _storageDirectory,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      purpose: kind.name,
      plaintext: plaintext,
    );
  }

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) {
    return _bindings.unprotect(
      storageDirectory: _storageDirectory,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      purpose: kind.name,
      ciphertext: ciphertext,
    );
  }

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) {
    return _bindings.fingerprintAccount(
      storageDirectory: _storageDirectory,
      rawAccountIdentifier: rawAccountIdentifier,
    );
  }

  static String _validatedStorageDirectory(String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(
        value,
        'storageDirectory',
        'Must be an existing private application-support directory',
      );
    }
    return value;
  }
}

/// Typed façade over the generated FRB protection entry points.
///
/// Keeping the generated API typed makes binding drift a compile-time error
/// while [RustCloudSyncProtectionBindings] remains injectable in unit tests.
final class FrbCloudSyncProtectionBindings
    implements RustCloudSyncProtectionBindings {
  FrbCloudSyncProtectionBindings({RustLibApi? api})
    // ignore: invalid_use_of_internal_member
    : _api = api ?? RustLib.instance.api;

  final RustLibApi _api;

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
  }) {
    return Future.sync(() {
      return _api.crateApiApiCloudSyncProtect(
        storageDirectory: storageDirectory,
        accountFingerprint: accountFingerprint,
        container: container,
        database: database,
        zone: zone,
        streamKind: streamKind,
        schemaVersion: schemaVersion,
        purpose: purpose,
        plaintext: plaintext,
      );
    });
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
  }) {
    return Future.sync(() {
      return _api.crateApiApiCloudSyncUnprotect(
        storageDirectory: storageDirectory,
        accountFingerprint: accountFingerprint,
        container: container,
        database: database,
        zone: zone,
        streamKind: streamKind,
        schemaVersion: schemaVersion,
        purpose: purpose,
        ciphertext: ciphertext,
      );
    });
  }

  @override
  Future<String> fingerprintAccount({
    required String storageDirectory,
    required String rawAccountIdentifier,
  }) {
    return Future.sync(() {
      return _api.crateApiApiCloudSyncFingerprintAccount(
        storageDirectory: storageDirectory,
        rawAccountIdentifier: rawAccountIdentifier,
      );
    });
  }
}
