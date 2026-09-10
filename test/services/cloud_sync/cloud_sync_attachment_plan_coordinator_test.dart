// Bounded synthetic coverage for CloudSyncAttachmentPlanCoordinator.
//
// Uses a real disposable ObjectBox store plus the established local-send
// attachment fixtures (pending save -> protected-source adoption -> native IDS
// confirmation -> deferred promotion). Narrow injected inventory/stage
// functions receive the pinned source and live auth. No real accounts,
// files, or network.
import 'dart:io';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_plan_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
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
  late _FakeStaging staging;
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

  CloudSyncAttachmentUploadJournal buildUploads({int generation = 1}) =>
      CloudSyncAttachmentUploadJournal(
        store: store,
        localSends: localSends,
        scope: _uploadScope,
        checkpointGeneration: generation,
        currentAuth: auth,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-attachment-plan-coordinator-',
    );
    store = await openStore(directory: directory.path);
    provisionJournal();
    chat = _chat();
    _persistChat(store, chat);
    auth = _auth(Object());
    seedCheckpoint(1);
    uploads = buildUploads();
    staging = _FakeStaging();
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

  CloudSyncAttachmentPlanCoordinator buildCoordinator({
    required Future<List<CloudSyncAttachmentPlanInventoryItem>> Function(
      CloudSyncLocalSendSourceBinding pinnedSource,
      CloudSyncNativeAuthSnapshot liveAuth,
    )
    readInventory,
    required Future<CloudSyncProtectedOutboundStageData> Function(
      CloudSyncAttachmentPlanInventoryItem item,
      CloudSyncLocalSendSourceBinding pinnedSource,
      CloudSyncNativeAuthSnapshot liveAuth,
    )
    stagePlan,
    Future<CloudSyncNativeAuthSnapshot?> Function()? readAuth,
  }) => CloudSyncAttachmentPlanCoordinator(
    store: store,
    localSends: localSends,
    uploads: uploads,
    readLiveAuth: readAuth ?? () async => auth,
    staging: staging,
    readInventory: readInventory,
    stagePlan: stagePlan,
  );

  CloudSyncAttachmentPlanInventoryItem itemA() =>
      CloudSyncAttachmentPlanInventoryItem(
        originalAttachmentGuid: 'LOCAL-A',
        reflectedAttachmentGuid: '${_guidA}_0',
        logicalEntityKeyHash: _token('C'),
      );

  CloudSyncAttachmentPlanInventoryItem itemB() =>
      CloudSyncAttachmentPlanInventoryItem(
        originalAttachmentGuid: 'LOCAL-B',
        reflectedAttachmentGuid: '${_guidA}_1',
        logicalEntityKeyHash: _token('G'),
      );

  CloudSyncProtectedOutboundStageData stageFor(String hash) {
    if (hash == _token('G')) {
      return CloudSyncProtectedOutboundStageData(
        logicalEntityKeyHash: hash,
        protectedEnvelopeReference: _ref('I'),
        payloadSha256: _digest('f'),
        serverRecordIdHash: _token('H'),
        leaseReference: _lease('2'),
      );
    }
    return CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: hash,
      protectedEnvelopeReference: _ref('E'),
      payloadSha256: _digest('c'),
      serverRecordIdHash: _token('D'),
      leaseReference: _lease('d'),
    );
  }

  test('repeated run reuses same plan without new staging', () async {
    final intent = seedConfirmedIntent();
    var stageCalls = 0;
    CloudSyncLocalSendSourceBinding? inventorySource;
    final coordinator = buildCoordinator(
      readInventory: (source, liveAuth) async {
        inventorySource = source;
        expect(liveAuth.accountFingerprint, _accountA);
        return [itemA()];
      },
      stagePlan: (item, source, liveAuth) async {
        stageCalls++;
        expect(identical(source, inventorySource), isTrue);
        expect(liveAuth.accountFingerprint, _accountA);
        return stageFor(item.logicalEntityKeyHash);
      },
    );
    final first = await coordinator.ensurePlans(localSendIntentId: intent);
    expect(first, hasLength(1));
    expect(first.single.state, CloudAttachmentUploadState.prepared);
    expect(stageCalls, 1);
    expect(staging.commits, hasLength(1));
    expect(staging.rollbacks, isEmpty);
    expect(
      inventorySource!.encode(),
      uploads.readOriginalSource(first.single.id).encode(),
    );
    final second = await coordinator.ensurePlans(localSendIntentId: intent);
    expect(second.single.id, first.single.id);
    expect(second.single.plan.leaseReference, first.single.plan.leaseReference);
    expect(stageCalls, 1);
    expect(staging.commits, hasLength(2));
    uploads.beginAttempt(
      id: first.single.id,
      attemptId: _attemptA,
      now: _time(8),
    );
    final third = await coordinator.ensurePlans(localSendIntentId: intent);
    expect(third.single.id, first.single.id);
    expect(third.single.state, CloudAttachmentUploadState.started);
    expect(stageCalls, 1);
    expect(staging.commits, hasLength(2));
  });

  test('interruption after adopt before commit retains same plan', () async {
    final intent = seedConfirmedIntent();
    var stageCalls = 0;
    final coordinator = buildCoordinator(
      readInventory: (_, __) async => [itemA()],
      stagePlan: (item, _, __) async {
        stageCalls++;
        return stageFor(item.logicalEntityKeyHash);
      },
    );
    staging.failNextCommit = true;
    await expectLater(
      coordinator.ensurePlans(localSendIntentId: intent),
      throwsA(isA<StateError>()),
    );
    expect(stageCalls, 1);
    expect(staging.commits, hasLength(1));
    expect(staging.rollbacks, isEmpty);
    final retained = uploads.findForAttachment(
      localSendIntentId: intent,
      logicalEntityKeyHash: _token('C'),
      sourceAttachmentKeys: {_token('C')},
    );
    expect(retained, isNotNull);
    expect(retained!.state, CloudAttachmentUploadState.prepared);
    final second = await coordinator.ensurePlans(localSendIntentId: intent);
    expect(stageCalls, 1);
    expect(staging.commits, hasLength(2));
    expect(second.single.id, retained.id);
    expect(second.single.plan.leaseReference, retained.plan.leaseReference);
  });

  test('changed inventory catches retained row before any staging', () async {
    final intent = seedConfirmedIntent();
    var stageCalls = 0;
    final firstCoordinator = buildCoordinator(
      readInventory: (_, __) async => [itemA()],
      stagePlan: (item, _, __) async {
        stageCalls++;
        return stageFor(item.logicalEntityKeyHash);
      },
    );
    await firstCoordinator.ensurePlans(localSendIntentId: intent);
    expect(stageCalls, 1);
    final secondCoordinator = buildCoordinator(
      readInventory: (_, __) async => [itemB()],
      stagePlan: (item, _, __) async {
        stageCalls++;
        return stageFor(item.logicalEntityKeyHash);
      },
    );
    await expectLater(
      secondCoordinator.ensurePlans(localSendIntentId: intent),
      throwsA(_stateFailure('cloud_sync_attachment_upload_inventory_changed')),
    );
    expect(stageCalls, 1);
    expect(store.box<CloudAttachmentUploadEntity>().count(), 1);
  });

  test('auth drift after staging rolls back unadopted lease', () async {
    final intent = seedConfirmedIntent();
    var stageCalls = 0;
    var drifted = false;
    final coordinator = buildCoordinator(
      readInventory: (_, __) async => [itemA()],
      stagePlan: (item, _, __) async {
        stageCalls++;
        drifted = true;
        return stageFor(item.logicalEntityKeyHash);
      },
      readAuth: () async => drifted ? _auth(Object()) : auth,
    );
    await expectLater(
      coordinator.ensurePlans(localSendIntentId: intent),
      throwsA(_stateFailure('cloud_sync_attachment_plan_auth_changed')),
    );
    expect(stageCalls, 1);
    expect(staging.rollbacks, hasLength(1));
    expect(store.box<CloudAttachmentUploadEntity>().count(), 0);
  });

  test('duplicate inventory rejected before any staging', () async {
    final intent = seedConfirmedIntent();
    var stageCalls = 0;
    final coordinator = buildCoordinator(
      readInventory: (_, __) async => [
        CloudSyncAttachmentPlanInventoryItem(
          originalAttachmentGuid: 'LOCAL-A',
          reflectedAttachmentGuid: '${_guidA}_0',
          logicalEntityKeyHash: _token('C'),
        ),
        CloudSyncAttachmentPlanInventoryItem(
          originalAttachmentGuid: 'LOCAL-C',
          reflectedAttachmentGuid: '${_guidA}_1',
          logicalEntityKeyHash: _token('C'),
        ),
      ],
      stagePlan: (item, _, __) async {
        stageCalls++;
        return stageFor(item.logicalEntityKeyHash);
      },
    );
    await expectLater(
      coordinator.ensurePlans(localSendIntentId: intent),
      throwsA(_stateFailure('cloud_sync_attachment_plan_inventory_invalid')),
    );
    expect(stageCalls, 0);
    expect(store.box<CloudAttachmentUploadEntity>().count(), 0);
  });

  test('mutating returned snapshots cannot affect later runs', () async {
    final intent = seedConfirmedIntent();
    final coordinator = buildCoordinator(
      readInventory: (_, __) async => [itemA()],
      stagePlan: (item, _, __) async => stageFor(item.logicalEntityKeyHash),
    );
    final first = await coordinator.ensurePlans(localSendIntentId: intent);
    expect(() => first.add(first.single), throwsA(isA<UnsupportedError>()));
    final second = await coordinator.ensurePlans(localSendIntentId: intent);
    expect(second.single.id, first.single.id);
  });

  test('coordinator rejects a store it is not bound to', () async {
    final otherDirectory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-attachment-plan-foreign-',
    );
    final otherStore = await openStore(directory: otherDirectory.path);
    try {
      expect(
        () => CloudSyncAttachmentPlanCoordinator(
          store: otherStore,
          localSends: localSends,
          uploads: uploads,
          readLiveAuth: () async => auth,
          staging: staging,
          readInventory: (_, __) async => [itemA()],
          stagePlan: (item, _, __) async => stageFor(item.logicalEntityKeyHash),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_plan_store_invalid')),
      );
    } finally {
      if (!otherStore.isClosed()) otherStore.close();
      if (otherDirectory.existsSync()) {
        await otherDirectory.delete(recursive: true);
      }
    }
  });
}

final class _FakeStaging implements CloudSyncOutboundStagingTransport {
  final List<String> commits = <String>[];
  final List<String> rollbacks = <String>[];
  bool failNextCommit = false;

  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) =>
      action();

  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
  }) => throw UnimplementedError();

  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  ) async {
    commits.add(leaseReference);
    if (failNextCommit) {
      failNextCommit = false;
      throw StateError('cloud_sync_attachment_plan_commit_failed');
    }
  }

  @override
  Future<void> rollbackOutboundLease(String leaseReference) async {
    rollbacks.add(leaseReference);
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

CloudSyncNativeAuthSnapshot _auth(Object client) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'native-session',
      accountFingerprint: _accountA,
      protectedStoreIdentity: _storeA,
      cloudMessagesClient: client,
    );

Matcher _stateFailure(String message) =>
    isA<StateError>().having((error) => error.message, 'message', message);

DateTime _time(int seconds) => DateTime.utc(2026, 9, 4, 12, 0, seconds);

String _token(String char) => List.filled(43, char).join();
String _digest(String char) => List.filled(64, char).join();
String _ref(String char) => 'obcs2.ref.${_token(char)}';
String _lease(String char) => 'obcs2.lease.${List.filled(32, char).join()}';

const _accountA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _storeA = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _guidA = '11111111-1111-4111-8111-111111111111';
const _attemptA = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';

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
