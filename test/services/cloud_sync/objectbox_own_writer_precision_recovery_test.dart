import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_own_writer_precision_recovery.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/transient_cloud_canonical_identity_registry.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

String hex(String value) => sha256.convert(utf8.encode(value)).toString();
String ref(String value) => 'obcs2.ref.${value * 43}';

void main() {
  late Directory directory;
  late Store db;
  late _Decoder decoder;
  late int localId;
  var accountCurrent = true;
  var echoProven = true;
  final scope = CloudSyncScope(
    accountFingerprint: 'A' * 43,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final operationId = CloudOperationIdentity.forMutation(
    scope: scope,
    logicalEntityKeyHash: 'L' * 43,
    action: CloudOutboxAction.save,
    payloadVersion: cloudSyncMessageUpdatePayloadVersion,
    mutationRevision: 1,
    payloadSha256: 'f' * 64,
  );
  const fence = CloudCoordinatorLeaseFence(
    ownerId: 'precision-test',
    generation: 1,
  );
  String scoped(String purpose, String value) =>
      '$purpose:${hex('${scope.storageKey}\u001f$purpose\u001f$value')}';
  CloudInboxChangeEntity row() =>
      db.box<CloudInboxChangeEntity>().getAll().first;
  ObjectBoxOwnWriterPrecisionRecovery recovery() =>
      ObjectBoxOwnWriterPrecisionRecovery(
        store: db,
        decoder: decoder,
        canonicalAdapter: _Adapter(db),
        identityRegistrar: TransientCloudCanonicalIdentityRegistry(),
        proveEcho: (_) => echoProven ? localId : null,
        revalidateAccount: () async => accountCurrent,
        clock: () => DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
      );
  Future<bool> run() =>
      recovery().requeueOwnWriterPrecisionBarrier(scope, leaseFence: fence);

  setUp(() async {
    directory = Directory.systemTemp.createTempSync(
      'own-writer-precision-test-',
    );
    db = await openStore(directory: directory.path);
    accountCurrent = true;
    echoProven = true;
    localId = db.box<Message>().put(
      Message(guid: 'own-message', isFromMe: true),
    );
    final message = db.box<Message>().get(localId)!;
    final chatId = db.box<Chat>().put(Chat(guid: 'own-chat'));
    message.chat.targetId = chatId;
    db.box<Message>().put(message);
    db.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: 2,
        persistenceLane: scope.persistenceLane.name,
        generation: 1,
        fetchedSequence: 1,
        appliedSequence: 0,
        pendingBatchId: 'page',
        pendingFetchedTokenCiphertext: 'pending-token',
        updatedAtMs: 2000,
      ),
    );
    db.box<CloudSyncLeaseEntity>().put(
      CloudSyncLeaseEntity(
        leaseKey: scoped('coordinator-lease', 'v1'),
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        ownerIdHash: hex('coordinator-owner\u001f${fence.ownerId}'),
        generation: 1,
        acquiredAtMs: 1000,
        expiresAtMs: 10000,
      ),
    );
    db.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: scoped('change', 'C' * 43),
        changeIdHash: 'C' * 43,
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        serverRecordIdHash: 'R' * 43,
        etagHash: 'E' * 43,
        changeType: 'save',
        encryptedServerRecordId: ref('I'),
        protectedSystemFieldsRef: ref('S'),
        encryptedPayloadRef: ref('P'),
        payloadSha256: 'a' * 64,
        batchId: 'page',
        generation: 1,
        fetchSequence: 1,
        status: 2,
        failureCategory: 'conflict',
        retryCount: 1,
        createdAtMs: 1500,
        updatedAtMs: 2000,
        completedAtMs: 2000,
      ),
    );
    db.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: cloudSyncCanonicalRecordMapKey(scope, 'L' * 43),
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        logicalEntityKeyHash: 'L' * 43,
        serverRecordIdHash: 'R' * 43,
        encryptedServerRecordId: ref('J'),
        generation: 1,
        etagHash: 'E' * 43,
        encryptedRawRecordRef: ref('M'),
        rawRecordGeneration: 1,
        updatedAtMs: 1000,
      ),
    );
    final source = CloudSyncLocalMutationSourceBinding(
      accountFingerprint: scope.accountFingerprint,
      protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
      mutationGuidHash: 'b' * 64,
      targetGuidHash: hex(
        jsonEncode(['cloud-sync-local-send-guid-v1', 'own-message']),
      ),
      targetPart: 0,
      sourceSha256: 'c' * 64,
      protectedReference: ref('U'),
      leaseReference: 'obcs2.lease.${'d' * 32}',
      payloadSha256: 'e' * 64,
      payloadLength: 123,
    );
    db.box<CloudSyncLocalMutationIntentEntity>().put(
      CloudSyncLocalMutationIntentEntity(
        intentKey: hex(
          jsonEncode([
            'cloud-sync-local-mutation-intent-v1',
            scope.accountFingerprint,
            source.mutationGuidHash,
          ]),
        ),
        accountFingerprint: scope.accountFingerprint,
        writerEpoch: 1,
        localMessageId: localId,
        localChatId: chatId,
        mutationGuidHash: source.mutationGuidHash,
        targetGuidHash: source.targetGuidHash,
        targetPart: 0,
        kind: 0,
        sourceSha256: source.sourceSha256,
        targetSnapshotSha256: 'f' * 64,
        protectedSourceBinding: source.encode(),
        state: 5,
        submissionAuthBindingSha256: 'a' * 64,
        idsReceiptBindingSha256: 'b' * 64,
        reflectedSnapshotSha256: cloudSyncPrecisionEchoReflectedSnapshotDigest(
          message,
        ),
        admittedOperationId: operationId,
        admittedBindingSha256: 'e' * 64,
        createdAtMs: 500,
        updatedAtMs: 1001,
      ),
    );
    db.box<CloudOutboxOperationEntity>().put(
      CloudOutboxOperationEntity(
        operationId: operationId,
        scopeKey: scopeKey,
        encryptedPayloadRef: ref('V'),
        payloadSha256: 'f' * 64,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        logicalEntityKeyHash: 'L' * 43,
        serverRecordIdHash: 'R' * 43,
        action: 0,
        payloadVersion: cloudSyncMessageUpdatePayloadVersion,
        mutationRevision: 1,
        checkpointGeneration: 1,
        state: 2,
        confirmedAtMs: 1000,
        appleRequestUuid: '11111111-1111-4111-8111-111111111111',
        appleOperationUuid: '22222222-2222-4222-8222-222222222222',
        createdAtMs: 500,
        updatedAtMs: 1000,
      ),
    );
    decoder = _Decoder();
  });
  tearDown(() async {
    db.close();
    await directory.delete(recursive: true);
  });

  test(
    'same-version finalized map and one source decode requeue once across restart',
    () async {
      expect(await run(), isTrue);
      expect(decoder.references, [ref('P')]);
      expect(row().status, 0);
      expect(row().retryCount, 2);
      expect(row().failureCategory, 'conflict');
      expect(row().completedAtMs, 2000); // Original failed evidence retained.
      expect(row().payloadSha256, 'a' * 64);
      expect(db.box<CloudSemanticReplayEntity>().count(), 0);
      expect(
        db.box<CloudRecordMapEntity>().getAll().single.encryptedRawRecordRef,
        ref('M'),
      );
      expect(
        db
            .box<CloudSyncCheckpointEntity>()
            .getAll()
            .single
            .pendingFetchedTokenCiphertext,
        'pending-token',
      );
      expect(
        db.box<CloudSyncCheckpointEntity>().getAll().single.appliedSequence,
        0,
      );
      db.close();
      db = await openStore(directory: directory.path);
      expect(await run(), isFalse);
      expect(decoder.references.length, 1);
      // Simulate the normal failure after the reserved retry, not a migration.
      db.box<CloudInboxChangeEntity>().put(
        row()
          ..status = 2
          ..retryCount = 3
          ..completedAtMs = 2500
          ..updatedAtMs = 2500,
      );
      expect(await run(), isFalse);
      expect(decoder.references.length, 1);
    },
  );

  test(
    'different mapped envelope is preserved and never decoded or consumed',
    () async {
      final mappedReference = db
          .box<CloudRecordMapEntity>()
          .getAll()
          .single
          .encryptedRawRecordRef;
      expect(mappedReference, isNot(row().encryptedPayloadRef));
      decoder.forbiddenReference = mappedReference;
      expect(await run(), isTrue);
      expect(decoder.references, [row().encryptedPayloadRef]);
      expect(
        db.box<CloudRecordMapEntity>().getAll().single.encryptedRawRecordRef,
        mappedReference,
      );
      expect(db.box<CloudRecordMapEntity>().getAll().single.etagHash, 'E' * 43);
      expect(db.box<CloudOutboxOperationEntity>().getAll().single.state, 2);
      expect(
        db.box<CloudSyncLocalMutationIntentEntity>().getAll().single.state,
        5,
      );
      expect(db.box<CloudSemanticReplayEntity>().count(), 0);
      expect(row().status, 0);
    },
  );

  test(
    'retained predecessor is not mistaken for the quarantine head',
    () async {
      final target = row()..fetchSequence = 2;
      db.box<CloudInboxChangeEntity>().put(target);
      db.box<CloudInboxChangeEntity>().put(
        row()
          ..id = 0
          ..changeKey = 'retained-predecessor'
          ..changeIdHash = 'D' * 43
          ..fetchSequence = 1
          ..status = 3,
      );
      db.box<CloudSyncCheckpointEntity>().put(
        db.box<CloudSyncCheckpointEntity>().getAll().single
          ..fetchedSequence = 2,
      );
      expect(await run(), isTrue);
      expect(db.box<CloudInboxChangeEntity>().get(target.id)!.status, 0);
      expect(
        db.box<CloudSyncCheckpointEntity>().getAll().single.appliedSequence,
        0,
      );
    },
  );

  for (final fault in [
    'source raw provenance',
    'account',
    'echo',
    'source race',
    'map race',
    'lease race',
    'pending readback',
    'wrong etag',
    'nonterminal intent',
    'wrong batch',
    'missing token',
    'retry spent',
    'generation',
    'checkpoint crossed',
    'semantic replay',
    'change replay at other sequence',
    'changed local reflection',
    'different readback time',
    'finalized operation record mismatch',
    'finalized operation generation mismatch',
    'finalized operation identity mismatch',
    'map physical mismatch',
    'map logical mismatch',
    'pending outbox',
    'other confirmed readback pending',
    'duplicate physical map',
    'journal gap',
  ]) {
    test('rejects $fault without reopening quarantine', () async {
      switch (fault) {
        case 'source raw provenance':
          decoder.rejectSource = true;
        case 'account':
          accountCurrent = false;
        case 'echo':
          echoProven = false;
        case 'source race':
          decoder.onSourceCompletion = () => db
              .box<CloudInboxChangeEntity>()
              .put(row()..payloadSha256 = 'b' * 64);
        case 'map race':
          decoder.onSourceCompletion = () => db.box<CloudRecordMapEntity>().put(
            db.box<CloudRecordMapEntity>().getAll().single
              ..encryptedRawRecordRef = ref('N'),
          );
        case 'lease race':
          decoder.onSourceCompletion = () => db.box<CloudSyncLeaseEntity>().put(
            db.box<CloudSyncLeaseEntity>().getAll().single..expiresAtMs = 2500,
          );
        case 'pending readback':
          db.box<CloudRecordMapEntity>().put(
            db.box<CloudRecordMapEntity>().getAll().single
              ..pendingUpdateOperationId = 'pending',
          );
        case 'wrong etag':
          db.box<CloudRecordMapEntity>().put(
            db.box<CloudRecordMapEntity>().getAll().single..etagHash = 'F' * 43,
          );
        case 'nonterminal intent':
          db.box<CloudSyncLocalMutationIntentEntity>().put(
            db.box<CloudSyncLocalMutationIntentEntity>().getAll().single
              ..state = 4,
          );
        case 'wrong batch':
          db.box<CloudInboxChangeEntity>().put(row()..batchId = 'other');
        case 'missing token':
          db.box<CloudSyncCheckpointEntity>().put(
            db.box<CloudSyncCheckpointEntity>().getAll().single
              ..pendingFetchedTokenCiphertext = null,
          );
        case 'retry spent':
          db.box<CloudInboxChangeEntity>().put(row()..retryCount = 2);
        case 'generation':
          db.box<CloudSyncCheckpointEntity>().put(
            db.box<CloudSyncCheckpointEntity>().getAll().single..generation = 2,
          );
        case 'checkpoint crossed':
          db.box<CloudSyncCheckpointEntity>().put(
            db.box<CloudSyncCheckpointEntity>().getAll().single
              ..appliedSequence = 1,
          );
        case 'semantic replay':
        case 'change replay at other sequence':
          db.box<CloudSemanticReplayEntity>().put(
            CloudSemanticReplayEntity(
              replayKey: 'existing-replay',
              scopeGenerationKey: 'generation',
              scopeKey: scopeKey,
              accountFingerprint: scope.accountFingerprint,
              container: scope.container,
              database: scope.database,
              zone: scope.zone,
              streamKind: scope.streamKind.name,
              schemaVersion: 2,
              generation: 1,
              changeIdHash: hex(row().changeIdHash),
              serverRecordIdHash: row().serverRecordIdHash,
              inboxSequence: fault == 'semantic replay' ? 1 : 2,
              changeType: 'save',
              terminalOutcome: 'quarantined',
              updatedAtMs: 2000,
            ),
          );
        case 'changed local reflection':
          db.box<Message>().put(
            db.box<Message>().get(localId)!..text = 'changed after readback',
          );
        case 'different readback time':
          db.box<CloudRecordMapEntity>().put(
            db.box<CloudRecordMapEntity>().getAll().single..updatedAtMs = 1002,
          );
        case 'finalized operation record mismatch':
          db.box<CloudOutboxOperationEntity>().put(
            db.box<CloudOutboxOperationEntity>().getAll().single
              ..serverRecordIdHash = 'Q' * 43,
          );
        case 'finalized operation generation mismatch':
          db.box<CloudOutboxOperationEntity>().put(
            db.box<CloudOutboxOperationEntity>().getAll().single
              ..checkpointGeneration = 2,
          );
        case 'finalized operation identity mismatch':
          db.box<CloudSyncLocalMutationIntentEntity>().put(
            db.box<CloudSyncLocalMutationIntentEntity>().getAll().single
              ..admittedOperationId = 'op1:${'8' * 64}',
          );
        case 'map physical mismatch':
          db.box<CloudRecordMapEntity>().put(
            db.box<CloudRecordMapEntity>().getAll().single
              ..serverRecordIdHash = 'Q' * 43,
          );
        case 'map logical mismatch':
          db.box<CloudRecordMapEntity>().put(
            db.box<CloudRecordMapEntity>().getAll().single
              ..logicalEntityKeyHash = 'Q' * 43
              ..mapKey = cloudSyncCanonicalRecordMapKey(scope, 'Q' * 43),
          );
        case 'pending outbox':
          db.box<CloudOutboxOperationEntity>().put(
            db.box<CloudOutboxOperationEntity>().getAll().single..state = 5,
          );
        case 'other confirmed readback pending':
          db.box<CloudOutboxOperationEntity>().put(
            db.box<CloudOutboxOperationEntity>().getAll().single
              ..id = 0
              ..operationId = 'op1:${'9' * 64}'
              ..protectedLeaseReference = 'obcs2.lease.${'9' * 32}',
          );
        case 'duplicate physical map':
          db.box<CloudRecordMapEntity>().put(
            db.box<CloudRecordMapEntity>().getAll().single
              ..id = 0
              ..mapKey = 'duplicate-map',
          );
        case 'journal gap':
          db.box<CloudInboxChangeEntity>().put(row()..fetchSequence = 2);
      }
      final replayCount = db.box<CloudSemanticReplayEntity>().count();
      expect(await run(), isFalse);
      if ([
        'source raw provenance',
        'source race',
        'map race',
        'lease race',
      ].contains(fault)) {
        expect(decoder.references, [ref('P')]);
      }
      expect(row().status, 2);
      expect(row().completedAtMs, 2000);
      expect(db.box<CloudSemanticReplayEntity>().count(), replayCount);
    });
  }
}

final class _Decoder implements CloudSemanticDecoder {
  final references = <String?>[];
  bool rejectSource = false;
  String? forbiddenReference;
  void Function()? onSourceCompletion;
  @override
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry) async {
    references.add(entry.change.encryptedPayloadReference);
    if (forbiddenReference != null &&
        entry.change.encryptedPayloadReference == forbiddenReference) {
      fail('The mapped readback envelope must not be decoded or consumed.');
    }
    if (rejectSource) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.conflict,
        safeCode: 'native_failure_protected_reference_mismatch',
      );
    }
    final decoded = CloudDecodedMutation.upsert(
      scope: entry.scope,
      generation: entry.generation,
      changeId: entry.change.changeId,
      snapshot: CloudSemanticSnapshot(
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'L' * 43,
        etagHash: entry.change.etagHash,
        encryptedRawRecordReference: entry.change.encryptedPayloadReference,
      ),
      payload: CloudMessageEntityPayload(
        logicalEntityKeyHash: 'L' * 43,
        canonicalGuid: 'own-message',
        chatAliasKeyHash: 'H' * 43,
        chatIdentifier: 'chat',
        body: 'edit',
        senderHandle: '',
      ),
    );
    if (references.length == 1) {
      onSourceCompletion?.call();
    }
    return decoded;
  }
}

final class _Adapter implements CloudCanonicalSemanticEntityAdapter {
  _Adapter(this.store);
  @override
  final Store store;
  @override
  bool isActiveAccountScope({
    required CloudSyncScope scope,
    required int generation,
  }) => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
