import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_create_queue_drain.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncScope scope(
  String zone, {
  String? account,
  String container = 'com.apple.messages.cloud',
  String database = 'private',
  CloudSyncStreamKind stream = CloudSyncStreamKind.messages,
  int schema = 2,
  CloudSyncPersistenceLane lane = CloudSyncPersistenceLane.semantic,
}) => CloudSyncScope(
  accountFingerprint: account ?? 'a' * 43,
  container: container,
  database: database,
  zone: zone,
  streamKind: stream,
  schemaVersion: schema,
  persistenceLane: lane,
);
final chat = scope('chatManateeZone');
final message = scope('messageManateeZone');
CloudOutboxOperation op(
  CloudSyncScope scope,
  CloudOutboxStatus status, {
  bool lease = false,
}) => CloudOutboxOperation(
  scope: scope,
  operationId: 'synthetic-${scope.zone}',
  logicalEntityKeyHash: 'synthetic',
  action: CloudOutboxAction.save,
  payloadVersion: scope == chat ? 1 : 2,
  mutationRevision: 0,
  checkpointGeneration: 1,
  dependencyOperationIds: const [],
  createdAt: DateTime.utc(2026),
  encryptedPayloadReference: 'synthetic',
  payloadSha256: 'synthetic',
  status: status,
  protectedLeaseReference: lease ? 'obcs2.lease.${'a' * 32}' : null,
);

class Fixture {
  final events = <String>[];
  final queues = <CloudSyncScope, List<CloudOutboxOperation>>{
    chat: [],
    message: [],
  };
  List<CloudSyncScope> scopes = [chat, message];
  bool current = true;
  bool ackFails = false;
  bool flushSettles = true;
  String? driftAfter;
  bool wrongScopeOnReread = false;
  int reads = 0;
  void event(String value) {
    events.add(value);
    if (driftAfter == value) current = false;
  }

  Future<bool> run() => drainCloudSyncCreateQueues(
    scopes: scopes,
    validateAccount: () async {
      events.add('auth');
      if (!current) throw StateError('synthetic account drift');
    },
    recoverExpired: (s) async => event('recover:${s.zone}'),
    readOutbox: (s) async {
      event('read:${s.zone}');
      reads++;
      if (wrongScopeOnReread && reads == 3) {
        return [op(message, CloudOutboxStatus.confirmed)];
      }
      return queues[s]!;
    },
    reconcileUnknown: (o) async => event('reconcile:${o.scope.zone}'),
    flush: (s) async {
      event('flush:${s.zone}');
      if (flushSettles) {
        queues[s] = [op(s, CloudOutboxStatus.confirmed, lease: true)];
      }
    },
    acknowledgeConfirmed: (s, o) async {
      expect(o.scope, s);
      event('ack:${s.zone}');
      if (ackFails) throw StateError('synthetic ack failure');
    },
  );
  List<String> get work => events.where((e) => e != 'auth').toList();
}

void main() {
  for (final unknownScope in [message, chat]) {
    test('unknown ${unknownScope.zone} prevents either queue flush', () async {
      final f = Fixture();
      f.queues[chat] = [op(chat, CloudOutboxStatus.pending)];
      f.queues[message] = [op(message, CloudOutboxStatus.pending)];
      f.queues[unknownScope] = [
        op(unknownScope, CloudOutboxStatus.unknownOutcome),
      ];
      expect(await f.run(), isFalse);
      expect(f.work, [
        'recover:${chat.zone}',
        'recover:${message.zone}',
        'read:${chat.zone}',
        'read:${message.zone}',
        'reconcile:${unknownScope.zone}',
      ]);
    });
  }
  test('multiple unknown outcomes never reconcile or flush', () async {
    final f = Fixture();
    for (final s in f.scopes) {
      f.queues[s] = [op(s, CloudOutboxStatus.unknownOutcome)];
    }
    expect(await f.run(), isFalse);
    expect(f.work.length, 4);
  });
  test('pending Chat drains and acknowledges before Message flush', () async {
    final f = Fixture();
    for (final s in f.scopes) {
      f.queues[s] = [op(s, CloudOutboxStatus.pending)];
    }
    expect(await f.run(), isTrue);
    expect(f.work, [
      'recover:${chat.zone}',
      'recover:${message.zone}',
      'read:${chat.zone}',
      'read:${message.zone}',
      'flush:${chat.zone}',
      'read:${chat.zone}',
      'ack:${chat.zone}',
      'flush:${message.zone}',
      'read:${message.zone}',
      'ack:${message.zone}',
    ]);
    // Every successful callback await is followed by account validation.
    for (var i = 0; i < f.events.length; i++) {
      if (f.events[i] != 'auth') expect(f.events[i + 1], 'auth');
    }
  });
  test('ack failure stops before next queue flush', () async {
    final f = Fixture()..ackFails = true;
    f.queues[chat] = [op(chat, CloudOutboxStatus.confirmed, lease: true)];
    f.queues[message] = [op(message, CloudOutboxStatus.pending)];
    await expectLater(f.run(), throwsStateError);
    expect(f.work.last, 'ack:${chat.zone}');
    expect(f.work, isNot(contains('flush:${message.zone}')));
  });
  for (final phase in [
    'recover:${chat.zone}',
    'read:${message.zone}',
    'flush:${chat.zone}',
    'ack:${chat.zone}',
    'reconcile:${message.zone}',
  ]) {
    test('account drift after $phase stops next work', () async {
      final f = Fixture()..driftAfter = phase;
      f.queues[chat] = [op(chat, CloudOutboxStatus.pending)];
      f.queues[message] = [
        op(
          message,
          phase.startsWith('reconcile')
              ? CloudOutboxStatus.unknownOutcome
              : CloudOutboxStatus.pending,
        ),
      ];
      await expectLater(f.run(), throwsStateError);
      expect(f.work.last, phase);
    });
  }
  test('initial auth failure performs no queue work', () async {
    final f = Fixture()..current = false;
    await expectLater(f.run(), throwsStateError);
    expect(f.work, isEmpty);
  });
  test('wrong operation scope in initial read stops before flush', () async {
    final f = Fixture();
    f.queues[message] = [op(chat, CloudOutboxStatus.pending)];
    await expectLater(f.run(), throwsStateError);
    expect(f.work.length, 4);
  });
  test(
    'wrong operation scope in reread stops before ack or next flush',
    () async {
      final f = Fixture()..wrongScopeOnReread = true;
      f.queues[chat] = [op(chat, CloudOutboxStatus.pending)];
      await expectLater(f.run(), throwsStateError);
      expect(f.work.last, 'read:${chat.zone}');
      expect(f.work.any((e) => e.startsWith('ack:')), isFalse);
    },
  );
  for (final status in [
    CloudOutboxStatus.pending,
    CloudOutboxStatus.quarantined,
  ]) {
    test('remaining $status is not settled', () async {
      final f = Fixture()..flushSettles = false;
      f.queues[chat] = [op(chat, status)];
      f.queues[message] = [op(message, CloudOutboxStatus.pending)];
      expect(await f.run(), isFalse);
      expect(
        f.work.contains('flush:${chat.zone}'),
        status == CloudOutboxStatus.pending,
      );
      expect(f.work.contains('flush:${message.zone}'), isFalse);
    });
  }
  test(
    'empty and already acknowledged queues are settled without flush',
    () async {
      final f = Fixture();
      f.queues[message] = [op(message, CloudOutboxStatus.confirmed)];
      expect(await f.run(), isTrue);
      expect(
        f.work.any((e) => e.startsWith('flush:') || e.startsWith('ack:')),
        isFalse,
      );
    },
  );
  final invalid = <List<CloudSyncScope>>[
    [],
    [chat, chat],
    [message, chat],
    [chat, message, message],
    [chat, scope(message.zone, account: 'b' * 43)],
    [scope(chat.zone, container: 'other')],
    [scope(chat.zone, database: 'public')],
    [scope('unknown')],
    [scope(chat.zone, stream: CloudSyncStreamKind.profiles)],
    [scope(chat.zone, schema: 1)],
    [scope(chat.zone, lane: CloudSyncPersistenceLane.shadow)],
  ];
  for (var i = 0; i < invalid.length; i++) {
    test('invalid scopes $i rejected before all callbacks', () async {
      final f = Fixture()..scopes = invalid[i];
      await expectLater(f.run(), throwsArgumentError);
      expect(f.events, isEmpty);
    });
  }
}
