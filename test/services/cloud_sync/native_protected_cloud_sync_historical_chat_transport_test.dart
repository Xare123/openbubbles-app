import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';

// Focused contract for the historical chat-source transport plumbing.
//
// The journal owner supplies the exact historical source for one queued
// chat save; the transport never invents provenance or sender identity.
// Message and attachment lanes never consult the chat reader, and the
// generated pass-through field is exercised with fake bindings here. Native
// source reopening is qualified separately; these tests perform no Apple I/O.
void main() {
  late _ChatBindings bindings;
  late CloudSyncScope chatScope;
  late Directory interlockDirectory;
  late Object activeClient;

  NativeProtectedCloudSyncTransport buildTransport({
    CloudSyncHistoricalChatSourceReader? chatSourceReader,
    NativeProtectedCloudSyncBindings? overrideBindings,
  }) => NativeProtectedCloudSyncTransport(
    cloudMessagesClient: activeClient,
    storageDirectory: 'private-storage',
    protectedStoreIdentity: _storeIdentity,
    bindings: overrideBindings ?? bindings,
    readHistoricalChatSource: chatSourceReader,
  );

  setUp(() async {
    interlockDirectory = await Directory.systemTemp.createTemp(
      'openbubbles-historical-chat-',
    );
    bindings = _ChatBindings();
    activeClient = Object();
    chatScope = _chatScope();
  });

  tearDown(() async {
    if (interlockDirectory.existsSync()) {
      await interlockDirectory.delete(recursive: true);
    }
  });

  Future<T> runV2<T>(Future<T> Function() action) => CloudKitOperationInterlock(
    privateStorageDirectory: interlockDirectory.path,
    fenceStore: InMemoryCloudSyncStore(),
  ).runExclusive(kind: CloudKitOperationKind.v2ReadWrite, action: action);

  frb_api.CloudSyncNativeHistoricalArchiveSourceBinding chatSource() =>
      frb_api.CloudSyncNativeHistoricalArchiveSourceBinding(
        accountFingerprint: _hash('A'),
        protectedStoreIdentity: _storeIdentity,
        snapshotSha256: _sha('a'),
        messageGuidHash: _sha('b'),
        sourceSha256: _sha('c'),
        protectedReference: _reference('P'),
        leaseReference: _lease('a'),
        payloadSha256: _sha('d'),
        payloadLength: 128,
      );

  void reconcileAbsent() {
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: _reference('P'),
    );
    bindings.prepareResult = frb_api.CloudSyncPreparedMessageCreateResult(
      handle: _FakePreparedHandle(),
      handleBindingSha256: _sha('a'),
    );
  }

  test(
    'historical chat source reaches chat prepare and preflight reconcile',
    () async {
      reconcileAbsent();
      final source = chatSource();
      final seenScopes = <CloudSyncScope>[];
      final seenOperationIds = <String>[];
      final transport = buildTransport(
        chatSourceReader: (readScope, operationId) async {
          seenScopes.add(readScope);
          seenOperationIds.add(operationId);
          return source;
        },
      );
      final operation = _chatOperation(chatScope);
      await runV2(
        () => transport.prepareSubmission(
          chatScope,
          submissionIdentity: _submissionIdentity(operation.operationId),
          operations: [_protectedWriteOperation(operation)],
        ),
      );
      expect(seenScopes, [chatScope]);
      expect(seenOperationIds, [operation.operationId]);
      expect(bindings.chatReconcileCalls, 1);
      expect(bindings.chatPrepareCalls, 1);
      expect(
        identical(bindings.chatReconcileInput!.historicalChatSource, source),
        isTrue,
      );
      expect(
        identical(
          bindings.chatPreparedInputs.single.historicalChatSource,
          source,
        ),
        isTrue,
      );
      expect(bindings.chatReconcileInput!.receivedArchiveProof, isNull);
      expect(bindings.chatReconcileInput!.historicalArchiveProof, isNull);
      expect(bindings.chatReconcileInput!.attachmentParentContext, isNull);
      expect(
        bindings.chatPreparedInputs.single.attachmentParentContext,
        isNull,
      );
    },
  );

  test(
    'historical chat source is reopened on confirmed readback without caching',
    () async {
      bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: _reference('P'),
        serverRecordIdHash: _hash('S'),
        etagHash: _hash('E'),
      );
      final source = chatSource();
      var sourceInvocations = 0;
      final transport = buildTransport(
        chatSourceReader: (readScope, operationId) async {
          sourceInvocations++;
          return source;
        },
      );
      final operation = _confirmedChatOperation(chatScope);
      await runV2(
        () => transport.verifyConfirmedChatCreateNoSave(
          chatScope,
          operation: operation,
        ),
      );
      await runV2(
        () => transport.verifyConfirmedChatCreateNoSave(
          chatScope,
          operation: operation,
        ),
      );
      expect(sourceInvocations, 2);
      expect(
        identical(bindings.chatReconcileInput!.historicalChatSource, source),
        isTrue,
      );
    },
  );

  test(
    'message and attachment prepares never consult the chat source reader',
    () async {
      reconcileAbsent();
      var sourceInvocations = 0;
      final transport = buildTransport(
        chatSourceReader: (readScope, operationId) async {
          sourceInvocations++;
          return chatSource();
        },
      );
      final messageScope = _semanticScope(zone: 'messageManateeZone');
      final messageOperation = _messageOperation(messageScope);
      await runV2(
        () => transport.prepareSubmission(
          messageScope,
          submissionIdentity: _submissionIdentity(messageOperation.operationId),
          operations: [_protectedWriteOperation(messageOperation)],
        ),
      );
      final attachmentScope = _semanticScope(zone: 'attachmentManateeZone');
      final attachmentOperation = _attachmentOperation(attachmentScope);
      await runV2(
        () => transport.prepareSubmission(
          attachmentScope,
          submissionIdentity: _submissionIdentity(
            attachmentOperation.operationId,
          ),
          operations: [_protectedWriteOperation(attachmentOperation)],
        ),
      );
      expect(sourceInvocations, 0);
      expect(bindings.preparedInputs.single.historicalChatSource, isNull);
      expect(
        bindings.attachmentPreparedInputs.single.historicalChatSource,
        isNull,
      );
    },
  );

  test('null chat journal answer keeps chat inputs source-free', () async {
    reconcileAbsent();
    var sourceInvocations = 0;
    final transport = buildTransport(
      chatSourceReader: (readScope, operationId) async {
        sourceInvocations++;
        return null;
      },
    );
    final operation = _chatOperation(chatScope);
    await runV2(
      () => transport.prepareSubmission(
        chatScope,
        submissionIdentity: _submissionIdentity(operation.operationId),
        operations: [_protectedWriteOperation(operation)],
      ),
    );
    expect(sourceInvocations, 1);
    expect(bindings.chatReconcileCalls, 1);
    expect(bindings.chatPrepareCalls, 1);
    expect(bindings.chatReconcileInput!.historicalChatSource, isNull);
    expect(bindings.chatPreparedInputs.single.historicalChatSource, isNull);
  });

  test(
    'chat source bound to another account or store fails before native I/O',
    () async {
      reconcileAbsent();
      for (final source in [
        frb_api.CloudSyncNativeHistoricalArchiveSourceBinding(
          accountFingerprint: _hash('Z'),
          protectedStoreIdentity: _storeIdentity,
          snapshotSha256: _sha('a'),
          messageGuidHash: _sha('b'),
          sourceSha256: _sha('c'),
          protectedReference: _reference('P'),
          leaseReference: _lease('a'),
          payloadSha256: _sha('d'),
          payloadLength: 128,
        ),
        frb_api.CloudSyncNativeHistoricalArchiveSourceBinding(
          accountFingerprint: _hash('A'),
          protectedStoreIdentity: 'obcs2.store.${_hash('Z')}',
          snapshotSha256: _sha('a'),
          messageGuidHash: _sha('b'),
          sourceSha256: _sha('c'),
          protectedReference: _reference('P'),
          leaseReference: _lease('a'),
          payloadSha256: _sha('d'),
          payloadLength: 128,
        ),
      ]) {
        final transport = buildTransport(
          chatSourceReader: (readScope, operationId) async => source,
        );
        final operation = _chatOperation(chatScope);
        await expectLater(
          runV2(
            () => transport.prepareSubmission(
              chatScope,
              submissionIdentity: _submissionIdentity(operation.operationId),
              operations: [_protectedWriteOperation(operation)],
            ),
          ),
          throwsA(
            isA<CloudSyncFailure>().having(
              (failure) => failure.safeCode,
              'safeCode',
              'cloud_sync_historical_chat_source_invalid',
            ),
          ),
        );
        expect(bindings.reconcileCalls, 0);
        expect(bindings.prepareCalls, 0);
      }
    },
  );
}

CloudSyncScope _chatScope() => CloudSyncScope(
  accountFingerprint: _hash('A'),
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'chatManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: 2,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

CloudSyncScope _semanticScope({required String zone}) => CloudSyncScope(
  accountFingerprint: _hash('A'),
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: zone,
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: 2,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

String _repeat(String character, int count) =>
    List<String>.filled(count, character).join();
String _hash(String character) => _repeat(character, 43);
String _sha(String character) => _repeat(character, 64);
String _reference(String character) => 'obcs2.ref.${_hash(character)}';
String _lease(String character) => 'obcs2.lease.${_repeat(character, 32)}';
final String _storeIdentity = 'obcs2.store.${_hash('S')}';

CloudOutboxOperation _chatOperation(CloudSyncScope scope) {
  final key = _hash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: key,
      payloadVersion: cloudSyncOutboundChatPayloadVersion,
    ),
    logicalEntityKeyHash: key,
    action: CloudOutboxAction.save,
    payloadVersion: cloudSyncOutboundChatPayloadVersion,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: _reference('P'),
    payloadSha256: _sha('b'),
    serverRecordIdHash: _hash('S'),
    protectedLeaseReference: _lease('a'),
    appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
    dependencyOperationIds: const {},
    createdAt: DateTime.utc(2026, 9, 5),
    status: CloudOutboxStatus.unknownOutcome,
    attemptCount: 1,
  );
}

CloudOutboxOperation _confirmedChatOperation(CloudSyncScope scope) {
  final key = _hash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: key,
      payloadVersion: cloudSyncOutboundChatPayloadVersion,
    ),
    logicalEntityKeyHash: key,
    action: CloudOutboxAction.save,
    payloadVersion: cloudSyncOutboundChatPayloadVersion,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: _reference('P'),
    payloadSha256: _sha('b'),
    serverRecordIdHash: _hash('S'),
    protectedLeaseReference: _lease('a'),
    appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
    dependencyOperationIds: const {},
    createdAt: DateTime.utc(2026, 9, 5),
    status: CloudOutboxStatus.confirmed,
    attemptCount: 1,
  );
}

CloudOutboxOperation _messageOperation(CloudSyncScope scope) {
  final key = _hash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: key,
      payloadVersion: cloudSyncOutboundPayloadVersion,
    ),
    logicalEntityKeyHash: key,
    action: CloudOutboxAction.save,
    payloadVersion: cloudSyncOutboundPayloadVersion,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: _reference('P'),
    payloadSha256: _sha('b'),
    serverRecordIdHash: _hash('S'),
    protectedLeaseReference: _lease('a'),
    appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
    dependencyOperationIds: const {},
    createdAt: DateTime.utc(2026, 9, 5),
    status: CloudOutboxStatus.unknownOutcome,
    attemptCount: 1,
  );
}

CloudOutboxOperation _attachmentOperation(CloudSyncScope scope) {
  final key = _hash('L');
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: scope,
      logicalEntityKeyHash: key,
      payloadVersion: 1,
    ),
    logicalEntityKeyHash: key,
    action: CloudOutboxAction.save,
    payloadVersion: 1,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: _reference('P'),
    payloadSha256: _sha('b'),
    serverRecordIdHash: _hash('S'),
    protectedLeaseReference: _lease('a'),
    appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
    dependencyOperationIds: const {},
    createdAt: DateTime.utc(2026, 9, 5),
    status: CloudOutboxStatus.unknownOutcome,
    attemptCount: 1,
  );
}

CloudSyncProtectedWriteOperation _protectedWriteOperation(
  CloudOutboxOperation operation,
) => CloudSyncProtectedWriteOperation(
  operationId: operation.operationId,
  logicalEntityKeyHash: operation.logicalEntityKeyHash,
  action: operation.action,
  protectedLeaseReference: operation.protectedLeaseReference,
  protectedServerRecordIdReference: operation.encryptedPayloadReference!,
  serverRecordIdHash: operation.serverRecordIdHash!,
  protectedPayloadReference: operation.encryptedPayloadReference,
  payloadSha256: operation.payloadSha256,
);

CloudOutboxSubmissionIdentity _submissionIdentity(String operationId) =>
    CloudOutboxSubmissionIdentity(
      requestUuid: '11111111-2222-4ABC-8DEF-555555555555',
      operationUuids: {operationId: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001'},
    );

final class _FakePreparedHandle
    implements frb_api.CloudSyncPreparedMessageCreateHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ChatBindings
    implements
        NativeProtectedCloudSyncBindings,
        NativeProtectedCloudSyncWriteBindings,
        NativeProtectedCloudSyncAttachmentParentWriteBindings,
        NativeProtectedCloudSyncChatWriteBindings,
        NativeProtectedCloudSyncAttachmentWriteBindings,
        NativeProtectedCloudSyncMessageCreateReadbackBindings {
  int reconcileCalls = 0;
  int prepareCalls = 0;
  int chatReconcileCalls = 0;
  int chatPrepareCalls = 0;
  int attachmentReconcileCalls = 0;
  int attachmentPrepareCalls = 0;

  frb_api.CloudSyncOutboundReconcileResult reconcileResult =
      const frb_api.CloudSyncOutboundReconcileResult();
  frb_api.CloudSyncPreparedMessageCreateResult prepareResult =
      const frb_api.CloudSyncPreparedMessageCreateResult();

  frb_api.CloudSyncPreparedMessageCreateInput? reconcileInput;
  List<frb_api.CloudSyncPreparedMessageCreateInput> preparedInputs = const [];
  frb_api.CloudSyncPreparedMessageCreateInput? chatReconcileInput;
  List<frb_api.CloudSyncPreparedMessageCreateInput> chatPreparedInputs =
      const [];
  frb_api.CloudSyncPreparedMessageCreateInput? attachmentReconcileInput;
  List<frb_api.CloudSyncPreparedMessageCreateInput> attachmentPreparedInputs =
      const [];

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    reconcileCalls++;
    reconcileInput = input;
    return reconcileResult;
  }

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult>
  reconcileMessageCreateWithRawReadback({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required int rawGeneration,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    reconcileCalls++;
    reconcileInput = input;
    return reconcileResult;
  }

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) async {
    prepareCalls++;
    preparedInputs = [...inputs];
    return prepareResult;
  }

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileChatCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    chatReconcileCalls++;
    chatReconcileInput = input;
    return reconcileResult;
  }

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareChatCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) async {
    chatPrepareCalls++;
    chatPreparedInputs = [...inputs];
    return prepareResult;
  }

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileAttachmentCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    attachmentReconcileCalls++;
    attachmentReconcileInput = input;
    return reconcileResult;
  }

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareAttachmentCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) async {
    attachmentPrepareCalls++;
    attachmentPreparedInputs = [...inputs];
    return prepareResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected native call');
}
