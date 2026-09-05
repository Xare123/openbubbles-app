// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math';

import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/frb_generated.dart' as frb_generated;
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
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
    CloudSyncVerboseDiagnosticsEnabled? verboseDiagnosticsEnabled,
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
            verboseDiagnosticsEnabled: verboseDiagnosticsEnabled,
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
      readOutboxForConfirmation: durableStore.readOutboxEntries,
      writerExclusion: interlock,
      createSession: (snapshot, scope, kind, expectedOperation) async {
        final writerScope = CloudKitWriterScope(
          accountFingerprint: scope.accountFingerprint,
          container: scope.container,
          database: scope.database,
        );
        final resolvedTransportBindings =
            transportBindings ?? FrbNativeProtectedCloudSyncBindings();
        if (resolvedTransportBindings is! CloudKitWriterReconciliationBinding) {
          throw StateError('cloud_sync_writer_reconciliation_binding_required');
        }
        final reconciliationBinding =
            resolvedTransportBindings as CloudKitWriterReconciliationBinding;
        final mutationGuard = CloudKitWriterMutationGuard(
          store: Database.store,
          readActiveClient: readActiveClient,
          privateStorageDirectory: privateStorageDirectory,
          reconciliationBinding: reconciliationBinding,
        );
        final durableOperations = await durableStore.readOutboxEntries(scope);
        final expectedStatus = switch (kind) {
          CloudSyncOutboundCanarySessionKind.freshWrite => null,
          CloudSyncOutboundCanarySessionKind.pendingRecovery =>
            CloudOutboxStatus.pending,
          CloudSyncOutboundCanarySessionKind.unknownRecovery =>
            CloudOutboxStatus.unknownOutcome,
          CloudSyncOutboundCanarySessionKind.confirmedReplay =>
            CloudOutboxStatus.confirmed,
        };
        if ((expectedStatus == null && durableOperations.isNotEmpty) ||
            (expectedStatus != null &&
                (durableOperations.length != 1 ||
                    durableOperations.single.status != expectedStatus ||
                    expectedOperation == null ||
                    !durableOperations.single.sameDurableSnapshotAs(
                      expectedOperation,
                    ))) ||
            (expectedStatus == null && expectedOperation != null)) {
          throw StateError('cloud_sync_outbound_session_mode_mismatch');
        }
        final recoveryOperation = expectedStatus == null
            ? null
            : durableOperations.single;
        if (kind == CloudSyncOutboundCanarySessionKind.unknownRecovery) {
          await mutationGuard.requireReconciliationAllowed(
            owner: CloudKitWriterOwner.v2,
            expectedClient: snapshot.cloudMessagesClient,
            operation: recoveryOperation!,
          );
        } else {
          mutationGuard.requireClear();
        }
        if (kind == CloudSyncOutboundCanarySessionKind.unknownRecovery) {
          return _ProductionUnknownOutcomeCanarySession(
            scope: scope,
            expectedOperation: recoveryOperation!,
            readOutbox: () => durableStore.readOutboxEntries(scope),
            leaseUnknown:
                ({
                  required DateTime now,
                  required String leaseId,
                  required Duration leaseDuration,
                }) => durableStore.leaseUnknownOutcomes(
                  scope,
                  now: now,
                  limit: 1,
                  leaseId: leaseId,
                  leaseDuration: leaseDuration,
                ),
            applyTransition:
                ({
                  required String leaseId,
                  required CloudOutboxTransition transition,
                  required DateTime now,
                }) => durableStore.applyOutboxTransitions(
                  scope,
                  leaseId: leaseId,
                  transitions: [transition],
                  now: now,
                ),
            commitCreateReceipt:
                ({
                  required String leaseId,
                  required CloudOutboxCreateReceipt receipt,
                  required DateTime now,
                }) => durableStore.commitOutboxCreateReceipt(
                  scope,
                  leaseId: leaseId,
                  receipt: receipt,
                  retainProtectedLeaseReference: true,
                  now: now,
                ),
            reconcile: (operation) => mutationGuard.reconcileUnknownOutcome(
              owner: CloudKitWriterOwner.v2,
              expectedClient: snapshot.cloudMessagesClient,
              operation: operation,
            ),
            quiesce: () async {},
          );
        }

        final transport = NativeProtectedCloudSyncTransport(
          cloudMessagesClient: snapshot.cloudMessagesClient,
          storageDirectory: privateStorageDirectory,
          protectedStoreIdentity: snapshot.protectedStoreIdentity,
          bindings: resolvedTransportBindings,
          writerMutationGuard: mutationGuard,
          readCheckpointGeneration: (scope) async =>
              (await durableStore.readCheckpoint(scope)).generation,
          retainConfirmedReceiptsForReplay: true,
        );

        if (kind == CloudSyncOutboundCanarySessionKind.confirmedReplay) {
          return _ProductionConfirmedReplayCanarySession(
            scope: scope,
            readOutbox: () => durableStore.readOutboxEntries(scope),
            verify: (operation) => transport.verifyConfirmedMessageCreateNoSave(
              scope,
              operation: operation,
            ),
            finalize: (operation, proof) =>
                transport.releaseConfirmedReplayReceipt(
                  scope,
                  operation: operation,
                  proof: proof,
                  clearDurableAdoptionMarker: () => durableStore
                      .clearConfirmedProtectedOutboundLeaseReference(
                        expectedOperation: operation,
                      ),
                ),
            quiesce: transport.quiesceNativeOperations,
          );
        }

        final permit = authority.issuePermit(
          writerScope,
          expectedOwner: CloudKitWriterOwner.v2,
        );
        authority.verifyPermit(permit);
        final engineWriterAuthority = ObjectBoxCloudSyncWriterAuthority(
          store: Database.store,
        );
        final lifecycle = CloudProtectedPageLeaseLifecycle(
          store: durableStore,
          transport: transport,
        );
        final engine = CloudSyncEngine(
          scope: scope,
          coordinatorId:
              'manual-outbound-${snapshot.nativeSessionId}-${scope.zone}',
          store: durableStore,
          transport: transport,
          inboxApplier: const RejectingShadowInboxApplier(),
          writerAuthority: engineWriterAuthority,
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
        if (kind == CloudSyncOutboundCanarySessionKind.pendingRecovery) {
          return _ProductionPendingRecoveryCanarySession(
            readOutbox: () => durableStore.readOutboxEntries(scope),
            flush: () =>
                engine.synchronize(trigger: CloudSyncTrigger.localOutbox),
            quiesce: transport.quiesceNativeOperations,
          );
        }
        final admission = CloudSyncOutboundAdmissionCoordinator(
          store: durableStore,
          transport: transport,
          ensureProtectedStoreRecovered: lifecycle.ensureRecoveredBeforeWrite,
        );
        return _ProductionFreshWriteCanarySession(
          admit: ({required message, required createdAt}) => admission
              .admitMessage(scope, message: message, createdAt: createdAt),
          readOutbox: () => durableStore.readOutboxEntries(scope),
          flush: () =>
              engine.synchronize(trigger: CloudSyncTrigger.localOutbox),
          quiesce: transport.quiesceNativeOperations,
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

  @visibleForTesting
  static CloudSyncOutboundCanaryUnknownRecoverySession
  createUnknownOutcomeSessionForTest({
    required CloudSyncScope scope,
    required CloudOutboxOperation expectedOperation,
    required Future<List<CloudOutboxOperation>> Function() readOutbox,
    required Future<List<CloudOutboxOperation>> Function({
      required DateTime now,
      required String leaseId,
      required Duration leaseDuration,
    })
    leaseUnknown,
    required Future<void> Function({
      required String leaseId,
      required CloudOutboxTransition transition,
      required DateTime now,
    })
    applyTransition,
    required Future<void> Function({
      required String leaseId,
      required CloudOutboxCreateReceipt receipt,
      required DateTime now,
    })
    commitCreateReceipt,
    required Future<CloudUnknownOutcomeResolution> Function(
      CloudOutboxOperation operation,
    )
    reconcile,
    required Future<void> Function() quiesce,
  }) => _ProductionUnknownOutcomeCanarySession(
    scope: scope,
    expectedOperation: expectedOperation,
    readOutbox: readOutbox,
    leaseUnknown: leaseUnknown,
    applyTransition: applyTransition,
    commitCreateReceipt: commitCreateReceipt,
    reconcile: reconcile,
    quiesce: quiesce,
  );
}

typedef _CanaryOutboxRead = Future<List<CloudOutboxOperation>> Function();
typedef _CanaryFlush = Future<CloudSyncRunResult> Function();
typedef _CanaryQuiesce = Future<void> Function();
typedef _CanaryAdmit =
    Future<CloudOutboxOperation> Function({
      required frb_api.CloudMessage message,
      required DateTime createdAt,
    });
typedef _CanaryLeaseUnknown =
    Future<List<CloudOutboxOperation>> Function({
      required DateTime now,
      required String leaseId,
      required Duration leaseDuration,
    });
typedef _CanaryApplyUnknownTransition =
    Future<void> Function({
      required String leaseId,
      required CloudOutboxTransition transition,
      required DateTime now,
    });
typedef _CanaryCommitCreateReceipt =
    Future<void> Function({
      required String leaseId,
      required CloudOutboxCreateReceipt receipt,
      required DateTime now,
    });
typedef _CanaryReconcileUnknown =
    Future<CloudUnknownOutcomeResolution> Function(
      CloudOutboxOperation operation,
    );
typedef _CanaryVerifyReplay =
    Future<CloudSyncConfirmedReplayProof> Function(
      CloudOutboxOperation operation,
    );
typedef _CanaryFinalizeReplay =
    Future<void> Function(
      CloudOutboxOperation operation,
      CloudSyncConfirmedReplayProof proof,
    );

final class _ProductionFreshWriteCanarySession
    implements CloudSyncOutboundCanaryWriteSession {
  const _ProductionFreshWriteCanarySession({
    required _CanaryAdmit admit,
    required _CanaryOutboxRead readOutbox,
    required _CanaryFlush flush,
    required _CanaryQuiesce quiesce,
  }) : _admit = admit,
       _readOutbox = readOutbox,
       _flush = flush,
       _quiesce = quiesce;

  final _CanaryAdmit _admit;
  final _CanaryOutboxRead _readOutbox;
  final _CanaryFlush _flush;
  final _CanaryQuiesce _quiesce;

  @override
  Future<CloudOutboxOperation> admitMessage({
    required frb_api.CloudMessage message,
    required DateTime createdAt,
  }) => _admit(message: message, createdAt: createdAt);

  @override
  Future<CloudSyncRunResult> flushOneBatch() => _flush();

  @override
  Future<List<CloudOutboxOperation>> readOutbox() => _readOutbox();

  @override
  Future<void> quiesce() => _quiesce();
}

final class _ProductionPendingRecoveryCanarySession
    implements CloudSyncOutboundCanaryFlushSession {
  const _ProductionPendingRecoveryCanarySession({
    required _CanaryOutboxRead readOutbox,
    required _CanaryFlush flush,
    required _CanaryQuiesce quiesce,
  }) : _readOutbox = readOutbox,
       _flush = flush,
       _quiesce = quiesce;

  final _CanaryOutboxRead _readOutbox;
  final _CanaryFlush _flush;
  final _CanaryQuiesce _quiesce;

  @override
  Future<CloudSyncRunResult> flushOneBatch() => _flush();

  @override
  Future<List<CloudOutboxOperation>> readOutbox() => _readOutbox();

  @override
  Future<void> quiesce() => _quiesce();
}

final class _ProductionUnknownOutcomeCanarySession
    implements CloudSyncOutboundCanaryUnknownRecoverySession {
  const _ProductionUnknownOutcomeCanarySession({
    required this.scope,
    required this.expectedOperation,
    required _CanaryOutboxRead readOutbox,
    required _CanaryLeaseUnknown leaseUnknown,
    required _CanaryApplyUnknownTransition applyTransition,
    required _CanaryCommitCreateReceipt commitCreateReceipt,
    required _CanaryReconcileUnknown reconcile,
    required _CanaryQuiesce quiesce,
  }) : _readOutbox = readOutbox,
       _leaseUnknown = leaseUnknown,
       _applyTransition = applyTransition,
       _commitCreateReceipt = commitCreateReceipt,
       _reconcile = reconcile,
       _quiesce = quiesce;

  static const _leaseDuration = Duration(minutes: 2);
  static const _defaultRetryDelay = Duration(seconds: 30);

  final CloudSyncScope scope;
  final CloudOutboxOperation expectedOperation;
  final _CanaryOutboxRead _readOutbox;
  final _CanaryLeaseUnknown _leaseUnknown;
  final _CanaryApplyUnknownTransition _applyTransition;
  final _CanaryCommitCreateReceipt _commitCreateReceipt;
  final _CanaryReconcileUnknown _reconcile;
  final _CanaryQuiesce _quiesce;

  @override
  Future<CloudSyncRunResult> reconcileUnknownOutcome({
    required CloudOutboxOperation operation,
  }) async {
    if (operation.status != CloudOutboxStatus.unknownOutcome ||
        operation.scope != scope ||
        !operation.sameDurableSnapshotAs(expectedOperation)) {
      throw StateError('cloud_sync_unknown_recovery_operation_changed');
    }
    final startedAt = DateTime.now().toUtc();
    final leaseId =
        'manual-unknown-recovery:${operation.operationId}:'
        '${startedAt.microsecondsSinceEpoch}';
    final leased = await _leaseUnknown(
      now: startedAt,
      leaseId: leaseId,
      leaseDuration: _leaseDuration,
    );
    if (leased.isEmpty) {
      return CloudSyncRunResult(
        status: CloudSyncRunStatus.completed,
        counters: const CloudSyncRunCounters(),
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
      );
    }
    if (leased.length != 1 ||
        !_sameSnapshotIgnoringLease(leased.single, operation)) {
      if (leased.length == 1) {
        await _applyTransition(
          leaseId: leaseId,
          transition: CloudOutboxTransition.unknownOutcome(
            leased.single.operationId,
            nextEligibleAt: startedAt.add(_defaultRetryDelay),
          ),
          now: startedAt,
        );
      }
      throw StateError('cloud_sync_unknown_recovery_lease_mismatch');
    }

    final leasedOperation = leased.single;
    CloudUnknownOutcomeResolution? resolution;
    try {
      resolution = await _reconcile(leasedOperation);
    } catch (_) {
      // Any readback failure is still ambiguous. Keep the exact Apple UUIDs,
      // protected receipt, and durable mutation fence for another readback.
    }
    final now = DateTime.now().toUtc();
    CloudOutboxTransition? transition;
    CloudOutboxCreateReceipt? committedReceipt;
    final CloudSyncRunCounters counters;
    switch (resolution?.disposition) {
      case CloudUnknownOutcomeDisposition.committed:
        committedReceipt = resolution?.createReceipt;
        if (committedReceipt == null) {
          transition = CloudOutboxTransition.unknownOutcome(
            operation.operationId,
            nextEligibleAt: now.add(_defaultRetryDelay),
          );
        }
        counters = const CloudSyncRunCounters(confirmed: 1);
        break;
      case CloudUnknownOutcomeDisposition.notApplied:
        transition = CloudOutboxTransition.provenNotApplied(
          operation.operationId,
          category: CloudFailureCategory.server,
          nextEligibleAt: now,
        );
        counters = const CloudSyncRunCounters(retried: 1);
        break;
      case CloudUnknownOutcomeDisposition.serverRecordChanged:
      case CloudUnknownOutcomeDisposition.quarantined:
      case CloudUnknownOutcomeDisposition.unresolved:
      case null:
        final retryAfter = resolution?.retryAfter ?? _defaultRetryDelay;
        transition = CloudOutboxTransition.unknownOutcome(
          operation.operationId,
          nextEligibleAt: now.add(retryAfter),
        );
        counters = const CloudSyncRunCounters();
        break;
    }
    if (committedReceipt != null) {
      try {
        await _commitCreateReceipt(
          leaseId: leaseId,
          receipt: committedReceipt,
          now: now,
        );
      } catch (error, stackTrace) {
        await _applyTransition(
          leaseId: leaseId,
          transition: CloudOutboxTransition.unknownOutcome(
            operation.operationId,
            nextEligibleAt: now.add(_defaultRetryDelay),
          ),
          now: now,
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
    } else {
      await _applyTransition(
        leaseId: leaseId,
        transition: transition!,
        now: now,
      );
      if (resolution?.disposition == CloudUnknownOutcomeDisposition.committed) {
        throw StateError('cloud_sync_unknown_recovery_receipt_missing');
      }
    }
    return CloudSyncRunResult(
      status: CloudSyncRunStatus.completed,
      counters: counters,
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
    );
  }

  bool _sameSnapshotIgnoringLease(
    CloudOutboxOperation leased,
    CloudOutboxOperation expected,
  ) => leased
      .copyWith(clearLeaseId: true, clearLeaseExpiresAt: true)
      .sameDurableSnapshotAs(expected);

  @override
  Future<List<CloudOutboxOperation>> readOutbox() => _readOutbox();

  @override
  Future<void> quiesce() => _quiesce();
}

final class _ProductionConfirmedReplayCanarySession
    implements CloudSyncOutboundCanaryReplaySession {
  const _ProductionConfirmedReplayCanarySession({
    required this.scope,
    required _CanaryOutboxRead readOutbox,
    required _CanaryVerifyReplay verify,
    required _CanaryFinalizeReplay finalize,
    required _CanaryQuiesce quiesce,
  }) : _readOutbox = readOutbox,
       _verify = verify,
       _finalize = finalize,
       _quiesce = quiesce;

  final CloudSyncScope scope;
  final _CanaryOutboxRead _readOutbox;
  final _CanaryVerifyReplay _verify;
  final _CanaryFinalizeReplay _finalize;
  final _CanaryQuiesce _quiesce;

  @override
  Future<CloudSyncConfirmedReplayProof> verifyConfirmedNoSave({
    required CloudOutboxOperation operation,
  }) => _verify(operation);

  @override
  Future<void> finalizeConfirmedReplayProof({
    required CloudOutboxOperation operation,
    required CloudSyncConfirmedReplayProof proof,
  }) => _finalize(operation, proof);

  @override
  Future<List<CloudOutboxOperation>> readOutbox() => _readOutbox();

  @override
  Future<void> quiesce() => _quiesce();
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
