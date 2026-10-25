import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_chat_identity_session.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;
import 'package:crypto/crypto.dart';

/// Test-host-only inspection of ONE original protected journal source. This
/// neither projects its decoded payload nor substitutes a newer record map.
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
  return request.length == keys.length &&
      request.keys.every(keys.contains) &&
      request['schema'] == 1 &&
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
  'decode-started',
  'decode-finished',
  'read-released',
};

/// A restored native client is cold until read authentication establishes its
/// account binding. Do not ask capture() to prove that binding first.
Future<T> prepareWindowsChatSourceAuthentication<T>({
  required Object client,
  required Object? Function() readActiveClient,
  required Future<void> Function() ensure,
  required Future<T?> Function() capture,
}) async {
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
}

String safeWindowsChatSourceFailure(Object error) {
  const safe = {
    'backend_windows_chat_source_request_invalid',
    'backend_windows_chat_source_auth_missing',
    'backend_windows_chat_source_binding_changed',
    'backend_windows_chat_source_result_mismatch',
    'backend_windows_chat_source_projection_changed',
    'backend_windows_chat_source_requires_idle',
  };
  return error is StateError && safe.contains(error.message)
      ? error.message
      : 'backend_windows_chat_source_observation_failed';
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
  for (final raw in chat?.participantHandles ?? const <String>[]) {
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
      final counts = [
        store.box<Chat>().count(),
        store.box<Message>().count(),
        store.box<Attachment>().count(),
        store.box<CloudOutboxOperationEntity>().count(),
      ];
      Future<void> validate() async {
        await requireIdle();
        if (store.isClosed() ||
            !auth.sameIdentity(await provider.capture()) ||
            jsonEncode(source().toMapForChatSourceInspection()) != original) {
          throw StateError('backend_windows_chat_source_binding_changed');
        }
      }

      // The existing identity session tolerates a preserved queued outbox. Its
      // v2ReadWrite lock is exclusion only; this callback has no write operation.
      onStage('read-window');
      final session = CloudSyncWriteChatIdentitySession(
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
      );
      final result = await session.run((token) async {
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
      });
      onStage('read-released');
      await validate();
      final after = [
        store.box<Chat>().count(),
        store.box<Message>().count(),
        store.box<Attachment>().count(),
        store.box<CloudOutboxOperationEntity>().count(),
      ];
      if (jsonEncode(counts) != jsonEncode(after)) {
        throw StateError('backend_windows_chat_source_projection_changed');
      }
      return {
        'schema': 1,
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
