import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_adapters.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_fresh_group_recovery_snapshot.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_preparation_recovery.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_preparation_recovery_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_preparation_recovery_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_record_maps.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_protected_page_lease_lifecycle.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_group_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_chat_identity_session.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;
import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show AnyhowException;
import 'package:uuid/uuid.dart';

/// Test-host-only inspection of ONE original protected journal source. This
/// neither projects its decoded payload nor substitutes a newer record map.
/// Schema4 additionally owns exact local Message recovery + prepare/release,
/// with no consume, save, upload, send, or receipt-application capability.
bool validWindowsChatSourceRequest(Map<String, Object?> request) {
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
  final preparation = request['schema'] is int && request['schema'] == 4;
  final groupProbe = request['schema'] is int && (request['schema'] == 2 || preparation);
  final allowed = {...keys, if (groupProbe) 'groupChatId', if (preparation) ...{
    'messageOperationId', 'messageIntentId', 'messageId', 'messageSourceSha256', 'messageSnapshotSha256',
  }};
  return request.length == allowed.length &&
      request.keys.every(allowed.contains) &&
      (request['schema'] == 1 || groupProbe) &&
      (!preparation ||
        request['messageOperationId'] is String &&
        RegExp(r'^op1:[a-f0-9]{64}$').hasMatch(request['messageOperationId']! as String) &&
        const ['messageIntentId', 'messageId'].every((key) => request[key] is int && (request[key]! as int) > 0) &&
        const ['messageSourceSha256', 'messageSnapshotSha256'].every((key) =>
          request[key] is String && sha.hasMatch(request[key]! as String))) &&
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
  'message-source-bound',
  'message-owner-committed',
  'message-prepare-started',
  'message-prepare-settled',
  'message-prepared-released',
  'message-owner-retained',
};

String windowsMessagePreparationSnapshotSha256({
  required CloudSyncLocalSendIntentEntity intent,
  required CloudOutboxOperationEntity operation,
  required CloudRecordMapEntity mapping,
}) => _sha(jsonEncode([
  freshGroupRecoveryOperationSnapshot(operation),
  freshGroupRecoveryMapSnapshot(mapping), freshGroupRecoverySourceSnapshot(intent),
]));

/// No mutation callback exists. A failed preflight is a settled diagnostic only
/// after native quiescence and exact retained-owner validation both succeed.
Future<Map<String, Object?>> prepareWindowsMessageWithoutMutation<P extends Object>({
  required Future<P> Function() prepare,
  required Future<bool> Function(P) release,
  required Future<void> Function() quiesce,
  required Future<void> Function() retain,
  required void Function(String) onStage,
}) async {
  P? prepared;
  Object? failure;
  bool? released;
  onStage('message-prepare-started');
  try { prepared = await prepare(); } catch (error) { failure = error; }
  try {
    if (prepared != null) {
      released = await release(prepared);
      onStage('message-prepared-released');
    }
  } finally {
    await quiesce();
  }
  onStage('message-prepare-settled');
  await retain();
  onStage('message-owner-retained');
  return {
    'prepared': prepared != null,
    'preflightFailure': failure == null ? null : cloudSyncV2SafeFailureCode(failure),
    'preparedOwnerReleaseResult': released,
    'nativeCallsSettled': true, 'recoveryOwnerRetained': true,
    'cloudWritesRequested': false, 'idsSendsRequested': false,
    'preparedSubmissionConsumed': false, 'readbackReceiptApplied': false,
  };
}

Map<String, Object?> windowsMessagePreparationFailureDetails(Object error) => {
  'messageRecoverySafeCode': cloudSyncV2SafeFailureCode(error),
  if (error is CloudSyncMessagePreparationStageFailure)
    'nativeRecoveryPhase': error.phase.name,
};

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
  // This is the existing account-bound identity-read exclusion, with no save,
  // upload, staging or IDS operation supplied to the callback.
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
      final groupProbe = request['schema'] == 2 || request['schema'] == 4;
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
      Future<void> validate() async {
        await requireIdle();
        if (store.isClosed() ||
            !auth.sameIdentity(await provider.capture()) ||
            jsonEncode(source().toMapForChatSourceInspection()) != original) {
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

      // The existing identity session tolerates a preserved queued outbox. Its
      // v2ReadWrite lock is exclusion only; this callback has no write operation.
      onStage('read-window');
      Future<T> readWindow<T>(
        Future<T> Function(BigInt token) observe,
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
      if (request['schema'] == 4) {
        return _inspectWindowsOriginalMessagePreparation(store: store, profile: profile,
          request: request, client: client, auth: auth, provider: provider,
          readActiveClient: readActiveClient,
          pinnedGroup: pinnedGroup!, validateChat: validate,
          readProofWindow: (observe) => readWindow<api.CloudSyncAttachmentParentGroupProof>(observe),
          onStage: onStage);
      }
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

Future<Map<String, Object?>> _inspectWindowsOriginalMessagePreparation({
  required Store store,
  required String profile,
  required Map<String, Object?> request,
  required rustlib.ArcCloudMessagesClientDefaultAnisetteProvider client,
  required CloudSyncNativeAuthSnapshot auth,
  required CloudSyncProductionAuthSnapshotProvider provider,
  required Object? Function() readActiveClient,
  required CloudSyncRestoredGroupChatProof pinnedGroup,
  required Future<void> Function() validateChat,
  required Future<api.CloudSyncAttachmentParentGroupProof> Function(
    Future<api.CloudSyncAttachmentParentGroupProof> Function(BigInt)) readProofWindow,
  required void Function(String) onStage,
}) async {
  final operationId = request['messageOperationId']! as String;
  final intentId = request['messageIntentId']! as int;
  final chatId = request['groupChatId']! as int;
  final scope = CloudSyncScope(accountFingerprint: auth.accountFingerprint,
    container: 'com.apple.messages.cloud', database: 'private', zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic);
  ({CloudSyncLocalSendIntentEntity intent, CloudOutboxOperationEntity operation,
    CloudRecordMapEntity mapping, Message message, Chat chat}) rows() {
    final query = store.box<CloudOutboxOperationEntity>().query(
      CloudOutboxOperationEntity_.operationId.equals(operationId)).build();
    final CloudOutboxOperationEntity? operation;
    try { operation = query.findUnique(); } finally { query.close(); }
    final intent = store.box<CloudSyncLocalSendIntentEntity>().get(intentId);
    final message = store.box<Message>().get(request['messageId']! as int);
    final chat = store.box<Chat>().get(chatId);
    final mapping = operation == null ? null : cloudSyncFindRecordMap(store: store, scope: scope,
      generation: operation.checkpointGeneration, logicalEntityKeyHash: operation.logicalEntityKeyHash,
      serverRecordIdHash: operation.serverRecordIdHash);
    if (operation == null || intent == null || message == null || chat == null || mapping == null ||
        intent.localMessageId != message.id || message.chat.targetId != chatId ||
        intent.admittedOperationId != operationId || intent.state != 2 || intent.idsConfirmationVersion != 2 ||
        intent.sourceSha256 != request['messageSourceSha256'] ||
        operation.state != CloudOutboxStatus.quarantined.index) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    return (intent: intent, operation: operation, mapping: mapping, message: message, chat: chat);
  }
  final initial = rows();
  if (windowsMessagePreparationSnapshotSha256(intent: initial.intent, operation: initial.operation,
      mapping: initial.mapping) != request['messageSnapshotSha256']) {
    throw StateError('backend_windows_chat_source_binding_changed');
  }
  String immutableRows() {
    final current = rows();
    return _sha(jsonEncode([
      freshGroupRecoveryOperationSnapshot(current.operation), freshGroupRecoveryMapSnapshot(current.mapping),
      current.message.toMap(), current.chat.toMap(),
      current.message.dbAttachments.map((a) => a.toMap()).toList(),
    ]));
  }
  final immutableBefore = immutableRows();
  final authority = ObjectBoxCloudKitWriterAuthority(store: store);
  final writerScope = CloudKitWriterScope(accountFingerprint: auth.accountFingerprint);
  final owner = authority.read(writerScope);
  if (owner == null || owner.owner != CloudKitWriterOwner.v2) {
    throw StateError('cloud_sync_local_send_owner_changed');
  }
  List<Object?> ownerFields(CloudKitWriterAuthoritySnapshot? value) => [
    value?.owner.name, value?.state.name, value?.epoch, value?.ownershipEpoch,
    value?.targetOwner.name, value?.transitionIdHash,
  ];
  final ownerBefore = jsonEncode(ownerFields(owner));
  late final CloudSyncAttachmentUploadJournal uploads;
  final journal = CloudSyncLocalSendJournal(store: store, authority: authority,
    authoritySnapshot: owner, currentAuth: auth, attachmentParentReadback: (id, proof) {
      if (id != intentId || proof == null) throw StateError('cloud_sync_attachment_parent_readback_required');
      uploads.requireParentReadbackProof(localSendIntentId: id, proof: proof);
      return proof;
    });
  uploads = CloudSyncAttachmentUploadJournal(store: store, localSends: journal,
    scope: CloudSyncScope(accountFingerprint: auth.accountFingerprint,
      container: scope.container, database: scope.database, zone: 'attachmentManateeZone',
      persistenceLane: scope.persistenceLane),
    checkpointGeneration: initial.operation.checkpointGeneration, currentAuth: auth);
  final durable = ObjectBoxCloudSyncStore(store: store, localSendJournal: journal,
    attachmentUploadJournal: uploads, protector: RustCloudSyncProtector(storageDirectory: profile));
  final plans = FrbCloudSyncAttachmentPlanSource(storageDirectory: profile);
  CloudSyncRestoredGroupChatProof adoptedGroup() {
    final dependency = journal.readAdoptedAttachmentChatDependency(operationId: operationId, currentAuth: auth);
    final group = requireCloudSyncAdoptedGroupChatProof(store: store,
      messageScope: scope, binding: dependency, expectedChatId: chatId);
    if (group.binding != pinnedGroup.binding || group.generation != pinnedGroup.generation ||
        group.source != pinnedGroup.source || group.routingMetadataDigest != pinnedGroup.routingMetadataDigest) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    return group;
  }
  Future<void> validate() async {
    await validateChat();
    if (!auth.sameIdentity(await provider.capture()) ||
        jsonEncode(ownerFields(authority.read(writerScope))) != ownerBefore || immutableRows() != immutableBefore) {
      throw StateError('backend_windows_chat_source_binding_changed');
    }
    adoptedGroup();
  }
  final fence = CloudSyncLocalSendAuthFence(expected: auth, capture: provider.capture,
    stillCurrent: () => !store.isClosed() && identical(readActiveClient(), client) &&
      jsonEncode(ownerFields(authority.read(writerScope))) == ownerBefore);
  final proofs = <api.CloudSyncAttachmentParentGroupProof>[];
  final diagnostics = <Map<String, Object?>>[];
  var poisoned = false;
  final transport = NativeProtectedCloudSyncTransport(cloudMessagesClient: client,
    storageDirectory: profile, protectedStoreIdentity: auth.protectedStoreIdentity,
    // No writer mutation guard/token is supplied. Only local preparation is available.
    readAttachmentParentContext: (readScope, id) {
      if (readScope != scope || id != operationId || immutableRows() != immutableBefore) {
        throw StateError('backend_windows_chat_source_binding_changed');
      }
      final source = journal.readAdoptedAttachmentSource(operationId: id, currentAuth: auth);
      if (source == null) throw StateError('cloud_sync_local_send_protected_source_missing');
      return plans.receiptContext(source, auth);
    },
    readAttachmentParentGroupProof: (readScope, id) async {
      if (readScope != scope || id != operationId) throw StateError('backend_windows_chat_source_binding_changed');
      await validate();
      return readProofWindow((token) async {
        final group = adoptedGroup();
        final proof = await api.cloudSyncOpenAttachmentParentGroupProof(cloudMessagesClient: client,
          nativeWriterPauseToken: token, storageDirectory: profile,
          expectedAccountFingerprint: auth.accountFingerprint,
          expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
          generation: BigInt.from(group.generation), routingMetadataDigest: group.routingMetadataDigest,
          source: group.source);
        proofs.add(proof); // Own it even if the read-window resume later fails.
        return proof;
      });
    },
    recordCreatePreflightDiagnostic: (value) {
      if (diagnostics.length < 32) diagnostics.add(Map.unmodifiable(value));
    });
  final lifecycle = CloudProtectedPageLeaseLifecycle(store: durable, transport: transport);
  try {
    await validate();
    onStage('message-source-bound');
    await CloudSyncMessagePreparationRecoveryCoordinator(store: durable, transport: transport,
      ensureProtectedStoreRecovered: () async { await validate(); await lifecycle.ensureRecoveredBeforeFetch(); await validate(); },
      verifyRecoveredReceipts: () async { await validate(); await lifecycle.ensureRecoveredBeforeWrite(); await validate(); },
      onUncertainRecovery: () { poisoned = true; },
    ).recover(scope, operationId: operationId, chatId: chatId, intentId: intentId,
      currentAuth: auth, authFence: fence, now: DateTime.now().toUtc());
    onStage('message-owner-committed');
    final outcome = await prepareWindowsMessageWithoutMutation<CloudSyncPreparedSubmission>(
      prepare: () async {
        await validate();
        final origin = durable.readMessagePreparationRecovery(scope, operationId: operationId,
          chatId: chatId, intentId: intentId, currentAuth: auth)!;
        final original = validateMessagePreparationRecoveryReceipt(origin);
        return transport.prepareSubmission(scope,
          submissionIdentity: CloudOutboxSubmissionIdentity(requestUuid: const Uuid().v4().toUpperCase(),
            operationUuids: {operationId: const Uuid().v4().toUpperCase()}),
          operations: [resolveMessagePreparationRecoveryOperation(origin, originalOperation: original)]);
      },
      release: transport.releasePreparedSubmission,
      quiesce: transport.quiesceNativeOperations,
      retain: () async {
        await validate();
        if (poisoned) throw StateError('cloud_sync_message_preparation_recovery_changed');
        final current = durable.readMessagePreparationRecovery(scope, operationId: operationId,
          chatId: chatId, intentId: intentId, currentAuth: auth)!;
        if (current.phase == CloudSyncMessagePreparationRecoveryPhase.committed) {
          durable.advanceMessagePreparationRecoveryPhase(scope, expected: current,
            next: CloudSyncMessagePreparationRecoveryPhase.retained, currentAuth: auth);
        }
        if (immutableRows() != immutableBefore) throw StateError('backend_windows_chat_source_binding_changed');
      }, onStage: onStage);
    return {'schema': 4, 'completed': true, 'rowId': request['rowId'],
      'generation': request['generation'], 'sequence': request['sequence'],
      'messageId': request['messageId'], 'intentId': intentId,
      'originalOpMapMessageUnchanged': true, 'originalIdsEvidencePreserved': true,
      'preflightDiagnostics': diagnostics, ...outcome};
  } finally {
    await transport.quiesceNativeOperations();
    for (final proof in proofs) { proof.dispose(); }
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
