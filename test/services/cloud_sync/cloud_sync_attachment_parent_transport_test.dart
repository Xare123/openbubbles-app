import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';

// Focused contract for source-bound attachment-parent transport plumbing.
//
// The journal owner supplies the exact source receipt context; the transport
// never sniffs bodies or GUIDs to infer parenthood. Parent staging is an
// explicit capability, separate from final Attachment record saves.
void main() {
  late _ParentBindings bindings;
  late CloudSyncScope scope;
  late Directory interlockDirectory;
  late Object activeClient;

  NativeProtectedCloudSyncTransport buildTransport({
    CloudSyncAttachmentParentContextReader? reader,
    CloudSyncAttachmentParentGroupProofReader? proofReader,
    NativeProtectedCloudSyncBindings? overrideBindings,
  }) => NativeProtectedCloudSyncTransport(
    cloudMessagesClient: activeClient,
    storageDirectory: 'private-storage',
    protectedStoreIdentity: _storeIdentity,
    bindings: overrideBindings ?? bindings,
    readAttachmentParentContext: reader,
    readAttachmentParentGroupProof: proofReader,
  );

  setUp(() async {
    interlockDirectory = await Directory.systemTemp.createTemp(
      'openbubbles-attachment-parent-',
    );
    bindings = _ParentBindings();
    activeClient = Object();
    scope = _messageScope();
  });

  tearDown(() async {
    if (interlockDirectory.existsSync()) {
      await interlockDirectory.delete(recursive: true);
    }
  });

  Future<T> runV2<T>(Future<T> Function() action) =>
      CloudKitOperationInterlock(
        privateStorageDirectory: interlockDirectory.path,
        fenceStore: InMemoryCloudSyncStore(),
      ).runExclusive(kind: CloudKitOperationKind.v2ReadWrite, action: action);

  frb_api.CloudSyncNativeSendReceiptContext parentContext() =>
      frb_api.CloudSyncNativeSendReceiptContext(
        storageDirectory: 'private-storage',
        guidHash: _sha('1'),
        accountFingerprint: scope.accountFingerprint,
        protectedStoreIdentity: _storeIdentity,
        nativeSessionId: _hash('N'),
        sourceBinding: frb_api.CloudSyncNativeSendSourceBinding(
          sourceSha256: _sha('2'),
          protectedReference: _reference('P'),
          leaseReference: _lease('a'),
          payloadSha256: _sha('3'),
          payloadLength: BigInt.from(256),
        ),
      );

  void stageSuccess() {
    bindings.stageResult = frb_api.CloudSyncProtectedOutboundStageResult(
      stage: frb_api.CloudSyncProtectedOutboundStage(
        logicalEntityKeyHash: _hash('L'),
        protectedPayloadReference: _reference('P'),
        payloadSha256: _sha('b'),
        payloadLength: BigInt.from(256),
        protectedServerRecordReference: _reference('P'),
        serverRecordIdHash: _hash('S'),
        leaseReference: _lease('a'),
      ),
    );
  }

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

  test('staging forwards the exact source receipt context and headers', () async {
    stageSuccess();
    final transport = buildTransport();
    expect(
      transport,
      isA<CloudSyncOutboundAttachmentParentStagingTransport>(),
    );
    final context = parentContext();
    final headers = _FakeCloudMessage();
    final staged = await runV2(
      () => transport.stageOutboundAttachmentParent(
        scope,
        messageHeaders: headers,
        context: context,
      ),
    );
    expect(staged.protectedEnvelopeReference, _reference('P'));
    expect(staged.leaseReference, _lease('a'));
    expect(bindings.parentStageCalls, 1);
    expect(bindings.stageCalls, 0);
    expect(identical(bindings.parentContext, context), isTrue);
    expect(identical(bindings.parentHeaders, headers), isTrue);
    expect(bindings.parentStorageDirectory, 'private-storage');
    expect(bindings.parentAccountFingerprint, scope.accountFingerprint);
    expect(bindings.parentStoreIdentity, _storeIdentity);
  });

  test('staging rejects a context bound to another account, store, or directory',
      () async {
    stageSuccess();
    final transport = buildTransport();
    final exact = parentContext();
    final wrongAccount = frb_api.CloudSyncNativeSendReceiptContext(
      storageDirectory: exact.storageDirectory,
      guidHash: exact.guidHash,
      accountFingerprint: _hash('Z'),
      protectedStoreIdentity: exact.protectedStoreIdentity,
      nativeSessionId: exact.nativeSessionId,
    );
    final wrongStore = frb_api.CloudSyncNativeSendReceiptContext(
      storageDirectory: exact.storageDirectory,
      guidHash: exact.guidHash,
      accountFingerprint: exact.accountFingerprint,
      protectedStoreIdentity: 'obcs2.store.${_hash('Z')}',
      nativeSessionId: exact.nativeSessionId,
    );
    final wrongDirectory = frb_api.CloudSyncNativeSendReceiptContext(
      storageDirectory: 'elsewhere',
      guidHash: exact.guidHash,
      accountFingerprint: exact.accountFingerprint,
      protectedStoreIdentity: exact.protectedStoreIdentity,
      nativeSessionId: exact.nativeSessionId,
    );
    for (final context in [wrongAccount, wrongStore, wrongDirectory]) {
      await expectLater(
        runV2(
          () => transport.stageOutboundAttachmentParent(
            scope,
            messageHeaders: _FakeCloudMessage(),
            context: context,
          ),
        ),
        throwsA(isA<CloudSyncFailure>()),
      );
    }
    expect(bindings.parentStageCalls, 0);
  });

  test('Message-only bindings cannot stage an attachment parent', () async {
    final transport = buildTransport(
      overrideBindings: _MessageOnlyBindings(),
    );
    await expectLater(
      runV2(
        () => transport.stageOutboundAttachmentParent(
          scope,
          messageHeaders: _FakeCloudMessage(),
          context: parentContext(),
        ),
      ),
      throwsA(isA<CloudSyncFailure>()),
    );
  });

  test('staging forwards an optional group proof', () async {
    stageSuccess();
    final transport = buildTransport();
    final proof = _FakeGroupProof();
    final staged = await runV2(
      () => transport.stageOutboundAttachmentParent(
        scope,
        messageHeaders: _FakeCloudMessage(),
        context: parentContext(),
        groupProof: proof,
      ),
    );
    expect(staged.protectedEnvelopeReference, _reference('P'));
    expect(bindings.parentStageCalls, 1);
    expect(identical(bindings.parentGroupProof, proof), isTrue);
  });

  test('staging without a proof forwards a null group proof', () async {
    stageSuccess();
    final transport = buildTransport();
    await runV2(
      () => transport.stageOutboundAttachmentParent(
        scope,
        messageHeaders: _FakeCloudMessage(),
        context: parentContext(),
      ),
    );
    expect(bindings.parentStageCalls, 1);
    expect(bindings.parentGroupProof, isNull);
  });

  test('prepare and reconcile preserve the journal-supplied parent context',
      () async {
    reconcileAbsent();
    final context = parentContext();
    final seenScopes = <CloudSyncScope>[];
    final seenOperationIds = <String>[];
    final transport = buildTransport(
      reader: (readScope, operationId) {
        seenScopes.add(readScope);
        seenOperationIds.add(operationId);
        return context;
      },
    );
    final operation = _messageOperation(scope);
    await runV2(
      () => transport.prepareSubmission(
        scope,
        submissionIdentity: _submissionIdentity(operation.operationId),
        operations: [_protectedWriteOperation(operation)],
      ),
    );
    expect(seenScopes, [scope]);
    expect(seenOperationIds, [operation.operationId]);
    expect(bindings.reconcileCalls, 1);
    expect(bindings.prepareCalls, 1);
    expect(bindings.reconcileInput!.attachmentParentContext, context);
    expect(bindings.preparedInputs.single.attachmentParentContext, context);
    expect(
      bindings.preparedInputs.single.localOperationId,
      operation.operationId,
    );
  });

  test('prepare and reconcile attach the reopened group proof', () async {
    reconcileAbsent();
    final context = parentContext();
    final proof = _FakeGroupProof();
    var proofInvocations = 0;
    final transport = buildTransport(
      reader: (readScope, operationId) => context,
      proofReader: (readScope, operationId) async {
        proofInvocations++;
        return proof;
      },
    );
    final operation = _messageOperation(scope);
    await runV2(
      () => transport.prepareSubmission(
        scope,
        submissionIdentity: _submissionIdentity(operation.operationId),
        operations: [_protectedWriteOperation(operation)],
      ),
    );
    expect(proofInvocations, 1);
    expect(identical(bindings.reconcileInput!.attachmentParentGroupProof, proof), isTrue);
    expect(
      identical(bindings.preparedInputs.single.attachmentParentGroupProof, proof),
      isTrue,
    );
  });

  test('a context change across the proof await fails closed', () async {
    reconcileAbsent();
    final before = parentContext();
    final after = frb_api.CloudSyncNativeSendReceiptContext(
      storageDirectory: before.storageDirectory,
      guidHash: _sha('2'),
      accountFingerprint: before.accountFingerprint,
      protectedStoreIdentity: before.protectedStoreIdentity,
      nativeSessionId: before.nativeSessionId,
      sourceBinding: before.sourceBinding,
    );
    var reads = 0;
    final transport = buildTransport(
      reader: (readScope, operationId) => ++reads == 1 ? before : after,
      proofReader: (readScope, operationId) async => _FakeGroupProof(),
    );
    final operation = _messageOperation(scope);
    await expectLater(
      runV2(
        () => transport.prepareSubmission(
          scope,
          submissionIdentity: _submissionIdentity(operation.operationId),
          operations: [_protectedWriteOperation(operation)],
        ),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_sync_outbound_parent_context_changed',
        ),
      ),
    );
    expect(bindings.reconcileCalls, 0);
    expect(bindings.prepareCalls, 0);
  });

  test('the proof opener is never consulted without a context', () async {
    reconcileAbsent();
    var proofInvocations = 0;
    final transport = buildTransport(
      reader: (readScope, operationId) => null,
      proofReader: (readScope, operationId) async {
        proofInvocations++;
        return _FakeGroupProof();
      },
    );
    final operation = _messageOperation(scope);
    await runV2(
      () => transport.prepareSubmission(
        scope,
        submissionIdentity: _submissionIdentity(operation.operationId),
        operations: [_protectedWriteOperation(operation)],
      ),
    );
    expect(proofInvocations, 0);
    expect(bindings.reconcileCalls, 1);
    expect(bindings.prepareCalls, 1);
    expect(bindings.reconcileInput!.attachmentParentGroupProof, isNull);
    expect(bindings.preparedInputs.single.attachmentParentGroupProof, isNull);
  });

  test('null journal answer keeps message inputs context-free', () async {
    reconcileAbsent();
    var callbackInvocations = 0;
    final transport = buildTransport(
      reader: (readScope, operationId) {
        callbackInvocations++;
        return null;
      },
    );
    final operation = _messageOperation(scope);
    await runV2(
      () => transport.prepareSubmission(
        scope,
        submissionIdentity: _submissionIdentity(operation.operationId),
        operations: [_protectedWriteOperation(operation)],
      ),
    );
    expect(callbackInvocations, 1);
    expect(bindings.reconcileCalls, 1);
    expect(bindings.prepareCalls, 1);
    expect(bindings.reconcileInput!.attachmentParentContext, isNull);
    expect(bindings.preparedInputs.single.attachmentParentContext, isNull);
  });

  test('post-restart confirmed readback carries the parent context', () async {
    // A confirmed operation re-resolved after restart, with no prepared
    // submission alive: the readback path builds its own native input
    // rather than reusing the prepare preflight one. This test covers that
    // input; the prepare tests alone do not prove reconciliation coverage.
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
      protectedProofReference: _reference('P'),
      serverRecordIdHash: _hash('S'),
      etagHash: _hash('E'),
    );
    final context = parentContext();
    var callbackInvocations = 0;
    final transport = buildTransport(
      reader: (readScope, operationId) {
        callbackInvocations++;
        return context;
      },
    );
    final operation = _confirmedMessageOperation(scope);
    final proof = await runV2(
      () => transport.verifyConfirmedMessageCreateNoSave(
        scope,
        operation: operation,
      ),
    );
    expect(proof, isA<CloudSyncConfirmedReplayProof>());
    expect(callbackInvocations, 1);
    expect(bindings.reconcileCalls, 1);
    expect(bindings.prepareCalls, 0);
    expect(bindings.reconcileInput!.attachmentParentContext, context);
    expect(
      bindings.reconcileInput!.localOperationId,
      operation.operationId,
    );
  });

  test('post-restart readback reopens the group proof without caching', () async {
    bindings.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
      protectedProofReference: _reference('P'),
      serverRecordIdHash: _hash('S'),
      etagHash: _hash('E'),
    );
    final context = parentContext();
    final proof = _FakeGroupProof();
    var proofInvocations = 0;
    final transport = buildTransport(
      reader: (readScope, operationId) => context,
      proofReader: (readScope, operationId) async {
        proofInvocations++;
        return proof;
      },
    );
    final operation = _confirmedMessageOperation(scope);
    await runV2(
      () => transport.verifyConfirmedMessageCreateNoSave(
        scope,
        operation: operation,
      ),
    );
    await runV2(
      () => transport.verifyConfirmedMessageCreateNoSave(
        scope,
        operation: operation,
      ),
    );
    expect(proofInvocations, 2);
    expect(identical(bindings.reconcileInput!.attachmentParentGroupProof, proof), isTrue);
  });

  test('Chat and Attachment prepares never consult the proof opener', () async {
    reconcileAbsent();
    var proofInvocations = 0;
    final transport = buildTransport(
      reader: (readScope, operationId) => parentContext(),
      proofReader: (readScope, operationId) async {
        proofInvocations++;
        return _FakeGroupProof();
      },
    );
    final chatScope = _semanticScope(zone: 'chatManateeZone');
    await runV2(
      () => transport.prepareSubmission(
        chatScope,
        submissionIdentity: _submissionIdentity(
          _chatOperation(chatScope).operationId,
        ),
        operations: [_protectedWriteOperation(_chatOperation(chatScope))],
      ),
    );
    final attachmentScope = _semanticScope(zone: 'attachmentManateeZone');
    await runV2(
      () => transport.prepareSubmission(
        attachmentScope,
        submissionIdentity: _submissionIdentity(
          _attachmentOperation(attachmentScope).operationId,
        ),
        operations: [
          _protectedWriteOperation(_attachmentOperation(attachmentScope)),
        ],
      ),
    );
    expect(proofInvocations, 0);
  });

  test('no-callback message prepare stays context-free', () async {
    reconcileAbsent();
    final transport = buildTransport();
    final operation = _messageOperation(scope);
    await runV2(
      () => transport.prepareSubmission(
        scope,
        submissionIdentity: _submissionIdentity(operation.operationId),
        operations: [_protectedWriteOperation(operation)],
      ),
    );
    expect(bindings.reconcileCalls, 1);
    expect(bindings.prepareCalls, 1);
    expect(bindings.reconcileInput!.attachmentParentContext, isNull);
    expect(bindings.preparedInputs.single.attachmentParentContext, isNull);
  });

  test('Chat and Attachment prepares never consult the parent callback',
      () async {
    reconcileAbsent();
    var callbackInvocations = 0;
    final transport = buildTransport(
      reader: (readScope, operationId) {
        callbackInvocations++;
        return parentContext();
      },
    );
    final chatScope = _semanticScope(zone: 'chatManateeZone');
    final chatOperation = _chatOperation(chatScope);
    await runV2(
      () => transport.prepareSubmission(
        chatScope,
        submissionIdentity: _submissionIdentity(chatOperation.operationId),
        operations: [_protectedWriteOperation(chatOperation)],
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
    expect(callbackInvocations, 0);
    expect(bindings.chatReconcileCalls, 1);
    expect(bindings.chatPrepareCalls, 1);
    expect(bindings.attachmentReconcileCalls, 1);
    expect(bindings.attachmentPrepareCalls, 1);
    expect(bindings.chatReconcileInput!.attachmentParentContext, isNull);
    expect(
      bindings.chatPreparedInputs.single.attachmentParentContext,
      isNull,
    );
    expect(bindings.attachmentReconcileInput!.attachmentParentContext, isNull);
    expect(
      bindings.attachmentPreparedInputs.single.attachmentParentContext,
      isNull,
    );
  });
}
CloudSyncScope _messageScope() => CloudSyncScope(
  accountFingerprint: _hash('A'),
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: 2,
  persistenceLane: CloudSyncPersistenceLane.shadow,
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

CloudOutboxOperation _confirmedMessageOperation(CloudSyncScope scope) {
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
    status: CloudOutboxStatus.confirmed,
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

final class _FakeCloudMessage implements frb_api.CloudMessage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakePreparedHandle
    implements frb_api.CloudSyncPreparedMessageCreateHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeGroupProof
    implements frb_api.CloudSyncAttachmentParentGroupProof {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _MessageOnlyBindings
    implements
        NativeProtectedCloudSyncBindings,
        NativeProtectedCloudSyncWriteBindings {
  @override
  Future<NativeProtectedFetchResult> fetchProtectedPage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String stream,
    required int generation,
    required String? previousCheckpointReference,
    required int maximumChanges,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedFetchResult> fetchProtectedPageUnderWriterPause({
    required Object cloudMessagesClient,
    required BigInt nativeWriterPauseToken,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String stream,
    required int generation,
    required String? previousCheckpointReference,
    required int maximumChanges,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedLeaseResult> commitProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
    required List<String> retainedReferences,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedLeaseResult> acknowledgeCommittedPageLease({
    required String storageDirectory,
    required String leaseReference,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedLeaseResult> rollbackProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedRecoveryResult> recoverProtectedPageLeases({
    required String storageDirectory,
    required List<String> adoptedLeaseReferences,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedRetirementResult> retireProtectedReferences({
    required String storageDirectory,
    required List<String> references,
  }) => throw UnimplementedError();

  @override
  Future<NativeProtectedGarbageCollectionResult> collectProtectedGarbage({
    required String storageDirectory,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) => throw UnimplementedError();

  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundMessage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudMessage message,
  }) => throw UnimplementedError();

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) => throw UnimplementedError();

  @override
  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  }) => throw UnimplementedError();

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) => throw UnimplementedError();
}

final class _ParentBindings extends _MessageOnlyBindings
    implements
        NativeProtectedCloudSyncAttachmentParentWriteBindings,
        NativeProtectedCloudSyncChatWriteBindings,
        NativeProtectedCloudSyncAttachmentWriteBindings,
        NativeProtectedCloudSyncMessageCreateReadbackBindings {
  int parentStageCalls = 0;
  int stageCalls = 0;
  int reconcileCalls = 0;
  int prepareCalls = 0;
  int chatReconcileCalls = 0;
  int chatPrepareCalls = 0;
  int attachmentReconcileCalls = 0;
  int attachmentPrepareCalls = 0;

  frb_api.CloudSyncProtectedOutboundStageResult stageResult =
      const frb_api.CloudSyncProtectedOutboundStageResult();
  frb_api.CloudSyncOutboundReconcileResult reconcileResult =
      const frb_api.CloudSyncOutboundReconcileResult();
  frb_api.CloudSyncPreparedMessageCreateResult prepareResult =
      const frb_api.CloudSyncPreparedMessageCreateResult();

  frb_api.CloudMessage? parentHeaders;
  frb_api.CloudSyncNativeSendReceiptContext? parentContext;
  frb_api.CloudSyncAttachmentParentGroupProof? parentGroupProof;
  String? parentStorageDirectory;
  String? parentAccountFingerprint;
  String? parentStoreIdentity;

  frb_api.CloudSyncPreparedMessageCreateInput? reconcileInput;
  List<frb_api.CloudSyncPreparedMessageCreateInput> preparedInputs =
      const [];
  frb_api.CloudSyncPreparedMessageCreateInput? chatReconcileInput;
  List<frb_api.CloudSyncPreparedMessageCreateInput> chatPreparedInputs =
      const [];
  frb_api.CloudSyncPreparedMessageCreateInput? attachmentReconcileInput;
  List<frb_api.CloudSyncPreparedMessageCreateInput>
  attachmentPreparedInputs = const [];

  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult>
  stageOutboundAttachmentParent({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudMessage messageHeaders,
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentParentGroupProof? groupProof,
  }) async {
    parentStageCalls++;
    parentHeaders = messageHeaders;
    parentContext = context;
    parentGroupProof = groupProof;
    parentStorageDirectory = storageDirectory;
    parentAccountFingerprint = expectedAccountFingerprint;
    parentStoreIdentity = expectedProtectedStoreIdentity;
    return stageResult;
  }

  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundMessage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudMessage message,
  }) async {
    stageCalls++;
    return stageResult;
  }

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
    return frb_api.CloudSyncOutboundReconcileResult(
      disposition: reconcileResult.disposition,
      protectedProofReference: reconcileResult.protectedProofReference,
      failureClass: reconcileResult.failureClass,
      retryAfterSeconds: reconcileResult.retryAfterSeconds,
      serverRecordIdHash: reconcileResult.serverRecordIdHash,
      etagHash: reconcileResult.etagHash,
      protectedCurrentRawRecordReference: _reference('R'),
      protectedCurrentRawRecordLeaseReference: _lease('b'),
      rawGeneration: BigInt.from(rawGeneration),
      failure: reconcileResult.failure,
    );
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
  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  }) => throw UnimplementedError();

  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundChat({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudChat chat,
  }) => throw UnimplementedError();

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
  Future<frb_api.CloudSyncPreparedMessageCreateResult>
  prepareAttachmentCreate({
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
}
