import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/imessage_initial_submission.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_encoder.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitWriterAuthoritySnapshot authoritySnapshot;
  late CloudSyncLocalSendJournal journal;
  late Chat chat;

  void provisionJournal() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final existing = authority.read(_scope);
    if (existing == null) {
      final disabled = authority.initializeDisabled(_scope, now: _time(0));
      authority.provisionInitialOwner(
        _scope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: _completeEvidence,
        now: _time(1),
      );
    }
    authoritySnapshot = authority.read(_scope)!;
    journal = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authoritySnapshot,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-local-send-journal-',
    );
    store = await openStore(directory: directory.path);
    provisionJournal();
    chat = _chat();
    _persistChat(store, chat);
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
    provisionJournal();
  }

  Message awaitingNativeConfirmation({bool reflected = true}) {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    journal.saveSubmission(
      identity: identity, newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message), now: _time(2),
    );
    message.sendingServiceId = 'synthetic-native-send';
    if (reflected) {
      message..guid = _guidA..stagingGuid = null;
    }
    store.box<Message>().put(message);
    return message;
  }

  int? confirmNative({String guid = _guidA, bool succeeded = true,
      bool current = true, CloudSyncNativeAuthSnapshot? auth}) =>
      journal.recordNativeSendConfirmation(
        stableGuid: guid, succeeded: succeeded,
        capturedAuth: auth ?? _auth(Object()), stillCurrent: () => current,
        now: _time(4),
      );

  test('protected source ownership survives restart and IDS receipt consumption', () async {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    final auth = _auth(Object());
    journal.saveSubmission(identity: identity, newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message), now: _time(2));
    final source = _protectedSource(identity);
    void adopt([CloudSyncLocalSendSourceBinding? value]) => journal.adoptProtectedSource(
      identity: identity, source: value ?? source, capturedAuth: auth,
      stillCurrent: () => true, now: _time(3));
    adopt();
    final intent = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
    expect(intent.state, 0);
    expect(intent.idsConfirmationVersion, 0);
    await reopen();
    expect(journal.readProtectedSource(intentId: intent.id,
      currentAuth: _auth(Object()))!.encode(), source.encode());
    adopt(); // Exact idempotent adoption, never allocate a replacement source.
    expect(() => adopt(_protectedSource(identity, marker: 'B')),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_changed')));
    confirmNative();
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(intent.id)!.state, 3);
    await reopen();
    expect(journal.readProtectedSource(intentId: intent.id,
      currentAuth: _auth(Object()))!.encode(), source.encode());
    expect(() => journal.readProtectedSource(intentId: intent.id,
      currentAuth: _auth(Object(), store: 'obcs2.store.${'B' * 43}')),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_changed')));
  });

  test('source cannot be backfilled after IDS success or without pending origin', () {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    void adopt() => journal.adoptProtectedSource(identity: identity,
      source: _protectedSource(identity), capturedAuth: _auth(Object()),
      stillCurrent: () => true, now: _time(5));
    expect(adopt, throwsA(_stateFailure('cloud_sync_local_send_origin_missing')));
    journal.saveSubmission(identity: identity, newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message), now: _time(2));
    confirmNative();
    expect(adopt, throwsA(_stateFailure('cloud_sync_local_send_protected_source_too_late')));
    expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.protectedSourceBinding, isNull);
  });

  test('source adoption rejects changed message and account before persistence', () {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    journal.saveSubmission(identity: identity, newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message), now: _time(2));
    expect(() => journal.adoptProtectedSource(identity: identity,
      source: _protectedSource(identity), capturedAuth: _auth(Object(), account: _otherAccount),
      stillCurrent: () => true, now: _time(3)),
      throwsA(_stateFailure('cloud_sync_local_send_auth_changed')));
    expect(() => journal.adoptProtectedSource(identity: identity,
      source: _protectedSource(identity), capturedAuth: _auth(Object()),
      stillCurrent: () => false, now: _time(3)),
      throwsA(_stateFailure('cloud_sync_local_send_identity_changed')));
    message.text = 'different';
    store.box<Message>().put(message);
    expect(() => journal.adoptProtectedSource(identity: identity,
      source: _protectedSource(identity), capturedAuth: _auth(Object()),
      stillCurrent: () => true, now: _time(3)),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_too_late')));
    expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.protectedSourceBinding, isNull);
  });

  test('background send return is not confirmation; native success records proof', () {
    final message = awaitingNativeConfirmation();
    expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
    expect(journal.readReady(), isEmpty);
    final id = confirmNative()!;
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(id)!.state, 3);
    expect(store.box<Message>().get(message.id!)!.sendingServiceId, isNull);
    expect(journal.readReady(), isEmpty, reason: 'Fresh auth is still required');
    journal.promoteIdsConfirmedDeferred(
      intentId: id, currentAuth: _auth(Object()), now: _time(5),
    );
    expect(journal.readReady(), hasLength(1));
  });

  test(
    'old deferred proof stays retained and cannot promote after restart',
    () async {
      awaitingNativeConfirmation();
      final id = confirmNative()!;
      final old = store.box<CloudSyncLocalSendIntentEntity>().get(id)!
        ..idsConfirmationVersion = 0;
      final binding = old.admittedBindingSha256;
      store.box<CloudSyncLocalSendIntentEntity>().put(old);
      await reopen();
      expect(
        journal.readIdsConfirmedDeferred(currentAuth: _auth(Object())),
        isEmpty,
      );
      expect(
        () => journal.promoteIdsConfirmedDeferred(
          intentId: id,
          currentAuth: _auth(Object()),
          now: _time(5),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'code',
            'cloud_sync_local_send_ids_proof_required',
          ),
        ),
      );
      final retained = store.box<CloudSyncLocalSendIntentEntity>().get(id)!;
      expect(retained.state, 3);
      expect(retained.idsConfirmationVersion, 0);
      expect(retained.admittedBindingSha256, binding);
      expect(confirmNative(succeeded: false), isNull);
      expect(
        store
            .box<CloudSyncLocalSendIntentEntity>()
            .get(id)!
            .idsConfirmationVersion,
        0,
      );
      // Only a new positive native confirmation requalifies the original row.
      expect(confirmNative(), id);
      expect(
        journal.readIdsConfirmedDeferred(currentAuth: _auth(Object())),
        hasLength(1),
      );
    },
  );

  test(
    'old ready row requires new proof before receipt acknowledgment or admission',
    () async {
      awaitingNativeConfirmation();
      final id = confirmNative()!;
      journal.promoteIdsConfirmedDeferred(
        intentId: id,
        currentAuth: _auth(Object()),
        now: _time(5),
      );
      final old = store.box<CloudSyncLocalSendIntentEntity>().get(id)!
        ..idsConfirmationVersion = 0;
      store.box<CloudSyncLocalSendIntentEntity>().put(old);
      await reopen();
      expect(journal.readReady(), isEmpty);
      expect(
        () => journal.readForAdmission(id),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'code',
            'cloud_sync_local_send_ids_proof_required',
          ),
        ),
      );
      final resolution = journal.resolveNativeSendReceipt(old.messageGuidHash)!;
      expect(resolution.alreadyDurable, isFalse);
      expect(resolution.stableGuid, _guidA);
      expect(() => confirmNative(current: false), throwsStateError);
      expect(journal.readReady(), isEmpty);
      expect(confirmNative(), isNull);
      expect(
        journal.resolveNativeSendReceipt(old.messageGuidHash)!.alreadyDurable,
        isTrue,
      );
      expect(journal.readReady().single.id, id);
      expect(journal.readReady().single.idsConfirmationVersion, 2);
    },
  );

  test(
    'legacy ready rows do not consume the bounded qualified-send window',
    () {
      awaitingNativeConfirmation();
      final id = confirmNative()!;
      journal.promoteIdsConfirmedDeferred(
        intentId: id,
        currentAuth: _auth(Object()),
        now: _time(5),
      );
      final ready = store.box<CloudSyncLocalSendIntentEntity>().get(id)!;
      for (var i = 0; i < 60; i++) {
        store.box<CloudSyncLocalSendIntentEntity>().put(
          CloudSyncLocalSendIntentEntity(
            intentKey: 'synthetic-pre-proof-$i',
            accountFingerprint: ready.accountFingerprint,
            writerEpoch: ready.writerEpoch,
            localMessageId: ready.localMessageId,
            messageGuidHash: 'synthetic-$i',
            sourceSha256: ready.sourceSha256,
            state: 1,
            createdAtMs: 1,
            updatedAtMs: 1,
          ),
        );
      }
      expect(journal.readReady(limit: 1).single.id, id);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 61);
    },
  );

  test('startup failure sweep retains only unresolved native confirmation', () {
    final message = awaitingNativeConfirmation();
    expect(
      CloudSyncLocalSendJournal.hasUnresolvedNativeConfirmation(store, message),
      isTrue,
    );
    expect(
      CloudSyncLocalSendJournal.claimUntrackedCrashedSend(
        store, message.id!, 'replacement-service',
      ),
      isNull,
    );
    final id = confirmNative()!;
    expect(
      CloudSyncLocalSendJournal.hasUnresolvedNativeConfirmation(store, message),
      isTrue,
      reason: 'deferred IDS success must survive restart until promotion',
    );
    expect(
      CloudSyncLocalSendJournal.claimUntrackedCrashedSend(
        store, message.id!, 'replacement-service',
      ),
      isNull,
    );
    journal.promoteIdsConfirmedDeferred(
      intentId: id, currentAuth: _auth(Object()), now: _time(5),
    );
    expect(
      CloudSyncLocalSendJournal.hasUnresolvedNativeConfirmation(store, message),
      isFalse,
    );

    final legacy = _message(chat: chat, stagingGuid: _guidB)
      ..sendingServiceId = 'crashed-service';
    store.box<Message>().put(legacy);
    final claimed = CloudSyncLocalSendJournal.claimUntrackedCrashedSend(
      store, legacy.id!, 'replacement-service',
    );
    expect(claimed?.id, legacy.id);
    expect(store.box<Message>().get(legacy.id!)!.sendingServiceId, isNull);
  });

  test('native confirmation can beat foreground GUID normalization', () {
    final message = awaitingNativeConfirmation(reflected: false);
    final id = confirmNative()!;
    final saved = store.box<Message>().get(message.id!)!;
    expect(saved.guid, _guidA);
    expect(saved.stagingGuid, isNull);
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(id)!.state, 3);
  });

  test('native failure does not authorize, mutate or clear the pending send', () {
    final message = awaitingNativeConfirmation();
    expect(confirmNative(succeeded: false), isNull);
    expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
    expect(store.box<Message>().get(message.id!)!.sendingServiceId, isNotNull);
  });

  test('unmatched native GUID never invents an origin', () {
    awaitingNativeConfirmation();
    expect(confirmNative(guid: _guidB), isNull);
    expect(confirmNative(guid: 'not-a-guid'), isNull);
    expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
  });

  test('native receipt replays after restart with a rotated native session', () async {
    awaitingNativeConfirmation();
    final guidHash =
        store.box<CloudSyncLocalSendIntentEntity>().getAll().single.messageGuidHash;
    await reopen();
    final resolved = journal.resolveNativeSendReceipt(guidHash)!;
    final restartedAuth = _auth(Object(), session: 'restarted-native-session');
    final id = confirmNative(guid: resolved.stableGuid!, auth: restartedAuth)!;
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(id)!.state, 3);
    expect(confirmNative(auth: restartedAuth), id);
    journal.promoteIdsConfirmedDeferred(
      intentId: id, currentAuth: restartedAuth, now: _time(5),
    );
    expect(confirmNative(auth: restartedAuth), isNull);
    expect(journal.readReady(), hasLength(1));
  });

  test('native receipt replay binding fails closed across every scope transition', () {
    var currentState = Object();
    var currentStore = Object();
    var currentClient = Object();
    var currentPath = 'first-path';
    var runtimeCurrent = true;
    final auth = _auth(currentClient);
    CloudSyncNativeReceiptReplayBinding binding() =>
        CloudSyncNativeReceiptReplayBinding(
          expectedAuth: auth,
          expectedState: currentState,
          expectedStore: currentStore,
          expectedClient: currentClient,
          expectedStoragePath: currentPath,
          readState: () => currentState,
          readStore: () => currentStore,
          readClient: () => currentClient,
          readStoragePath: () => currentPath,
          runtimeCurrent: () => runtimeCurrent,
        );

    final stateBound = binding();
    expect(stateBound.isCurrent, isTrue);
    stateBound.requireCapturedAuth(auth);
    currentState = Object();
    expect(stateBound.requireCurrent, throwsStateError);

    final storeBound = binding();
    currentStore = Object();
    expect(storeBound.requireCurrent, throwsStateError);

    final clientBound = binding();
    currentClient = Object();
    expect(clientBound.requireCurrent, throwsStateError);

    final pathBound = binding();
    currentPath = 'replacement-path';
    expect(pathBound.requireCurrent, throwsStateError);

    final runtimeBound = binding();
    runtimeCurrent = false;
    expect(runtimeBound.requireCurrent, throwsStateError);

    runtimeCurrent = true;
    final authBound = binding();
    expect(
      () => authBound.requireCapturedAuth(
        _auth(currentClient, session: 'replacement-native-session'),
      ),
      throwsStateError,
    );
  });

  test('native receipt resolves only the exact pending journal GUID hash', () {
    awaitingNativeConfirmation();
    final intent = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
    final resolved = journal.resolveNativeSendReceipt(intent.messageGuidHash)!;
    expect(resolved.alreadyDurable, isFalse);
    expect(resolved.stableGuid, _guidA);
    expect(journal.resolveNativeSendReceipt('f' * 64), isNull);
  });

  test('duplicate native receipt becomes acknowledgeable after durable state', () {
    awaitingNativeConfirmation();
    final intent = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
    final id = confirmNative()!;
    final deferred = journal.resolveNativeSendReceipt(intent.messageGuidHash)!;
    expect(deferred.alreadyDurable, isFalse);
    expect(deferred.stableGuid, _guidA);
    expect(confirmNative(), id, reason: 'state 3 replay is idempotent');
    journal.promoteIdsConfirmedDeferred(
      intentId: id, currentAuth: _auth(Object()), now: _time(5),
    );
    final promoted = journal.resolveNativeSendReceipt(intent.messageGuidHash)!;
    expect(promoted.alreadyDurable, isTrue);
    expect(promoted.stableGuid, isNull);
  });

  test('source-changed receipt remains uncommitted for later disposition', () {
    final message = awaitingNativeConfirmation();
    final intent = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
    final resolved = journal.resolveNativeSendReceipt(intent.messageGuidHash)!;
    message.text = 'changed after submission';
    store.box<Message>().put(message);
    expect(() => confirmNative(guid: resolved.stableGuid!), throwsStateError);
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(intent.id)!.state, 0);
  });

  test('edited source rejects native confirmation and rolls back normalization', () {
    final message = awaitingNativeConfirmation();
    message.text = 'changed after submission';
    store.box<Message>().put(message);
    expect(() => confirmNative(), throwsStateError);
    expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
    expect(store.box<Message>().get(message.id!)!.sendingServiceId, isNotNull);
  });

  test('deleted source cannot be revived by native confirmation', () {
    final message = awaitingNativeConfirmation();
    message.dateDeleted = _time(3);
    store.box<Message>().put(message);
    expect(() => confirmNative(), throwsStateError);
    expect(store.box<Message>().get(message.id!)!.dateDeleted?.toUtc(), _time(3));
    expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
  });

  test('identity change cannot commit native success or update message flags', () {
    final message = awaitingNativeConfirmation();
    expect(() => confirmNative(current: false), throwsStateError);
    expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
    expect(store.box<Message>().get(message.id!)!.sendingServiceId, isNotNull);
  });

  CloudSyncLocalSendIntentEntity saveDeferredIdsSuccess({
    CloudSyncNativeAuthSnapshot? capturedAuth,
    String stableGuid = _guidA,
  }) {
    final message = _message(chat: chat, stagingGuid: stableGuid);
    final identity = _identity(message, chat, stableGuid);
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(2),
    );
    message
      ..guid = stableGuid
      ..stagingGuid = null;
    final intentId = journal.saveIdsConfirmedDeferredSubmission(
      identity: identity,
      capturedAuth: capturedAuth ?? _auth(Object()),
      stillCurrent: () => true,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(3),
    );
    return store.box<CloudSyncLocalSendIntentEntity>().get(intentId)!;
  }

  test('exact selection reads deferred IDS success without promoting any row', () {
    final selected = saveDeferredIdsSuccess();
    final foreign = saveDeferredIdsSuccess(stableGuid: _guidB);
    final source = journal.readExactIntent(
      intentId: selected.id,
      expectedRecipient: chat.handles.single.address,
      expectedSourceSha256: selected.sourceSha256,
    );
    expect(source.intentId, selected.id);
    expect(source.state, 3);
    expect(source.message!.guid, _guidA);
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(selected.id)!.state, 3);
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(foreign.id)!.state, 3);
    journal.promoteIdsConfirmedDeferred(
      intentId: source.intentId, currentAuth: _auth(Object()), now: _time(4),
    );
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(selected.id)!.state, 1);
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(foreign.id)!.state, 3);
  });

  test('exact selection rejects missing intent and wrong caller identity', () {
    final selected = saveDeferredIdsSuccess();
    for (final request in [
      (selected.id + 100, chat.handles.single.address, selected.sourceSha256),
      (selected.id, 'other@example.invalid', selected.sourceSha256),
      (selected.id, '', selected.sourceSha256),
      (selected.id, chat.handles.single.address, 'a' * 64),
    ]) {
      expect(() => journal.readExactIntent(
        intentId: request.$1, expectedRecipient: request.$2,
        expectedSourceSha256: request.$3,
      ), throwsStateError);
    }
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(selected.id)!.state, 3);
  });

  test('exact selection cannot infer IDS confirmation from an ordinary Message', () {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    journal.saveSubmission(
      identity: identity, newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message), now: _time(2),
    );
    final selected = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
    expect(() => journal.readExactIntent(
      intentId: selected.id, expectedRecipient: chat.handles.single.address,
      expectedSourceSha256: selected.sourceSha256,
    ), throwsStateError);
    expect(selected.state, 0);
  });

  test(
    'callback failure rolls back the local message and intent atomically',
    () {
      final message = _message(chat: chat, stagingGuid: _guidA);
      final identity = _identity(message, chat, _guidA);

      expect(
        () => journal.saveSubmission(
          identity: identity,
          newlyGeneratedGuid: true,
          persistMessage: () {
            store.box<Message>().put(message);
            throw StateError('injected local persistence failure');
          },
          now: _time(2),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'injected local persistence failure',
          ),
        ),
      );

      expect(store.box<Message>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    },
  );

  test('saved source mismatch rolls back the local message and intent', () {
    final submitted = _message(
      chat: chat,
      text: 'submitted',
      stagingGuid: _guidA,
    );
    final identity = _identity(submitted, chat, _guidA);
    final changed = _message(
      chat: chat,
      guid: 'changed-local-row',
      text: 'changed after capture',
      stagingGuid: _guidA,
    );

    expect(
      () => journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(changed),
        now: _time(2),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_source_changed')),
    );

    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
  });

  test(
    'fresh send stays pending until the post-IDS-success callback marks it ready',
    () {
      final message = _message(chat: chat, stagingGuid: _guidA);
      final identity = _identity(message, chat, _guidA);

      journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(2),
      );

      var intent = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
      expect(intent.state, 0);
      expect(journal.readReady(), isEmpty);

      // This models the caller invoking the callback after sendMsg succeeds.
      // It is deliberately not evidence of a real IDS or network operation.
      message
        ..guid = _guidA
        ..stagingGuid = null;
      journal.saveConfirmedSubmission(
        identity: identity,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(3),
      );

      intent = journal.readReady().single;
      expect(intent.state, 1);
      expect(intent.localMessageId, message.id);
      expect(intent.writerEpoch, authoritySnapshot.epoch);
      expect(intent.accountFingerprint, _scope.accountFingerprint);
      expect(store.box<Message>().get(intent.localMessageId)?.guid, _guidA);
    },
  );

  test(
    'restart keeps interrupted pending non-ready and confirmed intent ready',
    () async {
      final pending = _message(
        chat: chat,
        guid: 'pending-local-row',
        stagingGuid: _guidA,
      );
      final pendingIdentity = _identity(pending, chat, _guidA);
      journal.saveSubmission(
        identity: pendingIdentity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(pending),
        now: _time(2),
      );

      final confirmed = _message(
        chat: chat,
        guid: 'confirmed-local-row',
        text: 'confirmed text',
        stagingGuid: _guidB,
      );
      final confirmedIdentity = _identity(confirmed, chat, _guidB);
      journal.saveSubmission(
        identity: confirmedIdentity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(confirmed),
        now: _time(3),
      );
      confirmed
        ..guid = _guidB
        ..stagingGuid = null;
      journal.saveConfirmedSubmission(
        identity: confirmedIdentity,
        persistMessage: () => store.box<Message>().put(confirmed),
        now: _time(4),
      );

      await reopen();

      final intents = store.box<CloudSyncLocalSendIntentEntity>().getAll();
      expect(intents, hasLength(2));
      expect(intents.where((intent) => intent.state == 0), hasLength(1));
      final ready = journal.readReady();
      expect(ready, hasLength(1));
      expect(ready.single.state, 1);
      expect(
        store.box<Message>().get(ready.single.localMessageId)?.guid,
        _guidB,
      );
    },
  );

  test(
    'completed IDS with unavailable post-auth capture stays deferred across restart',
    () async {
      final intent = saveDeferredIdsSuccess();
      expect(intent.state, 3);
      expect(intent.admittedOperationId, isNull);
      expect(intent.admittedBindingSha256, matches(r'^[0-9a-f]{64}$'));
      expect(intent.admittedChatBinding, isNull);
      expect(journal.readReady(), isEmpty);
      expect(
        () => journal.readForAdmission(intent.id),
        throwsA(_stateFailure('cloud_sync_local_send_not_ready')),
      );
      final pending = _message(
        chat: chat,
        guid: 'pending-local-row',
        text: 'pending text',
        stagingGuid: _guidB,
      );
      journal.saveSubmission(
        identity: _identity(pending, chat, _guidB),
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(pending),
        now: _time(4),
      );
      expect(
        journal
            .readIdsConfirmedDeferred(currentAuth: _auth(Object()))
            .map((row) => row.id),
        [intent.id],
      );

      await reopen();

      final durable = store.box<CloudSyncLocalSendIntentEntity>().get(
        intent.id,
      )!;
      expect(durable.state, 3);
      expect(durable.admittedBindingSha256, intent.admittedBindingSha256);
      expect(journal.readReady(), isEmpty);
      expect(
        journal
            .readIdsConfirmedDeferred(currentAuth: _auth(Object()))
            .map((row) => row.id),
        [intent.id],
      );
      expect(
        () => journal.readForAdmission(intent.id),
        throwsA(_stateFailure('cloud_sync_local_send_not_ready')),
      );
    },
  );

  test('generic confirmation cannot promote auth-deferred state', () {
    final intent = saveDeferredIdsSuccess();
    final message = store.box<Message>().get(intent.localMessageId)!;
    final identity = _identity(message, message.chat.target!, _guidA);

    journal.saveConfirmedSubmission(
      identity: identity,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(4),
    );

    final retained = store.box<CloudSyncLocalSendIntentEntity>().get(
      intent.id,
    )!;
    expect(retained.state, 3);
    expect(retained.admittedBindingSha256, intent.admittedBindingSha256);
    expect(journal.readReady(), isEmpty);
  });

  test(
    'unmatched durable identity cannot starve matching deferred evidence',
    () {
      final auth = _auth(Object());
      final retained = saveDeferredIdsSuccess(
        capturedAuth: _auth(Object(), store: 'obcs2.store.$_otherAccount'),
      );
      final eligible = saveDeferredIdsSuccess(
        capturedAuth: auth,
        stableGuid: _guidB,
      );

      expect(
        journal
            .readIdsConfirmedDeferred(currentAuth: auth, limit: 1)
            .map((row) => row.id),
        [eligible.id],
      );
      expect(
        store.box<CloudSyncLocalSendIntentEntity>().get(retained.id)!.state,
        3,
      );
    },
  );

  test('matching full auth identity promotes deferred IDS success once', () {
    final client = Object();
    final auth = _auth(client);
    final intent = saveDeferredIdsSuccess(capturedAuth: auth);

    journal.promoteIdsConfirmedDeferred(
      intentId: intent.id,
      currentAuth: auth,
      now: _time(4),
    );

    final ready = journal.readReady().single;
    expect(ready.id, intent.id);
    expect(ready.state, 1);
    expect(ready.admittedBindingSha256, isNull);
    expect(
      () => journal.promoteIdsConfirmedDeferred(
        intentId: intent.id,
        currentAuth: auth,
        now: _time(5),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_not_deferred')),
    );
  });

  test(
    'restarted client can recover confirmed IDS evidence for the same durable identity',
    () async {
      final intent = saveDeferredIdsSuccess(capturedAuth: _auth(Object()));
      await reopen();

      journal.promoteIdsConfirmedDeferred(
        intentId: intent.id,
        currentAuth: _auth(Object(), session: 'restarted-native-client'),
        now: _time(4),
      );

      expect(journal.readReady().single.id, intent.id);
    },
  );

  for (final change in <String, CloudSyncNativeAuthSnapshot Function(Object)>{
    'account': (client) => _auth(client, account: _otherAccount),
    'protected store': (client) =>
        _auth(client, store: 'obcs2.store.$_otherAccount'),
  }.entries) {
    test('changed ${change.key} cannot promote deferred IDS success', () {
      final client = Object();
      final intent = saveDeferredIdsSuccess(capturedAuth: _auth(client));

      expect(
        () => journal.promoteIdsConfirmedDeferred(
          intentId: intent.id,
          currentAuth: change.value(client),
          now: _time(4),
        ),
        throwsA(_stateFailure('cloud_sync_local_send_auth_changed')),
      );
      expect(
        store.box<CloudSyncLocalSendIntentEntity>().get(intent.id)!.state,
        3,
      );
      expect(journal.readReady(), isEmpty);
    });
  }

  test('changed writer owner cannot promote deferred IDS success', () {
    final auth = _auth(Object());
    final intent = saveDeferredIdsSuccess(capturedAuth: auth);
    final authorityBox = store.box<CloudKitWriterAuthorityEntity>();
    final durable = authorityBox.getAll().single..owner = 1;
    authorityBox.put(durable);

    expect(
      () => journal.promoteIdsConfirmedDeferred(
        intentId: intent.id,
        currentAuth: auth,
        now: _time(4),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_owner_changed')),
    );
    expect(
      store.box<CloudSyncLocalSendIntentEntity>().get(intent.id)!.state,
      3,
    );
  });

  test('changed writer epoch cannot promote deferred IDS success', () {
    final auth = _auth(Object());
    final intent = saveDeferredIdsSuccess(capturedAuth: auth);
    final authorityBox = store.box<CloudKitWriterAuthorityEntity>();
    final durable = authorityBox.getAll().single..epoch += 1;
    authorityBox.put(durable);

    expect(
      () => journal.promoteIdsConfirmedDeferred(
        intentId: intent.id,
        currentAuth: auth,
        now: _time(4),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_owner_changed')),
    );
    expect(
      store.box<CloudSyncLocalSendIntentEntity>().get(intent.id)!.state,
      3,
    );
  });

  test(
    'readReady rotates a considered ready row by updated time then id',
    () async {
      CloudSyncLocalSendIntentEntity saveReady(
        String stableGuid,
        String text,
        DateTime submittedAt,
      ) {
        final message = _message(
          chat: chat,
          guid: 'local-$text',
          text: text,
          stagingGuid: stableGuid,
        );
        final identity = _identity(message, chat, stableGuid);
        journal.saveSubmission(
          identity: identity,
          newlyGeneratedGuid: true,
          persistMessage: () => store.box<Message>().put(message),
          now: submittedAt,
        );
        message
          ..guid = stableGuid
          ..stagingGuid = null;
        journal.saveConfirmedSubmission(
          identity: identity,
          persistMessage: () => store.box<Message>().put(message),
          now: _time(4),
        );
        return journal.readReady().singleWhere(
          (intent) => intent.messageGuidHash == identity.guidHash,
        );
      }

      final first = saveReady(_guidA, 'first ready', _time(2));
      final second = saveReady(_guidB, 'second ready', _time(3));
      expect(journal.readReady().map((intent) => intent.id), [
        first.id,
        second.id,
      ]);
      final immutable = (
        intentKey: first.intentKey,
        accountFingerprint: first.accountFingerprint,
        writerEpoch: first.writerEpoch,
        localMessageId: first.localMessageId,
        messageGuidHash: first.messageGuidHash,
        sourceSha256: first.sourceSha256,
        state: first.state,
        admittedOperationId: first.admittedOperationId,
        admittedBindingSha256: first.admittedBindingSha256,
        admittedChatBinding: first.admittedChatBinding,
        createdAtMs: first.createdAtMs,
      );

      journal.markAdmissionConsidered(first.id, now: _time(5));
      expect(journal.readReady().map((intent) => intent.id), [
        second.id,
        first.id,
      ]);

      await reopen();

      expect(journal.readReady().map((intent) => intent.id), [
        second.id,
        first.id,
      ]);
      final rotated = store.box<CloudSyncLocalSendIntentEntity>().get(
        first.id,
      )!;
      expect((
        intentKey: rotated.intentKey,
        accountFingerprint: rotated.accountFingerprint,
        writerEpoch: rotated.writerEpoch,
        localMessageId: rotated.localMessageId,
        messageGuidHash: rotated.messageGuidHash,
        sourceSha256: rotated.sourceSha256,
        state: rotated.state,
        admittedOperationId: rotated.admittedOperationId,
        admittedBindingSha256: rotated.admittedBindingSha256,
        admittedChatBinding: rotated.admittedChatBinding,
        createdAtMs: rotated.createdAtMs,
      ), immutable);
      expect(rotated.updatedAtMs, _time(5).millisecondsSinceEpoch);
    },
  );

  test('stable GUID retries are idempotent before and after confirmation', () {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    int persist() => store.box<Message>().put(message);

    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: persist,
      now: _time(2),
    );
    final first = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;

    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: false,
      persistMessage: persist,
      now: _time(3),
    );
    message
      ..guid = _guidA
      ..stagingGuid = null;
    journal.saveConfirmedSubmission(
      identity: identity,
      persistMessage: persist,
      now: _time(4),
    );
    journal.saveConfirmedSubmission(
      identity: identity,
      persistMessage: persist,
      now: _time(5),
    );

    final only = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
    expect(only.id, first.id);
    expect(only.localMessageId, message.id);
    expect(only.state, 1);
    expect(only.createdAtMs, _time(2).millisecondsSinceEpoch);
    expect(only.updatedAtMs, _time(5).millisecondsSinceEpoch);
    expect(store.box<Message>().count(), 1);
    expect(journal.readReady(), hasLength(1));
  });

  test(
    'preexisting GUID without an intent cannot gain local origin on retry',
    () {
      final preexisting = _message(chat: chat, guid: _guidA);
      final identity = _identity(preexisting, chat, _guidA);
      final id = store.box<Message>().put(preexisting);
      var callbackInvoked = false;

      expect(
        () => journal.saveSubmission(
          identity: identity,
          newlyGeneratedGuid: false,
          persistMessage: () {
            callbackInvoked = true;
            return id;
          },
          now: _time(2),
        ),
        throwsA(_stateFailure('cloud_sync_local_send_origin_missing')),
      );

      expect(callbackInvoked, isFalse);
      expect(store.box<Message>().count(), 1);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      expect(journal.readReady(), isEmpty);
    },
  );

  test('account scope drift blocks before local persistence callback', () {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    final authorityBox = store.box<CloudKitWriterAuthorityEntity>();
    final durable = authorityBox.getAll().single
      ..accountFingerprint = _otherAccount;
    authorityBox.put(durable);
    var callbackInvoked = false;

    expect(
      () => journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () {
          callbackInvoked = true;
          return store.box<Message>().put(message);
        },
        now: _time(2),
      ),
      throwsA(_authorityFailure('cloudkit_writer_authority_scope_collision')),
    );

    expect(callbackInvoked, isFalse);
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
  });

  test('writer epoch drift blocks before local persistence callback', () {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    final authorityBox = store.box<CloudKitWriterAuthorityEntity>();
    final durable = authorityBox.getAll().single..epoch += 1;
    authorityBox.put(durable);
    var callbackInvoked = false;

    expect(
      () => journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () {
          callbackInvoked = true;
          return store.box<Message>().put(message);
        },
        now: _time(2),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_owner_changed')),
    );

    expect(callbackInvoked, isFalse);
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
  });

  test(
    'same-epoch mutationUnknown still records pending and confirmed local intent',
    () {
      final authorityBox = store.box<CloudKitWriterAuthorityEntity>();
      final durable = authorityBox.getAll().single..state = 4;
      authorityBox.put(durable);
      authoritySnapshot = authority.read(_scope)!;
      expect(
        authoritySnapshot.state,
        CloudKitWriterAuthorityState.mutationUnknown,
      );
      journal = CloudSyncLocalSendJournal(
        store: store,
        authority: authority,
        authoritySnapshot: authoritySnapshot,
      );
      final message = _message(chat: chat, stagingGuid: _guidA);
      final identity = _identity(message, chat, _guidA);

      journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(2),
      );
      expect(journal.readReady(), isEmpty);
      expect(
        store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state,
        0,
      );

      message
        ..guid = _guidA
        ..stagingGuid = null;
      journal.saveConfirmedSubmission(
        identity: identity,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(3),
      );

      final ready = journal.readReady().single;
      expect(ready.state, 1);
      expect(ready.writerEpoch, authoritySnapshot.epoch);
      expect(ready.localMessageId, message.id);
    },
  );

  test('actual wire text and route bind the same local source', () {
    final message = _message(chat: chat);
    final wire = _wire(chat, text: message.text!);
    final actual = CloudSyncLocalSendIdentity.captureWire(message, chat, wire)!;
    expect(actual.sourceSha256, _identity(message, chat, _guidA).sourceSha256);
  });

  for (final change in <String, void Function(api.MessageInst)>{
    'text frozen before local edit': (wire) {
      (wire.message as api.Message_Message).field0.parts = _parts('old text');
    },
    'sender': (wire) => wire.sender = 'mailto:someone-else@example.com',
    'recipient': (wire) =>
        wire.conversation!.participants[0] = 'mailto:other@example.com',
    'extra participant': (wire) =>
        wire.conversation!.participants.add('mailto:third@example.com'),
    'conversation': (wire) =>
        wire.conversation!.senderGuid = 'iMessage;-;other@example.com',
    'SMS service': (wire) => wire.message = api.Message.message(
      api.NormalMessage(
        parts: _parts('ordinary text'),
        voice: false,
        service: const api.MessageType.sms(
          isPhone: false,
          usingNumber: '+15555550123',
        ),
      ),
    ),
    'formatted text': (wire) {
      (wire.message as api.Message_Message).field0.parts =
          const api.MessageParts(
            field0: [
              api.IndexedMessagePart(
                part_: api.MessagePart.text(
                  'ordinary text',
                  api.TextFormat.flags(
                    api.TextFlags(
                      bold: true,
                      italic: false,
                      underline: false,
                      strikethrough: false,
                    ),
                  ),
                ),
              ),
            ],
          );
    },
    'reply': (wire) =>
        (wire.message as api.Message_Message).field0.replyGuid = _guidB,
    'verification failure': (wire) => wire.verificationFailed = true,
  }.entries) {
    test('wire identity rejects changed ${change.key}', () {
      final message = _message(chat: chat);
      final wire = _wire(chat, text: message.text!);
      change.value(wire);
      expect(
        CloudSyncLocalSendIdentity.captureWire(message, chat, wire),
        isNull,
      );
    });
  }

  test(
    'retry cannot mark a changed source as the original submitted payload',
    () {
      final message = _message(chat: chat, stagingGuid: _guidA);
      final original = CloudSyncLocalSendIdentity.captureWire(
        message,
        chat,
        _wire(chat),
      )!;
      journal.saveSubmission(
        identity: original,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(2),
      );
      message
        ..text = 'edited while sending'
        ..attributedBody = [AttributedBody.raw('edited while sending')];
      final rebuilt = CloudSyncLocalSendIdentity.captureWire(
        message,
        chat,
        _wire(chat, text: message.text!),
      )!;
      expect(rebuilt.sourceSha256, isNot(original.sourceSha256));
      message
        ..guid = _guidA
        ..stagingGuid = null;
      expect(
        () => journal.saveConfirmedSubmission(
          identity: rebuilt,
          persistMessage: () => store.box<Message>().put(message),
          now: _time(3),
        ),
        throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
      );
      expect(journal.readReady(), isEmpty);
      expect(store.box<Message>().get(message.id!)!.text, 'ordinary text');
    },
  );

  test(
    'new GUID alone cannot establish local origin for an existing message',
    () {
      bool isFresh(Message message, {String generated = _guidA}) =>
          CloudSyncLocalSendIdentity.isFreshLocalSubmission(
            message,
            generatedGuid: generated,
            stableGuid: _guidA,
          );
      final fresh = _message(chat: chat, guid: 'temp-Abc12345');
      expect(isFresh(fresh), isTrue);
      expect(isFresh(_message(chat: chat, guid: _guidB)), isFalse);
      expect(isFresh(fresh, generated: _guidB), isFalse);
      fresh.stagingGuid = _guidA;
      expect(isFresh(fresh), isFalse);
      fresh
        ..stagingGuid = null
        ..ckRecordId = 'restored';
      expect(isFresh(fresh), isFalse);
    },
  );

  test(
    'auth fence persists synchronously only after matching native proof',
    () async {
      final client = Object();
      final auth = _auth(client);
      var persisted = false;
      await CloudSyncLocalSendAuthFence(
        expected: auth,
        capture: () async => _auth(client),
        stillCurrent: () => true,
      ).run(() => persisted = true);
      expect(persisted, isTrue);
    },
  );

  for (final change in <String, CloudSyncNativeAuthSnapshot? Function(Object)>{
    'same-client account drift': (client) =>
        _auth(client, account: _otherAccount),
    'same-client native session drift': (client) =>
        _auth(client, session: 'new-native-session'),
    'same-client protected store drift': (client) =>
        _auth(client, store: 'obcs2.store.$_otherAccount'),
    'client replacement': (_) => _auth(Object()),
    'missing capture': (_) => null,
  }.entries) {
    test('auth fence rejects ${change.key} before local persistence', () async {
      final client = Object();
      var persisted = false;
      final fence = CloudSyncLocalSendAuthFence(
        expected: _auth(client),
        capture: () async => change.value(client),
        stillCurrent: () => true,
      );
      await expectLater(
        fence.run(() => persisted = true),
        throwsA(_stateFailure('cloud_sync_local_send_identity_changed')),
      );
      expect(persisted, isFalse);
    });
  }

  test('account teardown during native capture prevents persistence', () async {
    final client = Object();
    final captured = Completer<CloudSyncNativeAuthSnapshot?>();
    var active = true;
    var persisted = false;
    final fence = CloudSyncLocalSendAuthFence(
      expected: _auth(client),
      capture: () => captured.future,
      stillCurrent: () => active,
    );
    final result = fence.run(() => persisted = true);
    final assertion = expectLater(
      result,
      throwsA(_stateFailure('cloud_sync_local_send_identity_changed')),
    );
    active = false;
    captured.complete(_auth(client));
    await assertion;
    expect(persisted, isFalse);
  });

  test('native capture failure cannot promote an interrupted send', () async {
    final client = Object();
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(2),
    );
    message
      ..guid = _guidA
      ..stagingGuid = null;
    final fence = CloudSyncLocalSendAuthFence(
      expected: _auth(client),
      capture: () async => throw TimeoutException('injected'),
      stillCurrent: () => true,
    );
    await expectLater(
      fence.run(
        () => journal.saveConfirmedSubmission(
          identity: identity,
          persistMessage: () => store.box<Message>().put(message),
          now: _time(3),
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await reopen();
    expect(journal.readReady(), isEmpty);
    expect(
      store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state,
      0,
    );
  });

  for (final entry in <String, ({Message message, Chat chat}) Function()>{
    'restored CloudKit record': () {
      final shapeChat = _chat();
      return (
        message: _message(chat: shapeChat)..ckRecordId = 'restored-record',
        chat: shapeChat,
      );
    },
    'previously synced record': () {
      final shapeChat = _chat();
      return (
        message: _message(chat: shapeChat)..ckSyncState = true,
        chat: shapeChat,
      );
    },
    'SMS': () {
      final shapeChat = _chat(isRpSms: true);
      return (message: _message(chat: shapeChat), chat: shapeChat);
    },
    'two members incorrectly marked as a direct chat': () {
      final shapeChat = _chat(
        participants: [
          _handle('person@example.com'),
          _handle('second@example.com'),
        ],
      );
      return (message: _message(chat: shapeChat), chat: shapeChat);
    },
    'attachment': () {
      final shapeChat = _chat();
      return (
        message: _message(
          chat: shapeChat,
          attachments: [Attachment(guid: 'attachment-guid')],
        ),
        chat: shapeChat,
      );
    },
    'edit': () {
      final shapeChat = _chat();
      return (
        message: _message(chat: shapeChat, dateEdited: _time(2)),
        chat: shapeChat,
      );
    },
    'scheduled': () {
      final shapeChat = _chat();
      return (
        message: _message(chat: shapeChat, dateScheduled: _time(2)),
        chat: shapeChat,
      );
    },
    'reaction': () {
      final shapeChat = _chat();
      return (
        message: _message(
          chat: shapeChat,
          associatedMessageGuid: 'parent-message-guid',
        ),
        chat: shapeChat,
      );
    },
  }.entries) {
    test('identity capture rejects unsupported ${entry.key} shape', () {
      final shape = entry.value();
      expect(
        CloudSyncLocalSendIdentity.capture(shape.message, shape.chat, _guidA),
        isNull,
      );
    });
  }

  test(
    'production capture recovers v2 retry and validates original wire after adoption',
    () {
      const origin = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      chat.guid = origin;
      store.box<Chat>().put(chat);
      final message = _message(chat: chat, stagingGuid: _guidA);
      final originalWire = _wire(chat);
      final initial = CloudSyncLocalSendIdentity.capture(
        message,
        chat,
        originalWire.id,
      )!;
      final identity = journal.captureSubmissionWire(
        message: message,
        chat: chat,
        wire: originalWire,
        initialSourceSha256: initial.sourceSha256,
      )!;
      journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(2),
      );
      chat.guid = 'iMessage;-;person@example.com';
      chat.cloudGuid = origin;
      chat.usingHandle = 'mailto:me@example.com';
      store.box<Chat>().put(chat);
      final postAwait = CloudSyncLocalSendIdentity.captureWire(
        message,
        chat,
        originalWire,
        expectedSourceSha256: identity.sourceSha256,
      );
      expect(postAwait?.sourceSha256, identity.sourceSha256);
      final rebuilt = _wire(chat);
      final retryInitial = CloudSyncLocalSendIdentity.capture(
        message,
        chat,
        rebuilt.id,
      )!;
      expect(retryInitial.sourceSha256, isNot(identity.sourceSha256));
      final retry = journal.captureSubmissionWire(
        message: message,
        chat: chat,
        wire: rebuilt,
        initialSourceSha256: retryInitial.sourceSha256,
      )!;
      expect(retry.sourceSha256, identity.sourceSha256);
      journal.saveSubmission(
        identity: retry,
        newlyGeneratedGuid: false,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(3),
      );
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
      originalWire.sender = 'other@example.com';
      expect(
        CloudSyncLocalSendIdentity.captureWire(
          message,
          chat,
          originalWire,
          expectedSourceSha256: identity.sourceSha256,
        ),
        isNull,
      );
    },
  );

  test(
    'provisional first send survives same-row canonical adoption and restart',
    () async {
      const origin = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      chat.guid = origin;
      chat.style = null;
      chat.chatIdentifier = null;
      store.box<Chat>().put(chat);
      final message = _message(chat: chat, stagingGuid: _guidA);
      final identity = _identity(message, chat, _guidA);
      journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(2),
      );
      message.guid = _guidA;
      message.stagingGuid = null;
      journal.saveConfirmedSubmission(
        identity: identity,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(3),
      );
      final intent = journal.readReady().single;
      expect(
        journal.readForAdmission(intent.id).message!.chat.target!.guid,
        origin,
      );
      chat.guid = 'iMessage;-;person@example.com';
      chat.cloudGuid = origin;
      chat.style = 45;
      chat.chatIdentifier = 'person@example.com';
      chat.usingHandle = 'mailto:me@example.com';
      store.box<Chat>().put(chat);
      await reopen();
      final source = journal.readForAdmission(intent.id);
      expect(source.sourceSha256, identity.sourceSha256);
      expect(source.message!.chat.targetId, chat.id);
      expect(
        source.message!.chat.target!.guid,
        'iMessage;-;person@example.com',
      );
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
      // Journal identity is not a remote-write permission. Admission still
      // requires the separate authenticated canonical Chat ownership proof.
    },
  );

  for (final succeeded in [false, true]) {
    test('new-chat source persists before native result: $succeeded', () async {
      final wire = _wire(chat);
      chat
        ..guid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
        ..style = null
        ..chatIdentifier = null;
      store.box<Chat>().put(chat);
      wire.conversation!.senderGuid = chat.guid;
      final body = AttributedBody.raw('ordinary text');
      final pending = createPendingInitialIMessage(
        body, createdAt: _time(2), sender: _handle('me@example.com'),
      )..chat.target = chat;
      final fresh = CloudSyncLocalSendIdentity.isFreshLocalSubmission(
        pending, generatedGuid: wire.id, stableGuid: wire.id,
      );
      expect(fresh, isTrue);
      expect(pending.id, isNull);
      expect(pending.temp, isFalse);
      // Native newMsg has no sent timestamp yet. Do not encode epoch 1970.
      expect(wire.sentTimestamp, 0);
      expect(pending.dateCreated, _time(2));
      final initial = CloudSyncLocalSendIdentity.capture(pending, chat, wire.id)!;
      final identity = journal.captureSubmissionWire(
        message: pending, chat: chat, wire: wire,
        initialSourceSha256: initial.sourceSha256,
      )!;
      pending.stagingGuid = wire.id;
      journal.saveSubmission(
        identity: identity, newlyGeneratedGuid: fresh,
        persistMessage: () => store.box<Message>().put(pending), now: _time(2),
      );
      final rowId = pending.id!;
      expect(journal.readReady(), isEmpty);
      expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
      body.runs.single.range[1] = 1;
      expect(pending.attributedBody.single.runs.single.range[1], 13);
      await reopen();
      final id = journal.recordNativeSendConfirmation(
        stableGuid: wire.id, succeeded: succeeded,
        capturedAuth: _auth(Object()), stillCurrent: () => true, now: _time(4),
      );
      expect(store.box<Message>().count(), 1);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
      expect(journal.readReady(), isEmpty);
      if (succeeded) {
        expect(id, isNotNull);
        expect(store.box<CloudSyncLocalSendIntentEntity>().get(id!)!.state, 3);
        journal.promoteIdsConfirmedDeferred(
          intentId: id, currentAuth: _auth(Object()), now: _time(5),
        );
        final candidate = journal.readForAdmission(id);
        expect(candidate.localMessageId, rowId);
        expect(candidate.sourceSha256, identity.sourceSha256);
        expect(candidate.message!.guid, wire.id);
        expect(candidate.message!.chat.target!.guid, chat.guid);
        expect(journal.readReady(), hasLength(1));
      } else {
        expect(id, isNull);
        final saved = store.box<Message>().get(rowId)!;
        expect(saved.stagingGuid, wire.id);
        expect(saved.guid, startsWith('temp-'));
        expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
      }
    });
  }

  test('initial-message factory preserves formatting and malformed group guards', () {
    final body = AttributedBody(
      string: 'ordinary text',
      runs: [Run(range: [0, 13], attributes: Attributes(messagePart: 0, bold: true))],
    );
    final pending = createPendingInitialIMessage(
      body, createdAt: _time(2), sender: _handle('me@example.com'),
    );
    expect(pending.attributedBody.single.runs.single.attributes!.bold, isTrue);
    expect(CloudSyncLocalSendIdentity.capture(pending, chat, _guidA), isNull);
    pending.attributedBody = [AttributedBody.raw(pending.text!)];
    final group = _chat(participants: [
      _handle('person@example.com'), _handle('second@example.com'),
    ]);
    expect(CloudSyncLocalSendIdentity.capture(pending, group, _guidA), isNull);
    expect(CloudSyncLocalSendIdentity.capture(pending, _chat(isRpSms: true), _guidA), isNull);
  });

  for (final provisional in [false, true]) {
    test('group plaintext origin survives restart without authorizing an upload: $provisional', () async {
      const origin = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      final group = _chat(participants: [
        _handle('first@example.com'), _handle('second@example.com'),
      ])
        ..guid = provisional ? origin : 'iMessage;+;chat-group'
        ..chatIdentifier = provisional ? null : 'chat-group'
        ..style = provisional ? null : 43;
      _persistChat(store, group);
      final message = createPendingInitialIMessage(
        AttributedBody.raw('ordinary text'), createdAt: _time(2),
        sender: _handle('me@example.com'),
      )..chat.target = group;
      final wire = _wire(group);
      wire.conversation!.participants = [
        'mailto:second@example.com', 'mailto:first@example.com',
        'mailto:me@example.com',
      ];
      final initial = CloudSyncLocalSendIdentity.capture(message, group, wire.id)!;
      final identity = journal.captureSubmissionWire(
        message: message, chat: group, wire: wire,
        initialSourceSha256: initial.sourceSha256,
      )!;
      message.stagingGuid = wire.id;
      journal.saveSubmission(
        identity: identity, newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(message), now: _time(2),
      );
      expect(journal.readReady(), isEmpty);
      await reopen();
      final id = confirmNative()!;
      journal.promoteIdsConfirmedDeferred(
        intentId: id, currentAuth: _auth(Object()), now: _time(5),
      );
      if (provisional) {
        // Models only the same-row result of future authenticated group Chat
        // adoption. This fixture is not proof that group creation works.
        final adopted = store.box<Chat>().get(group.id!)!
          ..guid = 'iMessage;+;chat-group'
          ..chatIdentifier = 'chat-group'
          ..cloudGuid = origin
          ..style = 43;
        store.box<Chat>().put(adopted);
      }
      await reopen();
      final source = journal.readForAdmission(id);
      expect(source.sourceSha256, identity.sourceSha256);
      expect(source.message!.text, 'ordinary text');
      expect(source.message!.chat.targetId, group.id);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(() => encodeCloudSyncLocalSendPlainText(source.message!), throwsStateError);
      final changed = source.message!.chat.target!;
      changed.handles.add(_handle('other@example.com'));
      store.box<Chat>().put(changed);
      expect(() => journal.readForAdmission(id), throwsStateError);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
    });
  }

  test(
    'provisional identity rejects a different row, sender, text or original GUID',
    () {
      const origin = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      chat.guid = origin;
      final message = _message(chat: chat, stagingGuid: _guidA);
      final identity = _identity(message, chat, _guidA);
      chat.guid = 'iMessage;-;person@example.com';
      chat.cloudGuid = origin;
      CloudSyncLocalSendIdentity? verify() =>
          CloudSyncLocalSendIdentity.capture(
            message,
            chat,
            _guidA,
            expectedSourceSha256: identity.sourceSha256,
          );
      expect(verify(), isNotNull);
      final id = chat.id;
      chat.id = id! + 1;
      expect(verify(), isNull);
      chat.id = id;
      chat.usingHandle = 'other@example.com';
      expect(verify(), isNull);
      chat.usingHandle = 'me@example.com';
      chat.cloudGuid = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
      expect(verify(), isNull);
      chat.cloudGuid = origin;
      message.text = 'changed';
      message.attributedBody = [AttributedBody.raw('changed')];
      expect(verify(), isNull);
    },
  );

  test(
    'provisional wire capture works without mutating Chat routing fields',
    () {
      chat.guid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      final message = _message(chat: chat, stagingGuid: _guidA);
      final wire = _wire(chat);
      chat.style = null;
      chat.chatIdentifier = null;
      expect(
        CloudSyncLocalSendIdentity.captureWire(message, chat, wire),
        isNotNull,
      );
      expect(chat.style, isNull);
      expect(chat.chatIdentifier, isNull);
    },
  );

  test('v2 normalization rejects email and phone scheme mismatches', () {
    chat.guid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
    final message = _message(chat: chat, stagingGuid: _guidA);
    final wire = _wire(chat)..sender = 'tel:me@example.com';
    expect(CloudSyncLocalSendIdentity.captureWire(message, chat, wire), isNull);
    wire.sender = 'mailto:me@example.com';
    wire.conversation!.participants[0] = 'tel:person@example.com';
    expect(CloudSyncLocalSendIdentity.captureWire(message, chat, wire), isNull);
    chat.handles.single.address = '+15550000001';
    chat.chatIdentifier = '+15550000001';
    chat.usingHandle = 'tel:+15550000002';
    final phone = _wire(chat);
    phone.conversation!.participants[0] = 'tel:+15550000001';
    expect(
      CloudSyncLocalSendIdentity.captureWire(message, chat, phone),
      isNotNull,
    );
    phone.sender = 'mailto:+15550000002';
    expect(
      CloudSyncLocalSendIdentity.captureWire(message, chat, phone),
      isNull,
    );
    phone.sender = 'tel:+15550000002';
    phone.conversation!.participants[0] = 'mailto:+15550000001';
    expect(
      CloudSyncLocalSendIdentity.captureWire(message, chat, phone),
      isNull,
    );
  });

  test(
    'read and delivery receipts plus reaction flag preserve original text identity',
    () {
      final message = _message(chat: chat, stagingGuid: _guidA);
      final original = _identity(message, chat, _guidA);
      final id = store.box<Message>().put(message);

      final updated = store.box<Message>().get(id)!
        ..dateRead = _time(3)
        ..dateDelivered = _time(4)
        ..hasReactions = true;
      store.box<Message>().put(updated);
      final reloaded = store.box<Message>().get(id)!;
      final afterReceipts = _identity(reloaded, reloaded.chat.target!, _guidA);

      expect(afterReceipts.guidHash, original.guidHash);
      expect(afterReceipts.sourceSha256, original.sourceSha256);
      expect(reloaded.text, message.text);
      expect(reloaded.dateRead?.toUtc(), _time(3));
      expect(reloaded.dateDelivered?.toUtc(), _time(4));
      expect(reloaded.hasReactions, isTrue);
    },
  );
}

CloudSyncLocalSendIdentity _identity(
  Message message,
  Chat chat,
  String stableGuid,
) => CloudSyncLocalSendIdentity.capture(message, chat, stableGuid)!;

Message _message({
  required Chat chat,
  String guid = 'local-message-row',
  String text = 'ordinary text',
  String? stagingGuid,
  List<Attachment?> attachments = const [],
  DateTime? dateEdited,
  DateTime? dateScheduled,
  String? associatedMessageGuid,
}) {
  final message = Message(
    guid: guid,
    text: text,
    dateCreated: _time(1),
    isFromMe: true,
    hasAttachments: attachments.isNotEmpty,
    attachments: attachments,
    attributedBody: [AttributedBody.raw(text)],
    stagingGuid: stagingGuid,
    dateEdited: dateEdited,
    dateScheduled: dateScheduled,
    associatedMessageGuid: associatedMessageGuid,
  );
  message.chat.target = chat;
  return message;
}

Chat _chat({bool isRpSms = false, List<Handle>? participants}) {
  final actualParticipants = participants ?? [_handle('person@example.com')];
  final chat = Chat(
    guid: 'iMessage;-;person@example.com',
    chatIdentifier: 'person@example.com',
    usingHandle: 'me@example.com',
    isRpSms: isRpSms,
    style: 45,
    participants: actualParticipants,
  );
  chat.handles.addAll(actualParticipants);
  return chat;
}

Handle _handle(String address) => Handle(
  address: address,
  service: 'iMessage',
  uniqueAddressAndService: '$address/iMessage',
);

void _persistChat(Store store, Chat chat) {
  store.box<Handle>().putMany(chat.handles.toList());
  store.box<Chat>().put(chat);
}

api.MessageParts _parts(String text) => api.MessageParts(
  field0: [
    api.IndexedMessagePart(
      part_: api.MessagePart.text(
        text,
        const api.TextFormat.flags(
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
);

api.MessageInst _wire(Chat chat, {String text = 'ordinary text'}) =>
    api.MessageInst(
      id: _guidA,
      sender: chat.usingHandle,
      conversation: api.ConversationData(
        participants: ['mailto:${chat.chatIdentifier}', chat.usingHandle!],
        senderGuid: chat.guid,
      ),
      message: api.Message.message(
        api.NormalMessage(
          parts: _parts(text),
          service: const api.MessageType.iMessage(),
          voice: false,
        ),
      ),
      sentTimestamp: 0,
      sendDelivered: true,
      verificationFailed: false,
    );

CloudSyncLocalSendSourceBinding _protectedSource(
  CloudSyncLocalSendIdentity identity, {String marker = 'A'}
) => CloudSyncLocalSendSourceBinding(
  accountFingerprint: _scope.accountFingerprint,
  protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
  messageGuidHash: identity.guidHash, sourceSha256: identity.sourceSha256,
  protectedReference: 'obcs2.ref.${marker * 43}',
  leaseReference: 'obcs2.lease.${'a' * 32}',
  payloadSha256: 'b' * 64, payloadLength: 512,
);

CloudSyncNativeAuthSnapshot _auth(
  Object client, {
  String account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  String session = 'native-session',
  String store = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
}) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: session,
  accountFingerprint: account,
  protectedStoreIdentity: store,
  cloudMessagesClient: client,
);

Matcher _stateFailure(String message) =>
    isA<StateError>().having((error) => error.message, 'message', message);

Matcher _authorityFailure(String safeCode) =>
    isA<CloudKitWriterAuthorityFailure>().having(
      (failure) => failure.safeCode,
      'safeCode',
      safeCode,
    );

DateTime _time(int seconds) => DateTime.utc(2026, 9, 4, 12, 0, seconds);

const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);

final _scope = CloudKitWriterScope(
  accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);
const _otherAccount = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _guidA = '11111111-1111-4111-8111-111111111111';
const _guidB = '22222222-2222-4222-8222-222222222222';
