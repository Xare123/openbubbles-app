import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudSyncLocalMutationJournal journal;
  late Message target;
  late CloudSyncLocalMutationIdentity identity;
  late CloudSyncLocalMutationSourceBinding source;
  late String snapshot;

  void bind() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    if (authority.read(_scope) == null) {
      final disabled = authority.initializeDisabled(_scope, now: _time(0));
      authority.provisionInitialOwner(
        _scope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: _time(1),
      );
    }
    journal = CloudSyncLocalMutationJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authority.read(_scope)!,
    );
  }

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
    bind();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ob-mutation-journal-');
    store = await openStore(directory: directory.path);
    bind();
    final handle = Handle(
      address: 'peer@example.invalid',
      service: 'iMessage',
      uniqueAddressAndService: 'peer@example.invalid/iMessage',
    );
    store.box<Handle>().put(handle);
    final chat = Chat(
      guid: 'iMessage;-;peer@example.invalid',
      style: 45,
      chatIdentifier: 'peer@example.invalid',
      usingHandle: 'mailto:me@example.invalid',
      participants: [handle],
    );
    chat.handles.add(handle);
    store.box<Chat>().put(chat);
    target = Message(
      guid: _target,
      isFromMe: true,
      text: 'original',
      dateCreated: _time(1),
      attributedBody: [AttributedBody.raw('original')],
    );
    target.chat.target = chat;
    store.box<Message>().put(target);
    identity = CloudSyncLocalMutationIdentity.captureWire(_wire())!;
    source = _source(identity);
    snapshot = journal.captureTargetSnapshot(
      localMessageId: target.id!,
      identity: identity,
    );
  });
  tearDown(() async {
    if (!store.isClosed()) store.close();
    await directory.delete(recursive: true);
  });

  int adopt() => journal.adoptSource(
    localMessageId: target.id!,
    identity: identity,
    targetSnapshotSha256: snapshot,
    source: source,
    capturedAuth: _auth(),
    stillCurrent: () => true,
    now: _time(2),
  );
  void claim(int id) => journal.beginSubmission(
    intentId: id,
    committedSource: source,
    capturedAuth: _auth(),
    stillCurrent: () => true,
    now: _time(3),
  );
  void confirm(int id, {api.CloudSyncNativeSendReceipt? receipt}) =>
      journal.recordNativeReceipt(
        intentId: id,
        receipt: receipt ?? _receipt(identity, source),
        capturedAuth: _auth(),
        stillCurrent: () => true,
        now: _time(4),
      );
  CloudSyncLocalMutationIntentEntity row(int id) =>
      store.box<CloudSyncLocalMutationIntentEntity>().get(id)!;
  ObjectBoxCloudSyncStore gc() =>
      ObjectBoxCloudSyncStore(store: store, protector: _NoProtector());

  late _MutationTransport transport;
  late _MutationExclusion exclusion;
  late CloudSyncNativeAuthSnapshot stagingAuth;
  late CloudSyncNativeAuthSnapshot capturedNow;
  late bool current;
  late int stageCalls;
  late int restoreCalls;
  Future<void> Function()? duringStage;
  Future<void> Function()? duringRestore;
  api.MessageInst Function()? restoredWire;
  setUp(() {
    transport = _MutationTransport();
    exclusion = _MutationExclusion();
    stagingAuth = _auth();
    capturedNow = stagingAuth;
    current = true;
    stageCalls = 0;
    restoreCalls = 0;
    duringStage = null;
    duringRestore = null;
    restoredWire = null;
  });
  Future<
    ({
      int intentId,
      CloudSyncLocalMutationSourceBinding source,
      api.MessageInst wire,
    })
  >
  prepare() =>
      CloudSyncLocalMutationSourceStaging(
        journal: journal,
        authFence: CloudSyncLocalSendAuthFence(
          expected: stagingAuth,
          capture: () async => capturedNow,
          stillCurrent: () => current,
        ),
        capturedAuth: stagingAuth,
        stillCurrent: () => current,
        exclusion: exclusion,
        transport: transport,
      ).prepareSubmission(
        localMessageId: target.id!,
        identity: identity,
        stage: () async {
          expect(exclusion.held && transport.held, isTrue);
          stageCalls++;
          await duringStage?.call();
          return source;
        },
        restore: (committed) async {
          expect(exclusion.held && transport.held, isTrue);
          expect(committed.encode(), source.encode());
          expect(transport.commits, isNotEmpty);
          restoreCalls++;
          await duringRestore?.call();
          return restoredWire?.call() ?? _wire();
        },
      );

  Future<int> submit(Future<api.CloudSyncNativeSendReceipt> Function() send) =>
      CloudSyncLocalMutationSourceStaging(
        journal: journal,
        authFence: CloudSyncLocalSendAuthFence(
          expected: stagingAuth,
          capture: () async => capturedNow,
          stillCurrent: () => current,
        ),
        capturedAuth: stagingAuth,
        stillCurrent: () => current,
        exclusion: exclusion,
        transport: transport,
      ).submitConfirmed(
        localMessageId: target.id!,
        identity: identity,
        stage: () async {
          stageCalls++;
          return source;
        },
        restore: (_) async {
          restoreCalls++;
          return _wire();
        },
        send: (wire, original) {
          expect(exclusion.held || transport.held, isFalse);
          expect(original.encode(), source.encode());
          expect(
            CloudSyncLocalMutationIdentity.captureWire(wire)!.sourceSha256,
            identity.sourceSha256,
          );
          expect(
            store
                .box<CloudSyncLocalMutationIntentEntity>()
                .getAll()
                .single
                .state,
            1,
          );
          return send();
        },
      );

  test(
    'composed submission sends once and confirms durable original after reopen',
    () async {
      var sends = 0;
      final id = await submit(() async {
        sends++;
        return _receipt(identity, source);
      });
      expect(row(id).state, 2);
      expect(store.box<Message>().get(target.id!)!.text, 'original');
      await reopen();
      await expectLater(
        submit(() async {
          sends++;
          return _receipt(identity, source);
        }),
        throwsA(_failure('already_claimed')),
      );
      expect(sends, 1);
      expect(stageCalls, 1);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(transport.rollbacks, isEmpty);
      expect(transport.acknowledgements, 0);
    },
  );

  for (final fault in ['timeout', 'bad-receipt', 'auth-after-send']) {
    test(
      'composed $fault retains unknown outcome and cannot resend after reopen',
      () async {
        var sends = 0;
        await expectLater(
          submit(() async {
            sends++;
            if (fault == 'timeout') {
              throw StateError('synthetic_network_timeout');
            }
            if (fault == 'auth-after-send') {
              capturedNow = _auth(session: 'replacement');
            }
            return _receipt(
              identity,
              source,
              kind: fault == 'bad-receipt'
                  ? api.CloudSyncNativeSendSourceKind.attachment
                  : api.CloudSyncNativeSendSourceKind.mutation,
            );
          }),
          throwsStateError,
        );
        final id = store
            .box<CloudSyncLocalMutationIntentEntity>()
            .getAll()
            .single
            .id;
        expect(row(id).state, 1);
        await reopen();
        capturedNow = stagingAuth;
        await expectLater(
          submit(() async {
            sends++;
            return _receipt(identity, source);
          }),
          throwsA(_failure('already_claimed')),
        );
        expect(sends, 1);
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
        expect(store.box<Message>().get(target.id!)!.text, 'original');
        expect(transport.rollbacks, isEmpty);
        expect(transport.acknowledgements, 0);
      },
    );
  }

  test(
    'final submission check rejects changed target and current native session',
    () async {
      final prepared = await prepare();
      void verify() => journal.requireClaimedSubmission(
        intentId: prepared.intentId,
        committedSource: source,
        capturedAuth: stagingAuth,
        stillCurrent: () => current,
      );
      verify();
      target.text = 'changed after preparation';
      store.box<Message>().put(target);
      expect(verify, throwsA(_failure('target_changed')));
      target.text = 'original';
      store.box<Message>().put(target);
      expect(
        () => journal.requireClaimedSubmission(
          intentId: prepared.intentId,
          committedSource: source,
          capturedAuth: _auth(session: 'replacement'),
          stillCurrent: () => true,
        ),
        throwsA(_failure('submission_changed')),
      );
      expect(row(prepared.intentId).state, 1);
    },
  );

  test(
    'composed staging claims once and receipt routing confirms only mutation',
    () async {
      final prepared = await prepare();
      expect(row(prepared.intentId).state, 1);
      expect(stageCalls, 1);
      expect(restoreCalls, 1);
      expect(exclusion.held || transport.held, isFalse);
      expect(
        journal.recordNativeReceiptIfTracked(
          receipt: _receipt(identity, source),
          capturedAuth: stagingAuth,
          stillCurrent: () => true,
          now: DateTime.now().toUtc(),
        ),
        isTrue,
      );
      expect(row(prepared.intentId).state, 2);
      await expectLater(prepare(), throwsA(_failure('already_claimed')));
      expect(stageCalls, 1);
      expect(restoreCalls, 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(transport.rollbacks, isEmpty);
      expect(transport.acknowledgements, 0);
    },
  );

  test(
    'commit failure reopens and reuses the adopted lease without staging again',
    () async {
      transport.failCommit = true;
      await expectLater(prepare(), throwsStateError);
      final id = store
          .box<CloudSyncLocalMutationIntentEntity>()
          .getAll()
          .single
          .id;
      expect(row(id).state, 0);
      expect(restoreCalls, 0);
      expect(transport.rollbacks, isEmpty);
      await reopen();
      transport.failCommit = false;
      final prepared = await prepare();
      expect(prepared.intentId, id);
      expect(stageCalls, 1);
      expect(transport.commits, [source.leaseReference, source.leaseReference]);
      expect(row(id).state, 1);
      await reopen();
      await expectLater(prepare(), throwsA(_failure('already_claimed')));
      expect(stageCalls, 1);
      expect(restoreCalls, 1);
    },
  );

  test(
    'target changes during stage roll back only the unadopted lease',
    () async {
      duringStage = () async {
        target.text = 'newer';
        store.box<Message>().put(target);
      };
      await expectLater(prepare(), throwsA(_failure('target_changed')));
      expect(store.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
      expect(transport.rollbacks, [source.leaseReference]);
      expect(transport.commits, isEmpty);
      expect(exclusion.held || transport.held, isFalse);
    },
  );

  for (final point in ['stage', 'restore']) {
    test('native auth change during $point cannot claim a send', () async {
      Future<void> replaceAuth() async {
        capturedNow = _auth(session: 'replacement');
      }

      if (point == 'stage') {
        duringStage = replaceAuth;
      } else {
        duringRestore = replaceAuth;
      }
      await expectLater(prepare(), throwsStateError);
      final rows = store.box<CloudSyncLocalMutationIntentEntity>().getAll();
      if (point == 'stage') {
        expect(rows, isEmpty);
        expect(transport.rollbacks, [source.leaseReference]);
      } else {
        expect(rows.single.state, 0);
        expect(transport.rollbacks, isEmpty);
      }
    });
  }

  test('changed restored wire is retained but not claimed', () async {
    restoredWire = () => _wire()..sentTimestamp = 100;
    await expectLater(prepare(), throwsA(_failure('protected_source_changed')));
    expect(
      store.box<CloudSyncLocalMutationIntentEntity>().getAll().single.state,
      0,
    );
    expect(transport.rollbacks, isEmpty);
  });

  test(
    'newer target after native restore is preserved without claiming',
    () async {
      duringRestore = () async {
        target.text = 'newer';
        store.box<Message>().put(target);
      };
      await expectLater(prepare(), throwsA(_failure('target_changed')));
      expect(store.box<Message>().get(target.id!)!.text, 'newer');
      expect(
        store.box<CloudSyncLocalMutationIntentEntity>().getAll().single.state,
        0,
      );
      expect(transport.rollbacks, isEmpty);
    },
  );

  test('busy exclusion or wrong store prevents native staging', () async {
    exclusion.busy = true;
    await expectLater(prepare(), throwsStateError);
    exclusion.busy = false;
    transport.storeIdentity = 'obcs2.store.${'Z' * 43}';
    await expectLater(prepare(), throwsA(_failure('protected_source_changed')));
    expect(stageCalls, 0);
    expect(store.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
  });

  test(
    'receipt routing keeps untracked and attachment receipts separate',
    () async {
      expect(
        journal.recordNativeReceiptIfTracked(
          receipt: _receipt(identity, source),
          capturedAuth: stagingAuth,
          stillCurrent: () => true,
          now: _time(5),
        ),
        isFalse,
      );
      final id = adopt();
      claim(id);
      expect(
        journal.recordNativeReceiptIfTracked(
          receipt: _receipt(
            identity,
            source,
            kind: api.CloudSyncNativeSendSourceKind.attachment,
          ),
          capturedAuth: stagingAuth,
          stillCurrent: () => true,
          now: _time(5),
        ),
        isFalse,
      );
      expect(row(id).state, 1);
      expect(transport.acknowledgements, 0);
    },
  );

  test(
    'separate intent survives reopen without inventing an initial create',
    () async {
      final id = adopt();
      expect(adopt(), id);
      await reopen();
      expect(row(id).targetSnapshotSha256, snapshot);
      expect(row(id).mutationGuidHash, isNot(row(id).targetGuidHash));
      expect(row(id).state, 0);
      expect(journal.readConfirmed(), isEmpty);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(source.toString(), isNot(contains('replacement')));
    },
  );

  test('changed target during staging is rejected before adoption', () {
    target.text = 'newer';
    store.box<Message>().put(target);
    expect(adopt, throwsA(_failure('target_changed')));
    expect(store.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
  });

  for (final drift in ['sender', 'recipient', 'conversation']) {
    test('wire $drift must match the persisted target route', () {
      final wire = _wire();
      if (drift == 'sender') wire.sender = 'mailto:other@example.invalid';
      if (drift == 'recipient') {
        wire.conversation!.participants[1] = 'mailto:other@example.invalid';
      }
      if (drift == 'conversation') {
        wire.conversation!.senderGuid = 'iMessage;-;other@example.invalid';
      }
      final changed = CloudSyncLocalMutationIdentity.captureWire(wire)!;
      expect(
        () => journal.adoptSource(
          localMessageId: target.id!,
          identity: changed,
          targetSnapshotSha256: snapshot,
          source: _source(changed),
          capturedAuth: _auth(),
          stillCurrent: () => true,
          now: _time(2),
        ),
        throwsA(_failure('route_changed')),
      );
      expect(store.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
    });
  }

  test('changed target after adoption never becomes a claimed send', () {
    final id = adopt();
    target.text = 'newer';
    store.box<Message>().put(target);
    expect(() => claim(id), throwsA(_failure('target_changed')));
    expect(row(id).state, 0);
  });

  test('unsend remains a mutation, never an initial message create', () async {
    final wire = _wire()
      ..message = const api.Message.unsend(
        api.UnsendMessage(tuuid: _target, editPart: 0),
      );
    identity = CloudSyncLocalMutationIdentity.captureWire(wire)!;
    source = _source(identity);
    restoredWire = () => wire;
    final id = (await prepare()).intentId;
    expect(
      journal.recordNativeReceiptIfTracked(
        receipt: _receipt(identity, source),
        capturedAuth: stagingAuth,
        stillCurrent: () => true,
        now: DateTime.now().toUtc(),
      ),
      isTrue,
    );
    await reopen();
    expect(row(id).kind, CloudSyncLocalMutationKind.unsend.index);
    expect(row(id).state, 2);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
  });

  test('old writer epoch can retain proof but never reclaim a send', () async {
    final id = adopt();
    claim(id);
    final permit = authority.issuePermit(
      _scope,
      expectedOwner: CloudKitWriterOwner.v2,
    );
    authority.markMutationUnknown(permit, now: _time(4));
    expect(() => confirm(id), throwsA(_failure('owner_changed')));
    await reopen();
    expect(() => claim(id), throwsA(_failure('owner_changed')));
    confirm(id);
    expect(row(id).state, 2);
    expect(journal.readConfirmed().single.id, id);
    expect(
      await gc().readLiveProtectedOutboundLeaseReferences(maximumCount: 100),
      contains(source.leaseReference),
    );
  });

  test(
    'retained source stays live when its account is no longer current',
    () async {
      adopt();
      final unrelated = CloudKitWriterScope(accountFingerprint: 'B' * 43);
      authority.initializeDisabled(unrelated, now: _time(3));
      final anotherJournal = CloudSyncLocalMutationJournal(
        store: store,
        authority: authority,
        authoritySnapshot: authority.read(unrelated)!,
      );
      expect(() => anotherJournal.readConfirmed(), throwsStateError);
      await reopen();
      expect(
        (await gc().readLiveProtectedReferences(maximumCount: 100)).references,
        contains(source.protectedReference),
      );
      expect(
        await gc().readLiveProtectedOutboundLeaseReferences(maximumCount: 100),
        contains(source.leaseReference),
      );
    },
  );

  test(
    'claim persists before send and cannot be repeated after restart',
    () async {
      final id = adopt();
      claim(id);
      await reopen();
      expect(() => claim(id), throwsA(_failure('already_claimed')));
      expect(row(id).state, 1);
      expect(row(id).idsReceiptBindingSha256, isNull);
      expect(journal.readConfirmed(), isEmpty);
    },
  );

  test('receipt cannot promote a never-claimed source', () {
    final id = adopt();
    expect(() => confirm(id), throwsA(_failure('receipt_changed')));
    expect(row(id).state, 0);
  });

  for (final kind in [null, api.CloudSyncNativeSendSourceKind.attachment]) {
    test('receipt purpose $kind cannot be reclassified as mutation', () {
      final id = adopt();
      claim(id);
      expect(
        () => confirm(id, receipt: _receipt(identity, source, kind: kind)),
        throwsA(_failure('receipt_changed')),
      );
      expect(row(id).state, 1);
    });
  }

  test(
    'positive receipt is idempotent but changed receipt is not accepted',
    () async {
      final id = adopt();
      claim(id);
      confirm(id);
      final proof = row(id).idsReceiptBindingSha256;
      await reopen();
      confirm(id);
      expect(row(id).idsReceiptBindingSha256, proof);
      expect(journal.readConfirmed().single.id, id);
      expect(
        () => confirm(
          id,
          receipt: _receipt(identity, source, receiptMarker: 'B'),
        ),
        throwsA(_failure('receipt_changed')),
      );
      expect(row(id).idsReceiptBindingSha256, proof);
    },
  );

  test(
    'new native session needs authenticated replay of the original receipt',
    () async {
      final id = adopt();
      claim(id);
      await reopen();
      final auth = _auth(session: 'new-session');
      final receipt = _receipt(identity, source);
      expect(
        () => journal.recordNativeReceipt(
          intentId: id,
          receipt: receipt,
          capturedAuth: auth,
          stillCurrent: () => true,
          now: _time(4),
        ),
        throwsA(_failure('receipt_session_changed')),
      );
      final state = Object();
      final replay = CloudSyncNativeReceiptReplayBinding(
        expectedAuth: auth,
        expectedState: state,
        expectedStore: store,
        expectedClient: auth.cloudMessagesClient,
        expectedStoragePath: directory.path,
        readState: () => state,
        readStore: () => store,
        readClient: () => auth.cloudMessagesClient,
        readStoragePath: () => directory.path,
        runtimeCurrent: () => true,
      );
      expect(
        journal.recordNativeReceiptIfTracked(
          receipt: receipt,
          capturedAuth: auth,
          stillCurrent: () => true,
          replayBinding: replay,
          now: _time(4),
        ),
        isTrue,
      );
      expect(row(id).state, 2);
      expect(
        () => journal.recordNativeReceipt(
          intentId: id,
          receipt: _receipt(identity, source, session: 'new-session'),
          capturedAuth: auth,
          stillCurrent: () => true,
          replayBinding: replay,
          now: _time(5),
        ),
        throwsA(_failure('receipt_changed')),
      );
    },
  );

  test(
    'reflection is atomic and duplicate replay never projects twice',
    () async {
      final id = adopt();
      claim(id);
      confirm(id);
      var calls = 0;
      void reflect() => journal.reflectConfirmed(
        intentId: id,
        currentAuth: _auth(),
        stillCurrent: () => true,
        now: _time(5),
        project: (message) {
          calls++;
          message
            ..text = 'replacement'
            ..dateEdited = _time(4)
            ..attributedBody = [AttributedBody.raw('replacement')];
          return message;
        },
      );
      reflect();
      await reopen();
      reflect();
      expect(calls, 1);
      expect(row(id).state, 3);
      expect(store.box<Message>().get(target.id!)!.text, 'replacement');
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test('failed reflection rolls back row and message together', () {
    final id = adopt();
    claim(id);
    confirm(id);
    expect(
      () => journal.reflectConfirmed(
        intentId: id,
        currentAuth: _auth(),
        stillCurrent: () => true,
        now: _time(5),
        project: (message) {
          message.text = 'must roll back';
          store.box<Message>().put(message);
          throw StateError('synthetic projection failure');
        },
      ),
      throwsStateError,
    );
    expect(row(id).state, 2);
    expect(store.box<Message>().get(target.id!)!.text, 'original');
  });

  test(
    'projection cannot change the route or writer epoch while committing',
    () {
      final id = adopt();
      claim(id);
      confirm(id);
      expect(
        () => journal.reflectConfirmed(
          intentId: id,
          currentAuth: _auth(),
          stillCurrent: () => true,
          now: _time(5),
          project: (message) {
            final chat = message.chat.target!;
            chat.usingHandle = 'mailto:other@example.invalid';
            store.box<Chat>().put(chat);
            return message..text = 'replacement';
          },
        ),
        throwsA(_failure('reflection_target_changed')),
      );
      expect(row(id).state, 2);
      expect(
        store.box<Message>().get(target.id!)!.chat.target!.usingHandle,
        'mailto:me@example.invalid',
      );
      final permit = authority.issuePermit(
        _scope,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      expect(
        () => journal.reflectConfirmed(
          intentId: id,
          currentAuth: _auth(),
          stillCurrent: () => true,
          now: _time(5),
          project: (message) {
            authority.markMutationUnknown(permit, now: _time(5));
            return message..text = 'replacement';
          },
        ),
        throwsA(_failure('owner_changed')),
      );
      expect(row(id).state, 2);
      expect(store.box<Message>().get(target.id!)!.text, 'original');
      authority.verifyPermit(permit);
    },
  );

  test('newer target is never overwritten by delayed confirmed mutation', () {
    final id = adopt();
    claim(id);
    confirm(id);
    target.text = 'newer edit';
    store.box<Message>().put(target);
    expect(
      () => journal.reflectConfirmed(
        intentId: id,
        currentAuth: _auth(),
        stillCurrent: () => true,
        now: _time(5),
        project: (_) => throw StateError('must not run'),
      ),
      throwsA(_failure('target_changed')),
    );
    expect(row(id).state, 2);
    expect(store.box<Message>().get(target.id!)!.text, 'newer edit');
  });

  for (final stage in [0, 1, 2, 3]) {
    test(
      'both GC roots retain mutation source at stage $stage after reopen',
      () async {
        final id = adopt();
        if (stage >= 1) claim(id);
        if (stage >= 2) confirm(id);
        if (stage == 3) {
          journal.reflectConfirmed(
            intentId: id,
            currentAuth: _auth(),
            stillCurrent: () => true,
            now: _time(5),
            project: (message) => message..text = 'replacement',
          );
        }
        await reopen();
        final refs = await gc().readLiveProtectedReferences(maximumCount: 100);
        expect(refs.isComplete, isTrue);
        expect(refs.references, contains(source.protectedReference));
        expect(
          await gc().readLiveProtectedOutboundLeaseReferences(
            maximumCount: 100,
          ),
          contains(source.leaseReference),
        );
        final bounded = await gc().readLiveProtectedReferences(maximumCount: 1);
        expect(bounded.isComplete, isFalse);
      },
    );
  }

  test(
    'corrupt mutation row fails GC instead of omitting the source',
    () async {
      final id = adopt();
      store.box<CloudSyncLocalMutationIntentEntity>().put(
        row(id)..sourceSha256 = 'c' * 64,
      );
      await expectLater(
        gc().readLiveProtectedReferences(maximumCount: 100),
        throwsStateError,
      );
      await expectLater(
        gc().readLiveProtectedOutboundLeaseReferences(maximumCount: 100),
        throwsStateError,
      );
    },
  );

  test('changed account cannot claim an adopted mutation', () {
    final id = adopt();
    expect(
      () => journal.beginSubmission(
        intentId: id,
        committedSource: source,
        capturedAuth: _auth(account: 'B' * 43),
        stillCurrent: () => true,
        now: _time(3),
      ),
      throwsA(_failure('auth_changed')),
    );
    expect(row(id).state, 0);
  });
}

api.MessageInst _wire() => api.MessageInst(
  id: _mutation,
  sender: 'mailto:me@example.invalid',
  conversation: api.ConversationData(
    participants: ['mailto:me@example.invalid', 'mailto:peer@example.invalid'],
    senderGuid: 'iMessage;-;peer@example.invalid',
  ),
  message: const api.Message.edit(
    api.EditMessage(
      tuuid: _target,
      editPart: 0,
      newParts: api.MessageParts(
        field0: [
          api.IndexedMessagePart(
            part_: api.MessagePart.text(
              'replacement',
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
  sentTimestamp: 0,
  sendDelivered: true,
  verificationFailed: false,
);
CloudSyncLocalMutationSourceBinding _source(
  CloudSyncLocalMutationIdentity identity,
) => CloudSyncLocalMutationSourceBinding(
  accountFingerprint: 'A' * 43,
  protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
  mutationGuidHash: identity.guidHash,
  targetGuidHash: identity.targetGuidHash,
  targetPart: identity.targetPart,
  sourceSha256: identity.sourceSha256,
  protectedReference: 'obcs2.ref.${'B' * 43}',
  leaseReference: 'obcs2.lease.${'b' * 32}',
  payloadSha256: 'a' * 64,
  payloadLength: 512,
);
api.CloudSyncNativeSendReceipt _receipt(
  CloudSyncLocalMutationIdentity identity,
  CloudSyncLocalMutationSourceBinding source, {
  api.CloudSyncNativeSendSourceKind? kind =
      api.CloudSyncNativeSendSourceKind.mutation,
  String session = 'native-session',
  String receiptMarker = 'A',
}) => api.CloudSyncNativeSendReceipt(
  receiptId: 'obcs2.ids.${receiptMarker * 43}',
  guidHash: identity.guidHash,
  nativeSessionId: session,
  sourceBinding: api.CloudSyncNativeSendSourceBinding(
    kind: kind,
    sourceSha256: source.sourceSha256,
    protectedReference: source.protectedReference,
    leaseReference: source.leaseReference,
    payloadSha256: source.payloadSha256,
    payloadLength: BigInt.from(source.payloadLength),
  ),
);
CloudSyncNativeAuthSnapshot _auth({
  String account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  String session = 'native-session',
}) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: session,
  accountFingerprint: account,
  protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
  cloudMessagesClient: Object(),
);

class _NoProtector implements CloudSyncProtector {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation');
}

final class _MutationExclusion implements CloudKitOperationExclusion {
  bool held = false;
  bool busy = false;
  @override
  Future<T> runExclusive<T>({
    required CloudKitOperationKind kind,
    required CloudKitOperationBody<T> action,
  }) async {
    expect(kind, CloudKitOperationKind.v2ReadWrite);
    if (busy || held) throw StateError('cloudkit_operation_busy');
    held = true;
    try {
      return await action();
    } finally {
      held = false;
    }
  }

  @override
  void poisonUntilProcessRestart() => throw StateError('unexpected poison');
}

final class _MutationTransport implements CloudProtectedPageLeaseTransport {
  bool held = false;
  bool failCommit = false;
  int acknowledgements = 0;
  String storeIdentity = 'obcs2.store.${'A' * 43}';
  final commits = <String>[];
  final rollbacks = <String>[];
  @override
  String get protectedPageLeaseRecoveryIdentity => storeIdentity;
  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) async {
    held = true;
    try {
      return await action();
    } finally {
      held = false;
    }
  }

  @override
  Future<void> commitProtectedPageLease(String lease, Set<String> refs) async {
    expect(held, isTrue);
    expect(refs, {'obcs2.ref.${'B' * 43}'});
    commits.add(lease);
    if (failCommit) throw StateError('synthetic_commit_failure');
  }

  @override
  Future<void> rollbackProtectedPageLease(String lease) async {
    expect(held, isTrue);
    rollbacks.add(lease);
  }

  @override
  Future<void> acknowledgeCommittedPageLease(String lease) async {
    acknowledgements++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected native call');
}

Matcher _failure(String code) => isA<StateError>().having(
  (e) => e.message,
  'safe code',
  'cloud_sync_local_mutation_$code',
);
DateTime _time(int seconds) => DateTime.utc(2026, 9, 11, 17, 0, seconds);
final _scope = CloudKitWriterScope(accountFingerprint: 'A' * 43);
const _mutation = '11111111-1111-4111-8111-111111111111';
const _target = '22222222-2222-4222-8222-222222222222';
