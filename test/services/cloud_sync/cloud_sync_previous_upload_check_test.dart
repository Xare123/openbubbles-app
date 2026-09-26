// Real-store, fake-native integration tests for checkCloudSyncPreviousMessageUpload.
// Every test drives the exact production composition with a real ObjectBox store,
// a provisioned V2 owner, and scripted native fakes. No synthetic settled result is
// substituted for durable readback: commitment, adoption, and finalization all run
// through real store transactions, and the final settled verdict comes from the real
// ObjectBox preflight reader inside the seam. Submit and stage entrypoints throw when
// touched, and each settled-path test asserts they stayed silent. There is no delete
// entrypoint anywhere on these seams, so that absence is structural.
import 'dart:io';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_admission.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';
import 'cloud_sync_test_helpers.dart';
import 'cloud_sync_restored_chat_test_fixture.dart';
// Fake protection bridge. The seam never invokes crypto on these paths, but the
// production protector type is required, so its native bridge is stubbed out.
final class FakeProtectionBindings implements RustCloudSyncProtectionBindings {
  @override
  Future<String> protect({required String storageDirectory, required String accountFingerprint, required String container, required String database, required String zone, required String streamKind, required int schemaVersion, required String purpose, required String plaintext}) async => plaintext;
  @override
  Future<String> unprotect({required String storageDirectory, required String accountFingerprint, required String container, required String database, required String zone, required String streamKind, required int schemaVersion, required String purpose, required String ciphertext}) async => ciphertext;
  @override
  Future<String> fingerprintAccount({required String storageDirectory, required String rawAccountIdentifier}) async => testAccountFingerprintA;
}
// Fake native surface. Only reconcile, raw readback, and lease acknowledgement are
// scripted. Everything else throws and counts, proving submit, stage, prepare,
// consume, fetch, retire, collect, rollback, and recovery stayed silent.
final class FakeNativeBindings implements NativeProtectedCloudSyncBindings, NativeProtectedLocalStoreLockBindings, NativeProtectedCloudSyncWriteBindings, NativeProtectedCloudSyncMessageCreateReadbackBindings, CloudKitWriterReconciliationBinding, CloudSyncNativeAuthBinding {
  int reconcileCalls = 0;
  int rawReadbackCalls = 0;
  int commitLeaseCalls = 0;
  int ackLeaseCalls = 0;
  int stageCalls = 0;
  int prepareCalls = 0;
  int consumeCalls = 0;
  int unexpectedCalls = 0;
  Future<void> Function()? onReconcile;
  frb_api.CloudSyncOutboundReconcileResult reconcileResult = const frb_api.CloudSyncOutboundReconcileResult(disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved);
  frb_api.CloudSyncOutboundReconcileResult rawReadbackResult = const frb_api.CloudSyncOutboundReconcileResult(disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved);
  Object? reconcileThrow;
  List<String> events = <String>[];
  Never unexpected(String name) {
    unexpectedCalls++;
    events.add('unexpected:$name');
    throw StateError('unexpected native call ' + name);
  }
  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({required Object cloudMessagesClient, required String storageDirectory, required String expectedAccountFingerprint, required String expectedProtectedStoreIdentity, required String requestUuid, required frb_api.CloudSyncPreparedMessageCreateInput input}) async {
    reconcileCalls++;
    events.add('reconcile');
    await onReconcile?.call();
    final thrown = reconcileThrow;
    if (thrown != null) throw thrown;
    return reconcileResult;
  }
  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreateWithRawReadback({required Object cloudMessagesClient, required String storageDirectory, required String expectedAccountFingerprint, required String expectedProtectedStoreIdentity, required String requestUuid, required int rawGeneration, required frb_api.CloudSyncPreparedMessageCreateInput input}) async {
    rawReadbackCalls++;
    return rawReadbackResult;
  }
  @override
  Future<NativeProtectedLeaseResult> commitProtectedPageLease({required String storageDirectory, required String leaseReference, required List<String> retainedReferences}) async {
    commitLeaseCalls++;
    return const NativeProtectedLeaseResult();
  }
  @override
  Future<NativeProtectedLeaseResult> acknowledgeCommittedPageLease({required String storageDirectory, required String leaseReference}) async {
    ackLeaseCalls++;
    return const NativeProtectedLeaseResult();
  }
  @override
  Future<NativeProtectedFetchResult> fetchProtectedPage({required Object cloudMessagesClient, required String storageDirectory, required String expectedAccountFingerprint, required String stream, required int generation, required String? previousCheckpointReference, required int maximumChanges, required bool newestFirst}) async => unexpected('fetchProtectedPage');
  @override
  Future<NativeProtectedFetchResult> fetchProtectedPageUnderWriterPause({required Object cloudMessagesClient, required BigInt nativeWriterPauseToken, required String storageDirectory, required String expectedAccountFingerprint, required String stream, required int generation, required String? previousCheckpointReference, required int maximumChanges, required bool newestFirst}) async => unexpected('fetchProtectedPageUnderWriterPause');
  @override
  Future<NativeProtectedLeaseResult> rollbackProtectedPageLease({required String storageDirectory, required String leaseReference}) async => unexpected('rollbackProtectedPageLease');
  @override
  Future<NativeProtectedRecoveryResult> recoverProtectedPageLeases({required String storageDirectory, required List<String> adoptedLeaseReferences, required List<String> liveReferences, required bool liveReferenceEnumerationComplete}) async => unexpected('recoverProtectedPageLeases');
  @override
  Future<NativeProtectedRetirementResult> retireProtectedReferences({required String storageDirectory, required List<String> references}) async => unexpected('retireProtectedReferences');
  @override
  Future<NativeProtectedGarbageCollectionResult> collectProtectedGarbage({required String storageDirectory, required List<String> liveReferences, required bool liveReferenceEnumerationComplete}) async => unexpected('collectProtectedGarbage');
  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundMessage({required Object cloudMessagesClient, required String storageDirectory, required String expectedAccountFingerprint, required String expectedProtectedStoreIdentity, required frb_api.CloudMessage message}) async {
    stageCalls++;
    return unexpected('stageOutboundMessage');
  }
  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareMessageCreate({required Object cloudMessagesClient, required String storageDirectory, required String expectedAccountFingerprint, required String expectedProtectedStoreIdentity, required String requestUuid, required Duration requestTimeout, required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs}) async {
    prepareCalls++;
    return unexpected('prepareMessageCreate');
  }
  @override
  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({required frb_api.CloudSyncPreparedMessageCreateHandle handle, required String mutationCapabilityToken}) async {
    consumeCalls++;
    return unexpected('consumePreparedMessageCreate');
  }
  @override
  Future<Object> acquireLocalStoreLease({required String storageDirectory}) async => Object();
  @override
  Future<void> releaseLocalStoreLease(Object lease) async {}
  @override
  Future<void> ensureReadAuthentication({required Object cloudMessagesClient, required String privateStorageDirectory}) async {}
  @override
  Future<void> warmReadAuthentication({required Object cloudMessagesClient}) async {}
  int warmUnderPauseCalls = 0;
  Object? warmUnderPauseThrow;
  @override
  Future<void> warmReadAuthenticationUnderWriterPause({required Object cloudMessagesClient, required BigInt pauseToken}) async {
    warmUnderPauseCalls++;
    events.add('warm');
    final thrown = warmUnderPauseThrow;
    if (thrown != null) throw thrown;
  }
  @override
  Future<CloudSyncNativeAuthMetadata> capture({required Object cloudMessagesClient, required String privateStorageDirectory}) async => CloudSyncNativeAuthMetadata(nativeSessionId: 'N' * 43, accountFingerprint: testAccountFingerprintA, protectedStoreIdentity: 'obcs2.store.' + testAccountFingerprintA);
}
// Scriptable writer pause. Records pause, warm and resume order through the
// shared event log to prove the pause is released before writer lookup.
final class RecoveryNativeBindings extends FakeNativeBindings
    implements NativeProtectedPreparedReleaseBindings {
  List<frb_api.CloudSyncPreparedMessageCreateInput> preparedInputs = [];
  Future<void> Function()? onPrepare;
  bool uncertainConsume = false;
  int releaseCalls = 0;
  String sessionId = 'N' * 43;

  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient, required String privateStorageDirectory,
  }) async => CloudSyncNativeAuthMetadata(nativeSessionId: sessionId,
    accountFingerprint: testAccountFingerprintA,
    protectedStoreIdentity: 'obcs2.store.$testAccountFingerprintA');

  RecoveryNativeBindings() {
    reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: testProtectedReference('P'),
    );
  }

  @override
  Future<NativeProtectedRecoveryResult> recoverProtectedPageLeases({
    required String storageDirectory,
    required List<String> adoptedLeaseReferences,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) async => NativeProtectedRecoveryResult(recovery: NativeProtectedRecovery(
    finalizedAdoptedLeaseReferences: adoptedLeaseReferences,
    absentAdoptedLeaseReferences: const [],
    rolledBackCount: 0, removedTemporaryFilesCount: 0, hasMore: false,
  ));

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
    preparedInputs = List.of(inputs);
    await onPrepare?.call();
    return frb_api.CloudSyncPreparedMessageCreateResult(
      handle: _RecoveryHandle(),
      handleBindingSha256: testSha256('a'),
    );
  }

  @override
  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  }) async {
    consumeCalls++;
    return frb_api.CloudSyncOutboundConsumeResult(outcomes: [
      for (final input in preparedInputs)
        frb_api.CloudSyncOutboundSaveOutcome(
          localOperationId: input.localOperationId,
          appleOperationUuid: input.appleOperationUuid,
          disposition: uncertainConsume
              ? frb_api.CloudSyncOutboundSaveDisposition.unknownOutcome
              : frb_api.CloudSyncOutboundSaveDisposition.succeeded,
          serverRecordIdHash: digestFor('S'),
          etagHash: receiptEtagValue,
        ),
    ]);
  }

  @override
  Future<bool> releasePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
  }) async {
    releaseCalls++;
    return true;
  }
}

final class _RecoveryHandle implements frb_api.CloudSyncPreparedMessageCreateHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecoveryMessage implements frb_api.CloudMessage {
  _RecoveryMessage(Message message)
      : guid = message.guid!,
        chatId = message.chat.target!.guid,
        destinationCallerId = message.chat.target!.usingHandle!.replaceFirst('mailto:', '');
  @override
  final String guid;
  @override
  final String chatId;
  @override
  final String destinationCallerId;
  @override
  int get type => 1;
  @override
  String get service => 'iMessage';
  @override
  String get sender => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecoveryStage implements CloudSyncOutboundStagingTransport {
  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) => action();
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {required frb_api.CloudMessage message}
  ) async => CloudSyncProtectedOutboundStageData(
    logicalEntityKeyHash: digestFor('T'),
    protectedEnvelopeReference: testProtectedReference('P'),
    payloadSha256: testSha256('a'),
    serverRecordIdHash: digestFor('S'),
    leaseReference: testProtectedLeaseReference('a'),
  );
  @override
  Future<void> commitOutboundLease(String leaseReference, String protectedEnvelopeReference) async {}
  @override
  Future<void> rollbackOutboundLease(String leaseReference) async {}
}

final class FakeWriterPause implements CloudSyncNativeWriterPause {
  FakeWriterPause(this.events);
  final List<String> events;
  int pauseCalls = 0;
  int resumeCalls = 0;
  Object? pauseThrow;
  Object? resumeThrow;
  BigInt token = BigInt.from(7);
  @override
  Future<Object> pause() async {
    pauseCalls++;
    events.add('pause');
    final thrown = pauseThrow;
    if (thrown != null) throw thrown;
    return token;
  }
  @override
  Future<void> resume(Object token) async {
    resumeCalls++;
    events.add('resume');
    final thrown = resumeThrow;
    if (thrown != null) throw thrown;
  }
}
const String requestUuidValue = '11111111-2222-4ABC-8DEF-555555555555';
const String receiptEtagValue = 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE';
String digestFor(String character) => List<String>.filled(43, character).join();
String operationUuidFor(int index) => 'AAAAAAAA-BBBB-4CCC-8DDD-' + (index + 1).toRadixString(16).padLeft(12, '0').toUpperCase();
void main() {
  late Directory directory;
  late Store objectBox;
  late DateTime currentTime;
  late Object activeClient;
  late FakeNativeBindings native;
  late FakeWriterPause writerPause;
  late RustCloudSyncProtector protector;
  late CloudSyncNativeAuthSnapshot authSnapshot;
  late int authReads;
  late String? flipSessionId;
  late int flipAfterReads;
  late int runtimeBudget;
  final fences = <String, CloudCoordinatorLeaseFence>{};
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('previous-upload-check-');
    objectBox = await openStore(directory: directory.path);
    currentTime = testEpoch;
    activeClient = Object();
    native = FakeNativeBindings();
    writerPause = FakeWriterPause(native.events);
    protector = RustCloudSyncProtector(storageDirectory: directory.path, bindings: FakeProtectionBindings());
    authSnapshot = CloudSyncNativeAuthSnapshot.fromNative(nativeSessionId: 'N' * 43, accountFingerprint: testAccountFingerprintA, protectedStoreIdentity: 'obcs2.store.' + testAccountFingerprintA, cloudMessagesClient: activeClient);
    authReads = 0;
    flipSessionId = null;
    flipAfterReads = 1 << 30;
    runtimeBudget = 1 << 30;
    fences.clear();
  });
  tearDown(() async {
    objectBox.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });
  Future<void> reopen() async {
    objectBox.close();
    objectBox = await openStore(directory: directory.path);
  }
  CloudSyncScope zoneScope(String zone) => CloudSyncScope(accountFingerprint: testAccountFingerprintA, container: 'com.apple.messages.cloud', database: 'private', zone: zone, streamKind: CloudSyncStreamKind.messages, schemaVersion: 2, persistenceLane: CloudSyncPersistenceLane.semantic);
  CloudSyncScope scope() => zoneScope('messageManateeZone');
  CloudKitWriterScope writerScope() => CloudKitWriterScope(accountFingerprint: testAccountFingerprintA, container: 'com.apple.messages.cloud', database: 'private');
  ObjectBoxCloudSyncStore durable() => ObjectBoxCloudSyncStore(store: objectBox, protector: protector, clock: () => currentTime);
  Future<void> journalZone(String zone) async {
    final target = zoneScope(zone);
    final fence = fences[target.storageKey] ??= (await durable().tryAcquireCoordinatorLease(target, ownerId: 'previous-upload-check', now: testEpoch, leaseDuration: const Duration(days: 1)))!;
    final checkpoint = await durable().readCheckpoint(target);
    await durable().journalFetchedBatch(CloudFetchBatch(scope: target, changes: <CloudFetchedChange>[testChange(1)], batchId: 'completed-' + zone, generation: 1, nextToken: 'completed-token-' + zone, hasMore: false), now: testEpoch, leaseFence: fence, expectedGeneration: checkpoint.generation, expectedFetchedToken: checkpoint.fetchedToken);
    await durable().markInboxApplied(target, sequence: 1, now: testEpoch, leaseFence: fences[target.storageKey]!);
    await durable().recordPullSuccess(target, now: testEpoch);
  }
  Future<void> seedAccount() async {
    for (final zone in <String>['chatManateeZone', 'messageManateeZone', 'attachmentManateeZone']) {
      await journalZone(zone);
    }
  }
  Future<void> provisionV2() async {
    final target = writerScope();
    final noneAuthority = ObjectBoxCloudKitWriterAuthority.forTest(store: objectBox, buildDecision: CloudKitWriterOwnershipDecision(owner: CloudKitWriterOwner.none, configurationValid: true));
    final initial = noneAuthority.initializeDisabled(target, now: testEpoch);
    ObjectBoxCloudKitWriterAuthority.forTest(store: objectBox, buildDecision: CloudKitWriterOwnershipDecision(owner: CloudKitWriterOwner.v2, configurationValid: true)).provisionInitialOwner(target, owner: CloudKitWriterOwner.v2, expectedEpoch: initial.epoch, evidence: CloudKitWriterTransitionEvidence.forTest(operationsQuiesced: true, activeIdentityRevalidated: true, legacyMutationQueues: LegacyMutationQueueDisposition.empty), now: testEpoch);
  }
  Future<CloudSyncNativeAuthSnapshot?> readAuth() async {
    authReads++;
    if (flipSessionId != null && authReads > flipAfterReads) {
      return CloudSyncNativeAuthSnapshot.fromNative(nativeSessionId: flipSessionId!, accountFingerprint: testAccountFingerprintA, protectedStoreIdentity: 'obcs2.store.' + testAccountFingerprintA, cloudMessagesClient: activeClient);
    }
    return authSnapshot;
  }
  Future<CloudSyncShadowPreflightState> readPreflight() async => const CloudSyncShadowPreflightState(platformSupported: true, uiIsolate: true, rustPushReady: true, objectBoxReady: true, privateStorageExists: true, logoutActive: false, legacySyncEnabled: false, legacySyncActive: false, coordinatorLeaseActive: false, outboxCount: 1, protectorSentinelValid: true);
  bool runtimeAllowed() {
    if (runtimeBudget > 0) {
      runtimeBudget--;
      return true;
    }
    return false;
  }
  Future<CloudSyncPreviousUploadResult> runCheck({bool v2Build = false}) => checkCloudSyncPreviousMessageUpload(store: objectBox, protector: protector, readAuth: readAuth, readActiveClient: () => activeClient, nativeAuthBinding: native, bindings: native, readPreflight: readPreflight, runtimeAllowed: runtimeAllowed, storageDirectory: directory.path, writerPause: writerPause,
    writerBuildDecisionOverrideForTest: v2Build ? CloudKitWriterOwnership.resolve('v2') : null);
  CloudOutboxOperation buildOp({required String logicalCharacter, required int revision, required String payloadShaCharacter, required String leaseCharacter}) {
    final String logical = digestFor(logicalCharacter);
    final CloudSyncScope active = scope();
    return CloudOutboxOperation(scope: active, operationId: CloudOperationIdentity.forInitialCreate(scope: active, logicalEntityKeyHash: logical, payloadVersion: cloudSyncOutboundPayloadVersion), logicalEntityKeyHash: logical, action: CloudOutboxAction.save, payloadVersion: cloudSyncOutboundPayloadVersion, mutationRevision: revision, checkpointGeneration: 1, encryptedPayloadReference: testProtectedReference(logicalCharacter), payloadSha256: testSha256(payloadShaCharacter), protectedLeaseReference: testProtectedLeaseReference(leaseCharacter), dependencyOperationIds: const <String>{}, createdAt: testEpoch);
  }
  Future<String> seedSubmittedTarget() async {
    final op = buildOp(logicalCharacter: 'T', revision: 9, payloadShaCharacter: '9', leaseCharacter: 'a');
    await durable().enqueueOutbox(op);
    await durable().leaseEligibleOutbox(scope(), now: testEpoch, limit: 1, leaseId: 'previous-upload-seed', leaseDuration: const Duration(minutes: 1), allowedActions: const <CloudOutboxAction>{CloudOutboxAction.save});
    await durable().attachOutboxRecordMapping(scope(), leaseId: 'previous-upload-seed', operationId: op.operationId, serverRecordIdHash: digestFor('S'), now: testEpoch);
    await durable().markOutboxSubmissionStarted(scope(), leaseId: 'previous-upload-seed', submissionIdentity: testSubmissionIdentity(<String>[op.operationId]), now: testEpoch);
    await durable().upsertRecordMap(CloudRecordMapEntry(scope: scope(), logicalEntityKeyHash: op.logicalEntityKeyHash, serverRecordIdHash: digestFor('S'), encryptedServerRecordId: testProtectedReference('S'), updatedAt: testEpoch), generation: 1);
    return op.operationId;
  }
  Future<String> seedSettledRow({required String logicalCharacter, required int revision, required int uuidIndex, required String serverCharacter}) async {
    final op = buildOp(logicalCharacter: logicalCharacter, revision: revision, payloadShaCharacter: revision.toRadixString(16), leaseCharacter: 'e');
    await durable().enqueueOutbox(op);
    final leaseId = 'previous-upload-settled-' + revision.toString();
    await durable().leaseEligibleOutbox(scope(), now: testEpoch, limit: 1, leaseId: leaseId, leaseDuration: const Duration(minutes: 1), allowedActions: const <CloudOutboxAction>{CloudOutboxAction.save});
    await durable().attachOutboxRecordMapping(scope(), leaseId: leaseId, operationId: op.operationId, serverRecordIdHash: digestFor(serverCharacter), now: testEpoch);
    await durable().markOutboxSubmissionStarted(scope(), leaseId: leaseId, submissionIdentity: CloudOutboxSubmissionIdentity(requestUuid: requestUuidValue, operationUuids: <String, String>{op.operationId: operationUuidFor(uuidIndex)}), now: testEpoch);
    await durable().upsertRecordMap(CloudRecordMapEntry(scope: scope(), logicalEntityKeyHash: op.logicalEntityKeyHash, serverRecordIdHash: digestFor(serverCharacter), encryptedServerRecordId: testProtectedReference(serverCharacter), updatedAt: testEpoch), generation: 1);
    await durable().commitOutboxCreateReceipt(scope(), leaseId: leaseId, receipt: CloudOutboxCreateReceipt(operationId: op.operationId, logicalEntityKeyHash: op.logicalEntityKeyHash, serverRecordIdHash: digestFor(serverCharacter), etagHash: receiptEtagValue), now: testEpoch.add(const Duration(seconds: 1)));
    return op.operationId;
  }
  List<Object?> checkpointPin() {
    final key = cloudSyncPersistentScopeKey(scope());
    final row = objectBox.box<CloudSyncCheckpointEntity>().getAll().singleWhere((CloudSyncCheckpointEntity c) => c.checkpointKey == key);
    return <Object?>[row.generation, row.fetchDirection, row.fetchedTokenCiphertext, row.pendingFetchedTokenCiphertext, row.pendingBatchId, row.lastBatchId, row.fetchedSequence, row.appliedSequence, row.backoffAttempt, row.nextEligibleAtMs, row.mutationRevisionCounter];
  }
  void scriptCommitted() {
    native.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed, protectedProofReference: testProtectedReference('T'), serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue);
    native.rawReadbackResult = frb_api.CloudSyncOutboundReconcileResult(disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed, protectedProofReference: testProtectedReference('T'), serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue, protectedCurrentRawRecordReference: testProtectedReference('Q'), protectedCurrentRawRecordLeaseReference: testProtectedLeaseReference('c'), rawGeneration: BigInt.from(1));
  }
  Future<String> seedAdoptedPendingWithAudits({int auditCount = 8}) async {
    await provisionV2();
    for (final zone in ['chatManateeZone', 'messageManateeZone', 'attachmentManateeZone']) {
      await durable().recordPullSuccess(zoneScope(zone), now: testEpoch);
    }
    for (var i = 0; i < auditCount; i++) {
      await seedSettledRow(
        logicalCharacter: String.fromCharCode(65 + i), revision: i + 1,
        uuidIndex: i + 1, serverCharacter: String.fromCharCode(75 + i),
      );
    }
    final authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: objectBox, buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final journal = CloudSyncLocalSendJournal(
      store: objectBox, authority: authority,
      authoritySnapshot: authority.read(writerScope())!,
    );
    final handle = Handle(address: 'recipient@example.com', service: 'iMessage',
      uniqueAddressAndService: 'recipient@example.com/iMessage');
    objectBox.box<Handle>().put(handle);
    final chat = Chat(guid: 'iMessage;-;recipient@example.com',
      chatIdentifier: 'recipient@example.com', usingHandle: 'mailto:sender@example.com',
      style: 45, participants: [handle])..handles.add(handle);
    objectBox.box<Chat>().put(chat);
    const stableGuid = '11111111-1111-4111-8111-111111111111';
    final message = Message(guid: 'temp-Abc12345', stagingGuid: stableGuid,
      text: 'synthetic recovery', isFromMe: true, dateCreated: testEpoch,
      attributedBody: [AttributedBody.raw('synthetic recovery')])..chat.target = chat;
    final identity = CloudSyncLocalSendIdentity.capture(message, chat, stableGuid)!;
    journal.saveSubmission(identity: identity, newlyGeneratedGuid: true,
      persistMessage: () => objectBox.box<Message>().put(message), now: testEpoch);
    message..guid = stableGuid..stagingGuid = null;
    journal.saveConfirmedSubmission(identity: identity,
      persistMessage: () => objectBox.box<Message>().put(message), now: testEpoch);
    final chatScope = zoneScope('chatManateeZone');
    final applied = await seedSyntheticRestoredChatAppliedSource(
      objectBox: objectBox, store: durable(), chatScope: chatScope, now: testEpoch);
    await seedSyntheticRestoredChatProof(objectBox: objectBox, store: durable(),
      chatScope: chatScope, chat: chat, appliedSource: applied, now: testEpoch);
    final coordinator = CloudSyncOutboundAdmissionCoordinator(
      store: durable(), transport: _RecoveryStage(),
      ensureProtectedStoreRecovered: () async {},
    );
    final operation = await coordinator.admitLocalSend(scope(),
      intentId: objectBox.box<CloudSyncLocalSendIntentEntity>().getAll().single.id,
      journal: journal,
      authFence: CloudSyncLocalSendAuthFence(expected: authSnapshot,
        capture: () async => authSnapshot, stillCurrent: () => true),
      encodeMessage: _RecoveryMessage.new,
    );
    final ownedStore = ObjectBoxCloudSyncStore(
      store: objectBox, protector: protector, localSendJournal: journal,
      clock: () => testEpoch,
    );
    // Reproduce the retained row's lifecycle through real store transitions:
    // seven prior submissions proven not applied, with Apple UUIDs cleared
    // but the original adopted envelope and protected lease preserved.
    for (var i = 0; i < 7; i++) {
      final now = testEpoch.add(Duration(seconds: i + 1));
      final leaseId = 'synthetic-not-applied-$i';
      await ownedStore.leaseEligibleOutbox(scope(), now: now, limit: 1,
        leaseId: leaseId, leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save});
      await ownedStore.markOutboxSubmissionStarted(scope(), leaseId: leaseId,
        submissionIdentity: testSubmissionIdentity([operation.operationId]), now: now);
      await ownedStore.applyOutboxTransitions(scope(), leaseId: leaseId,
        transitions: [CloudOutboxTransition.provenNotApplied(operation.operationId,
          category: CloudFailureCategory.server, nextEligibleAt: now)], now: now);
    }
    return operation.operationId;
  }

  CloudSyncProductionOutboundCanaryAdapter recoveryAdapter({bool Function()? allowed}) =>
      CloudSyncProductionOutboundCanaryAdapter(
    privateStorageDirectory: directory.path,
    readActiveClient: () => activeClient,
    readPreflight: () async => CloudSyncShadowPreflightState(
      platformSupported: true, uiIsolate: true, rustPushReady: true,
      objectBoxReady: true, privateStorageExists: true, logoutActive: false,
      legacySyncEnabled: false, legacySyncActive: false,
      coordinatorLeaseActive: false,
      outboxCount: objectBox.box<CloudOutboxOperationEntity>().count(),
      protectorSentinelValid: true,
    ),
    nativeAuthBinding: native, transportBindings: native,
    protectionBindings: FakeProtectionBindings(),
    quarantineLegacyDeletionQueues: () => throw StateError('unexpected provisioning'),
    readWriterMeasurements: (_) => throw StateError('unexpected provisioning'),
    compileGateOverrideForTest: true, v2WriterOverrideForTest: true,
    storeOverrideForTest: objectBox,
    writerBuildDecisionOverrideForTest: CloudKitWriterOwnership.resolve('v2'),
    receiptRecoveryAllowed: allowed ?? () => true,
    writerPauseOverrideForTest: FakeWriterPause(native.events),
  );

  test('Profile retry uploads only its pinned pending create and finishes exact readback', () async {
    final targetId = await seedAdoptedPendingWithAudits();
    native = RecoveryNativeBindings();
    native.rawReadbackResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
      protectedProofReference: testProtectedReference('P'),
      serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue,
      protectedCurrentRawRecordReference: testProtectedReference('Q'),
      protectedCurrentRawRecordLeaseReference: testProtectedLeaseReference('c'),
      rawGeneration: BigInt.from(1),
    );
    final audits = ObjectBoxCloudSyncPreflightReader.settledAuditFingerprint(
      objectBox.box<CloudOutboxOperationEntity>().getAll().where((r) => r.operationId != targetId).toList());
    final adapter = recoveryAdapter();
    final confirmation = await adapter.armPendingUploadRetry();
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
    expect(await adapter.retryPendingUpload(confirmation), CloudSyncPreviousUploadResult.settled);
    expect(native.consumeCalls, 1);
    expect(native.stageCalls, 0);
    expect(native.rawReadbackCalls, 1);
    expect(ObjectBoxCloudSyncPreflightReader(store: objectBox).read().settledOutboxFingerprint, isNotNull);
    expect(objectBox.box<CloudOutboxOperationEntity>().count(), 9);
    expect(ObjectBoxCloudSyncPreflightReader.settledAuditFingerprint(
      objectBox.box<CloudOutboxOperationEntity>().getAll().where((r) => r.operationId != targetId).toList()), audits);
    await expectLater(adapter.retryPendingUpload(confirmation), throwsStateError);
    expect(native.consumeCalls, 1, reason: 'a reused confirmation never writes twice');
  });

  test('Profile retry cancellation preserves the pending envelope without native work', () async {
    await seedAdoptedPendingWithAudits();
    native = RecoveryNativeBindings();
    final adapter = recoveryAdapter();
    final before = await durable().readOutboxEntries(scope());
    final confirmation = await adapter.armPendingUploadRetry();
    adapter.canary.disarm(confirmation);
    await expectLater(adapter.retryPendingUpload(confirmation), throwsStateError);
    final after = await durable().readOutboxEntries(scope());
    expect(after.length, before.length);
    for (var i = 0; i < before.length; i++) {
      expect(after[i].sameDurableSnapshotAs(before[i]), isTrue);
    }
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
  });

  test('Profile retry cannot select an uncertain previous submission', () async {
    await provisionV2();
    await seedAccount();
    await seedSubmittedTarget();
    final adapter = recoveryAdapter();
    await expectLater(adapter.armPendingUploadRetry(), throwsStateError);
    expect(native.consumeCalls, 0);
    expect(native.reconcileCalls, 0);
  });

  test('Profile retry becoming unavailable during native prepare never consumes', () async {
    await seedAdoptedPendingWithAudits();
    var allowed = true;
    final recovery = RecoveryNativeBindings()..onPrepare = () async { allowed = false; };
    native = recovery;
    final adapter = recoveryAdapter(allowed: () => allowed);
    final confirmation = await adapter.armPendingUploadRetry();
    try { await adapter.retryPendingUpload(confirmation); } catch (_) {}
    expect(native.prepareCalls, 1);
    expect(native.consumeCalls, 0);
    expect(recovery.releaseCalls, 1);
  });

  test('post-retry receipt check rejects a different operation before native work', () async {
    await provisionV2();
    await seedAccount();
    await seedSubmittedTarget();
    final unrelated = buildOp(logicalCharacter: 'Z', revision: 9,
      payloadShaCharacter: '9', leaseCharacter: 'a');
    await expectLater(checkCloudSyncPreviousMessageUpload(
      store: objectBox, protector: protector, readAuth: readAuth,
      readActiveClient: () => activeClient, nativeAuthBinding: native,
      bindings: native, readPreflight: readPreflight, runtimeAllowed: () => true,
      storageDirectory: directory.path, writerPause: writerPause,
      expectedOperation: unrelated, expectedAuth: authSnapshot,
    ), throwsStateError);
    expect(native.reconcileCalls, 0);
    expect(native.rawReadbackCalls, 0);
    expect(native.warmUnderPauseCalls, 0);
  });

  test('production recovery sends adopted pending with eight audits then settles via receipt check', () async {
    final targetId = await seedAdoptedPendingWithAudits();
    final pending = (await durable().readOutboxEntries(scope()))
      .singleWhere((r) => r.operationId == targetId);
    expect(pending.mutationRevision, 9);
    expect(pending.attemptCount, 7);
    expect(pending.appleRequestUuid, isNull);
    expect(objectBox.box<CloudSyncLocalSendIntentEntity>().getAll()
      .single.protectedSourceBinding, isNull, reason: 'legacy text needs no fabricated source proof');
    final auditRows = objectBox.box<CloudOutboxOperationEntity>().getAll()
      .where((r) => r.operationId != targetId).toList();
    final auditPin = ObjectBoxCloudSyncPreflightReader.settledAuditFingerprint(auditRows);
    expect(auditPin, isNotNull);
    native = RecoveryNativeBindings();
    final adapter = recoveryAdapter();
    final confirmation = await adapter.canary.armRecoveryConfirmed();
    final report = await adapter.canary.runDoubleConfirmed(confirmation);
    expect(report.confirmed, 1, reason: '${report.toJson()} / ${native.events} / '
      '${(await durable().readOutboxEntries(scope())).singleWhere((r) => r.operationId == targetId).lastFailure}');
    expect(native.consumeCalls, 1);
    expect(native.prepareCalls, 1);
    expect(native.stageCalls, 0);
    expect(native.unexpectedCalls, 0);
    expect((await durable().readOutboxEntries(scope())).singleWhere(
      (r) => r.operationId == targetId).protectedLeaseReference, isNotNull);
    scriptCommitted();
    native.rawReadbackResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
      protectedProofReference: testProtectedReference('P'),
      serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue,
      protectedCurrentRawRecordReference: testProtectedReference('Q'),
      protectedCurrentRawRecordLeaseReference: testProtectedLeaseReference('c'),
      rawGeneration: BigInt.from(1),
    );
    expect(await runCheck(v2Build: true), CloudSyncPreviousUploadResult.settled);
    expect(ObjectBoxCloudSyncPreflightReader(store: objectBox).read().settledOutboxFingerprint, isNotNull);
    expect(ObjectBoxCloudSyncPreflightReader.settledAuditFingerprint(
      objectBox.box<CloudOutboxOperationEntity>().getAll()
        .where((r) => r.operationId != targetId).toList()), auditPin);
    expect(objectBox.box<CloudOutboxOperationEntity>().count(), 9);
    expect(native.consumeCalls, 1, reason: 'receipt lookup never resends');
  });

  test('manual confirmed replay resumes adopted readback only after postflight', () async {
    final targetId = await seedAdoptedPendingWithAudits();
    native = RecoveryNativeBindings();
    final adapter = recoveryAdapter();
    final write = await adapter.canary.armRecoveryConfirmed();
    await adapter.canary.runDoubleConfirmed(write);
    final confirmed = (await durable().readOutboxEntries(scope()))
        .singleWhere((r) => r.operationId == targetId);
    final authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: objectBox, buildDecision: CloudKitWriterOwnership.resolve('v2'));
    final owned = ObjectBoxCloudSyncStore(store: objectBox, protector: protector,
      localSendJournal: CloudSyncLocalSendJournal(store: objectBox,
        authority: authority, authoritySnapshot: authority.read(writerScope())!));
    await owned.commitConfirmedMessageCreateReadback(expectedOperation: confirmed,
      receipt: CloudOutboxCreateReceipt(operationId: targetId,
        logicalEntityKeyHash: confirmed.logicalEntityKeyHash,
        serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue,
        protectedCurrentRawRecordReference: testProtectedReference('Q'),
        protectedCurrentRawRecordLeaseReference: testProtectedLeaseReference('c'), rawGeneration: 1),
      now: DateTime.now().toUtc());
    final replay = await adapter.canary.armConfirmedReplay();
    final report = await adapter.canary.runDoubleConfirmed(replay);
    expect(report.replayVerification, isTrue);
    expect(report.confirmed, 0);
    expect(native.consumeCalls, 1, reason: 'only the initial synthetic write');
    expect(native.rawReadbackCalls, 0, reason: 'resume the already adopted exact raw readback');
    expect(ObjectBoxCloudSyncPreflightReader(store: objectBox).read().settledOutboxFingerprint, isNotNull);
    expect(objectBox.box<CloudOutboxOperationEntity>().count(), 9);
  });

  test('manual unknown recovery rejects changed audit before committing returned receipt', () async {
    await provisionV2();
    await seedAccount();
    await seedSettledRow(logicalCharacter: 'A', revision: 1, uuidIndex: 1, serverCharacter: 'K');
    final targetId = await seedSubmittedTarget();
    // Expired synthetic unknown submission has no active lease after process death.
    final row = objectBox.box<CloudOutboxOperationEntity>().getAll()
        .singleWhere((r) => r.operationId == targetId);
    objectBox.box<CloudOutboxOperationEntity>().put(row..leaseIdHash = null..leaseExpiresAtMs = 0);
    scriptCommitted();
    native.onReconcile = () async {
      final audit = objectBox.box<CloudOutboxOperationEntity>().getAll()
          .singleWhere((r) => r.operationId != targetId);
      objectBox.box<CloudOutboxOperationEntity>().put(audit..updatedAtMs += 1);
    };
    final adapter = recoveryAdapter();
    final recovery = await adapter.canary.armRecoveryConfirmed();
    await expectLater(adapter.canary.runDoubleConfirmed(recovery), throwsStateError);
    expect(native.reconcileCalls, 1);
    final target = (await durable().readOutboxEntries(scope())).singleWhere((r) => r.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(target.protectedLeaseReference, isNotNull);
    expect(native.rawReadbackCalls, 0);
    expect(native.consumeCalls, 0);
  });

  test('production recovery rejects an audit changed after native prepare before consume', () async {
    final targetId = await seedAdoptedPendingWithAudits();
    final recovery = RecoveryNativeBindings();
    native = recovery;
    recovery.onPrepare = () async {
      final row = objectBox.box<CloudOutboxOperationEntity>().getAll()
        .firstWhere((r) => r.operationId != targetId);
      objectBox.box<CloudOutboxOperationEntity>().put(
        row..updatedAtMs = row.updatedAtMs + 1,
      );
    };
    final adapter = recoveryAdapter();
    final confirmation = await adapter.canary.armRecoveryConfirmed();
    try { await adapter.canary.runDoubleConfirmed(confirmation); } catch (_) {}
    expect(native.prepareCalls, 1);
    expect(native.consumeCalls, 0, reason: 'full durable audit pin must precede a remote mutation');
    expect(objectBox.box<CloudOutboxOperationEntity>().count(), 9);
  });

  test('production recovery uncertain consume retains pending receipt without blind resend', () async {
    final targetId = await seedAdoptedPendingWithAudits();
    native = RecoveryNativeBindings()..uncertainConsume = true;
    final adapter = recoveryAdapter();
    final confirmation = await adapter.canary.armRecoveryConfirmed();
    await expectLater(adapter.canary.runDoubleConfirmed(confirmation), throwsStateError);
    final target = (await durable().readOutboxEntries(scope())).singleWhere((r) => r.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(target.appleOperationUuid, isNotNull);
    expect(target.protectedLeaseReference, isNotNull);
    expect(native.consumeCalls, 1);
    expect(native.rawReadbackCalls, 0);
    expect(ObjectBoxCloudSyncPreflightReader(store: objectBox).read().settledOutboxFingerprint, isNull);
    await expectLater(adapter.canary.armRecoveryConfirmed(), throwsStateError);
    await expectLater(runCheck(v2Build: true), throwsStateError);
    expect(native.consumeCalls, 1, reason: 'an active unknown receipt cannot resend');
    // Simulate expiry of this synthetic lease without waiting a minute. No
    // source, request identity or protected receipt is changed.
    final row = objectBox.box<CloudOutboxOperationEntity>().getAll()
      .singleWhere((r) => r.operationId == targetId);
    objectBox.box<CloudOutboxOperationEntity>().put(row..leaseExpiresAtMs = testEpoch.millisecondsSinceEpoch);
    native.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
      protectedProofReference: testProtectedReference('P'),
      serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue,
    );
    native.rawReadbackResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
      protectedProofReference: testProtectedReference('P'),
      serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue,
      protectedCurrentRawRecordReference: testProtectedReference('Q'),
      protectedCurrentRawRecordLeaseReference: testProtectedLeaseReference('c'),
      rawGeneration: BigInt.from(1),
    );
    expect(await runCheck(v2Build: true), CloudSyncPreviousUploadResult.settled);
    expect(native.consumeCalls, 1, reason: 'exact receipt recovery must not resend');
  });

  for (final change in ['adopted source proof', 'checkpoint', 'extra unfinished', 'auth', 'target binding']) {
    test('production recovery rejects $change change after prepare', () async {
      final targetId = await seedAdoptedPendingWithAudits();
      final recovery = RecoveryNativeBindings();
      native = recovery;
      recovery.onPrepare = () async {
        switch (change) {
          case 'adopted source proof':
            final intent = objectBox.box<CloudSyncLocalSendIntentEntity>().getAll().single;
            objectBox.box<CloudSyncLocalSendIntentEntity>().put(
              intent..admittedBindingSha256 = testSha256('f'));
          case 'checkpoint':
            final checkpoint = objectBox.box<CloudSyncCheckpointEntity>().getAll()
              .singleWhere((c) => c.checkpointKey == cloudSyncPersistentScopeKey(scope()));
            objectBox.box<CloudSyncCheckpointEntity>().put(checkpoint..generation += 1);
          case 'extra unfinished':
            await durable().enqueueOutbox(buildOp(logicalCharacter: 'Z',
              revision: 99, payloadShaCharacter: 'f', leaseCharacter: 'f'));
          case 'auth':
            recovery.sessionId = 'B' * 43;
          case 'target binding':
            final row = objectBox.box<CloudOutboxOperationEntity>().getAll()
              .singleWhere((r) => r.operationId == targetId);
            objectBox.box<CloudOutboxOperationEntity>().put(row..payloadSha256 = testSha256('f'));
        }
      };
      final adapter = recoveryAdapter();
      final confirmation = await adapter.canary.armRecoveryConfirmed();
      // The engine can return failed or the outer tripwire can reject the
      // run. Neither path may pass a prepared handle to native consumption.
      try { await adapter.canary.runDoubleConfirmed(confirmation); } catch (_) {}
      expect(native.prepareCalls, 1);
      expect(native.consumeCalls, 0);
      expect(recovery.releaseCalls, 1);
      expect(native.rawReadbackCalls, 0);
      expect(objectBox.box<CloudOutboxOperationEntity>().getAll()
        .singleWhere((r) => r.operationId == targetId).protectedLeaseReference, isNotNull);
    });
  }

  test('production recovery checks global inventory even with one scoped row', () async {
    final targetId = await seedAdoptedPendingWithAudits(auditCount: 0);
    await durable().enqueueOutbox(buildOp(logicalCharacter: 'Z', revision: 99,
      payloadShaCharacter: 'f', leaseCharacter: 'f'));
    final other = objectBox.box<CloudOutboxOperationEntity>().getAll()
      .singleWhere((r) => r.operationId != targetId);
    objectBox.box<CloudOutboxOperationEntity>().put(other
      ..scopeKey = 'different-scope'
      ..zone = 'attachmentManateeZone');
    native = RecoveryNativeBindings();
    final adapter = recoveryAdapter();
    final confirmation = await adapter.canary.armRecoveryConfirmed();
    await expectLater(adapter.canary.runDoubleConfirmed(confirmation), throwsStateError);
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
  });
  test('settled create with audit rows runs exact readback to settled preflight', () async {
    await provisionV2();
    await seedAccount();
    await seedSettledRow(logicalCharacter: 'A', revision: 1, uuidIndex: 1, serverCharacter: 'K');
    await seedSettledRow(logicalCharacter: 'B', revision: 2, uuidIndex: 2, serverCharacter: 'L');
    final targetId = await seedSubmittedTarget();
    final pin = checkpointPin();
    scriptCommitted();
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.settled);
    final rows = await durable().readOutboxEntries(scope());
    final target = rows.singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.confirmed);
    expect(target.protectedLeaseReference, isNull);
    expect(target.leaseId, isNull);
    expect(target.serverRecordIdHash, digestFor('S'));
    expect(checkpointPin(), pin);
    final preflight = ObjectBoxCloudSyncPreflightReader(store: objectBox).read();
    expect(preflight.settledOutboxFingerprint, isNotNull);
    expect(native.reconcileCalls, 1);
    expect(native.rawReadbackCalls, 1);
    expect(native.commitLeaseCalls, 1);
    expect(native.ackLeaseCalls, 2);
    expect(native.stageCalls, 0);
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('notApplied clears Apple IDs and stays pending with no resend', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    native.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied, protectedProofReference: testProtectedReference('T'));
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.notApplied);
    final target = (await durable().readOutboxEntries(scope())).single;
    expect(target.operationId, targetId);
    expect(target.status, CloudOutboxStatus.pending);
    expect(target.appleRequestUuid, isNull);
    expect(target.appleOperationUuid, isNull);
    expect(native.reconcileCalls, 1);
    expect(native.rawReadbackCalls, 0);
    expect(native.commitLeaseCalls, 0);
    expect(native.ackLeaseCalls, 0);
    expect(native.stageCalls, 0);
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('unresolved remains retained with identities intact', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    native.reconcileResult = const frb_api.CloudSyncOutboundReconcileResult(disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved);
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.unresolved);
    final target = (await durable().readOutboxEntries(scope())).single;
    expect(target.operationId, targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(target.appleOperationUuid, isNotNull);
    expect(target.serverRecordIdHash, digestFor('S'));
    expect(target.protectedLeaseReference, isNotNull);
    expect(native.reconcileCalls, 1);
    expect(native.commitLeaseCalls, 0);
    expect(native.ackLeaseCalls, 0);
    expect(native.rawReadbackCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('restart at confirmed retained receipt finalizes to settled', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    await durable().commitOutboxCreateReceipt(scope(), leaseId: 'previous-upload-seed', receipt: CloudOutboxCreateReceipt(operationId: targetId, logicalEntityKeyHash: digestFor('T'), serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue), retainProtectedLeaseReference: true, now: testEpoch);
    currentTime = testEpoch.add(const Duration(minutes: 5));
    await reopen();
    scriptCommitted();
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.settled);
    final target = (await durable().readOutboxEntries(scope())).single;
    expect(target.status, CloudOutboxStatus.confirmed);
    expect(target.protectedLeaseReference, isNull);
    expect(native.reconcileCalls, 0);
    expect(native.rawReadbackCalls, 1);
    expect(native.commitLeaseCalls, 1);
    expect(native.ackLeaseCalls, 2);
    expect(native.unexpectedCalls, 0);
  });
  test('restart at pending raw readback resumes finalize without verify', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    await durable().commitOutboxCreateReceipt(scope(), leaseId: 'previous-upload-seed', receipt: CloudOutboxCreateReceipt(operationId: targetId, logicalEntityKeyHash: digestFor('T'), serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue), retainProtectedLeaseReference: true, now: testEpoch);
    final confirmed = (await durable().readOutboxEntries(scope())).single;
    final journalAuthority = ObjectBoxCloudKitWriterAuthority.forTest(store: objectBox, buildDecision: CloudKitWriterOwnershipDecision(owner: CloudKitWriterOwner.v2, configurationValid: true));
    final ownerSnapshot = journalAuthority.read(writerScope())!;
    final replayStore = ObjectBoxCloudSyncStore(store: objectBox, protector: protector, localSendJournal: CloudSyncLocalSendJournal(store: objectBox, authority: journalAuthority, authoritySnapshot: ownerSnapshot));
    await replayStore.commitConfirmedMessageCreateReadback(expectedOperation: confirmed, receipt: CloudOutboxCreateReceipt(operationId: targetId, logicalEntityKeyHash: digestFor('T'), serverRecordIdHash: digestFor('S'), etagHash: receiptEtagValue, protectedCurrentRawRecordReference: testProtectedReference('Q'), protectedCurrentRawRecordLeaseReference: testProtectedLeaseReference('c'), rawGeneration: 1), now: DateTime.now().toUtc());
    currentTime = testEpoch.add(const Duration(minutes: 5));
    await reopen();
    scriptCommitted();
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.settled);
    expect(native.rawReadbackCalls, 0);
    expect(native.commitLeaseCalls, 1);
    expect(native.ackLeaseCalls, 2);
    final target = (await durable().readOutboxEntries(scope())).single;
    expect(target.protectedLeaseReference, isNull);
    expect(native.unexpectedCalls, 0);
  });
  test('auth replacement stops the check with bindings unchanged', () async {
    await provisionV2();
    await seedAccount();
    await seedSubmittedTarget();
    flipSessionId = 'F' * 43;
    flipAfterReads = 1;
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_receipt_check_binding_changed')));
    final target = (await durable().readOutboxEntries(scope())).single;
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(native.reconcileCalls, 0);
    expect(native.stageCalls, 0);
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('revoked runtime stops the check before any outbox mutation', () async {
    await provisionV2();
    await seedAccount();
    await seedSubmittedTarget();
    runtimeBudget = 2;
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_receipt_check_preflight_blocked')));
    expect(native.reconcileCalls, 0);
    final target = (await durable().readOutboxEntries(scope())).single;
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(native.unexpectedCalls, 0);
  });
  test('multiple unresolved rows reject before any reconcile', () async {
    await provisionV2();
    await seedAccount();
    await seedSubmittedTarget();
    final second = buildOp(logicalCharacter: 'U', revision: 8, payloadShaCharacter: '8', leaseCharacter: 'e');
    await durable().enqueueOutbox(second);
    await durable().leaseEligibleOutbox(scope(), now: testEpoch, limit: 1, leaseId: 'previous-upload-second', leaseDuration: const Duration(minutes: 1), allowedActions: const <CloudOutboxAction>{CloudOutboxAction.save});
    await durable().markOutboxSubmissionStarted(scope(), leaseId: 'previous-upload-second', submissionIdentity: CloudOutboxSubmissionIdentity(requestUuid: requestUuidValue, operationUuids: <String, String>{second.operationId: operationUuidFor(8)}), now: testEpoch);
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_receipt_check_candidate_required')));
    expect(native.reconcileCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('foreign account rows reject before any reconcile', () async {
    await provisionV2();
    await seedAccount();
    await seedSubmittedTarget();
    final foreignScope = CloudSyncScope(accountFingerprint: testAccountFingerprintB, container: 'com.apple.messages.cloud', database: 'private', zone: 'messageManateeZone', streamKind: CloudSyncStreamKind.messages, schemaVersion: 2, persistenceLane: CloudSyncPersistenceLane.semantic);
    objectBox.box<CloudOutboxOperationEntity>().put(CloudOutboxOperationEntity(operationId: CloudOperationIdentity.forInitialCreate(scope: foreignScope, logicalEntityKeyHash: digestFor('F'), payloadVersion: cloudSyncOutboundPayloadVersion), scopeKey: cloudSyncPersistentScopeKey(foreignScope), accountFingerprint: testAccountFingerprintB, zone: 'messageManateeZone', logicalEntityKeyHash: digestFor('F'), action: 0, payloadVersion: cloudSyncOutboundPayloadVersion, mutationRevision: 1, checkpointGeneration: 1, state: CloudOutboxStatus.unknownOutcome.index, appleRequestUuid: requestUuidValue, appleOperationUuid: operationUuidFor(20), protectedLeaseReference: testProtectedLeaseReference('b'), leaseExpiresAtMs: 0, createdAtMs: testEpoch.millisecondsSinceEpoch, updatedAtMs: testEpoch.millisecondsSinceEpoch));
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_receipt_check_inventory_changed')));
    expect(native.reconcileCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('active lease rejects before any reconcile', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    final leased = await durable().leaseUnknownOutcomes(scope(), now: DateTime.now().toUtc(), limit: 1, leaseId: 'previous-upload-active', leaseDuration: const Duration(hours: 1));
    expect(leased, hasLength(1));
    expect(leased.single.operationId, targetId);
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_receipt_check_lease_active')));
    expect(native.reconcileCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('native setup failure preserves exact durable state and surfaces check failure', () async {
    await provisionV2();
    await seedAccount();
    final auditId = await seedSettledRow(logicalCharacter: 'A', revision: 1, uuidIndex: 1, serverCharacter: 'K');
    final targetId = await seedSubmittedTarget();
    final before = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    final beforeBinding = cloudKitWriterReconciliationBindingSha256(before);
    final pin = checkpointPin();
    final auditBefore = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == auditId);
    final outboxBefore = ObjectBoxCloudSyncPreflightReader(store: objectBox).read().outboxCount;
    native.reconcileResult = const frb_api.CloudSyncOutboundReconcileResult(failure: frb_api.CloudSyncOutboundSafeCode.nativeAuthUnavailable);
    await expectLater(runCheck(), throwsA(isA<CloudSyncFailure>().having((CloudSyncFailure e) => e.safeCode, 'safeCode', 'cloud_sync_outbound_native_auth_unavailable')));
    final target = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, before.appleRequestUuid);
    expect(target.appleOperationUuid, before.appleOperationUuid);
    expect(target.logicalEntityKeyHash, before.logicalEntityKeyHash);
    expect(target.encryptedPayloadReference, before.encryptedPayloadReference);
    expect(target.payloadSha256, before.payloadSha256);
    expect(target.serverRecordIdHash, before.serverRecordIdHash);
    expect(target.protectedLeaseReference, before.protectedLeaseReference);
    expect(target.checkpointGeneration, before.checkpointGeneration);
    expect(cloudKitWriterReconciliationBindingSha256(target), beforeBinding);
    expect(target.attemptCount, before.attemptCount + 1);
    expect(target.leaseId, isNull);
    expect(target.nextEligibleAt, isNotNull);
    expect(checkpointPin(), pin);
    final auditAfter = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == auditId);
    expect(auditAfter.status, CloudOutboxStatus.confirmed);
    expect(auditAfter.serverRecordIdHash, auditBefore.serverRecordIdHash);
    expect(ObjectBoxCloudSyncPreflightReader(store: objectBox).read().outboxCount, outboxBefore);
    expect(auditAfter.sameDurableSnapshotAs(auditBefore), isTrue);
    expect(ObjectBoxCloudSyncPreflightReader(store: objectBox).read().settledOutboxFingerprint, isNull);
    expect(native.reconcileCalls, 1);
    expect(native.rawReadbackCalls, 0);
    expect(native.commitLeaseCalls, 0);
    expect(native.ackLeaseCalls, 0);
    expect(native.stageCalls, 0);
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('thrown bridge failure preserves unknown operation and surfaces instead of unresolved', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    final before = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    native.reconcileThrow = StateError('bridge_simulated_failure');
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'bridge_simulated_failure')));
    final target = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, before.appleRequestUuid);
    expect(target.appleOperationUuid, before.appleOperationUuid);
    expect(target.serverRecordIdHash, before.serverRecordIdHash);
    expect(target.protectedLeaseReference, before.protectedLeaseReference);
    expect(target.leaseId, isNull);
    expect(native.reconcileCalls, 1);
    expect(native.rawReadbackCalls, 0);
    expect(native.stageCalls, 0);
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('cold bootstrap failure surfaces before any lease or reconcile', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    final before = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    native.warmUnderPauseThrow = StateError('cloud_sync_native_auth_warm_failed');
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_native_auth_warm_failed')));
    final target = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, before.appleRequestUuid);
    expect(target.appleOperationUuid, before.appleOperationUuid);
    expect(target.serverRecordIdHash, before.serverRecordIdHash);
    expect(target.protectedLeaseReference, before.protectedLeaseReference);
    expect(target.leaseId, isNull);
    expect(writerPause.pauseCalls, 1);
    expect(writerPause.resumeCalls, 1);
    expect(native.warmUnderPauseCalls, 1);
    expect(native.reconcileCalls, 0);
    expect(native.rawReadbackCalls, 0);
    expect(native.stageCalls, 0);
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('pause released before writer lookup on genuine unresolved path', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    native.reconcileResult = const frb_api.CloudSyncOutboundReconcileResult(disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved);
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.unresolved);
    expect(native.events, <String>['pause', 'warm', 'resume', 'reconcile']);
    expect(writerPause.pauseCalls, 1);
    expect(writerPause.resumeCalls, 1);
    final target = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(native.reconcileCalls, 1);
    expect(native.unexpectedCalls, 0);
  });
  test('identity change across warming stops check with rows preserved', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    flipSessionId = 'F' * 43;
    flipAfterReads = 3;
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_receipt_check_binding_changed')));
    final target = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(writerPause.pauseCalls, 1);
    expect(writerPause.resumeCalls, 1);
    expect(native.reconcileCalls, 0);
    expect(native.stageCalls, 0);
    expect(native.prepareCalls, 0);
    expect(native.consumeCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('ambiguous pause acquisition poisons until test cleanup', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    writerPause.pauseThrow = const CloudSyncNativeWriterPauseUncertain();
    await expectLater(runCheck(), throwsA(isA<CloudSyncNativeWriterPauseUncertain>()));
    final target = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(target.appleOperationUuid, isNotNull);
    expect(target.serverRecordIdHash, digestFor('S'));
    expect(target.protectedLeaseReference, isNotNull);
    expect(target.leaseId, isNull);
    expect(native.warmUnderPauseCalls, 0);
    expect(native.reconcileCalls, 0);
    expect(writerPause.pauseCalls, 1);
    expect(writerPause.resumeCalls, 0);
    await expectLater(runCheck(), throwsA(isA<CloudKitOperationInterlockException>()));
    final stillBlocked = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(stillBlocked.status, CloudOutboxStatus.unknownOutcome);
    await CloudKitOperationInterlock.debugResetPoisonedLocksForTesting();
    writerPause.pauseThrow = null;
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.unresolved);
    expect(native.reconcileCalls, 1);
    expect(native.unexpectedCalls, 0);
  });
  test('resume failure after warm poisons with rows preserved', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    writerPause.resumeThrow = StateError('cloud_sync_native_writer_resume_failed');
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_native_writer_resume_failed')));
    final target = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(target.serverRecordIdHash, digestFor('S'));
    expect(target.protectedLeaseReference, isNotNull);
    expect(target.leaseId, isNull);
    expect(native.warmUnderPauseCalls, 1);
    expect(native.reconcileCalls, 0);
    expect(writerPause.pauseCalls, 1);
    expect(writerPause.resumeCalls, 1);
    await expectLater(runCheck(), throwsA(isA<CloudKitOperationInterlockException>()));
    await CloudKitOperationInterlock.debugResetPoisonedLocksForTesting();
    writerPause.resumeThrow = null;
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.unresolved);
    expect(native.reconcileCalls, 1);
    expect(native.unexpectedCalls, 0);
  });
  test('warm failure with failed resume surfaces resume failure and poisons', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    native.warmUnderPauseThrow = StateError('cloud_sync_native_auth_warm_failed');
    writerPause.resumeThrow = StateError('cloud_sync_native_writer_resume_failed');
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_native_writer_resume_failed')));
    final target = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(native.warmUnderPauseCalls, 1);
    expect(native.reconcileCalls, 0);
    await expectLater(runCheck(), throwsA(isA<CloudKitOperationInterlockException>()));
    await CloudKitOperationInterlock.debugResetPoisonedLocksForTesting();
    writerPause.resumeThrow = null;
    native.warmUnderPauseThrow = null;
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.unresolved);
    expect(native.unexpectedCalls, 0);
  });
  test('warm failure with successful resume permits safe retry', () async {
    await provisionV2();
    await seedAccount();
    final targetId = await seedSubmittedTarget();
    native.warmUnderPauseThrow = StateError('cloud_sync_native_auth_warm_failed');
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_native_auth_warm_failed')));
    expect(writerPause.resumeCalls, 1);
    expect(native.reconcileCalls, 0);
    native.warmUnderPauseThrow = null;
    final result = await runCheck();
    expect(result, CloudSyncPreviousUploadResult.unresolved);
    expect(native.reconcileCalls, 1);
    final target = (await durable().readOutboxEntries(scope())).singleWhere((CloudOutboxOperation o) => o.operationId == targetId);
    expect(target.status, CloudOutboxStatus.unknownOutcome);
    expect(target.appleRequestUuid, isNotNull);
    expect(native.unexpectedCalls, 0);
  });
}
