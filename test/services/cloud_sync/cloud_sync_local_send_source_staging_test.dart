import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:flutter_test/flutter_test.dart';

const _descriptor = '<attachment><id>A</id></attachment>';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
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
    journal = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authority.read(_scope)!,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-source-staging-',
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

  _StagingHarness harness(
    CloudSyncLocalSendIdentity identity, {
    CloudSyncNativeAuthSnapshot? auth,
    bool current = true,
    CloudProtectedPageLeaseTransport? stagingTransport,
  }) {
    final resolvedAuth = auth ?? _auth(Object());
    CloudSyncNativeAuthSnapshot? live = resolvedAuth;
    final fence = CloudSyncLocalSendAuthFence(
      expected: resolvedAuth,
      capture: () async => live,
      stillCurrent: () => current,
    );
    final exclusion = _FakeExclusion();
    final transport = _FakeTransport()
      ..recoveryIdentity = resolvedAuth.protectedStoreIdentity;
    final staging = CloudSyncLocalSendSourceStaging(
      journal: journal,
      authFence: fence,
      capturedAuth: resolvedAuth,
      stillCurrent: () => current,
      transport: stagingTransport ?? transport,
    );
    return _StagingHarness(
      staging: staging,
      exclusion: exclusion,
      transport: transport,
      flipAuth: (next) => live = next,
    );
  }

  int saveAttachmentSubmission(
    Message message,
    CloudSyncLocalSendIdentity identity,
  ) {
    var id = 0;
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => id = store.box<Message>().put(message),
      now: _time(2),
    );
    return id;
  }

  CloudSyncLocalSendSourceBinding? adoptedSource(
    CloudSyncLocalSendIdentity identity,
  ) => journal.readSubmissionProtectedSource(
    identity: identity,
    currentAuth: _auth(Object()),
  );

  test('stage adopt commit run ordered under the local lease only', () async {
    final message = _attachmentMessage(chat);
    final identity = _attachmentIdentity(message, chat);
    saveAttachmentSubmission(message, identity);
    final h = harness(identity);
    final order = <String>[];
    h.exclusion.log = order;
    h.transport.log = order;
    var stages = 0;
    var validations = 0;
    final expectedRef = _protectedSource(identity).protectedReference;
    h.transport.onCommit = (lease, retained) async {
      expect(h.exclusion.held, isFalse);
      expect(h.transport.localHeld, isTrue);
      expect(lease, _leaseReference);
      expect(retained, {expectedRef});
      expect(
        adoptedSource(identity)!.encode(),
        _protectedSource(identity).encode(),
      );
    };
    final result = await h.staging.prepare(
      identity: identity,
      stage: () async {
        stages++;
        order.add('stage');
        expect(h.exclusion.held, isFalse);
        expect(h.transport.localHeld, isTrue);
        return _protectedSource(identity);
      },
      validateWire: () async {
        validations++;
        order.add('validate');
        return true;
      },
    );
    expect(result.encode(), _protectedSource(identity).encode());
    expect(stages, 1);
    expect(validations, 3);
    expect(h.exclusion.kinds, isEmpty);
    expect(h.transport.networkRuns, 0);
    expect(order, [
      'local',
      'validate',
      'stage',
      'validate',
      'commit',
      'validate',
    ]);
    expect(adoptedSource(identity)!.encode(), result.encode());
    expect(h.exclusion.held, isFalse);
    expect(h.transport.localHeld, isFalse);
  });

  test('attachment preparation finishes while network gates stay held', () async {
    final message = _attachmentMessage(chat);
    final identity = _attachmentIdentity(message, chat);
    saveAttachmentSubmission(message, identity);
    final h = harness(identity);
    final entered = Completer<void>();
    final releaseNetwork = Completer<void>();
    final network = h.exclusion.runExclusive(
      kind: CloudKitOperationKind.v2ReadWrite,
      action: () => h.transport.runProtectedStoreExclusive(() async {
        entered.complete();
        await releaseNetwork.future;
      }),
    );
    await entered.future;
    try {
      h.transport.onCommit = (_, _) async {
        expect(h.exclusion.held && h.transport.networkHeld, isTrue);
        expect(h.transport.localHeld, isTrue);
        expect(
          adoptedSource(identity)!.encode(),
          _protectedSource(identity).encode(),
        );
      };
      final result = await h.staging.prepare(
        identity: identity,
        stage: () async {
          expect(h.exclusion.held && h.transport.networkHeld, isTrue);
          expect(h.transport.localHeld, isTrue);
          return _protectedSource(identity);
        },
        validateWire: () async {
          expect(h.transport.localHeld, isTrue);
          return true;
        },
      );
      expect(result.encode(), _protectedSource(identity).encode());
      expect(h.exclusion.held && h.transport.networkHeld, isTrue);
      expect(h.exclusion.kinds, [CloudKitOperationKind.v2ReadWrite]);
      expect(h.transport.networkRuns, 1);
      expect(h.transport.localHeld, isFalse);
      expect(h.transport.events, ['run', 'commit:$_leaseReference']);
      expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    } finally {
      releaseNetwork.complete();
      await network;
    }
  });

  test('attachment preparation rejects missing local capability', () async {
    final message = _attachmentMessage(chat);
    final identity = _attachmentIdentity(message, chat);
    final messageId = saveAttachmentSubmission(message, identity);
    final unsupported = _NetworkOnlyTransport();
    final h = harness(identity, stagingTransport: unsupported);
    var stages = 0;
    var validations = 0;
    await expectLater(
      h.staging.prepare(
        identity: identity,
        stage: () async {
          stages++;
          return _protectedSource(identity);
        },
        validateWire: () async {
          validations++;
          return true;
        },
      ),
      throwsA(
        _stateFailure('cloud_sync_local_send_local_exclusion_unavailable'),
      ),
    );
    expect(stages, 0);
    expect(validations, 0);
    expect(unsupported.networkRuns, 0);
    expect(h.exclusion.kinds, isEmpty);
    expect(adoptedSource(identity), isNull);
    expect(store.box<Message>().get(messageId)!.stagingGuid, _guidA);
    expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
  });

  test(
    'retry after commit failure and reopen reuses original with zero restages',
    () async {
      final message = _attachmentMessage(chat);
      final identity = _attachmentIdentity(message, chat);
      saveAttachmentSubmission(message, identity);
      final first = harness(identity);
      first.transport.failNextCommit = true;
      var stages = 0;
      await expectLater(
        first.staging.prepare(
          identity: identity,
          stage: () async {
            stages++;
            return _protectedSource(identity);
          },
          validateWire: () async => true,
        ),
        throwsA(_stateFailure('synthetic-commit-failure')),
      );
      expect(stages, 1);
      expect(first.transport.events, isNot(contains('rollback:$_leaseReference')));
      expect(
        adoptedSource(identity)!.encode(),
        _protectedSource(identity).encode(),
      );
      await reopen();
      final second = harness(identity);
      final result = await second.staging.prepare(
        identity: identity,
        stage: () async {
          stages++;
          throw StateError('must-not-restage');
        },
        validateWire: () async => true,
      );
      expect(stages, 1);
      expect(result.encode(), _protectedSource(identity).encode());
      expect(
        second.transport.events.where((event) => event.startsWith('commit:')),
        hasLength(1),
      );
      expect(adoptedSource(identity)!.encode(), result.encode());
    },
  );

  test('pre-adoption validation failure rolls back with no adoption', () async {
    final message = _attachmentMessage(chat);
    final identity = _attachmentIdentity(message, chat);
    saveAttachmentSubmission(message, identity);
    final h = harness(identity);
    var stages = 0;
    var validations = 0;
    await expectLater(
      h.staging.prepare(
        identity: identity,
        stage: () async {
          stages++;
          return _protectedSource(identity);
        },
        validateWire: () async => ++validations < 2,
      ),
      throwsA(_stateFailure('cloud_sync_local_send_source_changed')),
    );
    expect(stages, 1);
    expect(h.transport.events, contains('rollback:$_leaseReference'));
    expect(adoptedSource(identity), isNull);
  });

  test('auth change after stage rolls back with no adoption', () async {
    final message = _attachmentMessage(chat);
    final identity = _attachmentIdentity(message, chat);
    saveAttachmentSubmission(message, identity);
    final h = harness(identity);
    await expectLater(
      h.staging.prepare(
        identity: identity,
        stage: () async {
          h.flipAuth(_auth(Object(), account: _otherAccount));
          return _protectedSource(identity);
        },
        validateWire: () async => true,
      ),
      throwsA(_stateFailure('cloud_sync_local_send_identity_changed')),
    );
    expect(h.transport.events, contains('rollback:$_leaseReference'));
    expect(adoptedSource(identity), isNull);
  });

  for (final fault in ['missing-auth', 'not-current']) {
    test('local attachment preparation rejects $fault before staging', () async {
      final message = _attachmentMessage(chat);
      final identity = _attachmentIdentity(message, chat);
      saveAttachmentSubmission(message, identity);
      final h = harness(identity, current: fault != 'not-current');
      if (fault == 'missing-auth') h.flipAuth(null);
      var stages = 0;
      await expectLater(
        h.staging.prepare(
          identity: identity,
          stage: () async {
            stages++;
            return _protectedSource(identity);
          },
          validateWire: () async => true,
        ),
        throwsA(_stateFailure('cloud_sync_local_send_identity_changed')),
      );
      expect(stages, 0);
      expect(h.transport.events, ['run']);
      expect(h.transport.localHeld, isFalse);
      expect(adoptedSource(identity), isNull);
      expect(store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state, 0);
    });
  }

  for (final point in ['stage', 'commit']) {
    test(
      'local attachment owner change during $point preserves source ownership',
      () async {
        final message = _attachmentMessage(chat);
        final identity = _attachmentIdentity(message, chat);
        saveAttachmentSubmission(message, identity);
        final h = harness(identity);
        void changeOwnerEpoch() => authority.markMutationUnknown(
          authority.issuePermit(_scope, expectedOwner: CloudKitWriterOwner.v2),
          now: _time(3),
        );
        if (point == 'commit') {
          h.transport.onCommit = (_, _) async => changeOwnerEpoch();
        }
        await expectLater(
          h.staging.prepare(
            identity: identity,
            stage: () async {
              if (point == 'stage') changeOwnerEpoch();
              return _protectedSource(identity);
            },
            validateWire: () async => true,
          ),
          throwsA(_stateFailure('cloud_sync_local_send_owner_changed')),
        );
        final intent = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
        expect(intent.state, 0);
        expect(intent.idsConfirmationVersion, 0);
        expect(
          intent.protectedSourceBinding,
          point == 'stage' ? isNull : _protectedSource(identity).encode(),
        );
        expect(
          h.transport.events.contains('rollback:$_leaseReference'),
          point == 'stage',
        );
        expect(
          h.transport.events.contains('commit:$_leaseReference'),
          point == 'commit',
        );
        expect(h.transport.localHeld, isFalse);
        expect(h.transport.networkRuns, 0);
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );
  }

  test('post-commit wire mutation retains the owned binding', () async {
    final message = _attachmentMessage(chat);
    final identity = _attachmentIdentity(message, chat);
    saveAttachmentSubmission(message, identity);
    final h = harness(identity);
    var validations = 0;
    await expectLater(
      h.staging.prepare(
        identity: identity,
        stage: () async => _protectedSource(identity),
        validateWire: () async => ++validations < 3,
      ),
      throwsA(_stateFailure('cloud_sync_local_send_source_changed')),
    );
    expect(h.transport.events, isNot(contains('rollback:$_leaseReference')));
    expect(
      adoptedSource(identity)!.encode(),
      _protectedSource(identity).encode(),
    );
  });

  test(
    'busy local lease stages nothing and retains the pending message',
    () async {
      final message = _attachmentMessage(chat);
      final identity = _attachmentIdentity(message, chat);
      final messageId = saveAttachmentSubmission(message, identity);
      final h = harness(identity);
      h.transport.localBusy = true;
      var stages = 0;
      var validations = 0;
      await expectLater(
        h.staging.prepare(
          identity: identity,
          stage: () async {
            stages++;
            return _protectedSource(identity);
          },
          validateWire: () async {
            validations++;
            return true;
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(stages, 0);
      expect(validations, 0);
      expect(h.transport.events, isEmpty);
      expect(h.exclusion.kinds, isEmpty);
      expect(h.transport.networkRuns, 0);
      final retained = store.box<Message>().get(messageId)!;
      expect(retained.stagingGuid, _guidA);
      expect(adoptedSource(identity), isNull);
    },
  );

  test('missing origin never stages', () async {
    final message = _attachmentMessage(chat);
    final identity = CloudSyncLocalSendIdentity.captureAttachment(
      message,
      chat,
      _guidB,
    )!;
    final h = harness(identity);
    var stages = 0;
    await expectLater(
      h.staging.prepare(
        identity: identity,
        stage: () async {
          stages++;
          return _protectedSource(identity);
        },
        validateWire: () async => true,
      ),
      throwsA(_stateFailure('cloud_sync_local_send_origin_missing')),
    );
    expect(stages, 0);
  });

  test('wrong binding is rejected and rolled back', () async {
    final message = _attachmentMessage(chat);
    final identity = _attachmentIdentity(message, chat);
    saveAttachmentSubmission(message, identity);
    final h = harness(identity);
    final wrong = CloudSyncLocalSendSourceBinding(
      accountFingerprint: _scope.accountFingerprint,
      protectedStoreIdentity: _auth(Object()).protectedStoreIdentity,
      messageGuidHash: identity.guidHash,
      sourceSha256: 'c' * 64,
      protectedReference: 'obcs2.ref.${'C' * 43}',
      leaseReference: _leaseReference,
      payloadSha256: 'b' * 64,
      payloadLength: 512,
    );
    await expectLater(
      h.staging.prepare(
        identity: identity,
        stage: () async => wrong,
        validateWire: () async => true,
      ),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_changed')),
    );
    expect(h.transport.events, contains('rollback:$_leaseReference'));
    expect(adoptedSource(identity), isNull);
  });

  test('mismatched protected store is rejected before stage', () {
    final message = _attachmentMessage(chat);
    final identity = _attachmentIdentity(message, chat);
    saveAttachmentSubmission(message, identity);
    final h = harness(identity);
    h.transport.recoveryIdentity = 'obcs2.store.${'B' * 43}';
    var stages = 0;
    var validations = 0;
    expect(
      () => h.staging.prepare(
        identity: identity,
        stage: () async {
          stages++;
          return _protectedSource(identity);
        },
        validateWire: () async {
          validations++;
          return true;
        },
      ),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_changed')),
    );
    expect(stages, 0);
    expect(validations, 0);
    expect(h.exclusion.kinds, isEmpty);
    expect(h.transport.events, isEmpty);
    expect(adoptedSource(identity), isNull);
  });

  test('non-attachment identity is rejected before any gate', () async {
    final message = _textMessage(chat);
    final identity = CloudSyncLocalSendIdentity.capture(message, chat, _guidA)!;
    expect(identity.isAttachment, isFalse);
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(2),
    );
    final h = harness(identity);
    var stages = 0;
    expect(
      () => h.staging.prepare(
        identity: identity,
        stage: () async {
          stages++;
          return _protectedSource(identity);
        },
        validateWire: () async => true,
      ),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_invalid')),
    );
    expect(stages, 0);
    expect(h.exclusion.kinds, isEmpty);
    expect(h.transport.events, isEmpty);
  });
}

final class _StagingHarness {
  const _StagingHarness({
    required this.staging,
    required this.exclusion,
    required this.transport,
    required this.flipAuth,
  });

  final CloudSyncLocalSendSourceStaging staging;
  final _FakeExclusion exclusion;
  final _FakeTransport transport;
  final void Function(CloudSyncNativeAuthSnapshot? next) flipAuth;
}

final class _FakeExclusion implements CloudKitOperationExclusion {
  List<String>? log;
  bool busy = false;
  bool held = false;
  final List<CloudKitOperationKind> kinds = [];

  @override
  Future<T> runExclusive<T>({
    required CloudKitOperationKind kind,
    required CloudKitOperationBody<T> action,
  }) async {
    kinds.add(kind);
    log?.add('exclusion');
    if (busy || held) throw StateError('cloudkit_operation_busy');
    held = true;
    try {
      return await action();
    } finally {
      held = false;
    }
  }

  @override
  void poisonUntilProcessRestart() {}
}

final class _FakeTransport
    implements
        CloudProtectedPageLeaseTransport,
        CloudProtectedLocalLifecycleTransport {
  List<String>? log;
  bool failNextCommit = false;
  bool localHeld = false;
  bool localBusy = false;
  bool networkHeld = false;
  int networkRuns = 0;
  Future<void> Function(String leaseReference, Set<String> retained)? onCommit;
  final List<String> events = [];

  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) async {
    networkRuns++;
    expect(localHeld, isFalse);
    if (networkHeld) throw StateError('unexpected_network_lifecycle_entry');
    networkHeld = true;
    try {
      return await action();
    } finally {
      networkHeld = false;
    }
  }

  @override
  Future<T> runLocalProtectedStoreExclusive<T>(Future<T> Function() action) async {
    if (localBusy || localHeld) throw StateError('synthetic_local_lease_busy');
    events.add('run');
    log?.add('local');
    localHeld = true;
    try {
      return await action();
    } finally {
      localHeld = false;
    }
  }

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> retainedReferences,
  ) async {
    expect(localHeld, isTrue);
    events.add('commit:$leaseReference');
    log?.add('commit');
    await onCommit?.call(leaseReference, retainedReferences);
    if (failNextCommit) {
      failNextCommit = false;
      throw StateError('synthetic-commit-failure');
    }
  }

  @override
  Future<void> rollbackProtectedPageLease(String leaseReference) async {
    expect(localHeld, isTrue);
    events.add('rollback:$leaseReference');
    log?.add('rollback');
  }

  String recoveryIdentity = _protectedStore;

  @override
  String get protectedPageLeaseRecoveryIdentity => recoveryIdentity;

  @override
  Future<CloudProtectedPageLeaseRecoveryResult> recoverProtectedPageLeases(
    Set<String> adoptedLeaseReferences,
    CloudProtectedReferenceSnapshot liveReferences,
  ) => throw UnimplementedError();

  @override
  Future<void> acknowledgeCommittedPageLease(String leaseReference) =>
      throw StateError('unexpected lease acknowledgement');

  @override
  Future<int> retireProtectedReferences(Set<String> references) =>
      throw StateError('unexpected reference retirement');

  @override
  Future<CloudProtectedGarbageCollectionResult> collectProtectedGarbage(
    CloudProtectedReferenceSnapshot liveReferences,
  ) => throw UnimplementedError();
}

final class _NetworkOnlyTransport implements CloudProtectedPageLeaseTransport {
  int networkRuns = 0;

  @override
  String get protectedPageLeaseRecoveryIdentity => _protectedStore;

  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) {
    networkRuns++;
    throw StateError('unexpected_network_lifecycle_entry');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected native operation');
}

CloudSyncLocalSendIdentity _attachmentIdentity(Message message, Chat chat) =>
    CloudSyncLocalSendIdentity.captureAttachment(message, chat, _guidA)!;

Message _attachmentMessage(Chat chat) {
  final message = Message(
    guid: 'local-attachment-row',
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
            attributes: Attributes(attachmentGuid: 'LOCAL-ATTACHMENT'),
          ),
        ],
      ),
    ],
    stagingGuid: _guidA,
  );
  // The transient `attachments` list does not survive the ObjectBox
  // round-trip that `saveSubmission` revalidates against; the relation does.
  message.dbAttachments.add(
    Attachment(
      guid: 'LOCAL-ATTACHMENT',
      metadata: {'rustpush': _descriptor, 'myIris': null},
    ),
  );
  message.chat.target = chat;
  return message;
}

Message _textMessage(Chat chat) {
  final message = Message(
    guid: 'local-text-row',
    text: 'ordinary text',
    dateCreated: _time(1),
    isFromMe: true,
    attributedBody: [AttributedBody.raw('ordinary text')],
    stagingGuid: _guidA,
  );
  message.chat.target = chat;
  return message;
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

CloudSyncLocalSendSourceBinding _protectedSource(
  CloudSyncLocalSendIdentity identity,
) => CloudSyncLocalSendSourceBinding(
  accountFingerprint: _scope.accountFingerprint,
  protectedStoreIdentity: _protectedStore,
  messageGuidHash: identity.guidHash,
  sourceSha256: identity.sourceSha256,
  protectedReference: 'obcs2.ref.${'A' * 43}',
  leaseReference: _leaseReference,
  payloadSha256: 'b' * 64,
  payloadLength: 512,
);

CloudSyncNativeAuthSnapshot _auth(
  Object client, {
  String account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
}) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: 'native-session',
  accountFingerprint: account,
  protectedStoreIdentity: _protectedStore,
  cloudMessagesClient: client,
);

Matcher _stateFailure(String message) =>
    isA<StateError>().having((error) => error.message, 'message', message);

DateTime _time(int seconds) => DateTime.utc(2026, 9, 4, 12, 0, seconds);

final _scope = CloudKitWriterScope(
  accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);
final _protectedStore = 'obcs2.store.${'A' * 43}';
const _otherAccount = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _guidA = '11111111-1111-4111-8111-111111111111';

const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);
const _guidB = '22222222-2222-4222-8222-222222222222';
final _leaseReference = 'obcs2.lease.${'a' * 32}';
