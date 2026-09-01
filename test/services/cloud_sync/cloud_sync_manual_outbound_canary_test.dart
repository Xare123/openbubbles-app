import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

const _fingerprintA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _fingerprintB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _testRequestUuid = '00000000-0000-4000-8000-000000000001';
const _testOperationUuid = '00000000-0000-4000-8000-000000000002';

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
        _arm(
          disabledCanary,
          message: _FakeCloudMessage(),
          createdAt: testEpoch,
        ),
        'cloud_sync_outbound_canary_disabled',
      );
      expect(disabled.preflight.calls, 0);

      final writerDisabled = _CanaryFixture();
      final writerDisabledCanary = writerDisabled.build(writerGate: false);
      await _expectStateError(
        _arm(
          writerDisabledCanary,
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

    final confirmation = await _arm(
      canary,
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
    final confirmation = await _arm(
      canary,
      message: fixture.message,
      createdAt: testEpoch,
    );

    final report = await canary.runDoubleConfirmed(confirmation);

    expect(report.status, CloudSyncRunStatus.completed);
    expect(report.confirmed, 1);
    expect(report.outboxStatus, CloudOutboxStatus.confirmed);
    expect(report.recovery, isFalse);
    expect(report.replayVerification, isFalse);
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
    expect(fixture.exclusion.kinds, [CloudKitOperationKind.v2ReadWrite]);
    expect(canary.isActive, isFalse);
  });

  test(
    'second confirmation acquires cross-process exclusion before admission',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openbubbles-outbound-canary-interlock-',
      );
      final fenceStore = InMemoryCloudSyncStore();
      final holder = CloudKitOperationInterlock(
        privateStorageDirectory: directory.path,
        fenceStore: fenceStore,
      );
      final contender = CloudKitOperationInterlock(
        privateStorageDirectory: directory.path,
        fenceStore: fenceStore,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final held = holder.runExclusive<void>(
        kind: CloudKitOperationKind.legacyReadWrite,
        action: () async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;

      try {
        final fixture = _CanaryFixture();
        final canary = fixture.build(writerExclusion: contender);
        final confirmation = await _arm(
          canary,
          message: fixture.message,
          createdAt: testEpoch,
        );

        await expectLater(
          canary.runDoubleConfirmed(confirmation),
          throwsA(
            isA<CloudKitOperationInterlockException>().having(
              (error) => error.safeCode,
              'safeCode',
              'cloudkit_interlock_busy',
            ),
          ),
        );
        expect(fixture.preflight.calls, 1);
        expect(fixture.sessionFactoryCalls, 0);
        expect(fixture.session.admitCalls, 0);
        expect(fixture.session.flushCalls, 0);
        expect(canary.isActive, isFalse);
      } finally {
        release.complete();
        await held;
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'final in-run candidate revalidation precedes session creation',
    () async {
      final fixture = _CanaryFixture(
        preflightStates: [_readyState(), _readyState()],
      );
      final canary = fixture.build();
      var revalidationCalls = 0;
      final confirmation = await canary.armConfirmed(
        selectedCreatedAt: testEpoch,
        revalidateAdmission: () async {
          revalidationCalls++;
          return null;
        },
      );

      await _expectStateError(
        canary.runDoubleConfirmed(confirmation),
        'cloud_sync_outbound_candidate_changed',
      );

      expect(revalidationCalls, 1);
      expect(fixture.sessionFactoryCalls, 0);
      expect(fixture.session.admitCalls, 0);
      expect(fixture.session.flushCalls, 0);
    },
  );

  test('confirmation tokens are single-use', () async {
    final fixture = _CanaryFixture(
      preflightStates: [
        _readyState(),
        _readyState(),
        _readyState(outboxCount: 1),
      ],
    );
    final canary = fixture.build();
    final confirmation = await _arm(
      canary,
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
      final firstConfirmation = await _arm(
        firstCanary,
        message: first.message,
        createdAt: testEpoch,
      );
      final wrongConfirmation = await _arm(
        secondCanary,
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
      final confirmation = await _arm(
        canary,
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
    final confirmation = await _arm(
      canary,
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
        _arm(canary, message: fixture.message, createdAt: testEpoch),
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
    final confirmation = await _arm(
      canary,
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
    final confirmation = await _arm(
      canary,
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
    final confirmation = await _arm(
      canary,
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
      expect(report.replayVerification, isFalse);
      expect(report.outboxStatus, CloudOutboxStatus.confirmed);
      expect(report.terminal, isTrue);
      expect(fixture.sessionFactoryCalls, 1);
      expect(fixture.sessionKinds, [
        CloudSyncOutboundCanarySessionKind.pendingRecovery,
      ]);
      expect(
        fixture.expectedOperations.single,
        same(confirmation.armedOperation),
      );
      expect(fixture.session.admitCalls, 0);
      expect(fixture.session.flushCalls, 1);
      expect(fixture.session.reconcileUnknownCalls, 0);
      expect(fixture.session.readOutboxCalls, 2);
      expect(fixture.session.quiesceCalls, 1);
    },
  );

  test('recovery accepts an exact unknown-outcome row', () async {
    final unknown = _unknownOperation(_scope(_fingerprintA));
    final fixture = _CanaryFixture(
      operation: unknown,
      preflightStates: [
        _readyState(outboxCount: 1),
        _readyState(outboxCount: 1),
        _readyState(outboxCount: 1),
      ],
    );
    final canary = fixture.build();

    final confirmation = await canary.armRecoveryConfirmed();
    final report = await canary.runDoubleConfirmed(confirmation);

    expect(report.outboxStatus, CloudOutboxStatus.confirmed);
    expect(fixture.sessionKinds, [
      CloudSyncOutboundCanarySessionKind.unknownRecovery,
    ]);
    expect(
      fixture.expectedOperations.single,
      same(confirmation.armedOperation),
    );
    expect(fixture.session.flushCalls, 0);
    expect(fixture.session.reconcileUnknownCalls, 1);
  });

  test(
    'confirmed-only replay reports zero saves without admitting another row',
    () async {
      final confirmed = _confirmedOperation(_scope(_fingerprintA));
      final fixture = _CanaryFixture(
        operation: confirmed,
        result: _result(const CloudSyncRunCounters()),
        preflightStates: [
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
        ],
        outboxReads: [
          [confirmed],
          [confirmed],
        ],
      );
      final canary = fixture.build();

      final confirmation = await canary.armConfirmedReplay();
      final report = await canary.runDoubleConfirmed(confirmation);

      expect(report.recovery, isTrue);
      expect(report.replayVerification, isTrue);
      expect(report.confirmed, 0);
      expect(report.quarantined, 0);
      expect(report.retried, 0);
      expect(report.outboxStatus, CloudOutboxStatus.confirmed);
      expect(fixture.session.admitCalls, 0);
      expect(fixture.session.flushCalls, 0);
      expect(fixture.session.reconcileUnknownCalls, 0);
      expect(fixture.session.verifyNoSaveCalls, 1);
      expect(fixture.session.finalizeReplayCalls, 1);
      expect(fixture.sessionKinds, [
        CloudSyncOutboundCanarySessionKind.confirmedReplay,
      ]);
    },
  );

  test('ordinary recovery resumes a confirmed row as no-save replay', () async {
    final confirmed = _confirmedOperation(_scope(_fingerprintA));
    final fixture = _CanaryFixture(
      operation: confirmed,
      result: _result(const CloudSyncRunCounters()),
      preflightStates: [
        _readyState(outboxCount: 1),
        _readyState(outboxCount: 1),
        _readyState(outboxCount: 1),
      ],
      outboxReads: [
        [confirmed],
        [confirmed],
      ],
    );
    final canary = fixture.build();

    final confirmation = await canary.armRecoveryConfirmed();
    expect(confirmation.replayVerification, isTrue);
    final report = await canary.runDoubleConfirmed(confirmation);

    expect(report.replayVerification, isTrue);
    expect(fixture.session.flushCalls, 0);
    expect(fixture.session.verifyNoSaveCalls, 1);
    expect(fixture.session.finalizeReplayCalls, 1);
  });

  test(
    'confirmed-only replay retains the receipt when the row changes after proof',
    () async {
      final confirmed = _confirmedOperation(_scope(_fingerprintA));
      final changed = confirmed.copyWith(attemptCount: 1);
      final fixture = _CanaryFixture(
        operation: confirmed,
        result: _result(const CloudSyncRunCounters()),
        preflightStates: [
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
        ],
        outboxReads: [
          [confirmed],
          [changed],
        ],
      );
      final canary = fixture.build();
      final confirmation = await canary.armConfirmedReplay();

      await _expectStateError(
        canary.runDoubleConfirmed(confirmation),
        'cloud_sync_outbound_canary_operation_changed',
      );
      expect(fixture.session.verifyNoSaveCalls, 1);
      expect(fixture.session.finalizeReplayCalls, 0);
      expect(fixture.session.quiesceCalls, 1);
    },
  );

  test(
    'confirmed-only replay rejects a non-confirmed row while arming',
    () async {
      final fixture = _CanaryFixture(
        preflightStates: [
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
        ],
      );
      final canary = fixture.build();
      await _expectStateError(
        canary.armConfirmedReplay(),
        'cloud_sync_outbound_canary_replay_invalid',
      );
      expect(fixture.session.flushCalls, 0);
      expect(fixture.session.verifyNoSaveCalls, 0);
      expect(fixture.session.admitCalls, 0);
    },
  );

  test('confirmed-only replay cannot enter the write-capable flush', () async {
    final confirmed = _confirmedOperation(_scope(_fingerprintA));
    final fixture = _CanaryFixture(
      operation: confirmed,
      result: _result(const CloudSyncRunCounters(confirmed: 1)),
      preflightStates: [
        _readyState(outboxCount: 1),
        _readyState(outboxCount: 1),
      ],
      outboxReads: [
        [confirmed],
      ],
    );
    final canary = fixture.build();
    final confirmation = await canary.armConfirmedReplay();

    final report = await canary.runDoubleConfirmed(confirmation);

    expect(report.confirmed, 0);
    expect(report.quarantined, 0);
    expect(report.retried, 0);
    expect(fixture.session.flushCalls, 0);
    expect(fixture.session.verifyNoSaveCalls, 1);
    expect(fixture.session.admitCalls, 0);
  });

  test(
    'recovery rejects a leased, wrong-scope, or multiple-row outbox while arming',
    () async {
      final valid = _validOperation(_scope(_fingerprintA));
      final invalidRows = <List<CloudOutboxOperation>>[
        [valid.copyWith(status: CloudOutboxStatus.leased)],
        [valid.copyWith(status: CloudOutboxStatus.paused)],
        [valid.copyWith(status: CloudOutboxStatus.quarantined)],
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
        await _expectStateError(
          canary.armRecoveryConfirmed(),
          'cloud_sync_outbound_canary_recovery_invalid',
        );
        expect(fixture.session.admitCalls, 0);
        expect(fixture.session.flushCalls, 0);
        expect(fixture.session.quiesceCalls, 0);
      }
    },
  );

  test(
    'recovery rejects malformed durable lifecycle rows before a session',
    () async {
      final valid = _validOperation(_scope(_fingerprintA));
      final malformedRows = <CloudOutboxOperation>[
        valid.copyWith(status: CloudOutboxStatus.unknownOutcome),
        valid.copyWith(
          status: CloudOutboxStatus.unknownOutcome,
          appleRequestUuid: _testRequestUuid,
          appleOperationUuid: _testOperationUuid,
          lastFailure: CloudFailureCategory.unknown,
          leaseId: 'stale-lease',
          leaseExpiresAt: testEpoch.add(const Duration(minutes: 1)),
        ),
        valid.copyWith(
          attemptCount: 1,
          lastFailure: CloudFailureCategory.server,
        ),
        valid.copyWith(
          attemptCount: 1,
          nextEligibleAt: testEpoch.add(const Duration(minutes: 1)),
        ),
        valid.copyWith(
          status: CloudOutboxStatus.confirmed,
          confirmedAt: testEpoch.add(const Duration(seconds: 1)),
        ),
      ];

      for (final malformed in malformedRows) {
        final fixture = _CanaryFixture(
          confirmationRows: [malformed],
          preflightStates: [
            _readyState(outboxCount: 1),
            _readyState(outboxCount: 1),
          ],
        );
        final canary = fixture.build();

        await _expectStateError(
          canary.armRecoveryConfirmed(),
          'cloud_sync_outbound_canary_recovery_invalid',
        );
        expect(fixture.sessionFactoryCalls, 0);
        expect(fixture.session.flushCalls, 0);
      }
    },
  );

  test(
    'recovery operation must remain exact after final confirmation',
    () async {
      final pending = _validOperation(_scope(_fingerprintA));
      final changed = pending.copyWith(
        attemptCount: 1,
        nextEligibleAt: testEpoch.add(const Duration(minutes: 1)),
        lastFailure: CloudFailureCategory.server,
      );
      final fixture = _CanaryFixture(
        confirmationRows: [pending],
        outboxReads: [
          [changed],
        ],
        preflightStates: [
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
        ],
      );
      final canary = fixture.build();
      final confirmation = await canary.armRecoveryConfirmed();

      await _expectStateError(
        canary.runDoubleConfirmed(confirmation),
        'cloud_sync_outbound_canary_operation_changed',
      );
      expect(fixture.session.flushCalls, 0);
      expect(fixture.session.quiesceCalls, 1);
    },
  );

  test('postflight requires the same exact durable operation', () async {
    final operation = _validOperation(_scope(_fingerprintA));
    final confirmed = operation.copyWith(
      status: CloudOutboxStatus.confirmed,
      appleRequestUuid: _testRequestUuid,
      appleOperationUuid: _testOperationUuid,
      confirmedAt: testEpoch.add(const Duration(seconds: 1)),
    );
    final changedOperations = <CloudOutboxOperation>[
      confirmed.copyWith(payloadSha256: List.filled(64, 'c').join()),
      confirmed.copyWith(serverRecordIdHash: List.filled(43, 'R').join()),
      confirmed.copyWith(
        encryptedPayloadReference: 'obcs2.ref.${List.filled(43, 'E').join()}',
      ),
      confirmed.copyWith(dependencyOperationIds: const {'unexpected'}),
    ];

    for (final changed in changedOperations) {
      final fixture = _CanaryFixture(
        preflightStates: [
          _readyState(),
          _readyState(),
          _readyState(outboxCount: 1),
        ],
        operation: operation,
        outboxReads: [
          [changed],
        ],
      );
      final canary = fixture.build();
      final confirmation = await _arm(
        canary,
        message: fixture.message,
        createdAt: testEpoch,
      );

      await _expectStateError(
        canary.runDoubleConfirmed(confirmation),
        'cloud_sync_outbound_canary_postflight_invalid',
      );
      expect(fixture.session.flushCalls, 1);
      expect(fixture.session.quiesceCalls, 1);
    }
  });

  test('postflight permits exact lifecycle-valid recovery no-ops', () async {
    final cases = <CloudOutboxOperation>[
      _validOperation(_scope(_fingerprintA)),
      _unknownOperation(_scope(_fingerprintA)),
    ];

    for (final operation in cases) {
      final fixture = _CanaryFixture(
        operation: operation,
        result: _result(const CloudSyncRunCounters()),
        preflightStates: [
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
        ],
        outboxReads: [
          [operation],
          [operation],
        ],
      );
      final canary = fixture.build();
      final confirmation = await canary.armRecoveryConfirmed();

      final report = await canary.runDoubleConfirmed(confirmation);

      expect(report.outboxStatus, operation.status);
      expect(report.confirmed, 0);
      expect(report.quarantined, 0);
      expect(report.retried, 0);
    }
  });

  test(
    'pending quarantine preserves or safely assigns submission identity',
    () async {
      final pending = _validOperation(_scope(_fingerprintA));
      final cases = <(String, CloudOutboxOperation, CloudOutboxOperation)>[
        (
          'pre-submission quarantine',
          pending,
          pending.copyWith(
            status: CloudOutboxStatus.quarantined,
            attemptCount: 1,
            lastFailure: CloudFailureCategory.malformedRecord,
            clearProtectedLeaseReference: true,
          ),
        ),
        (
          'post-submission quarantine',
          pending,
          pending.copyWith(
            status: CloudOutboxStatus.quarantined,
            attemptCount: 1,
            lastFailure: CloudFailureCategory.malformedRecord,
            appleRequestUuid: _testRequestUuid,
            appleOperationUuid: _testOperationUuid,
            clearProtectedLeaseReference: true,
          ),
        ),
      ];

      for (final value in cases) {
        final fixture = _CanaryFixture(
          operation: value.$2,
          result: _result(const CloudSyncRunCounters(quarantined: 1)),
          preflightStates: [
            _readyState(outboxCount: 1),
            _readyState(outboxCount: 1),
            _readyState(outboxCount: 1),
          ],
          outboxReads: [
            [value.$2],
            [value.$3],
          ],
        );
        final canary = fixture.build();
        final confirmation = await canary.armRecoveryConfirmed();

        final report = await canary.runDoubleConfirmed(confirmation);

        expect(
          report.outboxStatus,
          CloudOutboxStatus.quarantined,
          reason: value.$1,
        );
      }
    },
  );

  test(
    'unknown recovery cannot quarantine or discard protected evidence',
    () async {
      final unknown = _unknownOperation(_scope(_fingerprintA));
      final quarantined = unknown.copyWith(
        status: CloudOutboxStatus.quarantined,
        attemptCount: unknown.attemptCount + 1,
        lastFailure: CloudFailureCategory.malformedRecord,
        clearProtectedLeaseReference: true,
      );
      final fixture = _CanaryFixture(
        operation: unknown,
        result: _result(const CloudSyncRunCounters(quarantined: 1)),
        preflightStates: [
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
        ],
        outboxReads: [
          [unknown],
          [quarantined],
        ],
      );
      final canary = fixture.build();
      final confirmation = await canary.armRecoveryConfirmed();

      await _expectStateError(
        canary.runDoubleConfirmed(confirmation),
        'cloud_sync_outbound_canary_postflight_invalid',
      );

      expect(fixture.sessionKinds, [
        CloudSyncOutboundCanarySessionKind.unknownRecovery,
      ]);
      expect(fixture.session.flushCalls, 0);
      expect(fixture.session.reconcileUnknownCalls, 1);
      expect(quarantined.appleRequestUuid, unknown.appleRequestUuid);
      expect(quarantined.appleOperationUuid, unknown.appleOperationUuid);
      expect(quarantined.protectedLeaseReference, isNull);
    },
  );

  test(
    'postflight rejects identity loss, replacement, and paused rows',
    () async {
      final unknown = _unknownOperation(_scope(_fingerprintA));
      const changedRequest = '00000000-0000-4000-8000-000000000003';
      const changedOperation = '00000000-0000-4000-8000-000000000004';
      final cases = <(String, CloudSyncRunCounters, CloudOutboxOperation)>[
        (
          'quarantine clears an existing identity',
          const CloudSyncRunCounters(quarantined: 1),
          unknown.copyWith(
            status: CloudOutboxStatus.quarantined,
            attemptCount: unknown.attemptCount + 1,
            lastFailure: CloudFailureCategory.malformedRecord,
            clearSubmissionIdentity: true,
            clearProtectedLeaseReference: true,
          ),
        ),
        (
          'quarantine replaces an existing identity',
          const CloudSyncRunCounters(quarantined: 1),
          unknown.copyWith(
            status: CloudOutboxStatus.quarantined,
            attemptCount: unknown.attemptCount + 1,
            lastFailure: CloudFailureCategory.malformedRecord,
            appleRequestUuid: changedRequest,
            appleOperationUuid: changedOperation,
            clearProtectedLeaseReference: true,
          ),
        ),
        (
          'unknown replaces an existing identity',
          const CloudSyncRunCounters(),
          unknown.copyWith(
            status: CloudOutboxStatus.unknownOutcome,
            attemptCount: unknown.attemptCount + 1,
            lastFailure: CloudFailureCategory.unknown,
            appleRequestUuid: changedRequest,
            appleOperationUuid: changedOperation,
          ),
        ),
        (
          'unknown retains a live lease after postflight',
          const CloudSyncRunCounters(),
          unknown.copyWith(
            status: CloudOutboxStatus.unknownOutcome,
            attemptCount: unknown.attemptCount + 1,
            lastFailure: CloudFailureCategory.unknown,
            leaseId: 'residual-lease',
            leaseExpiresAt: testEpoch.add(const Duration(minutes: 1)),
          ),
        ),
        (
          'paused is not a recoverable postflight state',
          const CloudSyncRunCounters(),
          unknown.copyWith(
            status: CloudOutboxStatus.paused,
            attemptCount: unknown.attemptCount + 1,
            lastFailure: CloudFailureCategory.authorization,
            nextEligibleAt: testEpoch.add(const Duration(hours: 6)),
            clearSubmissionIdentity: true,
          ),
        ),
      ];

      for (final value in cases) {
        final fixture = _CanaryFixture(
          operation: unknown,
          result: _result(value.$2),
          preflightStates: [
            _readyState(outboxCount: 1),
            _readyState(outboxCount: 1),
            _readyState(outboxCount: 1),
          ],
          outboxReads: [
            [unknown],
            [value.$3],
          ],
        );
        final canary = fixture.build();
        final confirmation = await canary.armRecoveryConfirmed();

        await _expectStateError(
          canary.runDoubleConfirmed(confirmation),
          'cloud_sync_outbound_canary_postflight_invalid',
        );
        expect(fixture.session.quiesceCalls, 1, reason: value.$1);
      }
    },
  );

  test(
    'another unresolved recovery attempt preserves submission identity',
    () async {
      final unknown = _unknownOperation(_scope(_fingerprintA));
      final unresolved = unknown.copyWith(
        status: CloudOutboxStatus.unknownOutcome,
        attemptCount: unknown.attemptCount + 1,
        lastFailure: CloudFailureCategory.unknown,
        nextEligibleAt: testEpoch.add(const Duration(minutes: 1)),
      );
      final fixture = _CanaryFixture(
        operation: unknown,
        result: _result(const CloudSyncRunCounters()),
        preflightStates: [
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
          _readyState(outboxCount: 1),
        ],
        outboxReads: [
          [unknown],
          [unresolved],
        ],
      );
      final canary = fixture.build();
      final confirmation = await canary.armRecoveryConfirmed();

      final report = await canary.runDoubleConfirmed(confirmation);

      expect(report.outboxStatus, CloudOutboxStatus.unknownOutcome);
      expect(unresolved.appleRequestUuid, unknown.appleRequestUuid);
      expect(unresolved.appleOperationUuid, unknown.appleOperationUuid);
    },
  );

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
      final confirmation = await _arm(
        canary,
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
    'postflight accepts only the exact lifecycle implied by counters',
    () async {
      final operation = _validOperation(_scope(_fingerprintA));
      final cases =
          <
            ({
              String name,
              CloudSyncRunCounters counters,
              CloudOutboxOperation actual,
              CloudOutboxStatus expectedStatus,
            })
          >[
            (
              name: 'retry',
              counters: const CloudSyncRunCounters(retried: 1),
              actual: operation.copyWith(
                status: CloudOutboxStatus.pending,
                attemptCount: 1,
                nextEligibleAt: testEpoch.add(const Duration(minutes: 1)),
                lastFailure: CloudFailureCategory.server,
              ),
              expectedStatus: CloudOutboxStatus.pending,
            ),
            (
              name: 'quarantine',
              counters: const CloudSyncRunCounters(quarantined: 1),
              actual: operation.copyWith(
                status: CloudOutboxStatus.quarantined,
                attemptCount: 1,
                lastFailure: CloudFailureCategory.malformedRecord,
                clearProtectedLeaseReference: true,
              ),
              expectedStatus: CloudOutboxStatus.quarantined,
            ),
          ];

      for (final value in cases) {
        final fixture = _CanaryFixture(
          preflightStates: [
            _readyState(),
            _readyState(),
            _readyState(outboxCount: 1),
          ],
          operation: operation,
          result: _result(value.counters),
          outboxReads: [
            [value.actual],
          ],
        );
        final canary = fixture.build();
        final confirmation = await _arm(
          canary,
          message: fixture.message,
          createdAt: testEpoch,
        );

        final report = await canary.runDoubleConfirmed(confirmation);

        expect(report.outboxStatus, value.expectedStatus, reason: value.name);
      }
    },
  );

  test('postflight rejects lifecycle or counter contradictions', () async {
    final operation = _validOperation(_scope(_fingerprintA));
    final cases =
        <
          ({
            String name,
            CloudSyncRunCounters counters,
            CloudOutboxOperation actual,
          })
        >[
          (
            name: 'confirmed without submission identity',
            counters: const CloudSyncRunCounters(confirmed: 1),
            actual: operation.copyWith(
              status: CloudOutboxStatus.confirmed,
              confirmedAt: testEpoch.add(const Duration(seconds: 1)),
            ),
          ),
          (
            name: 'confirmed with changed attempt',
            counters: const CloudSyncRunCounters(confirmed: 1),
            actual: operation.copyWith(
              status: CloudOutboxStatus.confirmed,
              attemptCount: 1,
              appleRequestUuid: '00000000-0000-4000-8000-000000000001',
              appleOperationUuid: '00000000-0000-4000-8000-000000000002',
              confirmedAt: testEpoch.add(const Duration(seconds: 1)),
            ),
          ),
          (
            name: 'retry without backoff',
            counters: const CloudSyncRunCounters(retried: 1),
            actual: operation.copyWith(
              status: CloudOutboxStatus.pending,
              attemptCount: 1,
              lastFailure: CloudFailureCategory.server,
            ),
          ),
          (
            name: 'quarantine retains protected receipt',
            counters: const CloudSyncRunCounters(quarantined: 1),
            actual: operation.copyWith(
              status: CloudOutboxStatus.quarantined,
              attemptCount: 1,
              lastFailure: CloudFailureCategory.malformedRecord,
            ),
          ),
          (
            name: 'counter says confirmed but row is unknown',
            counters: const CloudSyncRunCounters(confirmed: 1),
            actual: operation.copyWith(
              status: CloudOutboxStatus.unknownOutcome,
              attemptCount: 1,
              lastFailure: CloudFailureCategory.unknown,
              appleRequestUuid: '00000000-0000-4000-8000-000000000001',
              appleOperationUuid: '00000000-0000-4000-8000-000000000002',
            ),
          ),
        ];

    for (final value in cases) {
      final fixture = _CanaryFixture(
        preflightStates: [
          _readyState(),
          _readyState(),
          _readyState(outboxCount: 1),
        ],
        operation: operation,
        result: _result(value.counters),
        outboxReads: [
          [value.actual],
        ],
      );
      final canary = fixture.build();
      final confirmation = await _arm(
        canary,
        message: fixture.message,
        createdAt: testEpoch,
      );

      await _expectStateError(
        canary.runDoubleConfirmed(confirmation),
        'cloud_sync_outbound_canary_postflight_invalid',
      );
      expect(fixture.session.quiesceCalls, 1, reason: value.name);
    }
  });

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
        final confirmation = await _arm(
          canary,
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
      final confirmation = await _arm(
        canary,
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
          payloadVersion: cloudSyncOutboundPayloadVersion,
        ),
    logicalEntityKeyHash: logicalEntityKeyHash,
    action: CloudOutboxAction.save,
    payloadVersion: cloudSyncOutboundPayloadVersion,
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

CloudOutboxOperation _unknownOperation(CloudSyncScope scope) =>
    _validOperation(scope).copyWith(
      status: CloudOutboxStatus.unknownOutcome,
      appleRequestUuid: _testRequestUuid,
      appleOperationUuid: _testOperationUuid,
      lastFailure: CloudFailureCategory.unknown,
    );

CloudOutboxOperation _confirmedOperation(CloudSyncScope scope) =>
    _validOperation(scope).copyWith(
      status: CloudOutboxStatus.confirmed,
      appleRequestUuid: _testRequestUuid,
      appleOperationUuid: _testOperationUuid,
      confirmedAt: testEpoch.add(const Duration(seconds: 1)),
    );

final class _CanaryFixture {
  _CanaryFixture({
    Iterable<CloudSyncShadowPreflightState>? preflightStates,
    Iterable<CloudSyncNativeAuthSnapshot?>? authSnapshots,
    CloudOutboxOperation? operation,
    CloudSyncRunResult? result,
    Iterable<List<CloudOutboxOperation>>? outboxReads,
    this.confirmationRows,
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
  final List<CloudOutboxOperation>? confirmationRows;
  final Object? flushError;
  final message = _FakeCloudMessage();
  final exclusion = _ExclusionFake();
  final scopes = <CloudSyncScope>[];
  final sessionKinds = <CloudSyncOutboundCanarySessionKind>[];
  final expectedOperations = <CloudOutboxOperation?>[];
  int sessionFactoryCalls = 0;

  CloudSyncScope get expectedScope => _scope(_fingerprintA);

  CloudSyncManualOutboundCanary build({
    bool? compileGate,
    bool? writerGate,
    MutableTestClock? clock,
    CloudKitOperationExclusion? writerExclusion,
  }) => CloudSyncManualOutboundCanary(
    readPreflight: preflight.read,
    readAuthSnapshot: auth.read,
    readOutboxForConfirmation: (_) async =>
        confirmationRows ?? session.peekOutbox(),
    writerExclusion: writerExclusion ?? exclusion,
    createSession: (snapshot, scope, kind, expectedOperation) async {
      sessionFactoryCalls++;
      scopes.add(scope);
      sessionKinds.add(kind);
      expectedOperations.add(expectedOperation);
      return switch (kind) {
        CloudSyncOutboundCanarySessionKind.freshWrite => _FreshWriteSessionFake(
          session,
        ),
        CloudSyncOutboundCanarySessionKind.pendingRecovery =>
          _PendingRecoverySessionFake(session),
        CloudSyncOutboundCanarySessionKind.unknownRecovery =>
          _UnknownRecoverySessionFake(session),
        CloudSyncOutboundCanarySessionKind.confirmedReplay =>
          _ConfirmedReplaySessionFake(session),
      };
    },
    compileGateOverrideForTest: compileGate ?? true,
    v2WriterOverrideForTest: writerGate ?? true,
    clock: (clock ?? MutableTestClock(testEpoch)).call,
  );
}

final class _ExclusionFake implements CloudKitOperationExclusion {
  final kinds = <CloudKitOperationKind>[];

  @override
  Future<T> runExclusive<T>({
    required CloudKitOperationKind kind,
    required CloudKitOperationBody<T> action,
  }) async {
    kinds.add(kind);
    return action();
  }

  @override
  void poisonUntilProcessRestart() {}
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

final class _ReplayProofFake implements CloudSyncConfirmedReplayProof {
  const _ReplayProofFake();
}

final class _SessionFake {
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
  int reconcileUnknownCalls = 0;
  int verifyNoSaveCalls = 0;
  int finalizeReplayCalls = 0;
  int quiesceCalls = 0;
  int readOutboxCalls = 0;
  frb_api.CloudMessage? receivedMessage;
  static const _replayProof = _ReplayProofFake();
  static const _requestUuid = '00000000-0000-4000-8000-000000000001';
  static const _operationUuid = '00000000-0000-4000-8000-000000000002';

  Future<CloudOutboxOperation> admitMessage({
    required frb_api.CloudMessage message,
    required DateTime createdAt,
  }) async {
    admitCalls++;
    receivedMessage = message;
    return operation;
  }

  Future<CloudSyncRunResult> flushOneBatch() async {
    flushCalls++;
    if (flushError != null) throw flushError!;
    return result;
  }

  Future<CloudSyncRunResult> reconcileUnknownOutcome({
    required CloudOutboxOperation operation,
  }) async {
    reconcileUnknownCalls++;
    if (!operation.sameDurableSnapshotAs(this.operation)) {
      throw StateError('fake_unknown_recovery_operation_changed');
    }
    if (flushError != null) throw flushError!;
    return result;
  }

  Future<CloudSyncConfirmedReplayProof> verifyConfirmedNoSave({
    required CloudOutboxOperation operation,
  }) async {
    verifyNoSaveCalls++;
    if (operation.status != CloudOutboxStatus.confirmed) {
      throw StateError('fake_no_save_verification_requires_confirmed');
    }
    return _replayProof;
  }

  Future<void> finalizeConfirmedReplayProof({
    required CloudOutboxOperation operation,
    required CloudSyncConfirmedReplayProof proof,
  }) async {
    finalizeReplayCalls++;
    if (operation.status != CloudOutboxStatus.confirmed) {
      throw StateError('fake_replay_finalizer_requires_confirmed');
    }
    if (!identical(proof, _replayProof)) {
      throw StateError('fake_replay_finalizer_requires_exact_proof');
    }
  }

  List<CloudOutboxOperation> peekOutbox() {
    final custom = _outboxReads;
    if (custom != null && custom.isNotEmpty) return custom.first;
    return [operation];
  }

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
    if (flushCalls == 0 && reconcileUnknownCalls == 0) return [operation];
    if (result.counters.confirmed > 0) {
      return [
        operation.copyWith(
          status: CloudOutboxStatus.confirmed,
          appleRequestUuid: operation.appleRequestUuid ?? _requestUuid,
          appleOperationUuid: operation.appleOperationUuid ?? _operationUuid,
          confirmedAt: testEpoch.add(const Duration(seconds: 1)),
          clearNextEligibleAt: true,
          clearLastFailure: true,
          clearLeaseId: true,
          clearLeaseExpiresAt: true,
        ),
      ];
    }
    if (result.counters.quarantined > 0) {
      return [
        operation.copyWith(
          status: CloudOutboxStatus.quarantined,
          attemptCount: operation.attemptCount + 1,
          lastFailure: CloudFailureCategory.malformedRecord,
          clearNextEligibleAt: true,
          clearLeaseId: true,
          clearLeaseExpiresAt: true,
          clearProtectedLeaseReference: true,
        ),
      ];
    }
    if (result.counters.retried > 0) {
      return [
        operation.copyWith(
          status: CloudOutboxStatus.pending,
          attemptCount: operation.attemptCount + 1,
          nextEligibleAt: testEpoch.add(const Duration(minutes: 1)),
          lastFailure: CloudFailureCategory.server,
          clearSubmissionIdentity: true,
          clearLeaseId: true,
          clearLeaseExpiresAt: true,
        ),
      ];
    }
    return [
      operation.copyWith(
        status: CloudOutboxStatus.unknownOutcome,
        attemptCount: operation.attemptCount + 1,
        lastFailure: CloudFailureCategory.unknown,
        appleRequestUuid: operation.appleRequestUuid ?? _requestUuid,
        appleOperationUuid: operation.appleOperationUuid ?? _operationUuid,
        clearLeaseId: true,
        clearLeaseExpiresAt: true,
      ),
    ];
  }

  Future<void> quiesce() async {
    quiesceCalls++;
  }
}

final class _FreshWriteSessionFake
    implements CloudSyncOutboundCanaryWriteSession {
  const _FreshWriteSessionFake(this.delegate);

  final _SessionFake delegate;

  @override
  Future<CloudOutboxOperation> admitMessage({
    required frb_api.CloudMessage message,
    required DateTime createdAt,
  }) => delegate.admitMessage(message: message, createdAt: createdAt);

  @override
  Future<CloudSyncRunResult> flushOneBatch() => delegate.flushOneBatch();

  @override
  Future<List<CloudOutboxOperation>> readOutbox() => delegate.readOutbox();

  @override
  Future<void> quiesce() => delegate.quiesce();
}

final class _PendingRecoverySessionFake
    implements CloudSyncOutboundCanaryFlushSession {
  const _PendingRecoverySessionFake(this.delegate);

  final _SessionFake delegate;

  @override
  Future<CloudSyncRunResult> flushOneBatch() => delegate.flushOneBatch();

  @override
  Future<List<CloudOutboxOperation>> readOutbox() => delegate.readOutbox();

  @override
  Future<void> quiesce() => delegate.quiesce();
}

final class _UnknownRecoverySessionFake
    implements CloudSyncOutboundCanaryUnknownRecoverySession {
  const _UnknownRecoverySessionFake(this.delegate);

  final _SessionFake delegate;

  @override
  Future<CloudSyncRunResult> reconcileUnknownOutcome({
    required CloudOutboxOperation operation,
  }) => delegate.reconcileUnknownOutcome(operation: operation);

  @override
  Future<List<CloudOutboxOperation>> readOutbox() => delegate.readOutbox();

  @override
  Future<void> quiesce() => delegate.quiesce();
}

final class _ConfirmedReplaySessionFake
    implements CloudSyncOutboundCanaryReplaySession {
  const _ConfirmedReplaySessionFake(this.delegate);

  final _SessionFake delegate;

  @override
  Future<CloudSyncConfirmedReplayProof> verifyConfirmedNoSave({
    required CloudOutboxOperation operation,
  }) => delegate.verifyConfirmedNoSave(operation: operation);

  @override
  Future<void> finalizeConfirmedReplayProof({
    required CloudOutboxOperation operation,
    required CloudSyncConfirmedReplayProof proof,
  }) =>
      delegate.finalizeConfirmedReplayProof(operation: operation, proof: proof);

  @override
  Future<List<CloudOutboxOperation>> readOutbox() => delegate.readOutbox();

  @override
  Future<void> quiesce() => delegate.quiesce();
}

final class _FakeCloudMessage implements frb_api.CloudMessage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<CloudSyncOutboundCanaryConfirmation> _arm(
  CloudSyncManualOutboundCanary canary, {
  required frb_api.CloudMessage message,
  required DateTime createdAt,
}) => canary.armConfirmed(
  selectedCreatedAt: createdAt,
  revalidateAdmission: () async =>
      CloudSyncOutboundCanaryAdmission(message: message, createdAt: createdAt),
);
