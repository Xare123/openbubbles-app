import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_replay.dart';
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
  String targetGuid = _target,
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
      ? api.Message.unsend(api.UnsendMessage(tuuid: targetGuid, editPart: 0))
      : api.Message.edit(
          api.EditMessage(
            tuuid: targetGuid,
            editPart: 0,
            newParts: const api.MessageParts(
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
  Message target({bool mirrored = false, String guid = _target}) {
    final message = Message(
      guid: guid,
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

  Message? readTarget(String guid) {
    final query = store
        .box<Message>()
        .query(Message_.guid.equals(guid))
        .build();
    try {
      return query.findUnique();
    } finally {
      query.close();
    }
  }

  String wireTarget(api.MessageInst wire) => switch (wire.message) {
    api.Message_Edit(:final field0) => field0.tuuid,
    api.Message_Unsend(:final field0) => field0.tuuid,
    _ => throw StateError('synthetic-unsupported-mutation'),
  };

  // Synthetic reopening result tied to the same retained wire/seed. This is
  // deliberately not an Apple call, native decryption or authentication proof.
  api.CloudSyncRestoredReceivedMutation nativeResult(
    api.MessageInst wire, {
    String? account,
    String? protectedStore,
    String? eventHash,
    String? targetHash,
    String? digest,
    List<String>? handles,
    api.MessageInst? message,
  }) {
    final identity = CloudSyncReceivedMutationIdentity.captureWire(
      wire,
      liveContext: _live,
    )!;
    return api.CloudSyncRestoredReceivedMutation(
      accountFingerprint: account ?? auth.accountFingerprint,
      protectedStoreIdentity: protectedStore ?? auth.protectedStoreIdentity,
      mutationGuidHash: eventHash ?? identity.guidHash,
      targetGuidHash: targetHash ?? identity.targetGuidHash,
      sourceSha256: digest ?? identity.sourceSha256,
      capturedLocalHandles: handles ?? _live.observedLocalHandles,
      message: message ?? wire,
    );
  }

  CloudSyncReceivedMutationReplay replay({
    required Future<api.CloudSyncRestoredReceivedMutation> Function(
      CloudSyncReceivedMutationSourceBinding,
    )
    restoreNative,
    bool Function()? stillCurrent,
    Future<void> Function()? validateIdentity,
    Future<void> Function(Future<void> Function())? enqueueLocal,
    Future<Message?> Function(api.MessageInst)? reflectWire,
    void Function(Message)? onReflected,
    void Function(Object)? onDeferred,
  }) => CloudSyncReceivedMutationReplay(
    journal: journal,
    currentAuth: auth,
    stillCurrent: stillCurrent ?? () => true,
    validateIdentity: validateIdentity ?? () async {},
    restoreNative: restoreNative,
    enqueueLocal: enqueueLocal ?? (work) async => work(),
    readTarget: readTarget,
    reflect:
        reflectWire ??
        (wire) async => reflect(
          readTarget(wireTarget(wire))!,
          unsend: wire.message is api.Message_Unsend,
        ),
    onReflected: onReflected ?? (_) {},
    onDeferred: onDeferred ?? (_) {},
    clock: () => DateTime.utc(2026, 10, 21),
  );

  CloudSyncReceivedMutationIntentEntity eventRow(int id) =>
      store.box<CloudSyncReceivedMutationIntentEntity>().get(id)!;

  void expectNoOutgoingWork() {
    expect(store.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
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
      expect(
        restored.dateRead!.millisecondsSinceEpoch,
        current.dateRead!.millisecondsSinceEpoch,
      );
      expect(
        restored.dateDelivered!.millisecondsSinceEpoch,
        current.dateDelivered!.millisecondsSinceEpoch,
      );
      expect(restored.ckRecordId, current.ckRecordId);
    },
  );
  for (final mirrored in [false, true]) {
    for (final unsend in [false, true]) {
      test(
        'replay after reopen waits for target then executes queue; mirrored=$mirrored unsend=$unsend',
        () async {
          final wire = _wire(mirrored: mirrored, unsend: unsend);
          final seed = source(wire);
          final id = retain(wire, seed: seed);
          expect(store.box<Message>().count(), 0);
          store.close();
          store = await openStore(directory: directory.path);
          bind();
          chat = store.box<Chat>().get(chat.id!)!;
          remote = store.box<Handle>().get(remote.id!)!;

          final opened = <String>[];
          final errors = <Object>[];
          var queued = 0;
          var executed = 0;
          var reflected = 0;
          var notified = 0;
          final runner = replay(
            restoreNative: (selected) async {
              opened.add(selected.encode());
              return nativeResult(wire);
            },
            enqueueLocal: (work) async {
              queued++;
              await work();
              executed++;
            },
            reflectWire: (selected) async {
              reflected++;
              return reflect(readTarget(wireTarget(selected))!, unsend: unsend);
            },
            onReflected: (_) {
              notified++;
            },
            onDeferred: errors.add,
          );
          final waiting = await runner.runPage(afterId: 0, maximumIntentId: id);
          expect(waiting.nextId, id);
          expect(waiting.exhausted, isTrue);
          expect(waiting.deferred, isTrue);
          expect(waiting.applied, 0);
          expect(eventRow(id).state, 0);
          expect(eventRow(id).localMessageId, 0);

          final original = target(mirrored: mirrored);
          final row = eventRow(id);
          final identity = CloudSyncReceivedMutationIdentity.restoreNative(
            nativeResult(wire),
            expectedGuidHash: row.mutationGuidHash,
            expectedTargetGuidHash: row.targetGuidHash,
            expectedSourceSha256: row.sourceSha256,
          )!;
          expect(
            identity.origin,
            mirrored
                ? CloudSyncReceivedArchiveOrigin.mirrored
                : CloudSyncReceivedArchiveOrigin.incoming,
          );
          expect(
            identity.kind,
            unsend
                ? CloudSyncReceivedMutationKind.unsend
                : CloudSyncReceivedMutationKind.edit,
          );
          final result = await runner.runPage(afterId: 0, maximumIntentId: id);
          expect(result.applied, 1);
          expect(result.exhausted, isTrue);
          expect(result.deferred, isFalse);
          expect(queued, 2);
          expect(
            executed,
            2,
            reason: 'the injected queue must execute its callback',
          );
          expect(reflected, 1);
          expect(notified, 1);
          expect(errors, isEmpty);
          expect(opened, [seed.encode(), seed.encode()]);
          final saved = store.box<Message>().get(original.id!)!;
          expect(saved.text, unsend ? 'Original' : 'Edited');
          expect(
            saved.messageSummaryInfo.single.retractedParts,
            unsend ? [0] : [],
          );
          expect(saved.dateEdited!.millisecondsSinceEpoch, wire.sentTimestamp);
          expect(eventRow(id).state, 1);
          expect(eventRow(id).localMessageId, original.id);
          expect(eventRow(id).protectedSourceBinding, seed.encode());
          expect(eventRow(id).sourceSha256, seed.sourceSha256);
          expectNoOutgoingWork();
        },
      );
    }
  }

  test(
    'replay advances past missing and unsupported events then retries original seeds',
    () async {
      final wires = [
        _wire(),
        _wire(
          event: '11111111-2222-4333-8444-666666666666',
          targetGuid: '99999999-8888-4777-8666-666666666666',
        ),
        _wire(
          event: '11111111-2222-4333-8444-777777777777',
          targetGuid: '99999999-8888-4777-8666-777777777777',
        ),
      ];
      final seeds = [
        for (var i = 0; i < wires.length; i++)
          source(wires[i], suffix: 'retained_$i'),
      ];
      final ids = [
        for (var i = 0; i < wires.length; i++) retain(wires[i], seed: seeds[i]),
      ];
      final highWater = journal.captureReadHighWatermark(currentAuth: auth);
      target(guid: wireTarget(wires.last));
      var unsupported = true;
      final opened = <String>[];
      final errors = <Object>[];
      final runner = replay(
        restoreNative: (selected) async {
          opened.add(selected.encode());
          final index = seeds.indexWhere(
            (seed) => seed.mutationGuidHash == selected.mutationGuidHash,
          );
          if (index == 1 && unsupported) {
            throw UnsupportedError('synthetic-unsupported-seed');
          }
          return nativeResult(wires[index]);
        },
        onDeferred: errors.add,
      );
      final first = await runner.runPage(
        afterId: 0,
        maximumIntentId: highWater,
        limit: 2,
      );
      expect(first.nextId, ids[1]);
      expect(first.applied, 0);
      expect(first.deferred, isTrue);
      expect(first.exhausted, isFalse);
      final later = await runner.runPage(
        afterId: first.nextId,
        maximumIntentId: highWater,
        limit: 2,
      );
      expect(later.nextId, ids.last);
      expect(later.applied, 1);
      expect(later.exhausted, isTrue);
      expect(errors, [isA<UnsupportedError>()]);
      expect(eventRow(ids[0]).state, 0);
      expect(eventRow(ids[1]).state, 0);
      expect(eventRow(ids[2]).state, 1);

      target(guid: wireTarget(wires[0]));
      target(guid: wireTarget(wires[1]));
      unsupported = false;
      final retried = await runner.runPage(
        afterId: 0,
        maximumIntentId: highWater,
        limit: 2,
      );
      expect(retried.applied, 2);
      expect(retried.exhausted, isTrue);
      expect(opened, [
        seeds[0].encode(),
        seeds[1].encode(),
        seeds[2].encode(),
        seeds[0].encode(),
        seeds[1].encode(),
      ]);
      for (var i = 0; i < ids.length; i++) {
        expect(eventRow(ids[i]).state, 1);
        expect(eventRow(ids[i]).protectedSourceBinding, seeds[i].encode());
      }
      expectNoOutgoingWork();
    },
  );

  test(
    'native restore mismatches are rejected before queue and journal reflection',
    () async {
      final wire = _wire();
      final original = target();
      final seed = source(wire);
      final id = retain(wire, seed: seed);
      final pinned = eventRow(id);
      final variants = <String, api.CloudSyncRestoredReceivedMutation>{
        'account': nativeResult(wire, account: 'B' * 43),
        'store': nativeResult(wire, protectedStore: 'obcs2.store.${'T' * 43}'),
        'event': nativeResult(wire, eventHash: 'f' * 64),
        'source': nativeResult(wire, digest: 'f' * 64),
        'target': nativeResult(wire, targetHash: 'f' * 64),
        'recipient not local': nativeResult(wire, handles: [_remote]),
        'changed direction': nativeResult(wire, handles: [_owner, _remote]),
        'oversized handles': nativeResult(
          wire,
          handles: List.filled(65, _owner),
        ),
        'changed wire target': nativeResult(
          wire,
          message: _wire(targetGuid: '99999999-8888-4777-8666-666666666666'),
        ),
        'changed wire timestamp': nativeResult(
          wire,
          message: _wire(timestamp: 1700000020000),
        ),
        'failed wire verification': nativeResult(
          wire,
          message: _wire()..verificationFailed = true,
        ),
      };
      var queued = 0;
      var reflected = 0;
      for (final variant in variants.entries) {
        final errors = <Object>[];
        if (variant.key != 'account' && variant.key != 'store') {
          expect(
            CloudSyncReceivedMutationIdentity.restoreNative(
              variant.value,
              expectedGuidHash: pinned.mutationGuidHash,
              expectedTargetGuidHash: pinned.targetGuidHash,
              expectedSourceSha256: pinned.sourceSha256,
            ),
            isNull,
            reason: variant.key,
          );
        }
        final runner = replay(
          restoreNative: (_) async => variant.value,
          enqueueLocal: (work) async {
            queued++;
            await work();
          },
          reflectWire: (_) async {
            reflected++;
            return reflect(original);
          },
          onDeferred: errors.add,
        );
        final result = await runner.runPage(afterId: 0, maximumIntentId: id);
        expect(result.applied, 0, reason: variant.key);
        expect(result.nextId, id);
        expect(result.deferred, isTrue);
        expect(errors, [isA<StateError>()], reason: variant.key);
        expect(
          () => journal.commitReplayedReflection(
            intentId: id,
            restored: variant.value,
            currentAuth: auth,
            stillCurrent: () => true,
            expectedBeforeSnapshot: CloudSyncReceivedMutationJournal.snapshot(
              original,
            ),
            reflected: reflect(original),
            now: DateTime.utc(2026, 10, 21),
          ),
          throwsA(isA<StateError>()),
          reason: variant.key,
        );
        expect(eventRow(id).state, 0);
        expect(eventRow(id).localMessageId, 0);
        expect(eventRow(id).beforeSnapshotSha256, isNull);
        expect(eventRow(id).reflectedSnapshotSha256, isNull);
        expect(eventRow(id).protectedSourceBinding, seed.encode());
        expect(store.box<Message>().get(original.id!)!.text, 'Original');
      }
      expect(queued, 0);
      expect(reflected, 0);
      final valid = replay(restoreNative: (_) async => nativeResult(wire));
      expect((await valid.runPage(afterId: 0, maximumIntentId: id)).applied, 1);
      expect(eventRow(id).protectedSourceBinding, seed.encode());
      expectNoOutgoingWork();
    },
  );

  test(
    'duplicate live commit racing enqueue skips replay reflection',
    () async {
      final wire = _wire();
      final original = target();
      final seed = source(wire);
      final id = retain(wire, seed: seed);
      expect(retain(wire, seed: source(wire, suffix: 'duplicate')), id);
      var executed = 0;
      var reflected = 0;
      var notified = 0;
      final runner = replay(
        restoreNative: (selected) async {
          expect(selected.encode(), seed.encode());
          return nativeResult(wire);
        },
        enqueueLocal: (work) async {
          journal.commitReflection(
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
          );
          store.box<Message>().put(
            store.box<Message>().get(original.id!)!
              ..text = 'Newer after live commit',
          );
          await work();
          executed++;
        },
        reflectWire: (_) async {
          reflected++;
          return reflect(original);
        },
        onReflected: (_) {
          notified++;
        },
        onDeferred: (error) =>
            fail('A committed duplicate must skip replay: $error'),
      );
      final result = await runner.runPage(afterId: 0, maximumIntentId: id);
      expect(result.applied, 0);
      expect(result.deferred, isFalse);
      expect(result.exhausted, isTrue);
      expect(executed, 1);
      expect(reflected, 0);
      expect(notified, 0);
      expect(eventRow(id).state, 1);
      expect(eventRow(id).protectedSourceBinding, seed.encode());
      expect(
        store.box<Message>().get(original.id!)!.text,
        'Newer after live commit',
      );
      expect(store.box<CloudSyncReceivedMutationIntentEntity>().count(), 1);
      expectNoOutgoingWork();
    },
  );

  test(
    'account drift while native restore awaits aborts before enqueue',
    () async {
      final wire = _wire();
      final original = target();
      final seed = source(wire);
      final id = retain(wire, seed: seed);
      final capturedAuth = auth;
      final restored = nativeResult(wire);
      final entered = Completer<void>();
      final opened = Completer<api.CloudSyncRestoredReceivedMutation>();
      var queued = 0;
      var reflected = 0;
      final errors = <Object>[];
      final runner = replay(
        stillCurrent: () => capturedAuth.sameIdentity(auth),
        restoreNative: (_) {
          entered.complete();
          return opened.future;
        },
        enqueueLocal: (work) async {
          queued++;
          await work();
        },
        reflectWire: (_) async {
          reflected++;
          return reflect(original);
        },
        onDeferred: errors.add,
      );
      final running = runner.runPage(afterId: 0, maximumIntentId: id);
      final aborted = expectLater(running, throwsA(isA<StateError>()));
      await entered.future.timeout(const Duration(seconds: 5));
      auth = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'changed-account-session',
        accountFingerprint: 'B' * 43,
        protectedStoreIdentity: storeIdentity,
        cloudMessagesClient: Object(),
      );
      opened.complete(restored);
      await aborted;
      expect(queued, 0);
      expect(reflected, 0);
      expect(
        errors,
        isEmpty,
        reason: 'identity drift aborts rather than deferring a row',
      );
      expect(eventRow(id).state, 0);
      expect(eventRow(id).localMessageId, 0);
      expect(eventRow(id).protectedSourceBinding, seed.encode());
      expect(store.box<Message>().get(original.id!)!.text, 'Original');
      expectNoOutgoingWork();
    },
  );

  test(
    'owner epoch drift while native restore awaits aborts before enqueue',
    () async {
      final wire = _wire();
      final original = target();
      final seed = source(wire);
      final id = retain(wire, seed: seed);
      final capturedEpoch = owner.automaticArchiveEpoch;
      final restored = nativeResult(wire);
      final entered = Completer<void>();
      final opened = Completer<api.CloudSyncRestoredReceivedMutation>();
      var queued = 0;
      var reflected = 0;
      final runner = replay(
        stillCurrent: () =>
            authority.read(scope)?.automaticArchiveEpoch == capturedEpoch,
        restoreNative: (_) {
          entered.complete();
          return opened.future;
        },
        enqueueLocal: (work) async {
          queued++;
          await work();
        },
        reflectWire: (_) async {
          reflected++;
          return reflect(original);
        },
      );
      final running = runner.runPage(afterId: 0, maximumIntentId: id);
      final aborted = expectLater(running, throwsA(isA<StateError>()));
      await entered.future.timeout(const Duration(seconds: 5));
      ObjectBoxCloudKitWriterAuthority.forTest(
        store: store,
        buildDecision: const CloudKitWriterOwnershipDecision(
          owner: CloudKitWriterOwner.legacy,
          configurationValid: true,
        ),
      ).prepareMigration(
        scope,
        from: CloudKitWriterOwner.v2,
        to: CloudKitWriterOwner.legacy,
        expectedEpoch: owner.epoch,
        transitionIdHash: 'd' * 64,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: DateTime.utc(2026, 10, 21),
      );
      expect(
        authority.read(scope)!.automaticArchiveEpoch,
        isNot(capturedEpoch),
      );
      opened.complete(restored);
      await aborted;
      expect(queued, 0);
      expect(reflected, 0);
      expect(eventRow(id).state, 0);
      expect(eventRow(id).localMessageId, 0);
      expect(eventRow(id).protectedSourceBinding, seed.encode());
      expect(store.box<Message>().get(original.id!)!.text, 'Original');
      expectNoOutgoingWork();
    },
  );

  test(
    'replay preserves newer edits and terminal retraction against late events',
    () async {
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
        reflected: reflect(original)..text = 'Newer edit',
        now: DateTime.utc(2026, 10, 21),
      );
      final wires = [
        _wire(
          event: '11111111-2222-4333-8444-666666666666',
          timestamp: 1700000020000,
        ),
        _wire(
          event: '11111111-2222-4333-8444-777777777777',
          unsend: true,
          timestamp: 1700000025000,
        ),
        _wire(
          event: '11111111-2222-4333-8444-888888888888',
          unsend: true,
          timestamp: 1700000040000,
        ),
        _wire(
          event: '11111111-2222-4333-8444-999999999999',
          timestamp: 1700000050000,
        ),
      ];
      final byHash = {
        for (final wire in wires) source(wire).mutationGuidHash: wire,
      };
      final errors = <Object>[];
      final runner = replay(
        restoreNative: (selected) async =>
            nativeResult(byHash[selected.mutationGuidHash]!),
        onDeferred: errors.add,
      );
      final lateEditId = retain(wires[0]);
      final lateUnsendId = retain(wires[1]);
      final late = await runner.runPage(
        afterId: newerId,
        maximumIntentId: lateUnsendId,
      );
      expect(late.applied, 0);
      expect(late.deferred, isTrue);
      expect(late.nextId, lateUnsendId);
      expect(late.exhausted, isTrue);
      expect(eventRow(lateEditId).state, 0);
      expect(eventRow(lateUnsendId).state, 0);
      expect(store.box<Message>().get(original.id!)!.text, 'Newer edit');
      expect(
        store
            .box<Message>()
            .get(original.id!)!
            .dateEdited!
            .millisecondsSinceEpoch,
        newer.sentTimestamp,
      );
      expect(
        store
            .box<Message>()
            .get(original.id!)!
            .messageSummaryInfo
            .single
            .retractedParts,
        isEmpty,
      );
      expect(errors, hasLength(2));

      final unsendId = retain(wires[2]);
      expect(
        (await runner.runPage(
          afterId: lateUnsendId,
          maximumIntentId: unsendId,
        )).applied,
        1,
      );
      final resurrectId = retain(wires[3]);
      final resurrect = await runner.runPage(
        afterId: unsendId,
        maximumIntentId: resurrectId,
      );
      expect(resurrect.applied, 0);
      expect(resurrect.deferred, isTrue);
      expect(eventRow(resurrectId).state, 0);
      expect(store.box<Message>().get(original.id!)!.text, 'Newer edit');
      expect(
        store
            .box<Message>()
            .get(original.id!)!
            .messageSummaryInfo
            .single
            .retractedParts,
        [0],
      );
      expectNoOutgoingWork();
    },
  );

  test(
    'replayed wrong target and awaited snapshot drift preserve newer data',
    () async {
      final wire = _wire();
      final original = target()..text = 'Newer target data';
      store.box<Message>().put(original);
      final other = target(guid: '99999999-8888-4777-8666-666666666666')
        ..text = 'Unrelated newer data';
      store.box<Message>().put(other);
      final seed = source(wire);
      final id = retain(wire, seed: seed);
      final errors = <Object>[];
      var notified = 0;
      final wrongTarget = replay(
        restoreNative: (_) async => nativeResult(wire),
        reflectWire: (_) async => reflect(other)..text = 'Wrong projection',
        onReflected: (_) {
          notified++;
        },
        onDeferred: errors.add,
      );
      expect(
        (await wrongTarget.runPage(afterId: 0, maximumIntentId: id)).applied,
        0,
      );
      expect(store.box<Message>().get(original.id!)!.text, 'Newer target data');
      expect(store.box<Message>().get(other.id!)!.text, 'Unrelated newer data');
      final stale = replay(
        restoreNative: (_) async => nativeResult(wire),
        reflectWire: (_) async {
          final projected = reflect(original);
          await Future<void>.value();
          store.box<Message>().put(
            store.box<Message>().get(original.id!)!
              ..text = 'Concurrent newest data',
          );
          return projected;
        },
        onReflected: (_) {
          notified++;
        },
        onDeferred: errors.add,
      );
      final result = await stale.runPage(afterId: 0, maximumIntentId: id);
      expect(result.applied, 0);
      expect(result.deferred, isTrue);
      expect(errors, hasLength(2));
      expect(notified, 0);
      expect(eventRow(id).state, 0);
      expect(eventRow(id).localMessageId, 0);
      expect(eventRow(id).protectedSourceBinding, seed.encode());
      expect(
        store.box<Message>().get(original.id!)!.text,
        'Concurrent newest data',
      );
      expect(store.box<Message>().get(other.id!)!.text, 'Unrelated newer data');
      expectNoOutgoingWork();
    },
  );

  test(
    'replay pagination freezes high water until the next bounded round',
    () async {
      final original = target();
      final first = _wire();
      final second = _wire(
        event: '11111111-2222-4333-8444-666666666666',
        timestamp: 1700000020000,
      );
      final added = _wire(
        event: '11111111-2222-4333-8444-777777777777',
        timestamp: 1700000030000,
      );
      final firstId = retain(first);
      final secondId = retain(second);
      final highWater = journal.captureReadHighWatermark(currentAuth: auth);
      expect(highWater, secondId);
      final addedSeed = source(added, suffix: 'after_high_water');
      int? addedId;
      final byHash = {
        for (final wire in [first, second, added])
          source(wire).mutationGuidHash: wire,
      };
      final opened = <String>[];
      final runner = replay(
        restoreNative: (selected) async {
          opened.add(selected.mutationGuidHash);
          addedId ??= retain(added, seed: addedSeed);
          return nativeResult(byHash[selected.mutationGuidHash]!);
        },
        onDeferred: (error) =>
            fail('Valid bounded replay must not defer: $error'),
      );
      final page1 = await runner.runPage(
        afterId: 0,
        maximumIntentId: highWater,
        limit: 1,
      );
      expect(page1.nextId, firstId);
      expect(page1.applied, 1);
      expect(page1.exhausted, isFalse);
      expect(addedId, greaterThan(highWater));
      expect(eventRow(addedId!).state, 0);
      final page2 = await runner.runPage(
        afterId: page1.nextId,
        maximumIntentId: highWater,
        limit: 1,
      );
      expect(page2.nextId, secondId);
      expect(page2.applied, 1);
      expect(page2.exhausted, isTrue);
      expect(opened, [
        source(first).mutationGuidHash,
        source(second).mutationGuidHash,
      ]);
      final exhausted = await runner.runPage(
        afterId: page2.nextId,
        maximumIntentId: highWater,
        limit: 1,
      );
      expect(exhausted.nextId, secondId);
      expect(exhausted.applied, 0);
      expect(exhausted.exhausted, isTrue);
      expect(eventRow(addedId!).state, 0);

      final nextHighWater = journal.captureReadHighWatermark(currentAuth: auth);
      expect(nextHighWater, addedId);
      final nextRound = await runner.runPage(
        afterId: 0,
        maximumIntentId: nextHighWater,
        limit: 1,
      );
      expect(nextRound.applied, 1);
      expect(nextRound.nextId, addedId);
      expect(nextRound.exhausted, isTrue);
      expect(opened.last, addedSeed.mutationGuidHash);
      expect(eventRow(addedId!).state, 1);
      expect(eventRow(addedId!).protectedSourceBinding, addedSeed.encode());
      expect(
        store
            .box<Message>()
            .get(original.id!)!
            .dateEdited!
            .millisecondsSinceEpoch,
        added.sentTimestamp,
      );
      expectNoOutgoingWork();
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
