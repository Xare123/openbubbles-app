import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/frb_generated.dart' as frb_generated;
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;

import 'cloud_sync_manual_shadow_sampler.dart';
import 'native_protected_cloud_sync_transport.dart';
import 'cloud_sync_protector.dart';
import 'objectbox_cloud_sync_store.dart';

/// Redacted metadata returned by one native operation that reads the DSID from
/// the supplied Rust Cloud Messages client and derives its per-install
/// fingerprint internally. Raw account identifiers never enter Dart.
final class CloudSyncNativeAuthMetadata {
  const CloudSyncNativeAuthMetadata({
    required this.nativeSessionId,
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
  });

  final String nativeSessionId;
  final String accountFingerprint;
  final String protectedStoreIdentity;
}

abstract interface class CloudSyncNativeAuthBinding {
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  });
}

/// Production binding for the native client-bound authentication snapshot.
///
/// Rust reads the raw DSID from the supplied Cloud Messages client and derives
/// both returned values with the private per-install key. Raw Apple account
/// identifiers therefore never cross the FRB boundary into Dart.
final class FrbCloudSyncNativeAuthBinding
    implements CloudSyncNativeAuthBinding {
  FrbCloudSyncNativeAuthBinding({frb_generated.RustLibApi? api})
    : _apiOverride = api;

  final frb_generated.RustLibApi? _apiOverride;

  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async {
    if (cloudMessagesClient
        is! frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw ArgumentError(
        'cloudMessagesClient must be the generated FRB Cloud Messages client',
      );
    }
    if (privateStorageDirectory.isEmpty) {
      throw ArgumentError.value(
        privateStorageDirectory,
        'privateStorageDirectory',
        'must not be empty',
      );
    }

    // Resolving the generated singleton is intentionally delayed until after
    // validation so malformed calls fail closed without loading native state.
    // ignore: invalid_use_of_internal_member
    final api = _apiOverride ?? frb_generated.RustLib.instance.api;
    final metadata = await api.crateApiApiCloudSyncCaptureAuthSnapshot(
      cloudMessagesClient: cloudMessagesClient,
      storageDirectory: privateStorageDirectory,
    );
    return _metadataFromFrb(metadata);
  }

  CloudSyncNativeAuthMetadata _metadataFromFrb(
    frb_api.CloudSyncNativeAuthMetadata metadata,
  ) {
    final nativeDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
    if (!nativeDigest.hasMatch(metadata.nativeSessionId) ||
        !nativeDigest.hasMatch(metadata.accountFingerprint) ||
        !RegExp(
          r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(metadata.protectedStoreIdentity)) {
      throw StateError('cloud_sync_native_auth_metadata_invalid');
    }
    return CloudSyncNativeAuthMetadata(
      nativeSessionId: metadata.nativeSessionId,
      accountFingerprint: metadata.accountFingerprint,
      protectedStoreIdentity: metadata.protectedStoreIdentity,
    );
  }
}

typedef ActiveCloudMessagesClientReader = Object? Function();

/// Dormant production composition for the developer-only manual sampler.
///
/// Constructing this adapter performs no network access and schedules no work.
/// The returned sampler remains compile-time disabled by default and can run
/// only through its explicit `runConfirmed` entry point.
final class CloudSyncProductionSamplerAdapter {
  CloudSyncProductionSamplerAdapter({
    required ActiveCloudMessagesClientReader readActiveClient,
    CloudSyncNativeAuthBinding? nativeAuthBinding,
    required CloudSyncShadowPreflightReader readPreflight,
    required String privateStorageDirectory,
    required String platform,
    required String architecture,
    required String buildCommit,
    RustCloudSyncProtectionBindings? protectionBindings,
    NativeProtectedCloudSyncBindings? transportBindings,
    bool? compileGateOverrideForTest,
  }) {
    final authProvider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: readActiveClient,
      nativeAuthBinding: nativeAuthBinding ?? FrbCloudSyncNativeAuthBinding(),
      privateStorageDirectory: privateStorageDirectory,
    );
    final protector = RustCloudSyncProtector(
      storageDirectory: privateStorageDirectory,
      bindings: protectionBindings,
    );
    final durableStore = ObjectBoxCloudSyncStore.fromDatabase(
      protector: protector,
    );
    sampler = CloudSyncManualShadowSampler(
      readPreflight: readPreflight,
      readAuthSnapshot: authProvider.capture,
      createStore: (scope) async => durableStore,
      createRawTransport: (snapshot, scope) async =>
          NativeProtectedCloudSyncTransport(
            cloudMessagesClient: snapshot.cloudMessagesClient,
            storageDirectory: privateStorageDirectory,
            protectedStoreIdentity: snapshot.protectedStoreIdentity,
            bindings: transportBindings,
          ),
      operationFenceStore: durableStore,
      privateStorageDirectory: privateStorageDirectory,
      platform: platform,
      architecture: architecture,
      buildCommit: buildCommit,
      compileGateOverrideForTest: compileGateOverrideForTest,
    );
  }

  late final CloudSyncManualShadowSampler sampler;
}

/// Captures a client-bound snapshot and rejects replacement races.
final class CloudSyncProductionAuthSnapshotProvider {
  CloudSyncProductionAuthSnapshotProvider({
    required this._readActiveClient,
    required this._nativeAuthBinding,
    required this.privateStorageDirectory,
  });

  final ActiveCloudMessagesClientReader _readActiveClient;
  final CloudSyncNativeAuthBinding _nativeAuthBinding;
  final String privateStorageDirectory;

  Future<CloudSyncNativeAuthSnapshot?> capture() async {
    final client = _readActiveClient();
    if (client == null) return null;
    final metadata = await _nativeAuthBinding.capture(
      cloudMessagesClient: client,
      privateStorageDirectory: privateStorageDirectory,
    );
    // Reject a session replacement that raced the native capture.
    if (!identical(client, _readActiveClient())) return null;
    return CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: metadata.nativeSessionId,
      accountFingerprint: metadata.accountFingerprint,
      protectedStoreIdentity: metadata.protectedStoreIdentity,
      cloudMessagesClient: client,
    );
  }
}
