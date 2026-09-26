import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated protected DTOs expose no raw CloudKit material', () {
    final source = File('lib/src/rust/api/api.dart').readAsStringSync();
    final start = source.indexOf('class CloudSyncProtectedChange {');
    final end = source.indexOf('enum CloudSyncProtectedSafeCode {');
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final protectedSurface = source.substring(start, end);
    final forbidden = <RegExp>[
      RegExp(r'\brecordName\b'),
      RegExp(r'\betag\b'),
      RegExp(r'\bcontinuationToken\b'),
      RegExp(r'\bencryptedRecord\b'),
      RegExp(r'\btombstonePayload\b'),
      RegExp(r'\bcredentials\b'),
      RegExp(r'\bplaintext\b'),
      RegExp(r'\bstorageDirectory\b'),
      RegExp(r'\bfilePath\b'),
    ];

    for (final pattern in forbidden) {
      expect(
        pattern.hasMatch(protectedSurface),
        isFalse,
        reason: 'generated protected DTO boundary exposed ${pattern.pattern}',
      );
    }
  });

  test('protected transport is constructed only by reviewed gated compositions', () {
    final constructors = <String>[];
    const allowed =
        'lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
    const localSource = 'lib/services/rustpush/rustpush_service.dart';
    const windowsSource = 'lib/cloud_sync_v2_windows_local_write.dart';
    const receivedSource = 'lib/services/rustpush/cloud_sync/cloud_sync_received_inspection_adapter.dart';
    const receivedReader = 'lib/services/rustpush/cloud_sync/cloud_sync_received_reader_adapter.dart';
    const receivedDiscovery = 'lib/services/rustpush/cloud_sync/cloud_sync_received_discovery_retain_adapter.dart';

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final normalizedPath = entity.path.replaceAll(r'\', '/');
      if (normalizedPath.endsWith(
        '/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart',
      )) {
        continue;
      }
      if (entity.readAsStringSync().contains(
        'NativeProtectedCloudSyncTransport(',
      )) {
        constructors.add(entity.path);
      }
    }

    final normalized = constructors
        .map((path) => path.replaceAll(r'\', '/'))
        .toList(growable: false);
    expect(
      normalized,
      unorderedEquals([allowed, localSource, windowsSource, receivedSource, receivedReader, receivedDiscovery]),
      reason:
          'only reviewed canary adapters, source staging, received inspection/reader handoff and source-bound discovery construct this transport',
    );
    final discovery = File(receivedDiscovery).readAsStringSync();
    for (final gate in [
      'CloudSyncDevGate.receivedArchiveCaptureEnabled',
      'CloudSyncDevGate.receivedArchiveInspectionEnabled',
      'CloudSyncDevGate.manualSemanticPullEnabled',
      'CloudKitWriterOwnership.v2MutationsEnabled',
      'runProtectedStoreExclusive',
      'runLocalProtectedStoreExclusive',
      'rollbackProtectedPageLease',
      'quiesceNativeOperations',
      'cloudSyncDiscardReceivedDiscovery',
    ]) {
      expect(discovery, contains(gate), reason: 'source-bound discovery must keep $gate');
    }
    expect(RegExp('NativeProtectedCloudSyncTransport\\\(').allMatches(discovery).length, 1);
    for (final forbidden in [
      'requireCloudSyncRestoredDirectChat',
      'validateReaderAdmission',
      'journalReceivedFound(',
      'markReaderAdopted',
      'cloudSyncPrepareReceivedArchiveInspection',
      'cloudSyncStageReceivedFoundProjection',
    ]) {
      expect(discovery, isNot(contains(forbidden)),
        reason: 'discovery must never use parent-bound admission $forbidden');
    }

    final adapter = File(allowed).readAsStringSync();
    final windows = File(windowsSource).readAsStringSync();
    final windowsRun = windows.substring(
      windows.indexOf('Future<Map<String, Object?>> run()'),
    );
    final windowsTransport = windowsRun.indexOf(
      'NativeProtectedCloudSyncTransport(',
    );
    expect(windowsTransport, greaterThan(0));
    final windowsGate = windowsRun.substring(0, windowsTransport);
    for (final gate in [
      '!Platform.isWindows',
      '!fs.cloudSyncV2WindowsDevProfileActive',
      '!CloudSyncDevGate.manualOutboundCanaryEnabled',
      '!CloudKitWriterOwnership.v2MutationsEnabled',
      'CloudSyncLocalSendSourceStaging',
    ]) {
      // Staging follows construction; platform and build gates precede it.
      expect(
        gate == 'CloudSyncLocalSendSourceStaging' ? windowsRun : windowsGate,
        contains(gate),
      );
    }
    final mutationStart = windowsRun.indexOf(
      'Future<Map<String, Object?>> _runMutation(',
    );
    expect(mutationStart, greaterThan(0));
    final initialSend = windowsRun.substring(0, mutationStart);
    final mutationSend = windowsRun.substring(mutationStart);
    final constructorPattern = RegExp(r'NativeProtectedCloudSyncTransport\(');
    expect(constructorPattern.allMatches(initialSend).length, 1);
    expect(constructorPattern.allMatches(mutationSend).length, 1);
    expect(constructorPattern.allMatches(windows).length, 2);
    expect(initialSend, contains('if (request.mutationType != null)'));
    expect(initialSend, contains('return _runMutation('));
    expect(
      initialSend.indexOf('return _runMutation('),
      lessThan(windowsTransport),
    );
    expect(
      mutationSend,
      contains('final staging = CloudSyncLocalMutationSourceStaging('),
    );
    expect(mutationSend, contains('exclusion: interlock'));
    expect(
      mutationSend,
      contains('final transport = NativeProtectedCloudSyncTransport('),
    );
    expect(mutationSend, contains('transport: transport'));
    expect(mutationSend, contains('await staging.submitConfirmed('));
    expect(mutationSend, contains('cloudSyncStageIdsMutationSource('));
    expect(mutationSend, contains('cloudSyncRestoreIdsMutationSource('));
    expect(
      mutationSend,
      contains('sendMutationConfirmed!(wire, context(source))'),
    );
    expect(mutationSend, contains('await staging.reflectConfirmed('));
    expect(mutationSend, contains('if (replay && intent.state >= 1)'));
    expect(
      mutationSend,
      contains('cloud_sync_windows_mutation_retained_receipt_missing'),
    );
    for (final forbidden in [
      'sendConfirmed(',
      'CloudSyncLocalSendSourceStaging(',
      'cloudSyncPrepareMessageCreate(',
    ]) {
      expect(mutationSend, isNot(contains(forbidden)));
    }
    expect(mutationSend, contains('cloudSyncAcknowledgeNativeSendReceipt('));
    expect(windowsRun, contains('await CloudSyncLocalSendSourceStaging('));
    expect(windowsRun, contains('exclusion: interlock'));
    expect(windowsRun, contains('cloudSyncStageIdsAttachmentSource('));
    expect(
      windowsRun.indexOf('await CloudSyncLocalSendSourceStaging('),
      lessThan(windowsRun.indexOf('await sendConfirmed(wire)')),
    );
    for (final forbidden in [
      'transport.stageOutboundMessage(',
      'transport.stageOutboundChat(',
      'transport.save',
      'transport.fetch',
      'CloudSyncEngine(',
      'flushOutbox(',
    ]) {
      expect(windowsRun, isNot(contains(forbidden)));
    }
    expect(
      RegExp(r'NativeProtectedCloudSyncTransport\(').allMatches(adapter).length,
      6,
      reason:
          'shadow, semantic pull, local send, local staged observation, one-text outbound, and previous-upload receipt check are the only compositions',
    );
    expect(adapter, contains('NativeProtectedCloudSyncBindings?'));
    expect(adapter, isNot(contains('RustCloudSyncTransport(')));

    final shadowStart = adapter.indexOf(
      'final class CloudSyncProductionSamplerAdapter',
    );
    final semanticStart = adapter.indexOf(
      'final class CloudSyncProductionSemanticPullAdapter',
    );
    final outboundStart = adapter.indexOf(
      'final class CloudSyncProductionOutboundCanaryAdapter',
    );
    final localSendStart = adapter.indexOf(
      'final class CloudSyncProductionLocalSendAdapter',
    );
    final stagedStart = adapter.indexOf(
      'Future<T> cloudSyncObserveStagedChat<T>',
    );
    final previousUploadStart = adapter.indexOf(
      'Future<CloudSyncPreviousUploadResult> checkCloudSyncPreviousMessageUpload(',
    );
    final previousUploadEnd = adapter.indexOf(
      'typedef _CanaryOutboxRead',
      previousUploadStart,
    );
    expect(shadowStart, greaterThanOrEqualTo(0));
    expect(semanticStart, greaterThan(shadowStart));
    expect(localSendStart, greaterThan(semanticStart));
    expect(outboundStart, greaterThan(localSendStart));
    expect(stagedStart, greaterThan(localSendStart));
    expect(outboundStart, greaterThan(stagedStart));
    expect(previousUploadStart, greaterThan(outboundStart));
    expect(previousUploadEnd, greaterThan(previousUploadStart));
    final shadowComposition = adapter.substring(shadowStart, semanticStart);
    final semanticComposition = adapter.substring(
      semanticStart,
      localSendStart,
    );
    final localSendComposition = adapter.substring(localSendStart, stagedStart);
    final stagedComposition = adapter.substring(stagedStart, outboundStart);
    final outboundComposition = adapter.substring(outboundStart, previousUploadStart);
    final previousUploadComposition = adapter.substring(
      previousUploadStart,
      previousUploadEnd,
    );
    final previousUploadTransportStart = previousUploadComposition.indexOf(
      'NativeProtectedCloudSyncTransport(',
    );
    expect(previousUploadTransportStart, greaterThan(0));
    final previousUploadGate = previousUploadComposition.substring(
      0,
      previousUploadTransportStart,
    );
    for (final gate in [
      '!runtimeAllowed()',
      'bindings is! CloudKitWriterReconciliationBinding',
      'interlock.runExclusive(kind: CloudKitOperationKind.v2ReadWrite',
      'await requireReady()',
      'candidates.length != 1',
      "throw StateError('cloud_sync_receipt_check_lease_active')",
    ]) {
      expect(previousUploadGate, contains(gate));
    }
    expect(previousUploadComposition, contains('guard.reconcileUnknownOutcome('));
    expect(previousUploadComposition, contains('transport.verifyConfirmedMessageCreateNoSave('));
    expect(previousUploadComposition, contains('await transport.quiesceNativeOperations()'));
    for (final forbidden in [
      'CloudSyncEngine(',
      'flushOutbox(',
      'admitProtectedOutbound',
      'stageOutboundMessage(',
      'stageOutboundChat(',
      'pushOperations(',
      'sendMsg(',
      'provisionInitialOwner(',
    ]) {
      expect(previousUploadComposition, isNot(contains(forbidden)));
    }
    expect(
      stagedComposition.indexOf('!CloudSyncDevGate.manualSemanticPullEnabled'),
      lessThan(stagedComposition.indexOf('NativeProtectedCloudSyncTransport(')),
    );
    expect(
      stagedComposition,
      contains('await transport.rollbackOutboundLease(staged.leaseReference)'),
    );
    expect(stagedComposition, contains('CloudSyncWriteChatIdentitySession('));
    // Restored credentials are cold in a fresh Windows process. Establish
    // read authentication under the interlock BEFORE capturing its identity.
    expect(
      stagedComposition.indexOf('interlock.runExclusive('),
      lessThan(
        stagedComposition.indexOf(
          'await authBinding.ensureReadAuthentication(',
        ),
      ),
    );
    expect(
      stagedComposition.indexOf('await authBinding.ensureReadAuthentication('),
      lessThan(stagedComposition.indexOf('await authProvider.capture()')),
    );
    const lookupPreparation = 'await session.run<void>((_) async {})';
    expect(stagedComposition, contains(lookupPreparation));
    expect(
      stagedComposition.indexOf(lookupPreparation),
      lessThan(stagedComposition.indexOf('await transport.stageOutboundChat(')),
    );
    final recoveryStart = localSendComposition.indexOf(
      'Future<void> recoverProtectedStore()',
    );
    expect(recoveryStart, greaterThan(0));
    final recoveryEnd = localSendComposition.indexOf(
      'Future<CloudSyncChatIdentityEvidence?>',
      recoveryStart,
    );
    expect(recoveryEnd, greaterThan(recoveryStart));
    expect(
      localSendComposition.substring(recoveryStart, recoveryEnd),
      contains('await identitySession.run<void>((_) async {})'),
    );
    for (final forbidden in [
      'commitOutboundLease(',
      'stageOutboundMessage(',
      'admitProtectedOutbound',
      'CloudSyncEngine(',
      'flushOutbox(',
    ]) {
      expect(stagedComposition, isNot(contains(forbidden)));
    }
    final localTransportStart = localSendComposition.indexOf(
      'NativeProtectedCloudSyncTransport(',
    );
    expect(localTransportStart, greaterThan(0));
    final localSendGate = localSendComposition.substring(
      0,
      localTransportStart,
    );
    for (final gate in [
      '!CloudKitWriterOwnership.v2MutationsEnabled',
      '!CloudSyncDevGate.manualOutboundCanaryEnabled',
      '!CloudSyncDevGate.localSendRuntimeEnabled',
      "throw StateError('cloud_sync_local_send_consumer_disabled')",
    ]) {
      expect(localSendGate, contains(gate));
    }
    for (final composition in [
      shadowComposition,
      semanticComposition,
      localSendComposition,
      stagedComposition,
      outboundComposition,
      previousUploadComposition,
    ]) {
      expect(
        RegExp(
          r'NativeProtectedCloudSyncTransport\(',
        ).allMatches(composition).length,
        1,
        reason: 'each reviewed adapter owns exactly one protected transport',
      );
    }
    expect(
      shadowComposition,
      isNot(contains('nativeWriterPauseToken: pauseToken')),
      reason: 'the non-projecting shadow diagnostic remains explicitly unbound',
    );
    expect(
      semanticComposition,
      contains('createRawTransport: (snapshot, scope, pauseToken)'),
    );
    expect(
      semanticComposition,
      contains('nativeWriterPauseToken: pauseToken'),
      reason:
          'semantic protected fetch must carry the exact active writer-pause capability',
    );
  });

  test('received capture is independently gated and performs no upload', () {
    final service = File('lib/services/rustpush/rustpush_service.dart').readAsStringSync();
    final received = _section(service, 'Future<Message> _captureCloudSyncV2ReceivedMessage(',
        '// Local intent capture only.');
    for (final fence in [
      '!CloudSyncDevGate.receivedArchiveCaptureEnabled',
      '!CloudKitWriterOwnership.v2MutationsEnabled',
      '!_cloudSyncV2CanaryRuntimeAllowed', '!_cloudSyncV2DeveloperRuntimeAllowed',
      'ss.settings.cloudSyncingEnabled.value', 'wire.receivedOnHandle == null',
      'owner.owner != CloudKitWriterOwner.v2', 'journal.hasOutgoingOrigin(wire.id)',
      'CloudSyncReceivedArchiveStaging.persistSealed(', 'api.cloudSyncSealReceivedArchiveSeed(',
    ]) { expect(received, contains(fence)); }
    expect(received, isNot(contains('pushOperations(')));
    expect(received, isNot(contains('sendMsg(')));
    expect(received, isNot(contains('CloudOutboxOperation(')));
    expect(received, isNot(contains('NativeProtectedCloudSyncTransport(')));
    expect(received, isNot(contains('runLocalProtectedStoreExclusive(')));
    final materialize = _section(service, 'Future<({bool more, bool deferred})> _materializeCloudSyncV2ReceivedSources()',
        'Future<Message> _captureCloudSyncV2ReceivedMessage(');
    expect(materialize, contains('onlyPendingMaterialization: !CloudSyncDevGate.receivedArchiveInspectionEnabled'));
    expect(materialize, contains('if (CloudSyncDevGate.receivedArchiveInspectionEnabled)'));
    expect(materialize, isNot(contains('onlyWithoutObservation')));
    expect(materialize, contains('maximumIntentId: _cloudSyncV2ReceivedRoundCeiling'));
    expect(materialize, contains('api.cloudSyncStageReceivedArchiveSeed('));
    expect(materialize, contains('await transport.quiesceNativeOperations()'));
    expect(materialize, isNot(contains('pushOperations(')));
    expect(materialize, isNot(contains('sendMsg(')));
    expect(service, contains('ls.retainEngineUntil(_materializeCloudSyncV2ReceivedSources)'));
    final gate = File('lib/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart').readAsStringSync();
    expect(gate, matches(RegExp(
        r"receivedArchiveCaptureEnabled = bool.fromEnvironment\(\s*'OPENBUBBLES_CLOUD_SYNC_V2_RECEIVED_CAPTURE',\s*defaultValue: false")));
    final reset = _section(service, 'Future reset(bool hw, bool logout, bool setup)',
        '_cloudSyncV2OutboundQuiescing = false;');
    expect(reset.indexOf('_drainCloudSyncV2ReceivedCaptures()'), greaterThan(0));
    expect(reset.indexOf('_drainCloudSyncV2ReceivedCaptures()'),
        lessThan(reset.indexOf('_runCloudKitDestructiveReset(')));
  });

  test('received inspection adapter cannot turn an observation into a save', () {
    final adapter=File('lib/services/rustpush/cloud_sync/cloud_sync_received_inspection_adapter.dart').readAsStringSync();
    for(final proof in ['!CloudSyncDevGate.receivedArchiveCaptureEnabled',
        '!CloudSyncDevGate.receivedArchiveInspectionEnabled',
        '!CloudKitWriterOwnership.v2MutationsEnabled',
        'readMaterializedForInspection(', 'requireCloudSyncRestoredDirectChatProof(',
        'CloudSyncWriteChatIdentitySession(', 'nativeWriterPauseToken: token',
        'cloudSyncPrepareReceivedArchiveInspection(',
        'api.cloudSyncStageReceivedArchiveInspection(',
        'api.cloudSyncDiscardReceivedArchiveInspection(',
        'await transport.quiesceNativeOperations()']) {
      expect(adapter,contains(proof));
    }
    for(final forbidden in ['pushOperations(', 'consumePrepared', 'sendMsg(', 'admitProtectedOutboundCreate(']) {
      expect(adapter,isNot(contains(forbidden)));
    }
    final native = File('rust/src/api/api.rs').readAsStringSync();
    final prepare = _section(native, 'pub async fn cloud_sync_prepare_received_archive_inspection(',
        'pub async fn cloud_sync_stage_received_archive_inspection(');
    expect(prepare, contains('lookup_received_message_record('));
    expect(prepare, isNot(contains('cloud_sync_stage_protected_received_record_readback(')));
    final stage = _section(native, 'pub async fn cloud_sync_stage_received_archive_inspection(',
        'pub async fn cloud_sync_discard_received_archive_inspection(');
    expect(stage, contains('pending.lock().await.take()'));
    expect(stage, contains('Arc::ptr_eq(&pending.container, &current_container)'));
    expect(stage, contains('bind_envelope(&request, &parent, &hasher)'));
    expect(stage, contains('cloud_sync_stage_protected_received_record_readback('));
    expect(stage, isNot(contains('lookup_received_message_record(')));
    expect(stage.substring(stage.indexOf('cloud_sync_stage_protected_received_record_readback(')),
        isNot(contains('.await')));
  });

  test('received Found joins the normal reader without making a cursor or IDS send', () {
    final adapter = File('lib/services/rustpush/cloud_sync/cloud_sync_received_reader_adapter.dart').readAsStringSync();
    for (final proof in ['!CloudSyncDevGate.receivedArchiveCaptureEnabled',
      '!CloudSyncDevGate.receivedArchiveInspectionEnabled', '!CloudSyncDevGate.manualSemanticPullEnabled',
      'readForReader(', 'journal.validateReaderAdmission(', 'journalReceivedFound(',
      'cloudSyncPrepareReceivedArchiveInspection(', 'cloudSyncStageReceivedFoundProjection(',
      'tryAcquireCoordinatorLease(', 'releaseCoordinatorLease(', 'runLocalProtectedStoreExclusive(',
      'lifecycle.commitJournaledPage(', 'previousCheckpointReference: null',
      'api.cloudSyncDiscardReceivedArchiveInspection(', 'await transport.quiesceNativeOperations()']) {
      expect(adapter, contains(proof));
    }
    for (final forbidden in ['sendMsg(', 'pushOperations(', 'journalFetchedBatch(',
      'fetchedTokenCiphertext =', 'pendingFetchedTokenCiphertext =', 'message.text =']) {
      expect(adapter, isNot(contains(forbidden)));
    }
    final service = File('lib/services/rustpush/rustpush_service.dart').readAsStringSync();
    final worker = _section(service, 'Future<({bool more, bool deferred})> _materializeCloudSyncV2ReceivedSources()',
      'Future<Message> _captureCloudSyncV2ReceivedMessage(');
    final uploadWorker = _section(service, 'void _queueCloudSyncV2LocalSends(',
      'Future<Message> _trackCloudSyncV2ReceivedCapture(');
    expect(uploadWorker, matches(RegExp(r"result\.deferredReasons\.containsKey\(\s*'cloud_sync_received_archive_not_absent'\)")));
    expect(uploadWorker, contains('_queueCloudSyncV2ReceivedSources(CloudSyncTrigger.localOutbox)'));
    for (final proof in ['journal.readFoundCandidates(', 'handoffCloudSyncReceivedFound(',
      'readerCheckpoint.hasUnmarkedPendingInbox', 'readerCheckpoint.pendingBatchId != null',
      'resumeAutomaticUploads: false',
      'journal.markReaderAttemptConsidered(', 'sweepRetainedAtHead: false', 'foundRemaining']) {
      expect(worker, contains(proof));
    }
    final native = File('rust/src/api/api.rs').readAsStringSync();
    final handoff = _section(native, 'pub async fn cloud_sync_stage_received_found_projection(',
      '/// Ephemeral native source');
    expect(handoff, contains('CloudSyncReceivedRecordDisposition::Equivalent'));
    expect(handoff, contains('CloudSyncReceivedRecordDisposition::NeedsProjection'));
    expect(handoff, contains('pending.prepared_at.elapsed()'));
    expect(handoff, contains('bind_envelope(&request, &parent, &hasher)'));
    expect(handoff, contains('page.protected_next_checkpoint_reference().is_some()'));
    expect(handoff, isNot(contains('lookup_received_message_record(')));
    expect(handoff, isNot(contains('prepare_message_save_submission(')));
  });

  test('received uploads require native absence and never an IDS receipt', () {
    final native = File('rust/src/api/api.rs').readAsStringSync();
    final stage = _section(native, 'pub async fn cloud_sync_stage_received_archive_create(',
        'pub async fn cloud_sync_open_received_archive_create_proof(');
    for (final required in ['pending.lock().await.take()',
        'CloudSyncReceivedRecordDisposition::Absent', 'pending.raw_found.is_some()',
        'pending.prepared_at.elapsed()', 'cloud_sync_validate_received_create_proof(',
        'stage_received_message(']) {
      expect(stage, contains(required));
    }
    for (final forbidden in ['send_message', 'sendMsg', 'positiveIdsReceipt',
        'prepare_message_save_submission', 'consume_once', 'source_binding: None']) {
      expect(stage, isNot(contains(forbidden)));
    }
    final open = _section(native, 'fn cloud_sync_open_message_create_bound(',
        'mod cloud_sync_attachment_parent_create_tests');
    expect(open, contains('input.received_archive_proof'));
    expect(open, contains('open_staged_received_message('));
    expect(open, contains('verify_deterministic_message_record_name('));
    final adapter = File('lib/services/rustpush/cloud_sync/cloud_sync_received_create_adapter.dart').readAsStringSync();
    expect(adapter, contains('!CloudSyncDevGate.receivedArchiveUploadsEnabled'));
    expect(adapter, contains('cloudSyncPrepareReceivedArchiveInspection('));
    expect(adapter, contains('cloudSyncStageReceivedArchiveCreate('));
    expect(adapter, contains('replaceAbsenceWithFound('));
    expect(adapter, contains('runLocalProtectedStoreExclusive('));
    expect(adapter, isNot(contains('CloudSyncNativeSendReceiptContext(')));
    expect(adapter, isNot(contains('sendMsg(')));
  });

  test('runtime transport is restricted to gated local IDS source leases', () {
    final service = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final capture = _section(
      service,
      'Future<_CloudSyncV2LocalSendContext?> _captureCloudSyncV2LocalSend(',
      'Future<api.CloudSyncNativeSendReceiptContext>',
    );
    final prepare = _section(
      service,
      'Future<api.CloudSyncNativeSendReceiptContext>',
      'Future<api.MessageInst> _restoreCloudSyncV2AttachmentWire(',
    );
    final send = _section(
      service,
      'Future<Message> _sendPreparedMessage(',
      'var backgroundSendPending = false;',
    );

    // No automatic-upload opt-in is required for local source preservation.
    // The only caller receives a nullable context from the separately gated
    // V2 capture path; disabling it cannot instantiate this transport.
    expect(
      capture,
      matches(
        RegExp(
          r'if \(!CloudKitWriterOwnership\.v2MutationsEnabled \|\|\s*'
          r'!CloudSyncDevGate\.manualOutboundCanaryEnabled\)\s*\{\s*return null;',
        ),
      ),
    );
    for (final fence in [
      '!_cloudSyncV2CanaryRuntimeAllowed',
      '!ls.isUiThread',
      'loggingOut',
      'ss.settings.cloudSyncingEnabled.value',
      'isSyncing.value != null',
      'statePath.isEmpty',
      '!objectBox.isClosed()',
      'identical(objectBox, Database.store)',
      'identical(currentState, state)',
      'identical(client, state?.icloudServices?.cloudMessagesClient)',
      'storagePath == statePath',
      'auth == null || !stillCurrent()',
      'authoritySnapshot.owner != CloudKitWriterOwner.v2',
      'authFence: CloudSyncLocalSendAuthFence(',
    ]) {
      expect(capture, contains(fence));
    }
    expect(
      send,
      contains(
        'var localCloudIntent = await pushService._captureCloudSyncV2LocalSend(',
      ),
    );
    expect(
      send,
      matches(
        RegExp(
          r'attachmentReceiptContext = localCloudIntent\?\.identity\.isAttachment == true\s*'
          r'\? await pushService\._prepareCloudSyncV2AttachmentSource\('
          r'\s*localCloudIntent!,\s*message: m,\s*chat: chat,\s*wire: msg,\s*\)\s*: null;',
        ),
      ),
    );
    expect(
      send.indexOf('await pushService._saveCloudSyncV2LocalSend('),
      lessThan(
        send.indexOf('await pushService._prepareCloudSyncV2AttachmentSource('),
      ),
    );
    expect(
      RegExp(
        r'_prepareCloudSyncV2AttachmentSource\(',
      ).allMatches(service).length,
      2,
      reason: 'one reviewed caller plus the private declaration',
    );
    expect(
      RegExp(r'NativeProtectedCloudSyncTransport\(').allMatches(service).length,
      4,
      reason:
          'attachment staging, mutation staging, receipt-bound conditional update, and local-only received seed materialization; foreground received capture has no file transport',
    );

    expect(
      prepare,
      contains('context.authFence.requireCurrentBinding(context.capturedAuth)'),
    );
    expect(
      prepare.indexOf('context.authFence.requireCurrentBinding('),
      lessThan(prepare.indexOf('NativeProtectedCloudSyncTransport(')),
    );
    expect(
      prepare,
      contains('!identical(client, context.capturedAuth.cloudMessagesClient)'),
    );
    expect(prepare, matches(RegExp(r'guids == null \|\|\s*guids\.isEmpty')));
    expect(
      prepare,
      matches(
        RegExp(
          r'final transport = NativeProtectedCloudSyncTransport\(\s*'
          r'cloudMessagesClient: client,\s*storageDirectory: original.storageDirectory,\s*'
          r'protectedStoreIdentity: original.protectedStoreIdentity,\s*\);',
        ),
      ),
      reason:
          'local leases need neither remote writer authority nor a read-pause capability',
    );
    expect(prepare, contains('final exclusion = CloudKitOperationInterlock('));
    expect(prepare, contains('CloudSyncLocalSendSourceStaging('));
    expect(
      prepare,
      matches(RegExp(r'exclusion: exclusion,\s*transport: transport')),
    );
    expect(
      RegExp(r'\btransport\b').allMatches(prepare).length,
      3,
      reason:
          'transport stays local and is passed only to the lease-only helper',
    );
    expect(
      prepare,
      contains('expectedSourceSha256: context.identity.sourceSha256'),
    );
    expect(
      prepare,
      contains('current?.sourceSha256 == context.identity.sourceSha256'),
    );
    expect(prepare, contains('await api.cloudSyncStageIdsAttachmentSource('));
    expect(
      prepare,
      contains('sourceBinding: api.CloudSyncNativeSendSourceBinding('),
    );

    final staging = File(
      'lib/services/rustpush/cloud_sync/cloud_sync_local_send_source_staging.dart',
    ).readAsStringSync();
    expect(
      staging,
      contains('final CloudProtectedPageLeaseTransport _transport;'),
    );
    expect(
      RegExp(
        r'\b_transport\.(\w+)',
      ).allMatches(staging).map((match) => match.group(1)).toSet(),
      unorderedEquals([
        'protectedPageLeaseRecoveryIdentity',
        'runProtectedStoreExclusive',
        'commitProtectedPageLease',
        'rollbackProtectedPageLease',
      ]),
      reason: 'no remote fetch, byte upload, record save or outbox admission',
    );
    expect(staging, contains('kind: CloudKitOperationKind.v2ReadWrite'));
    expect(
      staging.indexOf('_exclusion.runExclusive('),
      lessThan(staging.indexOf('_transport.runProtectedStoreExclusive(')),
    );
    expect(staging, contains('_authFence.requireCurrentBinding(_auth)'));
    expect(staging, contains('if (!await validateWire())'));
    final fresh = staging.substring(
      staging.indexOf('final source = await stage();'),
    );
    expect(
      fresh.indexOf('_journal.adoptProtectedSource('),
      lessThan(fresh.indexOf('_transport.commitProtectedPageLease(')),
    );
    expect(fresh, contains('if (!adopted)'));
    for (final source in [prepare, staging]) {
      for (final forbidden in [
        'CloudSyncEngine(',
        'flushOutbox(',
        'stageOutboundMessage(',
        'stageOutboundAttachment(',
        'runAuthorized(',
        'consumeAttachmentUpload',
        'cloudSyncConsume',
        'sync_keychain(',
        'get_container(',
      ]) {
        expect(source, isNot(contains(forbidden)));
      }
    }
    final api = File('rust/src/api/api.rs').readAsStringSync();
    final nativeStage = _section(
      api,
      'pub async fn cloud_sync_stage_ids_attachment_source(',
      'pub struct CloudSyncAttachmentUploadPlanResult',
    );
    expect(nativeStage, contains('cloud_sync_capture_auth_snapshot('));
    expect(
      nativeStage.indexOf(
        'cloud_sync_require_source_context_auth(&context, &auth)?',
      ),
      lessThan(nativeStage.indexOf('::stage_ids_attachment_source(')),
    );
    expect(
      nativeStage,
      contains(
        'crate::cloud_sync_ids_attachment_source::stage_ids_attachment_source(',
      ),
    );
    for (final forbidden in [
      'upload_asset(',
      'ZoneSaveOperation',
      'get_container(',
      'sync_keychain(',
      'prepare_attachment_upload(',
      '.send(',
    ]) {
      expect(nativeStage, isNot(contains(forbidden)));
    }
  });

  test('semantic transport cannot fall back to an unbound fetch', () {
    final transport = File(
      'lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart',
    ).readAsStringSync();
    expect(
      transport,
      contains('scope.persistenceLane != CloudSyncPersistenceLane.shadow'),
    );
    expect(
      transport,
      contains('cloud_sync_native_writer_pause_capability_required'),
    );
    expect(
      transport,
      contains('scope.persistenceLane != CloudSyncPersistenceLane.semantic'),
    );
    expect(transport, contains('unsupported_semantic_persistence_lane'));
  });

  test(
    'native semantic fetch acquires and forwards read-authentication permit',
    () {
      final api = File(
        'rust/src/api/api.rs',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final shadowFetchStart = api.indexOf(
        'pub async fn cloud_sync_fetch_protected_page',
      );
      final semanticFetchStart = api.indexOf(
        'pub async fn cloud_sync_fetch_protected_page_under_writer_pause',
        shadowFetchStart,
      );
      final discoveryFetchStart = api.indexOf(
        'pub async fn cloud_sync_fetch_protected_chat1_discovery_under_writer_pause',
        semanticFetchStart,
      );
      expect(shadowFetchStart, greaterThanOrEqualTo(0));
      expect(semanticFetchStart, greaterThan(shadowFetchStart));
      expect(discoveryFetchStart, greaterThan(semanticFetchStart));
      final shadowFetch = api.substring(shadowFetchStart, semanticFetchStart);
      final semanticFetch = api.substring(
        semanticFetchStart,
        discoveryFetchStart,
      );
      expect(shadowFetch, isNot(contains('native_writer_pause_token')));
      expect(
        shadowFetch,
        isNot(contains('acquire_cloudkit_read_authentication')),
      );
      expect(semanticFetch, contains('native_writer_pause_token: u64'));
      expect(
        semanticFetch,
        contains(
          'acquire_cloudkit_read_authentication(native_writer_pause_token)',
        ),
      );
      expect(semanticFetch, contains('Some(&permit)'));
      expect(semanticFetch, contains('newest_first: bool'));
      expect(
        semanticFetch,
        contains('maximum_changes,\n        newest_first,\n        false,'),
      );

      final native = File(
        'rust/src/cloud_sync_native_fetch.rs',
      ).readAsStringSync();
      expect(
        native,
        contains('.sync_messages_page_for_read_authentication_with_direction('),
      );
      expect(
        native,
        contains(
          '.sync_attachments_page_for_read_authentication_with_direction(',
        ),
      );
      expect(
        native,
        contains('.sync_chats_page_for_read_authentication_with_direction('),
      );
      expect(native, contains('request.newest_first'));
    },
  );

  test(
    'Chat1 discovery is an explicit bounded protected surface, not semantic admission',
    () {
      final api = File(
        'rust/src/api/api.rs',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final discovery = _section(
        api,
        'pub async fn cloud_sync_fetch_protected_chat1_discovery_under_writer_pause',
        'async fn cloud_sync_fetch_protected_page_inner',
      );
      expect(discovery, contains('maximum_changes > 50'));
      expect(discovery, contains('generation == 0'));
      expect(
        discovery,
        contains(
          'acquire_cloudkit_read_authentication(native_writer_pause_token)',
        ),
      );
      expect(discovery, contains('Some(&permit)'));
      expect(discovery, contains('"chat1ManateeZone".to_owned()'));
      expect(discovery, isNot(contains('stream: String')));
      expect(
        discovery,
        contains('maximum_changes,\n        false,\n        true,'),
      );
      expect(discovery, isNot(contains('cloud_sync_fetch_raw_page')));
      final native = File(
        'rust/src/cloud_sync_native_fetch.rs',
      ).readAsStringSync();
      final oldEntry = _section(
        native,
        'pub(crate) async fn cloud_sync_fetch_protected_page(',
        'pub(crate) async fn cloud_sync_fetch_protected_chat1_discovery(',
      );
      expect(oldEntry, contains('CloudNativeFetchPurpose::Existing'));
      expect(
        oldEntry,
        isNot(contains('CloudNativeFetchPurpose::Chat1Discovery')),
      );
      expect(
        native,
        contains('.sync_chat1_discovery_page_for_read_authentication('),
      );
      final decoder = File(
        'rust/src/cloud_sync_transient_bridge.rs',
      ).readAsStringSync();
      expect(decoder, contains('CloudNativeStream::Chat1 => {'));
      expect(decoder, contains('decoder_failure_at("unsupported_stream")'));
    },
  );
}

String _section(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  expect(start, greaterThanOrEqualTo(0), reason: startMarker);
  final end = source.indexOf(endMarker, start);
  expect(end, greaterThan(start), reason: endMarker);
  return source.substring(start, end);
}
