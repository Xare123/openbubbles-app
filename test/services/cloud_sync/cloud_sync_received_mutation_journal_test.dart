import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

const _owner = 'mailto:owner@example.com';
const _remote = 'mailto:remote@example.com';
const _target = '99999999-8888-4777-8666-555555555555';
const _event = '11111111-2222-4333-8444-555555555555';
const _live = CloudSyncReceivedArchiveLiveContext(
  observedViaLiveReceive: true,
  observedLocalHandles: [_owner],
  receivedOnHandle: _owner,
);
api.MessageInst _wire({
  bool mirrored = false,
  bool unsend = false,
  String event = _event,
  int timestamp = 1700000010000,
}) => api.MessageInst(
  id: event,
  sender: mirrored ? _owner : _remote,
  receivedOnHandle: _owner,
  conversation: api.ConversationData(
    participants: [_owner, _remote],
    senderGuid: 'iMessage;-;remote@example.com',
  ),
  message: unsend
      ? const api.Message.unsend(api.UnsendMessage(tuuid: _target, editPart: 0))
      : const api.Message.edit(
          api.EditMessage(
            tuuid: _target,
            editPart: 0,
            newParts: api.MessageParts(
              field0: [
                api.IndexedMessagePart(
                  part_: api.MessagePart.text(
                    'Edited',
                    api.TextFormat.flags(
                      api.TextFlags(
                        bold: false,
                        italic: false,
                        underline: false,
                        strikethrough: false,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
  sentTimestamp: timestamp,
  sendDelivered: false,
  verificationFailed: false,
);

void main() {
  late Store store;
  late Directory directory;
  late Directory root;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitWriterAuthoritySnapshot owner;
  late CloudSyncReceivedMutationJournal journal;
  late Chat chat;
  late Handle remote;
  late CloudSyncNativeAuthSnapshot auth;
  final scope = CloudKitWriterScope(accountFingerprint: 'A' * 43);
  final storeIdentity = 'obcs2.store.${'S' * 43}';
  void bind() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    if (authority.read(scope) == null) {
      final disabled = authority.initializeDisabled(
        scope,
        now: DateTime.utc(2026),
      );
      authority.provisionInitialOwner(
        scope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: DateTime.utc(2026, 1, 1, 0, 0, 1),
      );
    }
    owner = authority.read(scope)!;
    auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic-session',
      accountFingerprint: scope.accountFingerprint,
      protectedStoreIdentity: storeIdentity,
      cloudMessagesClient: Object(),
    );
    journal = CloudSyncReceivedMutationJournal(
      store: store,
      authority: authority,
      owner: owner,
    );
  }

  setUp(() async {
    root = await Directory(
      '${Directory.current.path}/build/test-temp',
    ).create(recursive: true);
    directory = await root.createTemp('received-mutation-');
    store = await openStore(directory: directory.path);
    bind();
    remote = Handle(
      address: 'remote@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'remote@example.com/iMessage',
    )..originalROWID = 9001;
    store.box<Handle>().put(remote);
    chat = Chat(
      guid: 'iMessage;-;remote@example.com',
      chatIdentifier: 'remote@example.com',
      style: 45,
      usingHandle: _owner,
      isRpSms: false,
    )..handles.add(remote);
    store.box<Chat>().put(chat);
  });
  tearDown(() async {
    if (!store.isClosed()) store.close();
    expect(directory.parent.absolute.path, root.absolute.path);
    await directory.delete(recursive: true);
  });
  CloudSyncReceivedMutationSourceBinding source(
    api.MessageInst wire, {
    String suffix = 'ciphertext',
  }) {
    final identity = CloudSyncReceivedMutationIdentity.captureWire(
      wire,
      liveContext: _live,
    )!;
    return CloudSyncReceivedMutationSourceBinding(
      accountFingerprint: auth.accountFingerprint,
      protectedStoreIdentity: auth.protectedStoreIdentity,
      mutationGuidHash: identity.guidHash,
      sourceSha256: identity.sourceSha256,
      ciphertext: 'obcs2.test.$suffix',
    );
  }

  int retain(
    api.MessageInst wire, {
    CloudSyncReceivedMutationSourceBinding? seed,
  }) => journal.retain(
    wire: wire,
    liveContext: _live,
    source: seed ?? source(wire),
    currentAuth: auth,
    stillCurrent: () => true,
    now: DateTime.utc(2026, 10, 21),
  );
  Message target({bool mirrored = false}) {
    final message = Message(
      guid: _target,
      text: 'Original',
      isFromMe: mirrored,
      handleId: mirrored ? 0 : remote.originalROWID,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      hasAttachments: false,
    )..chat.target = chat;
    store.box<Message>().put(message);
    return message;
  }

  Message reflect(Message before, {bool unsend = false}) {
    final changed = store.box<Message>().get(before.id!)!;
    changed.dateEdited = DateTime.fromMillisecondsSinceEpoch(1700000010000);
    changed.text = unsend ? before.text : 'Edited';
    changed.messageSummaryInfo = [
      MessageSummaryInfo.empty()..retractedParts.addAll(unsend ? [0] : []),
    ];
    return changed;
  }

  test(
    'encrypted event survives restart with no target and no outgoing or upload entry',
    () async {
      final wire = _wire();
      final seed = source(wire);
      final id = retain(wire, seed: seed);
      expect(
        journal.reflectionCommitted(intentId: id, currentAuth: auth),
        isFalse,
      );
      expect(store.box<Message>().count(), 0);
      expect(store.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      store.close();
      store = await openStore(directory: directory.path);
      bind();
      final pending = journal.readPending(currentAuth: auth).single;
      expect(pending.id, id);
      expect(pending.localMessageId, 0);
      expect(
        journal.findSource(eventGuid: wire.id, currentAuth: auth)!.encode(),
        seed.encode(),
      );
    },
  );
  test('duplicate event preserves its original ciphertext and identity', () {
    final wire = _wire();
    final seed = source(wire);
    final id = retain(wire, seed: seed);
    expect(retain(wire, seed: source(wire, suffix: 'randomized')), id);
    expect(
      journal.findSource(eventGuid: wire.id, currentAuth: auth)!.encode(),
      seed.encode(),
    );
    final altered = _wire(unsend: true);
    expect(() => retain(altered), throwsA(isA<StateError>()));
    expect(store.box<CloudSyncReceivedMutationIntentEntity>().count(), 1);
  });
  for (final mirrored in [false, true]) {
    for (final unsend in [false, true]) {
      test(
        'reflection commits with exact event, no resend; mirrored=$mirrored unsend=$unsend',
        () async {
          final wire = _wire(mirrored: mirrored, unsend: unsend);
          final original = target(mirrored: mirrored);
          final id = retain(wire);
          final before = CloudSyncReceivedMutationJournal.snapshot(original);
          final changed = reflect(original, unsend: unsend);
          journal.commitReflection(
            intentId: id,
            wire: wire,
            liveContext: _live,
            currentAuth: auth,
            stillCurrent: () => true,
            expectedBeforeSnapshot: before,
            reflected: changed,
            now: DateTime.utc(2026, 10, 21),
          );
          expect(
            journal.reflectionCommitted(intentId: id, currentAuth: auth),
            isTrue,
          );
          expect(store.box<Message>().get(original.id!)!.text, changed.text);
          final row = store.box<CloudSyncReceivedMutationIntentEntity>().get(
            id,
          )!;
          expect(row.beforeSnapshotSha256, before);
          expect(
            row.reflectedSnapshotSha256,
            CloudSyncReceivedMutationJournal.snapshot(
              store.box<Message>().get(original.id!)!,
            ),
          );
          expect(store.box<CloudOutboxOperationEntity>().count(), 0);
          // A duplicate cannot roll a newer local value back to the old edit.
          final newer = store.box<Message>().get(original.id!)!..text = 'Later';
          store.box<Message>().put(newer);
          final result = journal.commitReflection(
            intentId: id,
            wire: wire,
            liveContext: _live,
            currentAuth: auth,
            stillCurrent: () => true,
            expectedBeforeSnapshot: before,
            reflected: changed,
            now: DateTime.utc(2026, 10, 22),
          );
          expect(result.text, 'Later');
          store.close();
          store = await openStore(directory: directory.path);
          bind();
          expect(
            journal.reflectionCommitted(intentId: id, currentAuth: auth),
            isTrue,
          );
          expect(store.box<Message>().get(original.id!)!.text, 'Later');
        },
      );
    }
  }
  test('target change rejects reflection and preserves event', () {
    final wire = _wire();
    final original = target();
    final id = retain(wire);
    final before = CloudSyncReceivedMutationJournal.snapshot(original);
    final changed = reflect(original);
    final concurrent = store.box<Message>().get(original.id!)!
      ..text = 'Concurrent';
    store.box<Message>().put(concurrent);
    expect(
      () => journal.commitReflection(
        intentId: id,
        wire: wire,
        liveContext: _live,
        currentAuth: auth,
        stillCurrent: () => true,
        expectedBeforeSnapshot: before,
        reflected: changed,
        now: DateTime.utc(2026, 10, 21),
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      journal.reflectionCommitted(intentId: id, currentAuth: auth),
      isFalse,
    );
    expect(store.box<Message>().get(original.id!)!.text, 'Concurrent');
  });
  test(
    'identity revoked during commit rolls back Message and event marker together',
    () {
      final wire = _wire();
      final original = target();
      final id = retain(wire);
      final before = CloudSyncReceivedMutationJournal.snapshot(original);
      var checks = 0;
      expect(
        () => journal.commitReflection(
          intentId: id,
          wire: wire,
          liveContext: _live,
          currentAuth: auth,
          stillCurrent: () => ++checks < 2,
          expectedBeforeSnapshot: before,
          reflected: reflect(original),
          now: DateTime.utc(2026, 10, 21),
        ),
        throwsA(isA<StateError>()),
      );
      expect(store.box<Message>().get(original.id!)!.text, 'Original');
      expect(
        journal.reflectionCommitted(intentId: id, currentAuth: auth),
        isFalse,
      );
    },
  );
  test('foreign target author never gains mutation ownership', () {
    final wire = _wire();
    final original = target(mirrored: true);
    final id = retain(wire);
    expect(
      () => journal.commitReflection(
        intentId: id,
        wire: wire,
        liveContext: _live,
        currentAuth: auth,
        stillCurrent: () => true,
        expectedBeforeSnapshot: CloudSyncReceivedMutationJournal.snapshot(
          original,
        ),
        reflected: reflect(original),
        now: DateTime.utc(2026, 10, 21),
      ),
      throwsA(isA<StateError>()),
    );
    expect(store.box<Message>().get(original.id!)!.text, 'Original');
    expect(
      journal.reflectionCommitted(intentId: id, currentAuth: auth),
      isFalse,
    );
  });
  test(
    'late edit stays retained and cannot overwrite the newer reflected edit',
    () {
      final original = target();
      final newer = _wire(timestamp: 1700000030000);
      final newerId = retain(newer);
      journal.commitReflection(
        intentId: newerId,
        wire: newer,
        liveContext: _live,
        currentAuth: auth,
        stillCurrent: () => true,
        expectedBeforeSnapshot: CloudSyncReceivedMutationJournal.snapshot(
          original,
        ),
        reflected: reflect(original),
        now: DateTime.utc(2026, 10, 21),
      );
      final current = store.box<Message>().get(original.id!)!;
      expect(current.dateEdited!.millisecondsSinceEpoch, newer.sentTimestamp);
      final late = _wire(
        event: '11111111-2222-4333-8444-666666666666',
        timestamp: 1700000020000,
      );
      final lateId = retain(late);
      expect(
        () => journal.commitReflection(
          intentId: lateId,
          wire: late,
          liveContext: _live,
          currentAuth: auth,
          stillCurrent: () => true,
          expectedBeforeSnapshot: CloudSyncReceivedMutationJournal.snapshot(
            current,
          ),
          reflected: reflect(current)..text = 'Late',
          now: DateTime.utc(2026, 10, 21),
        ),
        throwsA(isA<StateError>()),
      );
      expect(store.box<Message>().get(original.id!)!.text, 'Edited');
      expect(
        journal.reflectionCommitted(intentId: lateId, currentAuth: auth),
        isFalse,
      );
      expect(journal.readPending(currentAuth: auth), hasLength(2));
    },
  );
  test(
    'edit cannot resurrect a retracted part even with a later timestamp',
    () {
      final original = target();
      final unsend = _wire(unsend: true);
      final id = retain(unsend);
      journal.commitReflection(
        intentId: id,
        wire: unsend,
        liveContext: _live,
        currentAuth: auth,
        stillCurrent: () => true,
        expectedBeforeSnapshot: CloudSyncReceivedMutationJournal.snapshot(
          original,
        ),
        reflected: reflect(original, unsend: true),
        now: DateTime.utc(2026, 10, 21),
      );
      final current = store.box<Message>().get(original.id!)!;
      final edit = _wire(
        event: '11111111-2222-4333-8444-666666666666',
        timestamp: 1700000020000,
      );
      final editId = retain(edit);
      expect(
        () => journal.commitReflection(
          intentId: editId,
          wire: edit,
          liveContext: _live,
          currentAuth: auth,
          stillCurrent: () => true,
          expectedBeforeSnapshot: CloudSyncReceivedMutationJournal.snapshot(
            current,
          ),
          reflected: reflect(current),
          now: DateTime.utc(2026, 10, 21),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        store
            .box<Message>()
            .get(original.id!)!
            .messageSummaryInfo
            .single
            .retractedParts,
        [0],
      );
      expect(
        journal.reflectionCommitted(intentId: editId, currentAuth: auth),
        isFalse,
      );
    },
  );
  test(
    'reflection does not roll back concurrent delivery and bookmark state',
    () {
      final wire = _wire();
      final original = target();
      final digest = CloudSyncReceivedMutationJournal.snapshot(original);
      final staleReflection = reflect(original);
      final current = store.box<Message>().get(original.id!)!
        ..dateDelivered = DateTime.utc(2026, 10, 20)
        ..dateRead = DateTime.utc(2026, 10, 21)
        ..isBookmarked = true
        ..ckRecordId = 'synthetic-existing-map';
      store.box<Message>().put(current);
      final id = retain(wire);
      final saved = journal.commitReflection(
        intentId: id,
        wire: wire,
        liveContext: _live,
        currentAuth: auth,
        stillCurrent: () => true,
        expectedBeforeSnapshot: digest,
        reflected: staleReflection,
        now: DateTime.utc(2026, 10, 21),
      );
      expect(saved.text, 'Edited');
      final restored = store.box<Message>().get(original.id!)!;
      expect(restored.isBookmarked, isTrue);
      expect(restored.dateRead!.millisecondsSinceEpoch, current.dateRead!.millisecondsSinceEpoch);
      expect(restored.dateDelivered!.millisecondsSinceEpoch, current.dateDelivered!.millisecondsSinceEpoch);
      expect(restored.ckRecordId, current.ckRecordId);
    },
  );
  test('state-zero row cannot pretend it owns a completed target snapshot', () {
    final id = retain(_wire());
    final rows = store.box<CloudSyncReceivedMutationIntentEntity>();
    final row = rows.get(id)!..localMessageId = 100;
    rows.put(row);
    expect(
      () => journal.readPending(currentAuth: auth),
      throwsA(isA<StateError>()),
    );
    expect(rows.get(id)!.protectedSourceBinding, row.protectedSourceBinding);
  });
  test(
    'source decoder rejects outgoing/original roles, corruption and account drift',
    () {
      final wire = _wire();
      final encoded = source(wire).encode();
      expect(
        () => CloudSyncReceivedMutationSourceBinding.decode(
          encoded.replaceFirst(
            'idsReceivedMutationSeed',
            'idsReceivedArchiveSeed',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => CloudSyncReceivedMutationSourceBinding.decode('$encoded '),
        throwsA(isA<StateError>()),
      );
      expect(
        () => CloudSyncReceivedMutationSourceBinding.decode(
          encoded.replaceFirst('ciphertext', 'tampered'),
        ),
        throwsA(isA<StateError>()),
      );
      final foreign = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'other',
        accountFingerprint: 'B' * 43,
        protectedStoreIdentity: storeIdentity,
        cloudMessagesClient: Object(),
      );
      expect(
        () => journal.retain(
          wire: wire,
          liveContext: _live,
          source: source(wire),
          currentAuth: foreign,
          stillCurrent: () => true,
          now: DateTime.utc(2026),
        ),
        throwsA(isA<StateError>()),
      );
      expect(store.box<CloudSyncReceivedMutationIntentEntity>().count(), 0);
    },
  );
}
