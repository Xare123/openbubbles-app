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
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';
import 'cloud_sync_test_helpers.dart';
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
  frb_api.CloudSyncOutboundReconcileResult reconcileResult = const frb_api.CloudSyncOutboundReconcileResult(disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved);
  frb_api.CloudSyncOutboundReconcileResult rawReadbackResult = const frb_api.CloudSyncOutboundReconcileResult(disposition: frb_api.CloudSyncOutboundReconcileDisposition.unresolved);
  Never unexpected(String name) {
    unexpectedCalls++;
    throw StateError('unexpected native call ' + name);
  }
  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({required Object cloudMessagesClient, required String storageDirectory, required String expectedAccountFingerprint, required String expectedProtectedStoreIdentity, required String requestUuid, required frb_api.CloudSyncPreparedMessageCreateInput input}) async {
    reconcileCalls++;
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
  @override
  Future<void> warmReadAuthenticationUnderWriterPause({required Object cloudMessagesClient, required BigInt pauseToken}) async {}
  @override
  Future<CloudSyncNativeAuthMetadata> capture({required Object cloudMessagesClient, required String privateStorageDirectory}) async => CloudSyncNativeAuthMetadata(nativeSessionId: 'N' * 43, accountFingerprint: testAccountFingerprintA, protectedStoreIdentity: 'obcs2.store.' + testAccountFingerprintA);
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
  Future<CloudSyncPreviousUploadResult> runCheck() => checkCloudSyncPreviousMessageUpload(store: objectBox, protector: protector, readAuth: readAuth, readActiveClient: () => activeClient, nativeAuthBinding: native, bindings: native, readPreflight: readPreflight, runtimeAllowed: runtimeAllowed, storageDirectory: directory.path);
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
  test('settled create with audit rows runs exact readback to settled preflight', () async {
    await seedAccount();
    await provisionV2();
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
    await seedAccount();
    await provisionV2();
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
    await seedAccount();
    await provisionV2();
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
    await seedAccount();
    await provisionV2();
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
    await seedAccount();
    await provisionV2();
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
    await seedAccount();
    await provisionV2();
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
    await seedAccount();
    await provisionV2();
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
    await seedAccount();
    await provisionV2();
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
    await seedAccount();
    await provisionV2();
    await seedSubmittedTarget();
    final foreignScope = CloudSyncScope(accountFingerprint: testAccountFingerprintB, container: 'com.apple.messages.cloud', database: 'private', zone: 'messageManateeZone', streamKind: CloudSyncStreamKind.messages, schemaVersion: 2, persistenceLane: CloudSyncPersistenceLane.semantic);
    objectBox.box<CloudOutboxOperationEntity>().put(CloudOutboxOperationEntity(operationId: CloudOperationIdentity.forInitialCreate(scope: foreignScope, logicalEntityKeyHash: digestFor('F'), payloadVersion: cloudSyncOutboundPayloadVersion), scopeKey: cloudSyncPersistentScopeKey(foreignScope), accountFingerprint: testAccountFingerprintB, zone: 'messageManateeZone', logicalEntityKeyHash: digestFor('F'), action: 0, payloadVersion: cloudSyncOutboundPayloadVersion, mutationRevision: 1, checkpointGeneration: 1, state: CloudOutboxStatus.unknownOutcome.index, appleRequestUuid: requestUuidValue, appleOperationUuid: operationUuidFor(20), protectedLeaseReference: testProtectedLeaseReference('b'), leaseExpiresAtMs: 0, createdAtMs: testEpoch.millisecondsSinceEpoch, updatedAtMs: testEpoch.millisecondsSinceEpoch));
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_receipt_check_inventory_changed')));
    expect(native.reconcileCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
  test('active lease rejects before any reconcile', () async {
    await seedAccount();
    await provisionV2();
    final targetId = await seedSubmittedTarget();
    final leased = await durable().leaseUnknownOutcomes(scope(), now: DateTime.now().toUtc(), limit: 1, leaseId: 'previous-upload-active', leaseDuration: const Duration(hours: 1));
    expect(leased, hasLength(1));
    expect(leased.single.operationId, targetId);
    await expectLater(runCheck(), throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'cloud_sync_receipt_check_lease_active')));
    expect(native.reconcileCalls, 0);
    expect(native.unexpectedCalls, 0);
  });
}
