import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

const _fingerprintA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _fingerprintB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

final _clientA = Object();
final _clientB = Object();

void main() {
  test('ordinary builds keep the outbound canary disabled by default', () {
    expect(CloudSyncDevGate.manualOutboundCanaryEnabled, isFalse);
    expect(CloudKitWriterOwnership.v2MutationsEnabled, isFalse);
  });

  test(
    'explicit gate overrides fail closed and never touch dependencies',
    () async {
      final disabled = _CanaryFixture();
      final disabledCanary = disabled.build(compileGate: false);
      await _expectStateError(
        disabledCanary.armConfirmed(
          message: _FakeCloudMessage(),
          createdAt: testEpoch,
        ),
        'cloud_sync_outbound_canary_disabled',
      );
      expect(disabled.preflight.calls, 0);

      final writerDisabled = _CanaryFixture();
      final writerDisabledCanary = writerDisabled.build(writerGate: false);
      await _expectStateError(
        writerDisabledCanary.armConfirmed(
          message: _FakeCloudMessage(),
          createdAt: testEpoch,
        ),
        'cloud_sync_outbound_canary_writer_disabled',
      );
      expect(writerDisabled.preflight.calls, 0);
    },
  );

  test('one confirmation only arms memory and admits nothing', () async {
    final fixture = _CanaryFixture();
    final canary = fixture.build();

    final confirmation = await canary.armConfirmed(
      message: _FakeCloudMessage(),
      createdAt: testEpoch,
    );

    expect(
      confirmation.toString(),
      'CloudSyncOutboundCanaryConfirmation(redacted)',
    );
    expect(fixture.sessionFactoryCalls, 0);
    expect(fixture.session.admitCalls, 0);
    expect(fixture.preflight.outboxCounts, [0]);
  });

  test('double confirmation succeeds in the exact message scope', () async {
    final fixture = _CanaryFixture(
      preflightStates: [
        _readyState(),
        _readyState(),
        _readyState(outboxCount: 1),
      ],
      result: _result(const CloudSyncRunCounters(confirmed: 1)),
    );
    final canary = fixture.build();
    final confirmation = await canary.armConfirmed(
      message: fixture.message,
      createdAt: testEpoch,
    );

    final report = await canary.runDoubleConfirmed(confirmation);

    expect(report.status, CloudSyncRunStatus.completed);
    expect(report.confirmed, 1);
    expect(report.outboxStatus, CloudOutboxStatus.confirmed);
    expect(report.recovery, isFalse);
    expect(report.terminal, isTrue);
    expect(fixture.sessionFactoryCalls, 1);
    expect(fixture.session.admitCalls, 1);
    expect(fixture.session.flushCalls, 1);
    expect(fixture.session.receivedMessage, same(fixture.message));
    expect(fixture.scopes, [fixture.expectedScope]);
    expect(fixture.session.operation.scope, fixture.expectedScope);
    expect(fixture.session.operation.action, CloudOutboxAction.save);
    expect(fixture.session.operation.status, CloudOutboxStatus.pending);
    expect(fixture.preflight.outboxCounts, [0, 0, 1]);
    expect(fixture.session.quiesceCalls, 1);
    expect(canary.isActive, isFalse);
  });

  test('confirmation tokens are single-use', () async {
    final fixture = _CanaryFixture(
      preflightStates: [
        _readyState(),
        _readyState(),
        _readyState(outboxCount: 1),
      ],
    );
    final canary = fixture.build();
    final confirmation = await canary.armConfirmed(
      message: fixture.message,
      createdAt: testEpoch,
    );

    await canary.runDoubleConfirmed(confirmation);
    await _expectStateError(
      canary.runDoubleConfirmed(confirmation),
      'cloud_sync_outbound_canary_confirmation_invalid',
    );
    expect(fixture.session.admitCalls, 1);
    expect(fixture.session.flushCalls, 1);
    expect(fixture.session.quiesceCalls, 1);
  });

  test(
    'a confirmation from another canary is rejected without consuming the real token',
    () async {
      final first = _CanaryFixture();
      final second = _CanaryFixture();
      final firstCanary = first.build();
      final secondCanary = second.build();
      final firstConfirmation = await firstCanary.armConfirmed(
        message: first.message,
        createdAt: testEpoch,
      );
      final wrongConfirmation = await secondCanary.armConfirmed(
        message: second.message,
        createdAt: testEpoch,
      );

      await _expectStateError(
        firstCanary.runDoubleConfirmed(wrongConfirmation),
        'cloud_sync_outbound_canary_confirmation_invalid',
      );
      expect(first.sessionFactoryCalls, 0);
      expect(first.session.admitCalls, 0);

      await firstCanary.runDoubleConfirmed(firstConfirmation);
      expect(first.session.admitCalls, 1);
    },
  );

  test(
    'expired confirmation is consumed before any session is created',
    () async {
      final clock = MutableTestClock(testEpoch);
      final fixture = _CanaryFixture();
      final canary = fixture.build(clock: clock);
      final confirmation = await canary.armConfirmed(
        message: fixture.message,
        createdAt: testEpoch,
      );

      clock.advance(CloudSyncManualOutboundCanary.confirmationLifetime);
      clock.advance(const Duration(microseconds: 1));
      await _expectStateError(
        canary.runDoubleConfirmed(confirmation),
        'cloud_sync_outbound_canary_confirmation_expired',
      );
      expect(fixture.sessionFactoryCalls, 0);
      expect(fixture.session.admitCalls, 0);
      expect(canary.isActive, isFalse);
    },
  );

  test('account replacement blocks admission', () async {
    final fixture = _CanaryFixture(
      authSnapshots: [
        _auth('session-a', _fingerprintA, _clientA),
        _auth('session-b', _fingerprintB, _clientB),
      ],
    );
    final canary = fixture.build();
    final confirmation = await canary.armConfirmed(
      message: fixture.message,
      createdAt: testEpoch,
    );

    await _expectStateError(
      canary.runDoubleConfirmed(confirmation),
      'account_changed',
    );
    expect(fixture.sessionFactoryCalls, 0);
    expect(fixture.session.admitCalls, 0);
    expect(canary.isActive, isFalse);
  });

  test('every preflight blocker is checked before admission', () async {
    final blockers =
        <({String expected, CloudSyncShadowPreflightState Function() state})>[
          (
            expected: 'unsupported_platform',
            state: () => _readyState(platformSupported: false),
          ),
          (
            expected: 'not_ui_isolate',
            state: () => _readyState(uiIsolate: false),
          ),
          (
            expected: 'rustpush_not_ready',
            state: () => _readyState(rustPushReady: false),
          ),
          (
            expected: 'objectbox_not_ready',
            state: () => _readyState(objectBoxReady: false),
          ),
          (
            expected: 'storage_unavailable',
            state: () => _readyState(privateStorageExists: false),
          ),
          (
            expected: 'logout_active',
            state: () => _readyState(logoutActive: true),
          ),
          (
            expected: 'legacy_sync_active',
            state: () => _readyState(legacySyncEnabled: true),
          ),
          (
            expected: 'legacy_sync_active',
            state: () => _readyState(legacySyncActive: true),
          ),
          (
            expected: 'coordinator_active',
            state: () => _readyState(coordinatorLeaseActive: true),
          ),
          (
            expected: 'cloud_sync_outbound_canary_outbox_invalid',
            state: () => _readyState(outboxCount: 1),
          ),
          (
            expected: 'protector_unavailable',
            state: () => _readyState(protectorSentinelValid: false),
          ),
        ];

    for (final blocker in blockers) {
      final fixture = _CanaryFixture(preflightStates: [blocker.state()]);
      final canary = fixture.build();

      await _expectStateError(
        canary.armConfirmed(message: fixture.message, createdAt: testEpoch),
        blocker.expected,
      );
      expect(fixture.sessionFactoryCalls, 0, reason: blocker.expected);
      expect(fixture.session.admitCalls, 0, reason: blocker.expected);
    }
  });

  test('invalid admission is rejected and the session is quiesced', () async {
    final fixture = _CanaryFixture(
      operation: _validOperation(_scope(_fingerprintB)),
      preflightStates: [_readyState(), _readyState()],
    );
    final canary = fixture.build();
    final confirmation = await canary.armConfirmed(
      message: fixture.message,
      createdAt: testEpoch,
    );

    await _expectStateError(
      canary.runDoubleConfirmed(confirmation),
      'cloud_sync_outbound_canary_admission_invalid',
    );
    expect(fixture.session.admitCalls, 1);
    expect(fixture.session.flushCalls, 0);
    expect(fixture.session.quiesceCalls, 1);
    expect(canary.isActive, isFalse);
  });

  test('delete admission is rejected even when its scope is correct', () async {
    final fixture = _CanaryFixture(
      operation: testOutboxOperation(
        _scope(_fingerprintA),
        1,
        action: CloudOutboxAction.delete,
      ),
      preflightStates: [_readyState(), _readyState()],
    );
    final canary = fixture.build();
    final confirmation = await canary.armConfirmed(
      message: fixture.message,
      createdAt: testEpoch,
    );

    await _expectStateError(
      canary.runDoubleConfirmed(confirmation),
      'cloud_sync_outbound_canary_admission_invalid',
    );
    expect(fixture.session.quiesceCalls, 1);
  });

  test('a well-formed but unrelated operation identity is rejected', () async {
    final fixture = _CanaryFixture(
      operation: _validOperation(
        _scope(_fingerprintA),
        operationId: 'op1:${List.filled(64, 'f').join()}',
      ),
      preflightStates: [_readyState(), _readyState()],
    );
    final canary = fixture.build();
    final confirmation = await canary.armConfirmed(
      message: fixture.message,
      createdAt: testEpoch,
    );

    await _expectStateError(
      canary.runDoubleConfirmed(confirmation),
      'cloud_sync_outbound_canary_admission_invalid',
    );
    expect(fixture.session.flushCalls, 0);
    expect(fixture.session.quiesceCalls, 1);
  });

  test(
    'double-confirmed recovery advances one row without admitting another',
    () async {
      final fixture = _CanaryFixture(
        preflightStates: [
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
        ],
      );
      final canary = fixture.build();

      final confirmation = await canary.armRecoveryConfirmed();
      expect(fixture.sessionFactoryCalls, 0);
      expect(fixture.session.admitCalls, 0);

      final report = await canary.runDoubleConfirmed(confirmation);

      expect(report.recovery, isTrue);
      expect(report.outboxStatus, CloudOutboxStatus.confirmed);
      expect(report.terminal, isTrue);
      expect(fixture.sessionFactoryCalls, 1);
      expect(fixture.session.admitCalls, 0);
      expect(fixture.session.flushCalls, 1);
      expect(fixture.session.readOutboxCalls, 2);
      expect(fixture.session.quiesceCalls, 1);
    },
  );

  test(
    'recovery rejects a leased, wrong-scope, or multiple-row outbox',
    () async {
      final valid = _validOperation(_scope(_fingerprintA));
      final invalidRows = <List<CloudOutboxOperation>>[
        [valid.copyWith(status: CloudOutboxStatus.leased)],
        [_validOperation(_scope(_fingerprintB))],
        [valid, valid],
      ];

      for (final rows in invalidRows) {
        final fixture = _CanaryFixture(
          preflightStates: [
            _readyState(outboxCount: 1),
            _readyState(outboxCount: 1),
          ],
          outboxReads: [rows],
        );
        final canary = fixture.build();
        final confirmation = await canary.armRecoveryConfirmed();

        await _expectStateError(
          canary.runDoubleConfirmed(confirmation),
          'cloud_sync_outbound_canary_recovery_invalid',
        );
        expect(fixture.session.admitCalls, 0);
        expect(fixture.session.flushCalls, 0);
        expect(fixture.session.quiesceCalls, 1);
      }
    },
  );

  test('postflight requires the same exact durable operation', () async {
    final operation = _validOperation(_scope(_fingerprintA));
    final fixture = _CanaryFixture(
      preflightStates: [
        _readyState(),
        _readyState(),
        _readyState(outboxCount: 1),
      ],
      operation: operation,
      outboxReads: [
        [
          operation.copyWith(
            status: CloudOutboxStatus.confirmed,
            payloadSha256: List.filled(64, 'c').join(),
          ),
        ],
      ],
    );
    final canary = fixture.build();
    final confirmation = await canary.armConfirmed(
      message: fixture.message,
      createdAt: testEpoch,
    );

    await _expectStateError(
      canary.runDoubleConfirmed(confirmation),
      'cloud_sync_outbound_canary_postflight_invalid',
    );
    expect(fixture.session.flushCalls, 1);
    expect(fixture.session.quiesceCalls, 1);
  });

  test(
    'an ambiguous native outcome remains resumable and is reported',
    () async {
      final fixture = _CanaryFixture(
        preflightStates: [
          _readyState(),
          _readyState(),
          _readyState(outboxCount: 1),
        ],
        result: _result(const CloudSyncRunCounters()),
      );
      final canary = fixture.build();
      final confirmation = await canary.armConfirmed(
        message: fixture.message,
        createdAt: testEpoch,
      );

      final report = await canary.runDoubleConfirmed(confirmation);

      expect(report.outboxStatus, CloudOutboxStatus.unknownOutcome);
      expect(report.terminal, isFalse);
      expect(report.toJson()['outboxStatus'], 'unknownOutcome');
      expect(fixture.session.quiesceCalls, 1);
    },
  );

  test(
    'run tripwires reject fetch, apply, and multiple outbound results',
    () async {
      final cases = <String, CloudSyncRunCounters>{
        'fetch': const CloudSyncRunCounters(fetched: 1),
        'apply': const CloudSyncRunCounters(applied: 1),
        'multiple outbound': const CloudSyncRunCounters(confirmed: 2),
      };

      for (final entry in cases.entries) {
        final fixture = _CanaryFixture(
          result: _result(entry.value),
          preflightStates: [_readyState(), _readyState()],
        );
        final canary = fixture.build();
        final confirmation = await canary.armConfirmed(
          message: fixture.message,
          createdAt: testEpoch,
        );

        await _expectStateError(
          canary.runDoubleConfirmed(confirmation),
          'cloud_sync_outbound_canary_tripwire',
        );
        expect(fixture.session.flushCalls, 1, reason: entry.key);
        expect(fixture.session.quiesceCalls, 1, reason: entry.key);
        expect(canary.isActive, isFalse, reason: entry.key);
      }
    },
  );

  test(
    'flush failures also quiesce the session and clear active state',
    () async {
      final fixture = _CanaryFixture(
        preflightStates: [_readyState(), _readyState()],
        flushError: StateError('fake flush failure'),
      );
      final canary = fixture.build();
      final confirmation = await canary.armConfirmed(
        message: fixture.message,
        createdAt: testEpoch,
      );

      await _expectStateError(
        canary.runDoubleConfirmed(confirmation),
        'fake flush failure',
      );
      expect(fixture.session.quiesceCalls, 1);
      expect(canary.isActive, isFalse);
    },
  );
}

Future<void> _expectStateError(Future<Object?> future, String message) async {
  await expectLater(
    future,
    throwsA(
      isA<StateError>().having((error) => error.message, 'message', message),
    ),
  );
}

CloudSyncShadowPreflightState _readyState({
  bool platformSupported = true,
  bool uiIsolate = true,
  bool rustPushReady = true,
  bool objectBoxReady = true,
  bool privateStorageExists = true,
  bool logoutActive = false,
  bool legacySyncEnabled = false,
  bool legacySyncActive = false,
  bool coordinatorLeaseActive = false,
  int outboxCount = 0,
  bool protectorSentinelValid = true,
}) => CloudSyncShadowPreflightState(
  platformSupported: platformSupported,
  uiIsolate: uiIsolate,
  rustPushReady: rustPushReady,
  objectBoxReady: objectBoxReady,
  privateStorageExists: privateStorageExists,
  logoutActive: logoutActive,
  legacySyncEnabled: legacySyncEnabled,
  legacySyncActive: legacySyncActive,
  coordinatorLeaseActive: coordinatorLeaseActive,
  outboxCount: outboxCount,
  protectorSentinelValid: protectorSentinelValid,
);

CloudSyncScope _scope(String account) => CloudSyncScope(
  accountFingerprint: account,
  container: CloudSyncManualOutboundCanary.container,
  database: CloudSyncManualOutboundCanary.database,
  zone: CloudSyncManualOutboundCanary.zone,
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: 2,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

CloudSyncNativeAuthSnapshot _auth(
  String session,
  String fingerprint,
  Object client,
) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: session,
  accountFingerprint: fingerprint,
  protectedStoreIdentity:
      'obcs2.store.${List.filled(43, fingerprint.substring(0, 1)).join()}',
  cloudMessagesClient: client,
);

CloudSyncRunResult _result(CloudSyncRunCounters counters) {
  final now = testEpoch;
  return CloudSyncRunResult(
    status: CloudSyncRunStatus.completed,
    counters: counters,
    startedAt: now,
    finishedAt: now,
  );
}

CloudOutboxOperation _validOperation(
  CloudSyncScope scope, {
  String? operationId,
}) {
  final logicalEntityKeyHash = List.filled(43, 'L').join();
  return CloudOutboxOperation(
    scope: scope,
    operationId:
        operationId ??
        CloudOperationIdentity.forInitialCreate(
          scope: scope,
          logicalEntityKeyHash: logicalEntityKeyHash,
          payloadVersion: 1,
        ),
    logicalEntityKeyHash: logicalEntityKeyHash,
    action: CloudOutboxAction.save,
    payloadVersion: 1,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: 'obcs2.ref.${List.filled(43, 'P').join()}',
    payloadSha256: List.filled(64, 'a').join(),
    serverRecordIdHash: List.filled(43, 'S').join(),
    protectedLeaseReference: 'obcs2.lease.${List.filled(32, '0').join()}',
    dependencyOperationIds: const [],
    createdAt: testEpoch,
  );
}

final class _CanaryFixture {
  _CanaryFixture({
    Iterable<CloudSyncShadowPreflightState>? preflightStates,
    Iterable<CloudSyncNativeAuthSnapshot?>? authSnapshots,
    CloudOutboxOperation? operation,
    CloudSyncRunResult? result,
    Iterable<List<CloudOutboxOperation>>? outboxReads,
    this.flushError,
  }) : preflight = _PreflightFake(
         preflightStates ??
             [_readyState(), _readyState(), _readyState(outboxCount: 1)],
       ),
       auth = _AuthFake(
         authSnapshots ?? [_auth('session-a', _fingerprintA, _clientA)],
       ),
       session = _SessionFake(
         operation ?? _validOperation(_scope(_fingerprintA)),
         result ?? _result(const CloudSyncRunCounters(confirmed: 1)),
         outboxReads: outboxReads,
         flushError: flushError,
       );

  final _PreflightFake preflight;
  final _AuthFake auth;
  final _SessionFake session;
  final Object? flushError;
  final message = _FakeCloudMessage();
  final scopes = <CloudSyncScope>[];
  int sessionFactoryCalls = 0;

  CloudSyncScope get expectedScope => _scope(_fingerprintA);

  CloudSyncManualOutboundCanary build({
    bool? compileGate,
    bool? writerGate,
    MutableTestClock? clock,
  }) => CloudSyncManualOutboundCanary(
    readPreflight: preflight.read,
    readAuthSnapshot: auth.read,
    createSession: (snapshot, scope) async {
      sessionFactoryCalls++;
      scopes.add(scope);
      return session;
    },
    compileGateOverrideForTest: compileGate ?? true,
    v2WriterOverrideForTest: writerGate ?? true,
    clock: (clock ?? MutableTestClock(testEpoch)).call,
  );
}

final class _PreflightFake {
  _PreflightFake(Iterable<CloudSyncShadowPreflightState> states)
    : _states = states.toList(growable: false);

  final List<CloudSyncShadowPreflightState> _states;
  int calls = 0;
  final outboxCounts = <int>[];

  Future<CloudSyncShadowPreflightState> read() async {
    final state = _states.length > 1 && calls < _states.length
        ? _states[calls]
        : _states.last;
    calls++;
    outboxCounts.add(state.outboxCount);
    return state;
  }
}

final class _AuthFake {
  _AuthFake(Iterable<CloudSyncNativeAuthSnapshot?> snapshots)
    : _snapshots = snapshots.toList(growable: false);

  final List<CloudSyncNativeAuthSnapshot?> _snapshots;
  int calls = 0;

  Future<CloudSyncNativeAuthSnapshot?> read() async {
    final snapshot = _snapshots.length > 1 && calls < _snapshots.length
        ? _snapshots[calls]
        : _snapshots.last;
    calls++;
    return snapshot;
  }
}

final class _SessionFake implements CloudSyncOutboundCanarySession {
  _SessionFake(
    this.operation,
    this.result, {
    Iterable<List<CloudOutboxOperation>>? outboxReads,
    this.flushError,
  }) : _outboxReads = outboxReads?.toList(growable: false);

  final CloudOutboxOperation operation;
  final CloudSyncRunResult result;
  final Object? flushError;
  final List<List<CloudOutboxOperation>>? _outboxReads;
  int admitCalls = 0;
  int flushCalls = 0;
  int quiesceCalls = 0;
  int readOutboxCalls = 0;
  frb_api.CloudMessage? receivedMessage;

  @override
  Future<CloudOutboxOperation> admitMessage({
    required frb_api.CloudMessage message,
    required DateTime createdAt,
  }) async {
    admitCalls++;
    receivedMessage = message;
    return operation;
  }

  @override
  Future<CloudSyncRunResult> flushOneBatch() async {
    flushCalls++;
    if (flushError != null) throw flushError!;
    return result;
  }

  @override
  Future<List<CloudOutboxOperation>> readOutbox() async {
    final custom = _outboxReads;
    if (custom != null && custom.isNotEmpty) {
      final index = readOutboxCalls < custom.length
          ? readOutboxCalls
          : custom.length - 1;
      readOutboxCalls++;
      return custom[index];
    }
    readOutboxCalls++;
    final status = flushCalls == 0
        ? operation.status
        : result.counters.confirmed > 0
        ? CloudOutboxStatus.confirmed
        : result.counters.quarantined > 0
        ? CloudOutboxStatus.quarantined
        : result.counters.retried > 0
        ? CloudOutboxStatus.pending
        : CloudOutboxStatus.unknownOutcome;
    return [operation.copyWith(status: status)];
  }

  @override
  Future<void> quiesce() async {
    quiesceCalls++;
  }
}

final class _FakeCloudMessage implements frb_api.CloudMessage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
