import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_fixture_claims.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_adapters.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_group_send_route.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_encoder.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_group_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_chat_identity_session.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;
import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show AnyhowException;
import 'package:path/path.dart' as path;

/// Test-host-only inspection of ONE original protected journal source. This
/// neither projects its decoded payload nor substitutes a newer record map.
bool validWindowsChatSourceRequest(Map<String, Object?> request) {
  if (request['schema'] is int && request['schema'] == 3) {
    const extra = {
      'intentId', 'messageId', 'operationRowId', 'recordMapId', 'operationId',
      'parentSnapshotSha256', 'claimSha256', 'claimSource', 'sourceSha256',
    };
    final legacy = Map<String, Object?>.from(request)
      ..removeWhere((key, _) => extra.contains(key))
      ..['schema'] = 2;
    return request.length == legacy.length + extra.length &&
        extra.every(request.containsKey) && validWindowsChatSourceRequest(legacy) &&
        request['rowId'] == 24436 && request['generation'] == 1 && request['sequence'] == 1430 &&
        request['groupChatId'] == 773 && request['groupChatId'] is int &&
        request['intentId'] == 19 && request['intentId'] is int &&
        request['messageId'] == 14222 && request['messageId'] is int &&
        request['operationRowId'] == 30 && request['operationRowId'] is int &&
        request['recordMapId'] == 29119 && request['recordMapId'] is int &&
        request['operationId'] == _originalParentOperationId &&
        request['claimSource'] is String &&
        RegExp(r'^[a-f0-9]{40}$').hasMatch(request['claimSource']! as String) &&
        ['parentSnapshotSha256', 'claimSha256', 'sourceSha256'].every((key) =>
          request[key] is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(request[key]! as String));
  }
  const keys = {
    'schema',
    'launchId',
    'source',
    'pid',
    'rowId',
    'generation',
    'sequence',
    'changeIdHash',
    'recordIdHash',
    'etagHash',
    'payloadSha256',
    'referenceSha256',
  };
  final digest = RegExp(r'^[A-Za-z0-9_-]{43}$');
  final sha = RegExp(r'^[a-f0-9]{64}$');
  final groupProbe = request['schema'] is int && request['schema'] == 2;
  final allowed = {...keys, if (groupProbe) 'groupChatId'};
  return request.length == allowed.length &&
      request.keys.every(allowed.contains) &&
      (request['schema'] == 1 || groupProbe) &&
      (!groupProbe || request['groupChatId'] is int &&
          (request['groupChatId']! as int) > 0) &&
      request['launchId'] is String &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(request['launchId']! as String) &&
      request['source'] is String &&
      RegExp(r'^[a-f0-9]{40}$').hasMatch(request['source']! as String) &&
      const [
        'pid',
        'rowId',
        'generation',
        'sequence',
      ].every((key) => request[key] is int && (request[key]! as int) > 0) &&
      const ['changeIdHash', 'recordIdHash'].every(
        (key) =>
            request[key] is String && digest.hasMatch(request[key]! as String),
      ) &&
      (request['etagHash'] == null ||
          request['etagHash'] is String &&
              digest.hasMatch(request['etagHash']! as String)) &&
      const ['payloadSha256', 'referenceSha256'].every(
        (key) =>
            request[key] is String && sha.hasMatch(request[key]! as String),
      );
}

String _sha(String value) => sha256.convert(utf8.encode(value)).toString();

const windowsChatSourceInspectionStages = {
  'auth-prepare',
  'auth-bound',
  'read-window',
  'group-proof-before',
  'decode-started',
  'decode-finished',
  'group-proof-after',
  'read-released',
  'parent-source-bound',
  'parent-encoder',
  'parent-stage',
  'parent-compare',
  'parent-rollback',
  'parent-rolled-back',
};

const _originalParentOperationId =
    'op1:76ebc32305d883c0cb6dc5feb9a34280cb2eccb1eb0bf1d50f6796e46eaf0f0e';
const _originalParentFixtureId = '9e9e1891-49f1-42d2-a60a-880a7f2c9631';
const _originalParentOwner = '5eed7c60-7140-43a1-b9f0-e0426180b5ca';

/// Ordered metadata only; request writers can compute this on a CLOSED copy.
/// The output never contains a protected reference, raw GUID or source bytes.
String windowsParentStageSnapshotSha256({
  required CloudSyncLocalSendIntentEntity intent,
  required CloudOutboxOperationEntity operation,
  required CloudRecordMapEntity mapping,
}) => _sha(jsonEncode([
  'windows-parent-stage-snapshot-v1',
  [intent.id, intent.intentKey, intent.accountFingerprint, intent.writerEpoch,
    intent.localMessageId, intent.messageGuidHash, intent.sourceSha256, intent.state,
    intent.admittedOperationId, intent.admittedBindingSha256, intent.admittedChatBinding,
    intent.confirmedReadbackBindingSha256, intent.idsConfirmationVersion,
    intent.protectedSourceBinding, intent.createdAtMs, intent.updatedAtMs],
  [operation.id, operation.operationId, operation.scopeKey, operation.accountFingerprint,
    operation.zone, operation.logicalEntityKeyHash, operation.action,
    operation.dependencyOperationIdsJson, operation.payloadVersion, operation.mutationRevision,
    operation.checkpointGeneration, operation.appleRequestUuid, operation.appleOperationUuid,
    operation.encryptedPayloadRef, operation.payloadSha256, operation.protectedLeaseReference,
    operation.localChatOrigin, operation.state, operation.attemptCount, operation.nextEligibleAtMs,
    operation.lastErrorCategory, operation.serverRecordIdHash, operation.leaseIdHash,
    operation.leaseExpiresAtMs, operation.confirmedAtMs, operation.createdAtMs, operation.updatedAtMs],
  [mapping.id, mapping.mapKey, mapping.scopeKey, mapping.accountFingerprint, mapping.zone,
    mapping.logicalEntityKeyHash, mapping.serverRecordIdHash, mapping.generation,
    mapping.encryptedServerRecordId, mapping.etagHash, mapping.encryptedRawRecordRef,
    mapping.rawRecordGeneration, mapping.protectedReadbackLeaseReference,
    mapping.pendingUpdateOperationId, mapping.pendingUpdatePredecessorEtagHash, mapping.updatedAtMs],
]));

enum _ParentStagePhase { binding, proof, encoder, stage, compare, rollback }

final class _ParentStageFailure extends StateError {
  _ParentStageFailure(this.phase, Object error) : super(_parentStageSafeCode(error));
  final _ParentStagePhase phase;
}

String _parentStageSafeCode(Object error) {
  const local = {
    'backend_windows_chat_source_binding_changed',
    'backend_windows_chat_source_projection_changed',
    'backend_windows_parent_stage_mismatch',
    'backend_windows_parent_stage_rollback_failed',
    'backend_windows_parent_stage_cleanup_unconfirmed',
  };
  final candidate = error is StateError ? error.message
      : error is AnyhowException ? error.message : null;
  return local.contains(candidate) ? candidate! : error is AnyhowException
      ? cloudSyncV2SafeFailureCodeForCandidate(candidate) : cloudSyncV2SafeFailureCode(error);
}

/// Caller owns both outer exclusions. The proof callback returns ONLY after
/// the production read session resumes its pause. Native results are captured
/// before transport validation so even a rejected fresh stage gets rolled back.
Future<Map<String, Object?>> inspectWindowsParentStage<P extends Object, H>({
  required Future<void> Function() validate,
  required Future<P> Function() openProofAfterReadSession,
  required void Function(P) disposeProof,
  required H Function() encode,
  required Future<CloudSyncProtectedOutboundStageData> Function(
    P, H, void Function(String? lease) nativeResult) stage,
  required bool Function(CloudSyncProtectedOutboundStageData) matches,
  required Future<void> Function(String lease) rollback,
  required void Function() poison,
  required void Function(String stage) onStage,
}) async {
  var phase = _ParentStagePhase.binding;
  P? proof;
  String? freshLease;
  var nativeResultSeen = false;
  var stageEntered = false;
  try {
    try {
      await validate();
      phase = _ParentStagePhase.proof;
      proof = await openProofAfterReadSession();
      await validate();
      phase = _ParentStagePhase.encoder;
      onStage('parent-encoder');
      final headers = encode();
      await validate();
      phase = _ParentStagePhase.stage;
      onStage('parent-stage');
      stageEntered = true;
      final staged = await stage(proof, headers, (lease) {
        if (lease != null && !RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$').hasMatch(lease)) {
          throw StateError('backend_windows_parent_stage_cleanup_unconfirmed');
        }
        freshLease = lease;
        nativeResultSeen = true;
      });
      if (!nativeResultSeen || freshLease == null || freshLease != staged.leaseReference) {
        throw StateError('backend_windows_parent_stage_cleanup_unconfirmed');
      }
      phase = _ParentStagePhase.compare;
      onStage('parent-compare');
      await validate();
      if (!matches(staged)) {
        throw StateError('backend_windows_parent_stage_mismatch');
      }
    } finally {
      if (freshLease != null) {
        try {
          onStage('parent-rollback');
        } finally {
          try {
            await rollback(freshLease!);
          } catch (_) {
            phase = _ParentStagePhase.rollback;
            poison();
            throw StateError('backend_windows_parent_stage_rollback_failed');
          }
        }
        onStage('parent-rolled-back');
        try {
          await validate();
        } catch (error) {
          throw _ParentStageFailure(_ParentStagePhase.binding, error);
        }
      } else if (stageEntered && !nativeResultSeen) {
        phase = _ParentStagePhase.rollback;
        poison();
        throw StateError('backend_windows_parent_stage_cleanup_unconfirmed');
      }
    }
    return const {'encoderAccepted': true, 'stageMatched': true,
      'rollbackCompleted': true, 'sourceUnchanged': true,
      'canonicalCountsUnchanged': true, 'cloudWritesRequested': false,
      'rawContentExposed': false};
  } catch (error) {
    if (error is _ParentStageFailure) {
      rethrow;
    }
    throw _ParentStageFailure(phase, error);
  } finally {
    if (proof != null) {
      disposeProof(proof);
    }
  }
}

/// Refuse a newer/other retained Chat even when it has the same participants.
void requireWindowsChatSourceGroupBinding({
  required Map<String, Object?> request,
  required CloudInboxChangeEntity row,
  required CloudSyncRestoredGroupChatProof proof,
}) {
  final source = proof.source;
  if (row.id != request['rowId'] || row.fetchSequence != request['sequence'] ||
      row.generation != request['generation'] || proof.generation != row.generation ||
      source.changeIdHash != request['changeIdHash'] ||
      source.changeIdHash != row.changeIdHash ||
      source.recordIdHash != request['recordIdHash'] ||
      source.recordIdHash != row.serverRecordIdHash ||
      source.etagHash != request['etagHash'] || source.etagHash != row.etagHash ||
      source.payloadSha256 != request['payloadSha256'] ||
      source.payloadSha256 != row.payloadSha256 ||
      _sha(source.protectedRawEnvelopeReference) != request['referenceSha256'] ||
      source.protectedRawEnvelopeReference != row.encryptedPayloadRef) {
    throw StateError('backend_windows_chat_source_binding_changed');
  }
}

/// Exact native codes only. Unknown exception text never enters the result.
String windowsChatSourceGroupProofOutcome(Object error) {
  final message = error is AnyhowException
      ? error.message
      : error is StateError ? error.message : null;
  const outcomes = {
    'cloud_sync_attachment_parent_group_proof_unavailable': 'unavailable',
    'cloud_sync_attachment_parent_group_proof_auth': 'auth',
    'cloud_sync_attachment_parent_group_proof_scope': 'scope',
    'cloud_sync_attachment_parent_group_proof_invalid': 'invalid',
    'cloud_sync_attachment_parent_group_proof_mismatch': 'mismatch',
  };
  return outcomes[message] ?? 'other';
}

/// Runs inside the caller's ONE read pause. Injection keeps the ordering test
/// independent of native/account clients; binding failures remain terminal.
Future<Map<String, Object?>> decodeWindowsChatSourceWithGroupProofs<T extends Object>({
  required Map<String, Object?> request,
  required Future<void> Function() validate,
  required Future<Map<String, Object?>> Function() decode,
  required void Function(String stage) onStage,
  Future<T> Function()? openProof,
  void Function(T proof)? disposeProof,
}) async {
  if (!validWindowsChatSourceRequest(request)) {
    throw StateError('backend_windows_chat_source_request_invalid');
  }
  if (request['schema'] == 1) {
    return decode(); // Preserve schema1's summary, stages and call sequence.
  }
  if (openProof == null || disposeProof == null) {
    throw StateError('backend_windows_chat_source_request_invalid');
  }
  Future<String> probe(String stage) async {
    await validate();
    onStage(stage);
    T? proof;
    var outcome = 'ready';
    try {
      proof = await openProof();
    } catch (error) {
      outcome = windowsChatSourceGroupProofOutcome(error);
    } finally {
      if (proof != null) {
        disposeProof(proof);
      }
    }
    await validate();
    return outcome;
  }

  final before = await probe('group-proof-before');
  final summary = await decode();
  await validate();
  final after = await probe('group-proof-after');
  return {...summary, 'groupProofBefore': before, 'groupProofAfter': after};
}

/// A restored native client is cold until read authentication establishes its
/// account binding. Do not ask capture() to prove that binding first.
Future<T> prepareWindowsChatSourceAuthentication<T>({
  required Object client,
  required Object? Function() readActiveClient,
  required Future<void> Function() ensure,
  required Future<T?> Function() capture,
}) async {
  try {
    if (!identical(client, readActiveClient())) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    await ensure();
    if (!identical(client, readActiveClient())) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    final auth = await capture();
    if (auth == null || !identical(client, readActiveClient())) {
      throw StateError('backend_windows_chat_source_auth_missing');
    }
    return auth;
  } catch (error) {
    throw _WindowsChatSourceFailure(_WindowsChatSourcePhase.preparation, error);
  }
}

enum _WindowsChatSourcePhase {
  preparation('preparation'),
  readValidation('read_validation'),
  readEnsure('read_ensure'),
  readPause('read_pause'),
  readWarm('read_warm'),
  readObserve('read_observe'),
  readResume('read_resume');

  const _WindowsChatSourcePhase(this.code);
  final String code;
}

/// Only a fixed phase and a previously filtered code survive the callback.
final class _WindowsChatSourceFailure extends StateError {
  _WindowsChatSourceFailure(this.phase, Object error)
      : super(_windowsChatSourceFailureCode(error));

  final _WindowsChatSourcePhase phase;
}

final class _WindowsChatSourceReadTrace {
  var failedPhase = _WindowsChatSourcePhase.readValidation;

  Future<T> call<T>(
    _WindowsChatSourcePhase phase, Future<T> Function() action,
  ) async {
    try {
      return await action();
    } catch (_) {
      failedPhase = phase;
      rethrow; // Preserve pause-uncertainty types until the session unwinds.
    }
  }
}

final class _WindowsChatSourceObservedPause implements CloudSyncNativeWriterPause {
  _WindowsChatSourceObservedPause(this.delegate, this.trace);
  final CloudSyncNativeWriterPause delegate;
  final _WindowsChatSourceReadTrace trace;

  @override
  Future<Object> pause() => trace.call(_WindowsChatSourcePhase.readPause, delegate.pause);

  @override
  Future<void> resume(Object token) => trace.call(
    _WindowsChatSourcePhase.readResume, () => delegate.resume(token),
  );
}

/// Uses the production session unchanged. Annotation happens only after its
/// resume/poison path settles; a successful resume cannot hide an earlier phase.
Future<T> runWindowsChatSourceReadWindow<T>({
  required CloudKitOperationExclusion exclusion,
  required CloudSyncNativeWriterPause nativePause,
  required Future<void> Function() validate,
  required Future<void> Function() ensureReadAuthentication,
  required Future<void> Function(BigInt token) warmReadAuthentication,
  required Future<T> Function(BigInt token) observe,
}) async {
  final trace = _WindowsChatSourceReadTrace();
  final session = CloudSyncWriteChatIdentitySession(
    exclusion: exclusion,
    nativePause: _WindowsChatSourceObservedPause(nativePause, trace),
    validate: () => trace.call(_WindowsChatSourcePhase.readValidation, validate),
    ensureReadAuthentication: () => trace.call(
      _WindowsChatSourcePhase.readEnsure, ensureReadAuthentication,
    ),
    warmReadAuthentication: (token) => trace.call(
      _WindowsChatSourcePhase.readWarm, () => warmReadAuthentication(token),
    ),
  );
  try {
    return await session.run((token) => trace.call(
      _WindowsChatSourcePhase.readObserve, () => observe(token),
    ));
  } catch (error) {
    throw _WindowsChatSourceFailure(trace.failedPhase, error);
  }
}

String _windowsChatSourceFailureCode(Object error) {
  const safe = {
    'backend_windows_chat_source_request_invalid',
    'backend_windows_chat_source_auth_missing',
    'backend_windows_chat_source_binding_changed',
    'backend_windows_chat_source_result_mismatch',
    'backend_windows_chat_source_projection_changed',
    'backend_windows_chat_source_requires_idle',
    'cloud_sync_native_auth_account_unavailable',
    'cloud_sync_native_auth_account_changed',
    'cloud_sync_native_auth_client_type_invalid',
    'cloud_sync_native_auth_storage_invalid',
    'cloud_sync_native_auth_metadata_invalid',
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
    'cloud_sync_native_auth_refresh_relay_unavailable',
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
    'cloud_sync_native_auth_bridge_failed',
    'cloud_sync_native_writer_pause_already_active',
    'cloud_sync_native_writer_pause_failed',
    'cloud_sync_native_writer_pause_timeout',
    'cloud_sync_native_writer_pause_token_invalid',
    'cloud_sync_native_writer_pause_bridge_failed',
    'cloud_sync_native_writer_pause_resume_unconfirmed',
    'cloud_sync_native_writer_resume_failed',
    'cloud_sync_native_writer_resume_token_invalid',
    'cloudkit_interlock_required',
    'cloudkit_interlock_mode_violation',
    'cloudkit_interlock_profile_mismatch',
    'cloudkit_interlock_fence_lost',
    'cloudkit_interlock_busy',
    'cloudkit_interlock_unavailable',
    'cloudkit_interlock_reservation_lost',
  };
  final candidate = switch (error) {
    StateError() => error.message,
    AnyhowException() => error.message,
    CloudKitOperationInterlockException() => error.safeCode,
    CloudSyncNativeWriterPauseUncertain() => 'cloud_sync_native_writer_pause_resume_unconfirmed',
    _ => null,
  };
  return safe.contains(candidate)
      ? candidate! : 'backend_windows_chat_source_observation_failed';
}

String safeWindowsChatSourceFailure(Object error) {
  if (error is _ParentStageFailure) {
    return 'backend_windows_parent_${error.phase.name}__${error.message}';
  }
  final code = _windowsChatSourceFailureCode(error);
  return error is _WindowsChatSourceFailure
      ? 'backend_windows_chat_source_${error.phase.code}__$code' : code;
}

/// Closed format class using the app's existing participant projection grammar.
/// It never returns an address, unknown scheme name, or identifier fragment.
String classifyWindowsChatSourceParticipant(String raw) {
  if (raw.isEmpty ||
      raw.length > 512 ||
      raw != raw.trim() ||
      RegExp(r'[\x00-\x1f\x7f-\x9f\s\uFEFF]').hasMatch(raw)) {
    return 'malformed';
  }
  final telephone = RegExp(r'^\+?[0-9]{3,20}$');
  final email = RegExp(r'^[^@\s:]+@[^@\s:]+\.[^@\s:]+$');
  final lower = raw.toLowerCase();
  if (lower.startsWith('tel:')) {
    return telephone.hasMatch(raw.substring(4)) ? 'telephone' : 'malformed';
  }
  if (lower.startsWith('mailto:')) {
    return email.hasMatch(raw.substring(7)) ? 'email' : 'malformed';
  }
  if (RegExp(
    r'^urn:biz:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'
    r'[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
  ).hasMatch(raw)) {
    return 'business';
  }
  if (raw.contains(':')) {
    return 'unknownScheme';
  }
  if (raw.contains('@')) {
    return email.hasMatch(raw) ? 'email' : 'malformed';
  }
  return telephone.hasMatch(raw) ? 'telephone' : 'bareOpaque';
}

/// Closed classifications only. No identities, handles or plaintext are
/// returned, even when the canonical payload contains them in transient memory.
Map<String, Object?> summarizeWindowsChatSource(
  api.CloudSyncTransientDecodeResult decoded,
) {
  final chat = decoded.payload?.chat;
  final classes = <String, int>{
    'phone': 0,
    'email': 0,
    'opaque': 0,
    'other': 0,
  };
  final projectedClasses = <String, int>{
    'telephone': 0,
    'email': 0,
    'business': 0,
    'bareOpaque': 0,
    'unknownScheme': 0,
    'malformed': 0,
  };
  for (final raw in chat?.participantHandles ?? const <String>[]) {
    final projected = classifyWindowsChatSourceParticipant(raw);
    projectedClasses[projected] = projectedClasses[projected]! + 1;
    final lower = raw.toLowerCase();
    final value = lower.startsWith('tel:')
        ? lower.substring(4)
        : lower.startsWith('mailto:')
        ? lower.substring(7)
        : lower;
    final identityValid =
        raw.isNotEmpty &&
        utf8.encode(raw).length <= 4096 &&
        raw.trim() == raw &&
        !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(raw);
    final email = value.split('@');
    final kind = identityValid && RegExp(r'^\+[0-9]{1,15}$').hasMatch(value)
        ? 'phone'
        : identityValid &&
              email.length == 2 &&
              email.every((part) => part.isNotEmpty) &&
              !RegExp(r'\s').hasMatch(value)
        ? 'email'
        : identityValid && !RegExp(r'\s').hasMatch(value)
        ? 'opaque'
        : 'other';
    classes[kind] = classes[kind]! + 1;
  }
  bool identityValid(String value) =>
      value.isNotEmpty &&
      utf8.encode(value).length <= 4096 &&
      value.trim() == value &&
      !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value);
  return {
    'canonicalChatPresent': chat != null,
    'failure': decoded.failureCode?.name,
    'deferred': decoded.deferredReason?.name,
    'quarantine': decoded.quarantineReason?.name,
    'style': chat?.style.name,
    'service': chat?.service.name,
    'primaryIdentitiesValid':
        chat != null &&
        [
          chat.canonicalGuid,
          chat.chatIdentifier,
          chat.groupId,
          chat.originalGroupId,
        ].every(identityValid),
    'participantClasses': classes,
    'projectedParticipantClasses': projectedClasses,
    'aliasCount': chat?.aliases.length ?? 0,
    'rawContentExposed': false,
  };
}

Future<Map<String, Object?>> inspectWindowsChatSource({
  required Store store,
  required String profile,
  required Map<String, Object?> request,
  required Object? Function() readActiveClient,
  required Future<void> Function() requireIdle,
  required void Function(String stage) onStage,
}) async {
  if (!validWindowsChatSourceRequest(request)) {
    throw StateError('backend_windows_chat_source_request_invalid');
  }
  final provider = CloudSyncProductionAuthSnapshotProvider(
    readActiveClient: readActiveClient,
    nativeAuthBinding: FrbCloudSyncNativeAuthBinding(),
    privateStorageDirectory: profile,
  );
  final client = readActiveClient();
  if (client is! rustlib.ArcCloudMessagesClientDefaultAnisetteProvider) {
    throw StateError('backend_windows_chat_source_auth_missing');
  }
  final binding = FrbCloudSyncNativeAuthBinding();
  final interlock = CloudKitOperationInterlock(
    privateStorageDirectory: profile,
    fenceStore: ObjectBoxCloudSyncStore(
      store: store,
      protector: RustCloudSyncProtector(storageDirectory: profile),
    ),
  );
  // Schema3 additionally owns exactly one uncommitted local stage/rollback.
  // The account exclusion never grants a save, upload or IDS operation.
  return interlock.runExclusive(
    kind: CloudKitOperationKind.v2ReadWrite,
    action: () async {
      onStage('auth-prepare');
      final auth = await prepareWindowsChatSourceAuthentication(
        client: client,
        readActiveClient: readActiveClient,
        ensure: () => binding.ensureReadAuthentication(
          cloudMessagesClient: client,
          privateStorageDirectory: profile,
        ),
        capture: provider.capture,
      );
      onStage('auth-bound');
      final scope = CloudSyncScope(
        accountFingerprint: auth.accountFingerprint,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'chatManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      CloudInboxChangeEntity source() {
        final row = store.box<CloudInboxChangeEntity>().get(
          request['rowId']! as int,
        );
        if (row == null ||
            row.scopeKey != cloudSyncPersistentScopeKey(scope) ||
            row.accountFingerprint != auth.accountFingerprint ||
            row.zone != scope.zone ||
            row.generation != request['generation'] ||
            row.fetchSequence != request['sequence'] ||
            row.changeIdHash != request['changeIdHash'] ||
            row.serverRecordIdHash != request['recordIdHash'] ||
            row.etagHash != request['etagHash'] ||
            row.payloadSha256 != request['payloadSha256'] ||
            row.encryptedPayloadRef == null ||
            _sha(row.encryptedPayloadRef!) != request['referenceSha256'] ||
            row.changeType != 'save' ||
            row.isTombstone) {
          throw StateError('backend_windows_chat_source_binding_changed');
        }
        return row;
      }

      final original = jsonEncode(source().toMapForChatSourceInspection());
      final groupProbe = request['schema'] == 2 || request['schema'] == 3;
      CloudSyncRestoredGroupChatProof captureGroupProof() {
        final proof = requireCloudSyncRestoredGroupChatProofForId(
          store: store,
          messageScope: CloudSyncScope(
            accountFingerprint: auth.accountFingerprint,
            container: scope.container, database: scope.database,
            zone: 'messageManateeZone', streamKind: scope.streamKind,
            schemaVersion: scope.schemaVersion, persistenceLane: scope.persistenceLane,
          ),
          chatId: request['groupChatId']! as int,
        );
        requireWindowsChatSourceGroupBinding(request: request, row: source(), proof: proof);
        return proof;
      }
      final pinnedGroup = groupProbe ? captureGroupProof() : null;
      List<int> currentCounts() => [
        store.box<Chat>().count(),
        store.box<Message>().count(),
        store.box<Attachment>().count(),
        store.box<CloudOutboxOperationEntity>().count(),
        if (groupProbe) ...[
          store.box<CloudInboxChangeEntity>().count(),
          store.box<CloudSemanticSnapshotEntity>().count(),
          store.box<CloudSemanticChatAliasEntity>().count(),
          store.box<CloudRecordMapEntity>().count(),
          store.box<CloudSyncCheckpointEntity>().count(),
        ],
      ];
      final counts = currentCounts();
      void requireChatSnapshot() {
        if (store.isClosed() || jsonEncode(source().toMapForChatSourceInspection()) != original) {
          throw StateError('backend_windows_chat_source_binding_changed');
        }
        if (pinnedGroup != null) {
          final current = captureGroupProof();
          if (current.binding != pinnedGroup.binding ||
              current.generation != pinnedGroup.generation ||
              current.routingMetadataDigest != pinnedGroup.routingMetadataDigest ||
              current.logicalEntityKeyHash != pinnedGroup.logicalEntityKeyHash ||
              current.source != pinnedGroup.source) {
            throw StateError('backend_windows_chat_source_binding_changed');
          }
          if (jsonEncode(counts) != jsonEncode(currentCounts())) {
            throw StateError('backend_windows_chat_source_projection_changed');
          }
        }
      }
      Future<void> validate() async {
        await requireIdle();
        if (store.isClosed() || !auth.sameIdentity(await provider.capture())) {
          throw StateError('backend_windows_chat_source_binding_changed');
        }
        requireChatSnapshot();
      }

      if (request['schema'] == 3) {
        return _inspectWindowsOriginalParentStage(
          store: store, profile: profile, request: request, client: client,
          auth: auth, provider: provider, interlock: interlock,
          validateChat: validate, requireChatSnapshot: requireChatSnapshot,
          pinnedGroup: pinnedGroup!, onStage: onStage,
        );
      }

      // The existing identity session tolerates a preserved queued outbox. Its
      // v2ReadWrite lock is exclusion only; this callback has no write operation.
      onStage('read-window');
      Future<Map<String, Object?>> readWindow(
        Future<Map<String, Object?>> Function(BigInt token) observe,
      ) => runWindowsChatSourceReadWindow(
        exclusion: interlock,
        nativePause: FrbCloudSyncNativeWriterPause(),
        validate: validate,
        ensureReadAuthentication: () => binding.ensureReadAuthentication(
          cloudMessagesClient: auth.cloudMessagesClient,
          privateStorageDirectory: profile,
        ),
        warmReadAuthentication: (token) =>
            binding.warmReadAuthenticationUnderWriterPause(
              cloudMessagesClient: auth.cloudMessagesClient,
              pauseToken: token,
            ),
        observe: observe,
      );
      Future<Map<String, Object?>> decode(BigInt token) async {
        final row = source();
        onStage('decode-started');
        final decoded = await api.cloudSyncDecodeProtectedChange(
          cloudMessagesClient:
              auth.cloudMessagesClient
                  as rustlib.ArcCloudMessagesClientDefaultAnisetteProvider,
          nativeWriterPauseToken: token,
          storageDirectory: profile,
          expectedAccountFingerprint: auth.accountFingerprint,
          expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
          container: scope.container,
          database: scope.database,
          zone: scope.zone,
          streamKind: scope.streamKind.name,
          schemaVersion: scope.schemaVersion,
          nativeStream: 'chats',
          generation: BigInt.from(row.generation),
          expectedChangeKind: api.CloudSyncProtectedChangeKind.save,
          expectedChangeId: row.changeIdHash,
          expectedRecordIdHash: row.serverRecordIdHash,
          expectedEtagHash: row.etagHash,
          expectedPayloadSha256: row.payloadSha256!,
          expectedPayloadLength: null,
          expectedServerModifiedAtMillis:
              cloudInboxCanonicalServerModifiedAtMillis(row),
          protectedRawEnvelopeReference: row.encryptedPayloadRef!,
          tombstoneEntityKind: null,
          tombstoneLogicalEntityKeyHash: null,
        );
        if (decoded.generation != BigInt.from(row.generation) ||
            decoded.protectedSourceReference != row.encryptedPayloadRef ||
            decoded.payload?.chat != null &&
                (decoded.changeId != row.changeIdHash ||
                    decoded.entityKind !=
                        api.CloudSyncTransientEntityKind.chat ||
                    decoded.mutationKind !=
                        api.CloudSyncTransientMutationKind.upsert)) {
          throw StateError('backend_windows_chat_source_result_mismatch');
        }
        final summary = summarizeWindowsChatSource(decoded);
        onStage('decode-finished');
        return summary;
      }
      final result = await readWindow((token) =>
        decodeWindowsChatSourceWithGroupProofs<api.CloudSyncAttachmentParentGroupProof>(
          request: request, validate: validate, decode: () => decode(token), onStage: onStage,
          openProof: pinnedGroup == null ? null : () => api.cloudSyncOpenAttachmentParentGroupProof(
            cloudMessagesClient: client, nativeWriterPauseToken: token,
            storageDirectory: profile,
            expectedAccountFingerprint: auth.accountFingerprint,
            expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
            generation: BigInt.from(pinnedGroup.generation),
            routingMetadataDigest: pinnedGroup.routingMetadataDigest,
            source: pinnedGroup.source,
          ),
          // Generated RustOpaqueInterface.dispose releases this proof's Arc.
          disposeProof: (proof) => proof.dispose(),
        ));
      onStage('read-released');
      await validate();
      final after = currentCounts();
      if (jsonEncode(counts) != jsonEncode(after)) {
        throw StateError('backend_windows_chat_source_projection_changed');
      }
      return {
        'schema': groupProbe ? 2 : 1,
        'completed': true,
        'rowId': request['rowId'],
        'generation': request['generation'],
        'sequence': request['sequence'],
        'sourceUnchanged': true,
        'canonicalCountsUnchanged': true,
        'cloudWritesRequested': false,
        ...result,
      };
    },
  );
}

/// This deliberately supplies only staging and rollback to the production
/// transport. An accidentally reached save/commit/prepare method fails closed.
final class _WindowsParentStageBindings implements
    NativeProtectedCloudSyncBindings, NativeProtectedCloudSyncAttachmentParentWriteBindings {
  final delegate = FrbNativeProtectedCloudSyncBindings();
  void Function(String? lease)? captureResult;

  @override
  Future<api.CloudSyncProtectedOutboundStageResult> stageOutboundAttachmentParent({
    required Object cloudMessagesClient, required String storageDirectory,
    required String expectedAccountFingerprint, required String expectedProtectedStoreIdentity,
    required api.CloudMessage messageHeaders,
    required api.CloudSyncNativeSendReceiptContext context,
    required api.CloudSyncAttachmentParentGroupProof? groupProof,
  }) async {
    final result = await delegate.stageOutboundAttachmentParent(
      cloudMessagesClient: cloudMessagesClient, storageDirectory: storageDirectory,
      expectedAccountFingerprint: expectedAccountFingerprint,
      expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
      messageHeaders: messageHeaders, context: context, groupProof: groupProof,
    );
    if (result.stage == null && result.failure == null) {
      throw StateError('backend_windows_parent_stage_cleanup_unconfirmed');
    }
    captureResult!(result.stage?.leaseReference);
    return result;
  }

  @override
  Future<NativeProtectedLeaseResult> rollbackProtectedPageLease({
    required String storageDirectory, required String leaseReference,
  }) => delegate.rollbackProtectedPageLease(
    storageDirectory: storageDirectory, leaseReference: leaseReference,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('backend_windows_parent_stage_capability_unavailable');
}

Future<Map<String, Object?>> _inspectWindowsOriginalParentStage({
  required Store store, required String profile, required Map<String, Object?> request,
  required rustlib.ArcCloudMessagesClientDefaultAnisetteProvider client,
  required CloudSyncNativeAuthSnapshot auth,
  required CloudSyncProductionAuthSnapshotProvider provider,
  required CloudKitOperationInterlock interlock,
  required Future<void> Function() validateChat,
  required void Function() requireChatSnapshot,
  required CloudSyncRestoredGroupChatProof pinnedGroup,
  required void Function(String) onStage,
}) async {
  final scope = CloudSyncScope(accountFingerprint: auth.accountFingerprint,
    container: 'com.apple.messages.cloud', database: 'private', zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic);
  final attachmentScope = CloudSyncScope(accountFingerprint: auth.accountFingerprint,
    container: scope.container, database: scope.database, zone: 'attachmentManateeZone',
    persistenceLane: scope.persistenceLane);
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final bindings = _WindowsParentStageBindings();
  final transport = NativeProtectedCloudSyncTransport(cloudMessagesClient: client,
    storageDirectory: profile, protectedStoreIdentity: auth.protectedStoreIdentity,
    bindings: bindings);
  var poisoned = false;
  Future<Map<String, Object?>> inspect() async {
  final authority = ObjectBoxCloudKitWriterAuthority(store: store);
  final writerScope = CloudKitWriterScope(accountFingerprint: auth.accountFingerprint);
  final owner = authority.read(writerScope);
  if (owner == null || owner.owner != CloudKitWriterOwner.v2) {
    throw _ParentStageFailure(_ParentStagePhase.binding,
      StateError('cloud_sync_local_send_owner_changed'));
  }
  List<Object?> ownerFields(CloudKitWriterAuthoritySnapshot? value) => [
    value?.owner.name, value?.state.name, value?.epoch, value?.ownershipEpoch,
    value?.targetOwner.name, value?.transitionIdHash,
  ];
  final originalOwner = jsonEncode(ownerFields(owner));
  late final CloudSyncAttachmentUploadJournal uploads;
  final journal = CloudSyncLocalSendJournal(store: store, authority: authority,
    authoritySnapshot: owner, currentAuth: auth,
    attachmentParentReadback: (id, proof) {
      if (id != 19 || proof == null) {
        throw StateError('cloud_sync_attachment_parent_readback_required');
      }
      uploads.requireParentReadbackProof(localSendIntentId: id, proof: proof);
      return proof;
    });

  ({CloudSyncLocalSendIntentEntity intent, CloudOutboxOperationEntity operation,
      CloudRecordMapEntity mapping, Message message, Chat chat}) rows() {
    final intent = store.box<CloudSyncLocalSendIntentEntity>().get(19);
    final operation = store.box<CloudOutboxOperationEntity>().get(30);
    final mapping = store.box<CloudRecordMapEntity>().get(29119);
    final message = store.box<Message>().get(14222);
    final chat = store.box<Chat>().get(773);
    if (intent == null || operation == null || mapping == null || message == null || chat == null ||
        intent.localMessageId != message.id || message.chat.targetId != chat.id ||
        intent.state != 2 || intent.idsConfirmationVersion != 2 ||
        intent.admittedOperationId != _originalParentOperationId ||
        intent.sourceSha256 != request['sourceSha256'] ||
        intent.accountFingerprint != auth.accountFingerprint ||
        operation.operationId != _originalParentOperationId || operation.state != 4 ||
        operation.action != CloudOutboxAction.save.index || operation.payloadVersion != 2 ||
        operation.scopeKey != scopeKey || operation.accountFingerprint != auth.accountFingerprint ||
        operation.zone != scope.zone || operation.appleRequestUuid != null ||
        operation.appleOperationUuid != null || operation.protectedLeaseReference != null ||
        operation.leaseIdHash != null || operation.leaseExpiresAtMs != 0 ||
        operation.encryptedPayloadRef == null || operation.payloadSha256 == null ||
        operation.localChatOrigin != null || operation.dependencyOperationIdsJson != '[]' ||
        mapping.scopeKey != scopeKey || mapping.accountFingerprint != auth.accountFingerprint ||
        mapping.zone != scope.zone || mapping.generation != operation.checkpointGeneration ||
        mapping.logicalEntityKeyHash != operation.logicalEntityKeyHash ||
        mapping.serverRecordIdHash != operation.serverRecordIdHash ||
        mapping.encryptedServerRecordId != operation.encryptedPayloadRef ||
        mapping.etagHash != null || mapping.encryptedRawRecordRef != null ||
        windowsParentStageSnapshotSha256(intent: intent, operation: operation, mapping: mapping) !=
            request['parentSnapshotSha256']) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    return (intent: intent, operation: operation, mapping: mapping, message: message, chat: chat);
  }

  final initial = rows();
  uploads = CloudSyncAttachmentUploadJournal(store: store, localSends: journal,
    scope: attachmentScope, checkpointGeneration: initial.operation.checkpointGeneration,
    currentAuth: auth);
  final claimFile = File(path.join(profile, 'cloud-sync-v2', 'backend-fixtures',
    '${_originalParentFixtureId.toUpperCase()}.jsonl'));
  void requireClaim(Message message) {
    final claim = BackendHarnessFixtureClaims(storageDirectory: profile,
      source: request['claimSource']! as String, auth: auth)
        .read(_originalParentFixtureId, owner: _originalParentOwner);
    if (claim == null || claim.partialResult || claim.messageGuid != message.guid ||
        sha256.convert(claimFile.readAsBytesSync()).toString() != request['claimSha256']) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
  }
  String localSnapshot() {
    final current = rows();
    requireClaim(current.message);
    final attachments = current.message.dbAttachments.toList();
    if (attachments.length != 1 || attachments.single.id != 2551) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    return _sha(jsonEncode([
      current.message.toMap(), current.chat.toMap(),
      attachments.map((entry) => entry.toMap()).toList(),
      store.box<CloudSyncLocalSendIntentEntity>().count(),
      store.box<CloudAttachmentUploadEntity>().count(),
      store.box<CloudKitWriterAuthorityEntity>().count(),
      store.box<CloudProtectedPageLeaseEntity>().count(),
      originalOwner,
    ]));
  }
  final originalLocal = localSnapshot();
  final retained = journal.readAdoptedAttachmentSource(
    operationId: _originalParentOperationId, currentAuth: auth);
  if (retained == null || retained.sourceSha256 != request['sourceSha256']) {
    throw _ParentStageFailure(_ParentStagePhase.binding,
      StateError('cloud_sync_local_send_source_changed'));
  }
  final plans = FrbCloudSyncAttachmentPlanSource(storageDirectory: profile);
  final context = plans.receiptContext(retained, auth);
  CloudSyncRestoredGroupChatProof adoptedGroup() {
    final dependency = journal.readAdoptedAttachmentChatDependency(
      operationId: _originalParentOperationId, currentAuth: auth);
    final group = requireCloudSyncAdoptedGroupChatProof(store: store,
      messageScope: scope, binding: dependency, expectedChatId: 773);
    if (group.binding != pinnedGroup.binding || group.generation != pinnedGroup.generation ||
        group.source != pinnedGroup.source || group.routingMetadataDigest != pinnedGroup.routingMetadataDigest) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    return group;
  }
  Message selectedMessage() {
    adoptedGroup();
    final route = CloudSyncGroupSendRoute.capture(rows().chat);
    if (route == null || route.provisional || route.members.length != 2) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    final selected = journal.readExactGroupIntent(intentId: 19,
      expectedChatGuid: route.guid, expectedMembers: route.members,
      expectedSender: route.sender, expectedSourceSha256: retained.sourceSha256);
    if (selected.localMessageId != 14222 || selected.admittedOperationId != _originalParentOperationId ||
        selected.message == null) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    return selected.message!;
  }
  Future<void> validate() async {
    await validateChat();
    if (!auth.sameIdentity(await provider.capture()) ||
        jsonEncode(ownerFields(authority.read(writerScope))) != originalOwner ||
        localSnapshot() != originalLocal ||
        journal.readAdoptedAttachmentSource(operationId: _originalParentOperationId,
          currentAuth: auth)?.encode() != retained.encode()) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    requireChatSnapshot(); // Includes the Chat row's complete source snapshot after the LAST await.
    selectedMessage(); // Revalidates actual adopted child readback, never just state2.
  }

      await validate();
      onStage('parent-source-bound');
      final result = await inspectWindowsParentStage<api.CloudSyncAttachmentParentGroupProof, api.CloudMessage>(
        validate: validate,
        openProofAfterReadSession: () async {
          onStage('read-window');
          api.CloudSyncAttachmentParentGroupProof? opened;
          var transferred = false;
          try {
            final proof = await runWindowsChatSourceReadWindow(
              exclusion: interlock, nativePause: FrbCloudSyncNativeWriterPause(), validate: validate,
              ensureReadAuthentication: () => FrbCloudSyncNativeAuthBinding().ensureReadAuthentication(
                cloudMessagesClient: client, privateStorageDirectory: profile),
              warmReadAuthentication: (token) => FrbCloudSyncNativeAuthBinding()
                .warmReadAuthenticationUnderWriterPause(cloudMessagesClient: client, pauseToken: token),
              observe: (token) async {
                final group = adoptedGroup();
                opened = await api.cloudSyncOpenAttachmentParentGroupProof(
                  cloudMessagesClient: client, nativeWriterPauseToken: token, storageDirectory: profile,
                  expectedAccountFingerprint: auth.accountFingerprint,
                  expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
                  generation: BigInt.from(group.generation), routingMetadataDigest: group.routingMetadataDigest,
                  source: group.source);
                return opened!;
              },
            );
            onStage('read-released');
            transferred = true;
            return proof;
          } finally {
            if (!transferred && opened != null) {
              opened!.dispose();
            }
          }
        },
        disposeProof: (proof) => proof.dispose(),
        encode: () => encodeCloudSyncLocalSendAttachmentHeaders(selectedMessage(), source: retained),
        stage: (proof, headers, capture) {
          bindings.captureResult = (lease) {
            // A native result must never turn the original IDS source into a
            // rollback candidate. An unexpected alias is uncertain cleanup.
            if (lease == retained.leaseReference) {
              throw StateError('backend_windows_parent_stage_cleanup_unconfirmed');
            }
            capture(lease);
          };
          return transport.stageOutboundAttachmentParent(scope, messageHeaders: headers,
            context: context, groupProof: proof);
        },
        matches: (stage) => stage.payloadSha256 == initial.operation.payloadSha256 &&
          stage.logicalEntityKeyHash == initial.operation.logicalEntityKeyHash &&
          stage.serverRecordIdHash == initial.mapping.serverRecordIdHash &&
          CloudOperationIdentity.forInitialCreate(scope: scope,
            logicalEntityKeyHash: stage.logicalEntityKeyHash, payloadVersion: 2) == _originalParentOperationId &&
          stage.protectedEnvelopeReference != initial.operation.encryptedPayloadRef &&
          stage.leaseReference != retained.leaseReference,
        rollback: transport.rollbackOutboundLease,
        poison: () { poisoned = true; interlock.poisonUntilProcessRestart(); },
        onStage: onStage,
      );
      return {'schema': 3, 'completed': true, ...result};
  }
  try {
    return await transport.runOutboundAdmissionExclusive(inspect);
  } finally {
    // Never quiesce from INSIDE the tracked admission callback: it would wait
    // for itself. A poisoned outer interlock remains owned through this wait.
    if (poisoned) {
      await transport.quiesceNativeOperations();
    }
  }
}

extension on CloudInboxChangeEntity {
  List<Object?> toMapForChatSourceInspection() => [
    id,
    changeKey,
    changeIdHash,
    scopeKey,
    accountFingerprint,
    zone,
    serverRecordIdHash,
    etagHash,
    changeType,
    encryptedServerRecordId,
    protectedSystemFieldsRef,
    encryptedPayloadRef,
    payloadSha256,
    batchId,
    generation,
    fetchSequence,
    status,
    isTombstone,
    preflightCategory,
    failureCategory,
    preflightCode,
    retryCount,
    nextEligibleAtMs,
    serverModifiedAtMs,
    serverModifiedAtFormatVersion,
    createdAtMs,
    updatedAtMs,
    completedAtMs,
  ];
}
