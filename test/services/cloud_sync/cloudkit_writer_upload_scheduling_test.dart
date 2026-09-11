// Actual guard scheduling checks using disposable synthetic ObjectBox fixtures.
import 'dart:io';
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_consumer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_recovery.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitWriterAuthoritySnapshot authoritySnapshot;
  late CloudSyncLocalSendJournal localSends;
  late CloudSyncNativeAuthSnapshot auth;
  late CloudSyncAttachmentUploadJournal uploads;
  late Chat chat;

  void provisionJournal() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final existing = authority.read(_writerScope);
    if (existing == null) {
      final disabled = authority.initializeDisabled(
        _writerScope,
        now: _time(0),
      );
      authority.provisionInitialOwner(
        _writerScope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: _completeEvidence,
        now: _time(1),
      );
    }
    authoritySnapshot = authority.read(_writerScope)!;
    localSends = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authoritySnapshot,
    );
  }

  void seedCheckpoint(int generation) {
    final box = store.box<CloudSyncCheckpointEntity>();
    final key = cloudSyncPersistentScopeKey(_uploadScope);
    final query = box
        .query(CloudSyncCheckpointEntity_.checkpointKey.equals(key))
        .build();
    try {
      final existing = query.findUnique();
      if (existing != null) {
        existing
          ..generation = generation
          ..updatedAtMs = _time(0).millisecondsSinceEpoch;
        box.put(existing);
        return;
      }
    } finally {
      query.close();
    }
    box.put(
      CloudSyncCheckpointEntity(
        checkpointKey: key,
        accountFingerprint: _accountA,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'attachmentManateeZone',
        streamKind: 'messages',
        schemaVersion: 2,
        persistenceLane: 'semantic',
        generation: generation,
        updatedAtMs: _time(0).millisecondsSinceEpoch,
      ),
    );
  }

  CloudSyncAttachmentUploadJournal buildUploads({
    int generation = 1,
    CloudSyncNativeAuthSnapshot? authOverride,
  }) => CloudSyncAttachmentUploadJournal(
    store: store,
    localSends: localSends,
    scope: _uploadScope,
    checkpointGeneration: generation,
    currentAuth: authOverride ?? auth,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-attachment-upload-journal-',
    );
    store = await openStore(directory: directory.path);
    provisionJournal();
    chat = _chat();
    _persistChat(store, chat);
    auth = _auth(Object());
    seedCheckpoint(1);
    uploads = buildUploads();
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  int seedConfirmedIntent({
    String stableGuid = _guidA,
    String attachmentGuid = 'LOCAL-ATTACHMENT-A',
  }) {
    final attachment = Attachment(
      guid: attachmentGuid,
      metadata: const {'rustpush': '<attachment><id>A</id></attachment>'},
    );
    store.box<Attachment>().put(attachment);
    final message = _attachmentMessage(
      stableGuid: stableGuid,
      attachmentGuid: attachmentGuid,
    );
    message.chat.target = chat;
    message.dbAttachments.add(attachment);
    final identity = CloudSyncLocalSendIdentity.captureAttachment(
      message,
      chat,
      stableGuid,
    )!;
    localSends.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(2),
    );
    final source = CloudSyncLocalSendSourceBinding(
      accountFingerprint: _accountA,
      protectedStoreIdentity: _storeA,
      messageGuidHash: identity.guidHash,
      sourceSha256: identity.sourceSha256,
      protectedReference: _ref('A'),
      leaseReference: _lease('a'),
      payloadSha256: _digest('b'),
      payloadLength: 512,
    );
    localSends.adoptProtectedSource(
      identity: identity,
      source: source,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(3),
    );
    attachment.guid = '${stableGuid}_0';
    store.box<Attachment>().put(attachment);
    message
      ..guid = stableGuid
      ..stagingGuid = null
      ..text = ' '
      ..attributedBody = [
        AttributedBody(
          string: ' ',
          runs: [
            Run(
              range: const [0, 1],
              attributes: Attributes(
                messagePart: 0,
                attachmentGuid: attachment.guid,
              ),
            ),
          ],
        ),
      ];
    store.box<Message>().put(message);
    final intentId = localSends.recordNativeSendConfirmation(
      stableGuid: stableGuid,
      succeeded: true,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(4),
      protectedSource: source,
    )!;
    localSends.promoteIdsConfirmedDeferred(
      intentId: intentId,
      currentAuth: auth,
      now: _time(5),
    );
    return intentId;
  }

  test('consumer quiesces then schedules only receipt recovery for its lost upload', () async {
    final intent = seedConfirmedIntent();
    final plan = uploads.adoptPlan(
        localSendIntentId: intent, plan: _planA(), now: _time(6));
    final originalEpoch = authoritySnapshot.epoch;
    final binding = _SchedulingAuth();
    final interlock = CloudKitOperationInterlock(
        privateStorageDirectory: directory.path,
        fenceStore: InMemoryCloudSyncStore());
    CloudKitWriterMutationGuard makeGuard() => CloudKitWriterMutationGuard.forTest(
        store: store, readActiveClient: () => auth.cloudMessagesClient,
        privateStorageDirectory: directory.path, nativeAuthBinding: binding,
        reconciliationBinding: binding,
        buildDecision: CloudKitWriterOwnership.resolve('v2'));
    CloudSyncLocalSendAuthFence authFence(int epoch) => CloudSyncLocalSendAuthFence(
        expected: auth, capture: () async => auth,
        stillCurrent: () => authority.read(_writerScope)?.epoch == epoch);
    final messageScope = CloudSyncScope(
        accountFingerprint: _accountA, container: 'com.apple.messages.cloud',
        database: 'private', zone: 'messageManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic);
    final guard = makeGuard();
    var settled = false;
    var attempts = 0;
    var scheduled = 0;
    final consumer = CloudSyncLocalSendConsumer(
      scope: messageScope, journal: localSends, authFence: authFence(originalEpoch),
      exclusion: interlock, drainExisting: () async => true,
      admit: (_) async {
        uploads.beginAttempt(id: plan.id, attemptId: _attemptA, now: _time(7));
        return guard.runAuthorized<CloudOutboxOperation>(
          owner: CloudKitWriterOwner.v2, expectedClient: auth.cloudMessagesClient,
          expectedAccountFingerprint: _accountA,
          preparedHandleBindingSha256: _digest('a'),
          reconciliationBindingSha256: uploads.reconciliationBindingSha256(plan.id),
          requireAdmission: () {}, requireDurableAdmission: () async {},
          action: (capability) async {
            capability.consumeForNative();
            attempts++;
            throw StateError('synthetic_response_lost');
          },
        );
      },
    );
    final first = await runCloudSyncLocalSendRecoveryPass(
      action: consumer.runOnce,
      quiesce: () async { settled = true; },
      canRefreshAfterRecovery: () async => throw StateError('must_not_refresh'),
      canSchedulePendingUploadRecovery: () {
        expect(settled, isTrue);
        return interlock.runExclusive(kind: CloudKitOperationKind.v2ReadWrite,
          action: () async {
            scheduled++;
            return guard.canSchedulePendingAttachmentUploadRecovery(
                expectedClient: auth.cloudMessagesClient, uploads: uploads,
                uploadId: plan.id, expectedEpoch: originalEpoch);
          });
      },
    );
    expect(first.outboxBlocked, isTrue);
    expect(first.admitted, 0);
    expect(scheduled, 1);
    expect(attempts, 1);
    expect(binding.receiptCalls, 0);
    final fenceFile = File('${directory.path}/.openbubbles-cloudkit-writer-mutation-v1.fence');
    final originalFence = fenceFile.readAsStringSync();

    // New pass binds the unknown E+1 owner. Its very first drain must be
    // receipt-only, even with an empty record outbox and a ready parent.
    provisionJournal();
    uploads = buildUploads();
    final nextGuard = makeGuard();
    binding.allowMissingReceipt = true;
    final nextConsumer = CloudSyncLocalSendConsumer(
      scope: messageScope, journal: localSends,
      authFence: authFence(originalEpoch + 1), exclusion: interlock,
      drainExisting: () => recoverCloudSyncLocalSendUploadFence(
        recoverProtectedStore: () async {},
        reconcileUpload: () => nextGuard.reconcilePendingAttachmentUpload(
            expectedClient: auth.cloudMessagesClient, uploads: uploads)),
      admit: (_) async => throw StateError('must_not_admit_or_retry_upload'),
    );
    final next = await runCloudSyncLocalSendRecoveryPass(
        action: nextConsumer.runOnce, quiesce: () async {},
        canRefreshAfterRecovery: () async => throw StateError('must_not_refresh'));
    expect(next.outboxBlocked, isTrue);
    expect(next.admitted, 0);
    expect(binding.receiptCalls, 1);
    expect(binding.unexpectedCalls, 0);
    expect(attempts, 1);
    expect(fenceFile.readAsStringSync(), originalFence);
    expect(uploads.read(plan.id).plan.protectedEnvelopeReference,
        plan.plan.protectedEnvelopeReference);
    expect(uploads.read(plan.id).attemptId, _attemptA);
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    expect(authority.read(_writerScope)!.epoch, originalEpoch + 1);
  });

  for (final scenario in [
    'started',
    'unknown',
    'foreign_guard',
    'foreign_upload',
    'wrong_id',
    'wrong_epoch',
    'client',
    'session',
    'account',
    'store',
    'auth_failure',
    'client_during_capture',
    'fence_during_capture',
    'journal_during_capture',
    'owner_during_capture',
    'account_during_action',
    'active_operation',
    'journal_account',
    'journal_store',
    'journal_attempt',
    'journal_epoch',
    'journal_generation',
    'journal_intent',
    'journal_prepared',
    'journal_uploaded',
    'owner',
    'target_owner',
    'transition',
    'epoch_newer',
    'epoch_old',
    'stable',
    'missing_fence',
    'corrupt_fence',
    'fence_capability',
    'fence_prepared',
    'fence_binding',
    'fence_account',
    'fence_store',
    'fence_epoch',
    'fence_owner',
    'fence_container',
    'fence_database',
    'closed_store',
    'foreign_journal',
    'outside_interlock',
  ]) {
    test('pending upload scheduling exact proof: $scenario', () async {
      final intent = seedConfirmedIntent();
      final id = uploads
          .adoptPlan(localSendIntentId: intent, plan: _planA(), now: _time(6))
          .id;
      uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
      final originalEpoch = authoritySnapshot.epoch;
      final binding = _SchedulingAuth();
      Object activeClient = auth.cloudMessagesClient;
      CloudKitWriterMutationGuard makeGuard() =>
          CloudKitWriterMutationGuard.forTest(
            store: store,
            readActiveClient: () => activeClient,
            privateStorageDirectory: directory.path,
            nativeAuthBinding: binding,
            reconciliationBinding: binding,
            buildDecision: CloudKitWriterOwnership.resolve('v2'),
          );
      final guard = makeGuard();
      final interlock = CloudKitOperationInterlock(
        privateStorageDirectory: directory.path,
        fenceStore: InMemoryCloudSyncStore(),
      );
      Future<T> run<T>(Future<T> Function() action) => interlock.runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: action,
      );
      Future<bool> check({
        CloudKitWriterMutationGuard? checker,
        CloudSyncAttachmentUploadJournal? journal,
      }) => (checker ?? guard).canSchedulePendingAttachmentUploadRecovery(
        expectedClient: auth.cloudMessagesClient,
        uploads: journal ?? uploads,
        uploadId: scenario == 'wrong_id' ? id + 100 : id,
        expectedEpoch: originalEpoch + (scenario == 'wrong_epoch' ? 1 : 0),
      );
      await expectLater(
        run(
          () => guard.runAuthorized<void>(
            owner: CloudKitWriterOwner.v2,
            expectedClient: auth.cloudMessagesClient,
            expectedAccountFingerprint: _accountA,
            preparedHandleBindingSha256: _digest('a'),
            reconciliationBindingSha256: scenario == 'foreign_upload'
                ? _digest('b')
                : uploads.reconciliationBindingSha256(id),
            requireAdmission: () {},
            requireDurableAdmission: () async {},
            action: (capability) async {
              capability.consumeForNative();
              if (scenario == 'active_operation') {
                expect(await check(), isFalse);
              }
              if (scenario == 'account_during_action') {
                binding.account = _accountB;
              }
              throw StateError('synthetic_response_lost');
            },
          ),
        ),
        throwsA(
          isA<CloudKitWriterAuthorityFailure>().having(
            (e) => e.safeCode,
            'safeCode',
            'cloudkit_writer_mutation_outcome_unknown',
          ),
        ),
      );
      if (scenario == 'unknown') {
        uploads.markUnknown(id: id, attemptId: _attemptA, now: _time(8));
      }
      final fence = File(
        '${directory.path}/.openbubbles-cloudkit-writer-mutation-v1.fence',
      );
      void driftFence(String key, Object value) {
        final data =
            jsonDecode(fence.readAsStringSync()) as Map<String, dynamic>;
        data[key] = value;
        fence.writeAsStringSync(jsonEncode(data));
      }

      final rows = store.box<CloudAttachmentUploadEntity>();
      void changeAttempt() => rows.put(rows.get(id)!..attemptId = _attemptB);
      void changeOwner() {
        final box = store.box<CloudKitWriterAuthorityEntity>();
        box.put(box.getAll().single..epoch += 1);
      }

      switch (scenario) {
        case 'client':
          activeClient = Object();
        case 'session':
          binding.session = 'changed-session';
        case 'account':
          binding.account = _accountB;
        case 'store':
          binding.storeIdentity = _storeB;
        case 'auth_failure':
          binding.failCapture = true;
        case 'client_during_capture':
          binding.afterCapture = () => activeClient = Object();
        case 'fence_during_capture':
          binding.afterCapture = () =>
              driftFence('capabilitySha256', _digest('f'));
        case 'journal_during_capture':
          binding.afterCapture = changeAttempt;
        case 'owner_during_capture':
          binding.afterCapture = changeOwner;
        case 'journal_account':
          rows.put(rows.get(id)!..accountFingerprint = _accountB);
        case 'journal_store':
          rows.put(rows.get(id)!..protectedStoreIdentity = _storeB);
        case 'journal_attempt':
          changeAttempt();
        case 'journal_epoch':
          rows.put(rows.get(id)!..writerEpoch += 1);
        case 'journal_generation':
          rows.put(rows.get(id)!..checkpointGeneration += 1);
        case 'journal_intent':
          rows.put(rows.get(id)!..localSendIntentId += 100);
        case 'journal_prepared':
          rows.put(
            rows.get(id)!..state = CloudAttachmentUploadState.prepared.index,
          );
        case 'journal_uploaded':
          rows.put(
            rows.get(id)!..state = CloudAttachmentUploadState.uploaded.index,
          );
        case 'missing_fence':
          fence.deleteSync();
        case 'corrupt_fence':
          fence.writeAsStringSync('{}');
        case 'fence_capability':
          driftFence('capabilitySha256', _digest('f'));
        case 'fence_prepared':
          driftFence('preparedHandleBindingSha256', _digest('f'));
        case 'fence_binding':
          driftFence('reconciliationBindingSha256', _digest('f'));
        case 'fence_account':
          driftFence('accountFingerprint', _accountB);
        case 'fence_store':
          driftFence('protectedStoreIdentity', _storeB);
        case 'fence_epoch':
          driftFence('epoch', originalEpoch + 1);
        case 'fence_owner':
          driftFence('owner', 'legacy');
        case 'fence_container':
          driftFence('container', 'other.container');
        case 'fence_database':
          driftFence('database', 'public');
      }
      if ([
        'owner',
        'target_owner',
        'transition',
        'epoch_newer',
        'epoch_old',
        'stable',
      ].contains(scenario)) {
        final box = store.box<CloudKitWriterAuthorityEntity>();
        final row = box.getAll().single;
        switch (scenario) {
          case 'owner':
            row.owner = 1;
          case 'target_owner':
            row.targetOwner = 1;
          case 'transition':
            row.transitionIdHash = _digest('f');
          case 'epoch_newer':
            row.epoch += 2;
          case 'epoch_old':
            row.epoch = originalEpoch;
          case 'stable':
            row.state = 0;
        }
        box.put(row);
      }
      final expectedFence = fence.existsSync()
          ? fence.readAsStringSync()
          : null;
      final originalRow = rows.get(id)!;
      List<Object?> ownerFields() {
        final row = store.box<CloudKitWriterAuthorityEntity>().getAll().single;
        return [
          row.owner,
          row.state,
          row.epoch,
          row.targetOwner,
          row.transitionIdHash,
        ];
      }

      final expectedOwner = ownerFields();
      final expectedOutbox = store.box<CloudOutboxOperationEntity>().count();
      Directory? otherDirectory;
      Store? otherStore;
      CloudSyncAttachmentUploadJournal? foreignJournal;
      if (scenario == 'foreign_journal') {
        otherDirectory = await Directory.systemTemp.createTemp(
          'scheduling-foreign-',
        );
        otherStore = await openStore(directory: otherDirectory.path);
        final foreignAuthority = ObjectBoxCloudKitWriterAuthority.forTest(
          store: otherStore,
          buildDecision: CloudKitWriterOwnership.resolve('v2'),
        );
        foreignJournal = CloudSyncAttachmentUploadJournal(
          store: otherStore,
          localSends: CloudSyncLocalSendJournal(
            store: otherStore,
            authority: foreignAuthority,
            authoritySnapshot: authoritySnapshot,
          ),
          scope: _uploadScope,
          checkpointGeneration: 1,
          currentAuth: auth,
        );
      }
      if (scenario == 'closed_store') store.close();
      try {
        final checker = scenario == 'foreign_guard' ? makeGuard() : guard;
        final result = scenario == 'outside_interlock'
            ? await check(checker: checker)
            : await run(() => check(checker: checker, journal: foreignJournal));
        expect(
          result,
          ['started', 'unknown', 'active_operation'].contains(scenario),
        );
        expect(
          binding.unexpectedCalls,
          0,
        ); // No native receipt, warm or mutation.
        final nowFence = fence.existsSync() ? fence.readAsStringSync() : null;
        // Synthetic during-capture injections are the only permitted changes.
        if (scenario != 'fence_during_capture') expect(nowFence, expectedFence);
        if (!store.isClosed()) {
          final retained = rows.get(id)!;
          expect(retained.state, originalRow.state);
          expect(retained.writerEpoch, originalRow.writerEpoch);
          expect(retained.resultReference, originalRow.resultReference);
          if (scenario != 'journal_during_capture') {
            expect(retained.attemptId, originalRow.attemptId);
          }
          expect(
            store.box<CloudOutboxOperationEntity>().count(),
            expectedOutbox,
          );
          if (scenario != 'owner_during_capture') {
            expect(ownerFields(), expectedOwner);
          }
        }
        if (expectedFence != null) {
          expect(
            guard.requireClear,
            throwsA(isA<CloudKitWriterAuthorityFailure>()),
          );
        }
      } finally {
        otherStore?.close();
        if (otherDirectory != null) {
          await otherDirectory.delete(recursive: true);
        }
      }
    });
  }
}

final class _SchedulingAuth
    implements
        CloudSyncNativeAuthBinding,
        CloudKitWriterUploadReconciliationBinding {
  String account = _accountA;
  String session = 'native-session';
  String storeIdentity = _storeA;
  bool failCapture = false;
  bool allowMissingReceipt = false;
  int receiptCalls = 0;
  int unexpectedCalls = 0;
  void Function()? afterCapture;

  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async {
    if (failCapture) throw StateError('synthetic_auth_failure');
    final result = CloudSyncNativeAuthMetadata(
      nativeSessionId: session,
      accountFingerprint: account,
      protectedStoreIdentity: storeIdentity,
    );
    afterCapture?.call();
    return result;
  }

  @override
  Future<frb_api.CloudSyncAttachmentUploadReceiptEvidence?> verifyAttachmentUploadReceipt({
    required Object cloudMessagesClient,
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentUploadPlanReference planStage,
    required String expectedAttemptId,
  }) async {
    if (!allowMissingReceipt) {
      unexpectedCalls++;
      throw StateError('unexpected_native_receipt');
    }
    expect(expectedAttemptId, _attemptA);
    receiptCalls++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls++;
    throw StateError('unexpected_native_operation');
  }
}

Message _attachmentMessage({
  required String stableGuid,
  required String attachmentGuid,
}) {
  return Message(
    guid: 'local-$stableGuid',
    text: ' ',
    dateCreated: _time(1),
    isFromMe: true,
    hasAttachments: true,
    attributedBody: [
      AttributedBody(
        string: ' ',
        runs: [
          Run(
            range: const [0, 1],
            attributes: Attributes(attachmentGuid: attachmentGuid),
          ),
        ],
      ),
    ],
    stagingGuid: stableGuid,
  );
}

Chat _chat() {
  final handle = Handle(
    address: 'person@example.com',
    service: 'iMessage',
    uniqueAddressAndService: 'person@example.com/iMessage',
  );
  final chat = Chat(
    guid: 'iMessage;-;person@example.com',
    chatIdentifier: 'person@example.com',
    usingHandle: 'me@example.com',
    isRpSms: false,
    style: 45,
    participants: [handle],
  );
  chat.handles.addAll([handle]);
  return chat;
}

void _persistChat(Store store, Chat chat) {
  store.box<Handle>().putMany(chat.handles.toList());
  store.box<Chat>().put(chat);
}

CloudSyncNativeAuthSnapshot _auth(
  Object client, {
  String account = _accountA,
  String store = _storeA,
}) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: 'native-session',
  accountFingerprint: account,
  protectedStoreIdentity: store,
  cloudMessagesClient: client,
);

CloudSyncProtectedOutboundStageData _planA({
  String? record,
  String? payload,
  String? reference,
  String? lease,
}) => CloudSyncProtectedOutboundStageData(
  logicalEntityKeyHash: _token('C'),
  protectedEnvelopeReference: reference ?? _ref('E'),
  payloadSha256: payload ?? _digest('c'),
  serverRecordIdHash: record ?? _token('D'),
  leaseReference: lease ?? _lease('d'),
);

DateTime _time(int seconds) => DateTime.utc(2026, 9, 4, 12, 0, seconds);

String _token(String char) => List.filled(43, char).join();
String _digest(String char) => List.filled(64, char).join();
String _ref(String char) => 'obcs2.ref.${_token(char)}';
String _lease(String char) => 'obcs2.lease.${List.filled(32, char).join()}';

const _accountA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _accountB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _storeA = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _storeB = 'obcs2.store.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _guidA = '11111111-1111-4111-8111-111111111111';
const _attemptA = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _attemptB = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';

final _writerScope = CloudKitWriterScope(accountFingerprint: _accountA);
final _uploadScope = CloudSyncScope(
  accountFingerprint: _accountA,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'attachmentManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: 2,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);
