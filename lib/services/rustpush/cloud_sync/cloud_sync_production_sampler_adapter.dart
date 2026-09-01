// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math';

import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/frb_generated.dart' as frb_generated;
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    as frb;

import 'cloud_inbox_applier.dart';
import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_manual_outbound_canary.dart';
import 'cloud_sync_manual_semantic_pull_sampler.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_store.dart';
import 'native_protected_cloud_sync_transport.dart';
import 'objectbox_canonical_semantic_entity_adapter.dart';
import 'objectbox_cloud_semantic_store_gateway.dart';
import 'cloud_sync_protector.dart';
import 'cloud_sync_semantic_diagnostics.dart';
import 'cloud_sync_outbound_admission.dart';
import 'cloud_sync_writer_authority.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_mutation_guard.dart';
import 'cloudkit_writer_ownership.dart';
import 'objectbox_cloud_sync_store.dart';
import 'cloud_sync_shadow_transport.dart';
import 'rust_cloud_semantic_decoder.dart';
import 'transient_cloud_canonical_identity_registry.dart';

/// Resolves one production semantic dependency against the checkpoint for its
/// exact Manatee zone while preserving every other namespace dimension.
Future<CloudCanonicalActiveScope> cloudSyncProductionDependencyActiveScope({
  required CloudSyncStore store,
  required CloudCanonicalActiveScope current,
  required String zone,
}) async {
  if (zone == current.scope.zone) return current;
  if (zone != 'chatManateeZone' && zone != 'messageManateeZone') {
    throw ArgumentError.value(
      zone,
      'zone',
      'cloud_sync_semantic_dependency_zone_invalid',
    );
  }
  final dependencyScope = CloudSyncScope(
    accountFingerprint: current.scope.accountFingerprint,
    container: current.scope.container,
    database: current.scope.database,
    zone: zone,
    streamKind: current.scope.streamKind,
    schemaVersion: current.scope.schemaVersion,
    persistenceLane: current.scope.persistenceLane,
  );
  final checkpoint = await store.readCheckpoint(dependencyScope);
  return CloudCanonicalActiveScope(
    scope: dependencyScope,
    generation: checkpoint.generation,
  );
}

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
  Future<void> ensureReadAuthentication({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  });

  Future<void> warmReadAuthentication({required Object cloudMessagesClient});

  Future<void> warmReadAuthenticationUnderWriterPause({
    required Object cloudMessagesClient,
    required BigInt pauseToken,
  });

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
  Future<void> ensureReadAuthentication({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async {
    if (cloudMessagesClient
        is! frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw StateError('cloud_sync_native_auth_client_type_invalid');
    }
    if (privateStorageDirectory.isEmpty) {
      throw StateError('cloud_sync_native_auth_store_identity_failed');
    }
    // ignore: invalid_use_of_internal_member
    final api = _apiOverride ?? frb_generated.RustLib.instance.api;
    try {
      await api.crateApiApiCloudSyncEnsureReadAuthentication(
        cloudMessagesClient: cloudMessagesClient,
        storageDirectory: privateStorageDirectory,
      );
    } catch (error) {
      final safeCode = cloudSyncNativeAuthBridgeSafeCode(error);
      Logger.warn('Cloud Sync V2 read authentication failed code=$safeCode');
      throw StateError(safeCode);
    }
  }

  @override
  Future<void> warmReadAuthentication({
    required Object cloudMessagesClient,
  }) async {
    if (cloudMessagesClient
        is! frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw StateError('cloud_sync_native_auth_client_type_invalid');
    }
    // ignore: invalid_use_of_internal_member
    final api = _apiOverride ?? frb_generated.RustLib.instance.api;
    try {
      await api.crateApiApiCloudSyncWarmReadAuthentication(
        cloudMessagesClient: cloudMessagesClient,
      );
    } catch (error) {
      final safeCode = cloudSyncNativeAuthBridgeSafeCode(error);
      Logger.warn('Cloud Sync V2 read authentication failed code=$safeCode');
      throw StateError(safeCode);
    }
  }

  @override
  Future<void> warmReadAuthenticationUnderWriterPause({
    required Object cloudMessagesClient,
    required BigInt pauseToken,
  }) async {
    if (pauseToken <= BigInt.zero || pauseToken.bitLength > 64) {
      throw StateError('cloud_sync_native_auth_writer_pause_scope_failed');
    }
    if (cloudMessagesClient
        is! frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw StateError('cloud_sync_native_auth_client_type_invalid');
    }
    // ignore: invalid_use_of_internal_member
    final api = _apiOverride ?? frb_generated.RustLib.instance.api;
    try {
      await api.crateApiApiCloudSyncWarmReadAuthenticationUnderWriterPause(
        cloudMessagesClient: cloudMessagesClient,
        pauseToken: pauseToken,
      );
    } catch (error) {
      final safeCode = cloudSyncNativeAuthBridgeSafeCode(error);
      Logger.warn('Cloud Sync V2 read authentication failed code=$safeCode');
      throw StateError(safeCode);
    }
  }

  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async {
    if (cloudMessagesClient
        is! frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw StateError('cloud_sync_native_auth_client_type_invalid');
    }
    if (privateStorageDirectory.isEmpty) {
      throw StateError('cloud_sync_native_auth_storage_invalid');
    }

    // Resolving the generated singleton is intentionally delayed until after
    // validation so malformed calls fail closed without loading native state.
    // ignore: invalid_use_of_internal_member
    final api = _apiOverride ?? frb_generated.RustLib.instance.api;
    late final frb_api.CloudSyncNativeAuthMetadata metadata;
    try {
      metadata = await api.crateApiApiCloudSyncCaptureAuthSnapshot(
        cloudMessagesClient: cloudMessagesClient,
        storageDirectory: privateStorageDirectory,
      );
    } catch (error) {
      throw StateError(cloudSyncNativeAuthBridgeSafeCode(error));
    }
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

/// Classifies only fixed native auth tags. Arbitrary exception text is never
/// returned or logged and collapses to one reviewed bridge failure code.
String cloudSyncNativeAuthBridgeSafeCode(Object error) {
  const reviewed = <String>{
    'cloud_sync_native_auth_account_unavailable',
    'cloud_sync_native_auth_account_changed',
    'cloud_sync_native_auth_warm_failed',
    'cloud_sync_native_auth_warm_timeout',
    'cloud_sync_native_auth_writer_pause_scope_failed',
    'cloud_sync_native_auth_messages_container_failed',
    'cloud_sync_native_auth_keychain_container_failed',
    'cloud_sync_native_auth_security_container_failed',
    'cloud_sync_native_auth_pcs_zones_failed',
    'cloud_sync_native_auth_cloudkit_token_failed',
    'cloud_sync_native_auth_credentials_unavailable',
    'cloud_sync_native_auth_credentials_rejected',
    'cloud_sync_native_auth_transport_failed',
    'cloud_sync_native_auth_refresh_session_missing',
    'cloud_sync_native_auth_refresh_credentials_rejected',
    'cloud_sync_native_auth_refresh_transport_failed',
    'cloud_sync_native_auth_refresh_state_failed',
    'cloud_sync_native_auth_refresh_timeout',
    'cloud_sync_native_auth_refresh_failed',
    'cloud_sync_native_auth_refresh_unsupported',
    'cloud_sync_native_auth_refresh_writer_busy',
    'cloud_sync_native_auth_identity_mismatch',
    'cloud_sync_native_auth_account_fingerprint_failed',
    'cloud_sync_native_auth_session_fingerprint_failed',
    'cloud_sync_native_auth_store_identity_failed',
  };
  if (error is frb.AnyhowException && reviewed.contains(error.message)) {
    return error.message;
  }
  return 'cloud_sync_native_auth_bridge_failed';
}

typedef CloudSyncNativeWriterPauseCall = Future<BigInt> Function(BigInt token);
typedef CloudSyncNativeWriterResumeCall = Future<void> Function(BigInt token);
typedef CloudSyncNativeWriterPauseTokenFactory = BigInt Function();

/// Production bridge that pauses every native CloudKit writer workflow for the
/// complete semantic pull.
///
/// The native gate owns the actual exclusion permit. Dart carries only its
/// opaque, positive token and exposes only reviewed failure codes.
final class FrbCloudSyncNativeWriterPause
    implements CloudSyncNativeWriterPause {
  FrbCloudSyncNativeWriterPause({
    CloudSyncNativeWriterPauseCall? pauseCall,
    CloudSyncNativeWriterResumeCall? resumeCall,
    CloudSyncNativeWriterPauseTokenFactory? tokenFactory,
    Duration bridgeCallTimeout = const Duration(seconds: 35),
    Duration retryDelay = const Duration(milliseconds: 100),
  }) : _pauseCall = pauseCall,
       _resumeCall = resumeCall,
       _tokenFactory = tokenFactory ?? _createPauseToken,
       _bridgeCallTimeout = bridgeCallTimeout,
       _retryDelay = retryDelay {
    if (bridgeCallTimeout <= Duration.zero || retryDelay < Duration.zero) {
      throw ArgumentError('cloud_sync_native_writer_pause_timing_invalid');
    }
  }

  final CloudSyncNativeWriterPauseCall? _pauseCall;
  final CloudSyncNativeWriterResumeCall? _resumeCall;
  final CloudSyncNativeWriterPauseTokenFactory _tokenFactory;
  final Duration _bridgeCallTimeout;
  final Duration _retryDelay;
  static const _maximumBridgeAttempts = 3;
  static final Random _secureRandom = Random.secure();

  static BigInt _createPauseToken() {
    do {
      final high = BigInt.from(_secureRandom.nextInt(1 << 30));
      final low = BigInt.from(_secureRandom.nextInt(1 << 30));
      final token = (high << 30) | low;
      if (token > BigInt.zero) return token;
    } while (true);
  }

  @override
  Future<Object> pause() async {
    late final BigInt token;
    try {
      token = _tokenFactory();
    } catch (_) {
      throw StateError('cloud_sync_native_writer_pause_token_invalid');
    }
    if (token <= BigInt.zero || token.bitLength > 64) {
      throw StateError('cloud_sync_native_writer_pause_token_invalid');
    }

    final pauseCall =
        _pauseCall ??
        (token) => frb_api.cloudSyncPausePasswordCloudkitWriters(token: token);
    var finalSafeCode = 'cloud_sync_native_writer_pause_bridge_failed';
    var ambiguousAttempt = false;
    for (var attempt = 1; attempt <= _maximumBridgeAttempts; attempt++) {
      try {
        final returnedToken = await pauseCall(
          token,
        ).timeout(_bridgeCallTimeout);
        if (returnedToken != token) {
          ambiguousAttempt = true;
          finalSafeCode = 'cloud_sync_native_writer_pause_token_invalid';
          break;
        }
        return token;
      } catch (error) {
        finalSafeCode = cloudSyncNativeWriterPauseBridgeSafeCode(error);
        if (error is TimeoutException ||
            (finalSafeCode != 'cloud_sync_native_writer_pause_already_active' &&
                finalSafeCode !=
                    'cloud_sync_native_writer_pause_token_invalid')) {
          ambiguousAttempt = true;
        }
        if (finalSafeCode == 'cloud_sync_native_writer_pause_token_invalid') {
          break;
        }
        if (attempt < _maximumBridgeAttempts && _retryDelay > Duration.zero) {
          await Future<void>.delayed(_retryDelay);
        }
      }
    }

    if (ambiguousAttempt) {
      try {
        await _resumeToken(token, allowInvalidTokenAsAbsent: true);
      } catch (_) {
        throw const CloudSyncNativeWriterPauseUncertain();
      }
    }
    throw StateError(finalSafeCode);
  }

  @override
  Future<void> resume(Object token) async {
    if (token is! BigInt || token <= BigInt.zero) {
      throw StateError('cloud_sync_native_writer_resume_token_invalid');
    }
    await _resumeToken(token);
  }

  Future<void> _resumeToken(
    BigInt token, {
    bool allowInvalidTokenAsAbsent = false,
  }) async {
    final resumeCall =
        _resumeCall ??
        (token) => frb_api.cloudSyncResumePasswordCloudkitWriters(token: token);
    var finalSafeCode = 'cloud_sync_native_writer_pause_bridge_failed';
    for (var attempt = 1; attempt <= _maximumBridgeAttempts; attempt++) {
      try {
        await resumeCall(token).timeout(_bridgeCallTimeout);
        return;
      } catch (error) {
        finalSafeCode = cloudSyncNativeWriterPauseBridgeSafeCode(error);
        if (finalSafeCode == 'cloud_sync_native_writer_resume_token_invalid') {
          if (allowInvalidTokenAsAbsent) return;
          break;
        }
        if (attempt < _maximumBridgeAttempts && _retryDelay > Duration.zero) {
          await Future<void>.delayed(_retryDelay);
        }
      }
    }
    throw StateError(finalSafeCode);
  }
}

/// Classifies only fixed native writer-gate tags. Arbitrary exception text is
/// never returned or logged.
String cloudSyncNativeWriterPauseBridgeSafeCode(Object error) {
  const reviewed = <String>{
    'cloud_sync_native_writer_pause_already_active',
    'cloud_sync_native_writer_pause_failed',
    'cloud_sync_native_writer_pause_timeout',
    'cloud_sync_native_writer_pause_token_invalid',
    'cloud_sync_native_writer_resume_failed',
    'cloud_sync_native_writer_resume_token_invalid',
  };
  final candidate = switch (error) {
    frb.AnyhowException() => error.message,
    StateError() => error.message.toString(),
    _ => null,
  };
  return reviewed.contains(candidate)
      ? candidate!
      : 'cloud_sync_native_writer_pause_bridge_failed';
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
    CloudSyncObserverFactory? observerFactory,
    RustCloudSyncProtectionBindings? protectionBindings,
    NativeProtectedCloudSyncBindings? transportBindings,
    bool? compileGateOverrideForTest,
  }) {
    final authBinding = nativeAuthBinding ?? FrbCloudSyncNativeAuthBinding();
    final authProvider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: readActiveClient,
      nativeAuthBinding: authBinding,
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
      prepareAuthSnapshot: authProvider.prepareReadAuthenticationUnderInterlock,
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
      observerFactory: observerFactory,
      compileGateOverrideForTest: compileGateOverrideForTest,
    );
  }

  late final CloudSyncManualShadowSampler sampler;
}

/// Production composition for the separately compile-gated manual semantic
/// pull canary. CloudKit transport remains read-only while supported chat,
/// message, reaction, and attachment metadata records are projected locally.
final class CloudSyncProductionSemanticPullAdapter {
  CloudSyncProductionSemanticPullAdapter({
    required ActiveCloudMessagesClientReader readActiveClient,
    CloudSyncNativeAuthBinding? nativeAuthBinding,
    required CloudSyncShadowPreflightReader readPreflight,
    required String privateStorageDirectory,
    required String platform,
    required String architecture,
    required String buildCommit,
    CloudSyncObserverFactory? observerFactory,
    RustCloudSyncProtectionBindings? protectionBindings,
    NativeProtectedCloudSyncBindings? transportBindings,
    RustCloudSemanticDecodeBindings? semanticDecodeBindings,
    CloudSyncNativeWriterPause? nativeWriterPause,
    bool? compileGateOverrideForTest,
  }) {
    final diagnosticCollectors =
        <String, CloudSyncSemanticDiagnosticCollector>{};
    final authBinding = nativeAuthBinding ?? FrbCloudSyncNativeAuthBinding();
    final authProvider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: readActiveClient,
      nativeAuthBinding: authBinding,
      privateStorageDirectory: privateStorageDirectory,
    );
    final protector = RustCloudSyncProtector(
      storageDirectory: privateStorageDirectory,
      bindings: protectionBindings,
    );
    final durableStore = ObjectBoxCloudSyncStore.fromDatabase(
      protector: protector,
    );
    sampler = CloudSyncManualSemanticPullSampler(
      readPreflight: readPreflight,
      ensureAuthSnapshot: authProvider.ensureReadAuthenticationUnderInterlock,
      prepareAuthSnapshot:
          authProvider.prepareReadAuthenticationUnderNativeWriterPause,
      readAuthSnapshot: authProvider.capture,
      createStore: (scope) async => durableStore,
      createRawTransport: (snapshot, scope, pauseToken) async {
        if (pauseToken is! BigInt ||
            pauseToken <= BigInt.zero ||
            pauseToken.bitLength > 64) {
          throw StateError('cloud_sync_native_auth_writer_pause_scope_failed');
        }
        return NativeProtectedCloudSyncTransport(
          cloudMessagesClient: snapshot.cloudMessagesClient,
          storageDirectory: privateStorageDirectory,
          protectedStoreIdentity: snapshot.protectedStoreIdentity,
          nativeWriterPauseToken: pauseToken,
          bindings: transportBindings,
        );
      },
      createInboxApplier: (snapshot, scope, generation, pauseToken) async {
        if (pauseToken is! BigInt ||
            pauseToken <= BigInt.zero ||
            pauseToken.bitLength > 64) {
          throw StateError('cloud_sync_native_auth_writer_pause_scope_failed');
        }
        final diagnostics = CloudSyncSemanticDiagnosticCollector();
        diagnosticCollectors[scope.zone] = diagnostics;
        final identityRegistry = TransientCloudCanonicalIdentityRegistry();
        final activeScope = CloudCanonicalActiveScope(
          scope: scope,
          generation: generation,
        );
        final canonicalAdapter = ObjectBoxCanonicalSemanticEntityAdapter(
          store: Database.store,
          activeScopeProvider: () =>
              identical(snapshot.cloudMessagesClient, readActiveClient())
              ? activeScope
              : null,
          identityResolver: identityRegistry,
          chatDependencyScope: await cloudSyncProductionDependencyActiveScope(
            store: durableStore,
            current: activeScope,
            zone: 'chatManateeZone',
          ),
          messageDependencyScope:
              await cloudSyncProductionDependencyActiveScope(
                store: durableStore,
                current: activeScope,
                zone: 'messageManateeZone',
              ),
          diagnosticRecorder: diagnostics.record,
          semanticApplyEnabled: true,
          allowExistingChatPresentationUpdates: false,
          allowChatUpserts: true,
          allowExistingChatDisplayNameClears: false,
          allowMessageUpserts: true,
          allowReactionUpserts: true,
          allowAttachmentMetadataUpserts: true,
        );
        final gateway = ObjectBoxCloudSemanticStoreGateway.fromDatabase(
          canonicalAdapter: canonicalAdapter,
        );
        return TransactionalCloudInboxApplier(
          decoder: RustCloudSemanticDecoder(
            readAuthSnapshot: authProvider.capture,
            storageDirectory: privateStorageDirectory,
            nativeWriterPauseToken: pauseToken,
            bindings: semanticDecodeBindings,
            diagnosticRecorder: diagnostics.record,
          ),
          store: gateway,
          identityRegistrar: identityRegistry,
          activeScopeRevalidator: () async {
            final current = await authProvider.capture();
            return snapshot.sameIdentity(current) &&
                identical(snapshot.cloudMessagesClient, readActiveClient());
          },
          allowTombstones: false,
          diagnosticRecorder: diagnostics.record,
        );
      },
      nativeWriterPause: nativeWriterPause ?? FrbCloudSyncNativeWriterPause(),
      readDiagnosticCounts: (scope) =>
          diagnosticCollectors[scope.zone]?.snapshot() ?? const <String, int>{},
      operationFenceStore: durableStore,
      privateStorageDirectory: privateStorageDirectory,
      platform: platform,
      architecture: architecture,
      buildCommit: buildCommit,
      observerFactory: observerFactory,
      compileGateOverrideForTest: compileGateOverrideForTest,
    );
  }

  late final CloudSyncManualSemanticPullSampler sampler;
}

/// Production composition for the separately gated one-text outbound canary.
///
/// Constructing this adapter performs no network access and admits no work.
/// The durable writer authority must already be stable and owned by V2 before
/// [CloudSyncManualOutboundCanary.runDoubleConfirmed] can flush an operation.
final class CloudSyncProductionOutboundCanaryAdapter {
  CloudSyncProductionOutboundCanaryAdapter({
    required ActiveCloudMessagesClientReader readActiveClient,
    CloudSyncNativeAuthBinding? nativeAuthBinding,
    required CloudSyncShadowPreflightReader readPreflight,
    required String privateStorageDirectory,
    RustCloudSyncProtectionBindings? protectionBindings,
    NativeProtectedCloudSyncBindings? transportBindings,
    required CloudKitWriterLegacyQueueQuarantine quarantineLegacyDeletionQueues,
    required CloudKitWriterProvisioningMeasurementsReader
    readWriterMeasurements,
    bool? compileGateOverrideForTest,
    bool? v2WriterOverrideForTest,
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
    final authority = ObjectBoxCloudKitWriterAuthority(store: Database.store);
    final interlock = CloudKitOperationInterlock(
      privateStorageDirectory: privateStorageDirectory,
      fenceStore: durableStore,
    );
    writerProvisioner = CloudKitV2WriterProvisioner(
      authority: authority,
      interlock: interlock,
      readAuthSnapshot: authProvider.capture,
      quarantineLegacyDeletionQueues: quarantineLegacyDeletionQueues,
      readMeasurements: readWriterMeasurements,
    );
    _captureAuth = authProvider.capture;
    canary = CloudSyncManualOutboundCanary(
      readPreflight: readPreflight,
      readAuthSnapshot: authProvider.capture,
      writerExclusion: interlock,
      createSession: (snapshot, scope) async {
        final writerScope = CloudKitWriterScope(
          accountFingerprint: scope.accountFingerprint,
          container: scope.container,
          database: scope.database,
        );
        final mutationGuard = CloudKitWriterMutationGuard(
          store: Database.store,
          readActiveClient: readActiveClient,
          privateStorageDirectory: privateStorageDirectory,
        );
        mutationGuard.requireClear();
        final permit = authority.issuePermit(
          writerScope,
          expectedOwner: CloudKitWriterOwner.v2,
        );
        authority.verifyPermit(permit);
        final transport = NativeProtectedCloudSyncTransport(
          cloudMessagesClient: snapshot.cloudMessagesClient,
          storageDirectory: privateStorageDirectory,
          protectedStoreIdentity: snapshot.protectedStoreIdentity,
          bindings: transportBindings,
          writerMutationGuard: mutationGuard,
        );
        final lifecycle = CloudProtectedPageLeaseLifecycle(
          store: durableStore,
          transport: transport,
        );
        final admission = CloudSyncOutboundAdmissionCoordinator(
          store: durableStore,
          transport: transport,
          ensureProtectedStoreRecovered: lifecycle.ensureRecoveredBeforeWrite,
        );
        final engine = CloudSyncEngine(
          scope: scope,
          coordinatorId:
              'manual-outbound-${snapshot.nativeSessionId}-${scope.zone}',
          store: durableStore,
          transport: transport,
          inboxApplier: const RejectingShadowInboxApplier(),
          writerAuthority: ObjectBoxCloudSyncWriterAuthority(
            store: Database.store,
          ),
          writerExclusion: interlock,
          config: CloudSyncEngineConfig(
            maximumBatchSize: 1,
            maximumFetchPagesPerRun: 1,
            maximumInboxEntriesPerRun: 1,
            maximumOutboxBatchesPerRun: 1,
            flags: const CloudSyncFeatureFlags(
              readOnlyFetch: false,
              semanticApply: false,
              saves: true,
              deletions: false,
              profiles: false,
              notificationHints: false,
            ),
          ),
        );
        return _ProductionOutboundCanarySession(
          scope: scope,
          admission: admission,
          engine: engine,
          transport: transport,
          store: durableStore,
        );
      },
      compileGateOverrideForTest: compileGateOverrideForTest,
      v2WriterOverrideForTest: v2WriterOverrideForTest,
    );
  }

  late final CloudSyncManualOutboundCanary canary;
  late final CloudKitV2WriterProvisioner writerProvisioner;
  late final CloudSyncNativeAuthSnapshotReader _captureAuth;

  Future<CloudKitV2WriterProvisioningResult> ensureWriterOwned() async {
    final auth = await _captureAuth();
    if (auth == null) {
      throw StateError('native_auth_unavailable');
    }
    return writerProvisioner.ensureV2Owned(expectedAuth: auth);
  }
}

final class _ProductionOutboundCanarySession
    implements CloudSyncOutboundCanarySession {
  const _ProductionOutboundCanarySession({
    required this.scope,
    required CloudSyncOutboundAdmissionCoordinator admission,
    required CloudSyncEngine engine,
    required NativeProtectedCloudSyncTransport transport,
    required ObjectBoxCloudSyncStore store,
  }) : _admission = admission,
       _engine = engine,
       _transport = transport,
       _store = store;

  final CloudSyncScope scope;
  final CloudSyncOutboundAdmissionCoordinator _admission;
  final CloudSyncEngine _engine;
  final NativeProtectedCloudSyncTransport _transport;
  final ObjectBoxCloudSyncStore _store;

  @override
  Future<CloudOutboxOperation> admitMessage({
    required frb_api.CloudMessage message,
    required DateTime createdAt,
  }) => _admission.admitMessage(scope, message: message, createdAt: createdAt);

  @override
  Future<CloudSyncRunResult> flushOneBatch() =>
      _engine.synchronize(trigger: CloudSyncTrigger.localOutbox);

  @override
  Future<List<CloudOutboxOperation>> readOutbox() =>
      _store.readOutboxEntries(scope);

  @override
  Future<void> quiesce() => _transport.quiesceNativeOperations();
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

  /// Performs the single bounded CloudKit read-auth warmup for a manual run.
  /// The caller must already hold the CloudKit operation interlock.
  Future<CloudSyncNativeAuthSnapshot?>
  prepareReadAuthenticationUnderInterlock() async {
    CloudKitOperationInterlock.requireActive(
      CloudKitOperationKind.v2ShadowRead,
    );
    final before = await capture();
    if (before == null) return null;
    await _nativeAuthBinding.warmReadAuthentication(
      cloudMessagesClient: before.cloudMessagesClient,
    );
    if (!identical(before.cloudMessagesClient, _readActiveClient())) {
      return null;
    }
    final after = await capture();
    return before.sameIdentity(after) ? after : null;
  }

  /// Replenishes only a missing or invalidated semantic-read credential before
  /// native CloudKit writers are paused. A warm credential returns without
  /// network I/O; a cold one performs one bounded authentication refresh.
  Future<CloudSyncNativeAuthSnapshot?>
  ensureReadAuthenticationUnderInterlock() async {
    CloudKitOperationInterlock.requireActive(
      CloudKitOperationKind.v2SemanticRead,
    );
    final client = _readActiveClient();
    if (client == null) return null;
    await _nativeAuthBinding.ensureReadAuthentication(
      cloudMessagesClient: client,
      privateStorageDirectory: privateStorageDirectory,
    );
    if (!identical(client, _readActiveClient())) {
      return null;
    }
    final before = await capture();
    if (before == null) return null;
    final after = await capture();
    return before.sameIdentity(after) ? after : null;
  }

  Future<CloudSyncNativeAuthSnapshot?>
  prepareReadAuthenticationUnderNativeWriterPause(
    Object pauseToken, [
    CloudSyncNativeAuthSnapshot? expectedAuth,
  ]) async {
    CloudKitOperationInterlock.requireActive(
      CloudKitOperationKind.v2SemanticRead,
    );
    if (pauseToken is! BigInt ||
        pauseToken <= BigInt.zero ||
        pauseToken.bitLength > 64) {
      throw StateError('cloud_sync_native_auth_writer_pause_scope_failed');
    }
    final before = await capture();
    if (before == null ||
        (expectedAuth != null && !expectedAuth.sameIdentity(before))) {
      return null;
    }
    await _nativeAuthBinding.warmReadAuthenticationUnderWriterPause(
      cloudMessagesClient: before.cloudMessagesClient,
      pauseToken: pauseToken,
    );
    if (!identical(before.cloudMessagesClient, _readActiveClient())) {
      return null;
    }
    final after = await capture();
    return before.sameIdentity(after) ? after : null;
  }

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
