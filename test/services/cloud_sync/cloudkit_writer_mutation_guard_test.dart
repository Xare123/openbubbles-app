import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_adapters.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory directory;
  late Store store;
  late Object activeClient;
  late _FakeAuthBinding binding;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloudkit-writer-mutation-guard-',
    );
    store = await openStore(directory: directory.path);
    activeClient = Object();
    binding = _FakeAuthBinding();
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  CloudKitWriterOwnershipDecision decision(CloudKitWriterOwner owner) =>
      CloudKitWriterOwnershipDecision(owner: owner, configurationValid: true);

  ObjectBoxCloudKitWriterAuthority authority(CloudKitWriterOwner owner) =>
      ObjectBoxCloudKitWriterAuthority.forTest(
        store: store,
        buildDecision: decision(owner),
      );

  void provision(CloudKitWriterOwner owner) {
    final adapter = authority(CloudKitWriterOwner.none);
    final initial = adapter.initializeDisabled(_scope, now: _time(0));
    authority(owner).provisionInitialOwner(
      _scope,
      owner: owner,
      expectedEpoch: initial.epoch,
      evidence: _completeEvidence,
      now: _time(1),
    );
  }

  CloudKitWriterMutationGuard guard({
    CloudKitWriterOwner owner = CloudKitWriterOwner.legacy,
    Object? Function()? reader,
    CloudKitWriterReconciliationBinding? reconciler,
    frb_api.CloudSyncNativeSendReceiptContext? Function(CloudOutboxOperation)? parentContext,
    Future<frb_api.CloudSyncAttachmentParentGroupProof?> Function(CloudOutboxOperation)? groupProof,
  }) => CloudKitWriterMutationGuard.forTest(
    store: store,
    readActiveClient: reader ?? () => activeClient,
    privateStorageDirectory: directory.path,
    nativeAuthBinding: binding,
    reconciliationBinding: reconciler ?? binding,
    readAttachmentParentContext: parentContext,
    readAttachmentParentGroupProof: groupProof,
    buildDecision: decision(owner),
  );

  Future<T> runGuard<T>({
    Object? Function()? reader,
    required Future<T> Function() action,
  }) {
    return CloudKitOperationInterlock(
      privateStorageDirectory: directory.path,
      fenceStore: InMemoryCloudSyncStore(),
    ).runExclusive(
      kind: CloudKitOperationKind.legacyReadWrite,
      action: () => guard(
        reader: reader,
      ).run(owner: CloudKitWriterOwner.legacy, action: action),
    );
  }

  Future<T> runV2<T>(Future<T> Function() action) {
    return CloudKitOperationInterlock(
      privateStorageDirectory: directory.path,
      fenceStore: InMemoryCloudSyncStore(),
    ).runExclusive(kind: CloudKitOperationKind.v2ReadWrite, action: action);
  }

  Future<void> armUnknownV2Fence(CloudOutboxOperation operation) async {
    await expectLater(
      runV2(
        () => guard(owner: CloudKitWriterOwner.v2).runAuthorized<void>(
          owner: CloudKitWriterOwner.v2,
          expectedClient: activeClient,
          expectedAccountFingerprint: _cloudScope.accountFingerprint,
          preparedHandleBindingSha256: _sha('a'),
          reconciliationBindingSha256:
              cloudKitWriterReconciliationBindingSha256(operation),
          requireAdmission: () {},
          requireDurableAdmission: () async {},
          action: (capability) async {
            capability.consumeForNative();
            throw StateError('response_lost');
          },
        ),
      ),
      throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
    );
  }

  test(
    'matching durable owner uses lookup-only auth and permits one mutation',
    () async {
      provision(CloudKitWriterOwner.legacy);
      var actionCalls = 0;
      final value = await runGuard(
        action: () async {
          actionCalls++;
          return 42;
        },
      );

      expect(value, 42);
      expect(actionCalls, 1);
      expect(binding.captureCalls, 2);
      expect(binding.warmCalls, 0);
      expect(_persistentFence(directory).existsSync(), isFalse);
    },
  );

  test(
    'mutation guard refuses to run outside the operation interlock',
    () async {
      provision(CloudKitWriterOwner.legacy);
      var actionCalls = 0;
      await expectLater(
        guard().run(
          owner: CloudKitWriterOwner.legacy,
          action: () async => actionCalls++,
        ),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (value) => value.safeCode,
            'safeCode',
            'cloudkit_interlock_required',
          ),
        ),
      );
      expect(actionCalls, 0);
      expect(binding.captureCalls, 0);
      expect(binding.warmCalls, 0);
    },
  );

  test('missing authority fails before invoking the remote action', () async {
    var actionCalls = 0;
    await expectLater(
      runGuard(action: () async => actionCalls++),
      throwsA(_failure('cloudkit_writer_authority_missing')),
    );
    expect(actionCalls, 0);
  });

  test('missing active client fails before native capture or action', () async {
    var actionCalls = 0;
    await expectLater(
      runGuard(reader: () => null, action: () async => actionCalls++),
      throwsA(_failure('cloudkit_writer_active_client_missing')),
    );
    expect(binding.captureCalls, 0);
    expect(binding.warmCalls, 0);
    expect(actionCalls, 0);
  });

  test('client replacement during initial capture blocks the action', () async {
    provision(CloudKitWriterOwner.legacy);
    var actionCalls = 0;
    binding.afterCapture = (call) {
      if (call == 1) activeClient = Object();
    };
    await expectLater(
      runGuard(action: () async => actionCalls++),
      throwsA(_failure('cloudkit_writer_identity_changed_before_mutation')),
    );
    expect(actionCalls, 0);
  });

  test('v2 account mismatch blocks the action before arming a fence', () async {
    provision(CloudKitWriterOwner.v2);
    var actionCalls = 0;
    binding.metadataForCall = (_) => const CloudSyncNativeAuthMetadata(
      nativeSessionId: _digestB,
      accountFingerprint: _fingerprintB,
      protectedStoreIdentity: 'obcs2.store.$_digestB',
    );

    await expectLater(
      runV2(
        () => guard(owner: CloudKitWriterOwner.v2).runAuthorized<void>(
          owner: CloudKitWriterOwner.v2,
          expectedClient: activeClient,
          expectedAccountFingerprint: _cloudScope.accountFingerprint,
          preparedHandleBindingSha256: _sha('a'),
          reconciliationBindingSha256: _sha('b'),
          requireAdmission: () {},
          requireDurableAdmission: () async {},
          action: (_) async => actionCalls++,
        ),
      ),
      throwsA(_failure('cloudkit_writer_account_scope_mismatch')),
    );

    expect(actionCalls, 0);
    expect(_persistentFence(directory).existsSync(), isFalse);
    expect(
      authority(CloudKitWriterOwner.v2).read(_scope)!.state,
      CloudKitWriterAuthorityState.stable,
    );
  });

  test('client replacement after action becomes an unknown outcome', () async {
    provision(CloudKitWriterOwner.legacy);
    await expectLater(
      runGuard(
        action: () async {
          activeClient = Object();
        },
      ),
      throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
    );
    final snapshot = authority(CloudKitWriterOwner.legacy).read(_scope)!;
    expect(snapshot.state, CloudKitWriterAuthorityState.mutationUnknown);
    expect(
      () => authority(
        CloudKitWriterOwner.legacy,
      ).issuePermit(_scope, expectedOwner: CloudKitWriterOwner.legacy),
      throwsA(_failure('cloudkit_writer_authority_not_stable')),
    );
  });

  test('native identity replacement after action becomes unknown', () async {
    provision(CloudKitWriterOwner.legacy);
    binding.metadataForCall = (call) => call == 1
        ? _metadataA
        : const CloudSyncNativeAuthMetadata(
            nativeSessionId: _digestB,
            accountFingerprint: _fingerprintB,
            protectedStoreIdentity: 'obcs2.store.$_digestB',
          );
    await expectLater(
      runGuard(action: () async {}),
      throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
    );
    final snapshot = authority(CloudKitWriterOwner.legacy).read(_scope)!;
    expect(snapshot.state, CloudKitWriterAuthorityState.mutationUnknown);
    expect(
      () => authority(
        CloudKitWriterOwner.legacy,
      ).issuePermit(_scope, expectedOwner: CloudKitWriterOwner.legacy),
      throwsA(_failure('cloudkit_writer_authority_not_stable')),
    );
  });

  test('authority epoch replacement after action becomes unknown', () async {
    provision(CloudKitWriterOwner.legacy);
    await expectLater(
      runGuard(
        action: () async {
          final current = authority(CloudKitWriterOwner.legacy).read(_scope)!;
          authority(CloudKitWriterOwner.v2).prepareMigration(
            _scope,
            from: CloudKitWriterOwner.legacy,
            to: CloudKitWriterOwner.v2,
            expectedEpoch: current.epoch,
            transitionIdHash: _migrationId,
            evidence: _completeEvidence,
            now: _time(2),
          );
        },
      ),
      throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
    );
    final snapshot = authority(CloudKitWriterOwner.legacy).read(_scope)!;
    expect(snapshot.state, isNot(CloudKitWriterAuthorityState.stable));
    expect(
      () => authority(
        CloudKitWriterOwner.legacy,
      ).issuePermit(_scope, expectedOwner: CloudKitWriterOwner.legacy),
      throwsA(_failure('cloudkit_writer_authority_not_stable')),
    );
  });

  test(
    'remote action failure revokes authority as an unknown outcome',
    () async {
      provision(CloudKitWriterOwner.legacy);
      await expectLater(
        runGuard(action: () async => throw StateError('remote_failed')),
        throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
      );
      expect(binding.captureCalls, 1);
      expect(binding.warmCalls, 0);
      expect(_persistentFence(directory).existsSync(), isTrue);
      final snapshot = authority(CloudKitWriterOwner.legacy).read(_scope)!;
      expect(snapshot.state, CloudKitWriterAuthorityState.mutationUnknown);
      expect(
        () => authority(
          CloudKitWriterOwner.legacy,
        ).issuePermit(_scope, expectedOwner: CloudKitWriterOwner.legacy),
        throwsA(_failure('cloudkit_writer_authority_not_stable')),
      );
    },
  );

  test(
    'ObjectBox fence failure leaves a restart-stable filesystem poison',
    () async {
      provision(CloudKitWriterOwner.legacy);
      await expectLater(
        runGuard(
          action: () async {
            store.close();
            throw StateError('response_lost');
          },
        ),
        throwsA(_failure('cloudkit_writer_mutation_authority_fence_failed')),
      );
      expect(_persistentFence(directory).existsSync(), isTrue);

      store = await openStore(directory: directory.path);
      var replayCalls = 0;
      await expectLater(
        runGuard(action: () async => replayCalls++),
        throwsA(_failure('cloudkit_writer_mutation_reconciliation_required')),
      );
      expect(replayCalls, 0);
      expect(_persistentFence(directory).existsSync(), isTrue);
    },
  );

  test(
    'reconciliation rejects a different operation without releasing poison',
    () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation();
      await armUnknownV2Fence(operation);
      final unknown = authority(CloudKitWriterOwner.v2).read(_scope)!;
      expect(unknown.state, CloudKitWriterAuthorityState.mutationUnknown);

      final differentOperation = operation.copyWith(
        serverRecordIdHash: _hash('T'),
      );
      binding.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: differentOperation.encryptedPayloadReference,
      );
      await expectLater(
        runV2(
          () => guard(owner: CloudKitWriterOwner.v2).reconcileUnknownOutcome(
            owner: CloudKitWriterOwner.v2,
            expectedClient: activeClient,
            operation: differentOperation,
          ),
        ),
        throwsA(
          _failure('cloudkit_writer_mutation_reconciliation_fence_mismatch'),
        ),
      );

      expect(binding.reconcileCalls, 0);
      expect(_persistentFence(directory).existsSync(), isTrue);
      final stillUnknown = authority(CloudKitWriterOwner.v2).read(_scope)!;
      expect(stillUnknown.state, CloudKitWriterAuthorityState.mutationUnknown);
      expect(stillUnknown.epoch, unknown.epoch);
    },
  );

  test(
    'Chat exact readback uses its own binding and clears only its fence',
    () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation(
        zone: 'chatManateeZone',
        payloadVersion: 1,
      );
      await armUnknownV2Fence(operation);
      final chatBinding = _ChatReconciliationBinding();
      final result = await runV2(
        () => guard(owner: CloudKitWriterOwner.v2, reconciler: chatBinding)
            .reconcileUnknownOutcome(
              owner: CloudKitWriterOwner.v2,
              expectedClient: activeClient,
              operation: operation,
            ),
      );
      expect(result.disposition, CloudUnknownOutcomeDisposition.notApplied);
      expect(chatBinding.chatCalls, 1);
      expect(chatBinding.messageCalls, 0);
      expect(_persistentFence(directory).existsSync(), isFalse);
    },
  );

  frb_api.CloudSyncNativeSendReceiptContext parentContext({String? mismatch}) =>
      frb_api.CloudSyncNativeSendReceiptContext(
        storageDirectory: mismatch == 'directory' ? 'different' : directory.path,
        accountFingerprint: mismatch == 'account' ? _digestB : _metadataA.accountFingerprint,
        protectedStoreIdentity: mismatch == 'store' ? 'obcs2.store.$_digestB' : _metadataA.protectedStoreIdentity,
        nativeSessionId: mismatch == 'session' ? _digestB : _metadataA.nativeSessionId,
        guidHash: _sha('c'),
        sourceBinding: frb_api.CloudSyncNativeSendSourceBinding(
          protectedReference: 'obcs2.ref.${_hash('S')}',
          leaseReference: 'obcs2.lease.${'a' * 32}',
          payloadSha256: _sha('d'), payloadLength: BigInt.from(512),
          sourceSha256: _sha('e'),
        ),
      );

  test('unknown parent readback carries the original journal context', () async {
    provision(CloudKitWriterOwner.v2);
    final operation = _unknownOutcomeOperation();
    await armUnknownV2Fence(operation);
    final context = parentContext();
    binding.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: operation.encryptedPayloadReference,
    );
    final resolution = await runV2(() => guard(
      owner: CloudKitWriterOwner.v2,
      parentContext: (exact) {
        expect(exact.operationId, operation.operationId);
        return context;
      },
    ).reconcileUnknownOutcome(owner: CloudKitWriterOwner.v2,
      expectedClient: activeClient, operation: operation));
    expect(resolution.disposition, CloudUnknownOutcomeDisposition.notApplied);
    expect(binding.lastInput?.attachmentParentContext, same(context));
    expect(_persistentFence(directory).existsSync(), isFalse);
  });

  test('unknown group parent carries fresh proof with original context', () async {
    provision(CloudKitWriterOwner.v2);
    final operation = _unknownOutcomeOperation();
    await armUnknownV2Fence(operation);
    final proof = _GroupProof();
    var opened = 0;
    binding.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: operation.encryptedPayloadReference,
    );
    final result = await runV2(() => guard(
      owner: CloudKitWriterOwner.v2,
      parentContext: (_) => parentContext(),
      groupProof: (exact) async {
        expect(exact.operationId, operation.operationId);
        opened++;
        return proof;
      },
    ).reconcileUnknownOutcome(owner: CloudKitWriterOwner.v2,
      expectedClient: activeClient, operation: operation));
    expect(result.disposition, CloudUnknownOutcomeDisposition.notApplied);
    expect(opened, 1);
    expect(binding.lastInput?.attachmentParentGroupProof, same(proof));
    expect(_persistentFence(directory).existsSync(), isFalse);
  });

  for (final drift in ['source', 'client', 'missing_context']) {
    test('group proof $drift change cannot release unknown fence', () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation();
      await armUnknownV2Fence(operation);
      final originalClient = activeClient;
      var changed = false;
      await expectLater(runV2(() => guard(
        owner: CloudKitWriterOwner.v2,
        parentContext: (_) => drift == 'missing_context' ? null :
            parentContext(mismatch: changed && drift == 'source' ? 'store' : null),
        groupProof: (_) async {
          changed = true;
          if (drift == 'client') activeClient = Object();
          return _GroupProof();
        },
      ).reconcileUnknownOutcome(owner: CloudKitWriterOwner.v2,
        expectedClient: originalClient, operation: operation)),
        throwsA(isA<CloudKitWriterAuthorityFailure>()));
      expect(binding.reconcileCalls, 0);
      expect(_persistentFence(directory).existsSync(), isTrue);
    });
  }

  for (final mismatch in ['directory', 'account', 'store', 'session']) {
    test('unknown parent $mismatch drift cannot release the fence', () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation();
      await armUnknownV2Fence(operation);
      await expectLater(runV2(() => guard(
        owner: CloudKitWriterOwner.v2,
        parentContext: (_) => parentContext(mismatch: mismatch),
      ).reconcileUnknownOutcome(owner: CloudKitWriterOwner.v2,
        expectedClient: activeClient, operation: operation)),
        throwsA(_failure('cloudkit_writer_reconciliation_parent_context_mismatch')));
      expect(binding.reconcileCalls, 0);
      expect(_persistentFence(directory).existsSync(), isTrue);
    });
  }

  test(
    'Chat cannot fall back to a Message-only reconciliation binding',
    () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation(
        zone: 'chatManateeZone',
        payloadVersion: 1,
      );
      await armUnknownV2Fence(operation);
      await expectLater(
        runV2(
          () => guard(owner: CloudKitWriterOwner.v2).reconcileUnknownOutcome(
            owner: CloudKitWriterOwner.v2,
            expectedClient: activeClient,
            operation: operation,
          ),
        ),
        throwsA(
          _failure('cloudkit_writer_chat_reconciliation_binding_missing'),
        ),
      );
      expect(binding.reconcileCalls, 0);
      expect(_persistentFence(directory).existsSync(), isTrue);
    },
  );

  test(
    'Attachment exact readback uses its own binding and clears only its fence',
    () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation(
        zone: 'attachmentManateeZone',
        payloadVersion: 1,
      );
      await armUnknownV2Fence(operation);
      final attachmentBinding = _AttachmentReconciliationBinding();
      final result = await runV2(
        () =>
            guard(
              owner: CloudKitWriterOwner.v2,
              reconciler: attachmentBinding,
              parentContext: (_) => throw StateError('Attachment cannot read parent context'),
              groupProof: (_) => throw StateError('Attachment cannot read group proof'),
            ).reconcileUnknownOutcome(
              owner: CloudKitWriterOwner.v2,
              expectedClient: activeClient,
              operation: operation,
            ),
      );
      // Exact record absence resolves uncertainty about the final save. It
      // does not report that save as successful or authorize a byte re-upload.
      expect(result.disposition, CloudUnknownOutcomeDisposition.notApplied);
      expect(result.retryAfter, isNull);
      expect(attachmentBinding.attachmentCalls, 1);
      expect(attachmentBinding.messageCalls, 0);
      expect(_persistentFence(directory).existsSync(), isFalse);
    },
  );

  test(
    'attachment adapter preserves the real guard fence after unknown result',
    () async {
      provision(CloudKitWriterOwner.v2);
      final gate = GuardedCloudSyncAttachmentUploadMutationGate(
        guard(owner: CloudKitWriterOwner.v2),
      );
      var consumes = 0;
      Future<void> attempt(bool unknown) => runV2(
        () => gate.runAuthorized<void>(
          owner: CloudKitWriterOwner.v2,
          expectedClient: activeClient,
          expectedAccountFingerprint: _cloudScope.accountFingerprint,
          preparedHandleBindingSha256: _sha('a'),
          reconciliationBindingSha256: _sha('b'),
          requireAdmission: () {},
          requireDurableAdmission: () async {},
          action: (token) async {
            expect(token, matches(RegExp(r'^[a-f0-9]{64}$')));
            consumes++;
            if (unknown) gate.markActiveMutationUnknown();
          },
        ),
      );
      await attempt(false);
      expect(consumes, 1);
      expect(_persistentFence(directory).existsSync(), isFalse);
      await expectLater(
        attempt(true),
        throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
      );
      expect(consumes, 2);
      expect(_persistentFence(directory).existsSync(), isTrue);
      expect(
        authority(CloudKitWriterOwner.v2).read(_scope)!.state,
        CloudKitWriterAuthorityState.mutationUnknown,
      );
      await expectLater(
        attempt(false),
        throwsA(isA<CloudKitWriterAuthorityFailure>()),
      );
      expect(consumes, 2);
      expect(_persistentFence(directory).existsSync(), isTrue);
    },
  );

  test(
    'Attachment cannot fall back to Message-only or Chat-only bindings',
    () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation(
        zone: 'attachmentManateeZone',
        payloadVersion: 1,
      );
      await armUnknownV2Fence(operation);
      await expectLater(
        runV2(
          () => guard(owner: CloudKitWriterOwner.v2).reconcileUnknownOutcome(
            owner: CloudKitWriterOwner.v2,
            expectedClient: activeClient,
            operation: operation,
          ),
        ),
        throwsA(
          _failure('cloudkit_writer_attachment_reconciliation_binding_missing'),
        ),
      );
      expect(binding.reconcileCalls, 0);
      final chatBinding = _ChatReconciliationBinding();
      await expectLater(
        runV2(
          () => guard(owner: CloudKitWriterOwner.v2, reconciler: chatBinding)
              .reconcileUnknownOutcome(
                owner: CloudKitWriterOwner.v2,
                expectedClient: activeClient,
                operation: operation,
              ),
        ),
        throwsA(
          _failure('cloudkit_writer_attachment_reconciliation_binding_missing'),
        ),
      );
      expect(chatBinding.chatCalls, 0);
      expect(chatBinding.messageCalls, 0);
      expect(_persistentFence(directory).existsSync(), isTrue);
    },
  );

  test(
    'Attachment rejects wrong-scope identity before native lookup',
    () async {
      provision(CloudKitWriterOwner.v2);
      // The operation id stays bound to the message scope while the operation
      // itself claims the attachment scope.
      final operation = _unknownOutcomeOperation(
        zone: 'attachmentManateeZone',
        payloadVersion: 1,
        operationIdZone: 'messageManateeZone',
      );
      final attachmentBinding = _AttachmentReconciliationBinding();
      await expectLater(
        runV2(
          () =>
              guard(
                owner: CloudKitWriterOwner.v2,
                reconciler: attachmentBinding,
              ).reconcileUnknownOutcome(
                owner: CloudKitWriterOwner.v2,
                expectedClient: activeClient,
                operation: operation,
              ),
        ),
        throwsA(
          _failure('cloudkit_writer_mutation_reconciliation_operation_invalid'),
        ),
      );
      expect(attachmentBinding.attachmentCalls, 0);
      expect(attachmentBinding.messageCalls, 0);
    },
  );
  for (final invalid in [
    ('chatManateeZone', 2),
    ('messageManateeZone', 1),
    ('attachmentManateeZone', 2),
  ]) {
    test(
      'reconciliation rejects zone/payload mismatch $invalid before native lookup',
      () async {
        provision(CloudKitWriterOwner.v2);
        final operation = _unknownOutcomeOperation(
          zone: invalid.$1,
          payloadVersion: invalid.$2,
        );
        await expectLater(
          runV2(
            () => guard(owner: CloudKitWriterOwner.v2).reconcileUnknownOutcome(
              owner: CloudKitWriterOwner.v2,
              expectedClient: activeClient,
              operation: operation,
            ),
          ),
          throwsA(
            _failure(
              'cloudkit_writer_mutation_reconciliation_operation_invalid',
            ),
          ),
        );
        expect(binding.reconcileCalls, 0);
      },
    );
  }

  test('legacy version-two mutation fence fails closed', () async {
    final stable = () {
      provision(CloudKitWriterOwner.v2);
      return authority(CloudKitWriterOwner.v2).read(_scope)!;
    }();
    _persistentFence(directory).writeAsStringSync('{"version":2}');
    final operation = _unknownOutcomeOperation();

    await expectLater(
      runV2(
        () => guard(owner: CloudKitWriterOwner.v2).requireReconciliationAllowed(
          owner: CloudKitWriterOwner.v2,
          expectedClient: activeClient,
          operation: operation,
        ),
      ),
      throwsA(_failure('cloudkit_writer_mutation_fence_corrupt')),
    );

    expect(_persistentFence(directory).existsSync(), isTrue);
    final unchanged = authority(CloudKitWriterOwner.v2).read(_scope)!;
    expect(unchanged.state, CloudKitWriterAuthorityState.stable);
    expect(unchanged.epoch, stable.epoch);
  });

  test(
    'committed reconciliation returns a bound receipt and clears poison',
    () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation();
      await armUnknownV2Fence(operation);
      binding.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: operation.encryptedPayloadReference,
        serverRecordIdHash: _hash('S'),
        etagHash: _hash('E'),
      );

      final resolution = await runV2(
        () => guard(owner: CloudKitWriterOwner.v2).reconcileUnknownOutcome(
          owner: CloudKitWriterOwner.v2,
          expectedClient: activeClient,
          operation: operation,
        ),
      );

      expect(resolution.disposition, CloudUnknownOutcomeDisposition.committed);
      expect(resolution.failureCategory, isNull);
      expect(resolution.retryAfter, isNull);
      expect(resolution.createReceipt, isNotNull);
      expect(resolution.createReceipt!.operationId, operation.operationId);
      expect(
        resolution.createReceipt!.logicalEntityKeyHash,
        operation.logicalEntityKeyHash,
      );
      expect(
        resolution.createReceipt!.serverRecordIdHash,
        operation.serverRecordIdHash,
      );
      expect(resolution.createReceipt!.etagHash, _hash('E'));
      expect(binding.reconcileCalls, 1);
      expect(_persistentFence(directory).existsSync(), isFalse);
      final stable = authority(CloudKitWriterOwner.v2).read(_scope)!;
      expect(stable.state, CloudKitWriterAuthorityState.stable);
    },
  );

  test(
    'committed reconciliation without receipt hashes keeps poison',
    () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation();
      await armUnknownV2Fence(operation);
      final unknown = authority(CloudKitWriterOwner.v2).read(_scope)!;
      expect(unknown.state, CloudKitWriterAuthorityState.mutationUnknown);
      binding.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: operation.encryptedPayloadReference,
      );

      await expectLater(
        runV2(
          () => guard(owner: CloudKitWriterOwner.v2).reconcileUnknownOutcome(
            owner: CloudKitWriterOwner.v2,
            expectedClient: activeClient,
            operation: operation,
          ),
        ),
        throwsA(_failure('cloudkit_writer_reconciliation_receipt_invalid')),
      );

      expect(binding.reconcileCalls, 1);
      expect(_persistentFence(directory).existsSync(), isTrue);
      final stillUnknown = authority(CloudKitWriterOwner.v2).read(_scope)!;
      expect(stillUnknown.state, CloudKitWriterAuthorityState.mutationUnknown);
      expect(stillUnknown.epoch, unknown.epoch);
    },
  );

  test(
    'committed reconciliation with a swapped server hash keeps poison',
    () async {
      provision(CloudKitWriterOwner.v2);
      final operation = _unknownOutcomeOperation();
      await armUnknownV2Fence(operation);
      final unknown = authority(CloudKitWriterOwner.v2).read(_scope)!;
      expect(unknown.state, CloudKitWriterAuthorityState.mutationUnknown);
      binding.reconcileResult = frb_api.CloudSyncOutboundReconcileResult(
        disposition: frb_api.CloudSyncOutboundReconcileDisposition.committed,
        protectedProofReference: operation.encryptedPayloadReference,
        serverRecordIdHash: _hash('T'),
        etagHash: _hash('E'),
      );

      await expectLater(
        runV2(
          () => guard(owner: CloudKitWriterOwner.v2).reconcileUnknownOutcome(
            owner: CloudKitWriterOwner.v2,
            expectedClient: activeClient,
            operation: operation,
          ),
        ),
        throwsA(_failure('cloudkit_writer_reconciliation_receipt_mismatch')),
      );

      expect(binding.reconcileCalls, 1);
      expect(_persistentFence(directory).existsSync(), isTrue);
      final stillUnknown = authority(CloudKitWriterOwner.v2).read(_scope)!;
      expect(stillUnknown.state, CloudKitWriterAuthorityState.mutationUnknown);
      expect(stillUnknown.epoch, unknown.epoch);
    },
  );
}

final class _FakeAuthBinding
    implements CloudSyncNativeAuthBinding, CloudKitWriterReconciliationBinding {
  int captureCalls = 0;
  int warmCalls = 0;
  int pausedWarmCalls = 0;
  int reconcileCalls = 0;
  frb_api.CloudSyncPreparedMessageCreateInput? lastInput;
  void Function(int call)? afterCapture;
  CloudSyncNativeAuthMetadata Function(int call)? metadataForCall;
  frb_api.CloudSyncOutboundReconcileResult reconcileResult =
      const frb_api.CloudSyncOutboundReconcileResult(
        failure: frb_api.CloudSyncOutboundSafeCode.invalidRequest,
      );

  @override
  Future<void> ensureReadAuthentication({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async {}

  @override
  Future<void> warmReadAuthentication({
    required Object cloudMessagesClient,
  }) async {
    warmCalls++;
  }

  @override
  Future<void> warmReadAuthenticationUnderWriterPause({
    required Object cloudMessagesClient,
    required BigInt pauseToken,
  }) async {
    pausedWarmCalls++;
  }

  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async {
    captureCalls++;
    final metadata = metadataForCall?.call(captureCalls) ?? _metadataA;
    afterCapture?.call(captureCalls);
    return metadata;
  }

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    reconcileCalls++;
    lastInput = input;
    return reconcileResult;
  }
}

class _GroupProof implements frb_api.CloudSyncAttachmentParentGroupProof {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ChatReconciliationBinding
    implements CloudKitWriterChatReconciliationBinding {
  int chatCalls = 0;
  int messageCalls = 0;

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileChatCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    chatCalls++;
    return frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: input.protectedPayloadReference,
    );
  }

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    messageCalls++;
    throw StateError('Chat must not use Message reconciliation');
  }
}

final class _AttachmentReconciliationBinding
    implements CloudKitWriterAttachmentReconciliationBinding {
  int attachmentCalls = 0;
  int messageCalls = 0;

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileAttachmentCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    attachmentCalls++;
    return frb_api.CloudSyncOutboundReconcileResult(
      disposition: frb_api.CloudSyncOutboundReconcileDisposition.notApplied,
      protectedProofReference: input.protectedPayloadReference,
    );
  }

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    messageCalls++;
    throw StateError('Attachment must not use Message reconciliation');
  }
}

Matcher _failure(String safeCode) => isA<CloudKitWriterAuthorityFailure>()
    .having((value) => value.safeCode, 'safeCode', safeCode);

File _persistentFence(Directory directory) => File(
  path.join(directory.path, '.openbubbles-cloudkit-writer-mutation-v1.fence'),
);

DateTime _time(int seconds) => DateTime.utc(2026, 8, 22, 12, 0, seconds);

const _digestA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _digestB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _fingerprintB = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const _metadataA = CloudSyncNativeAuthMetadata(
  nativeSessionId: _digestA,
  accountFingerprint: _digestA,
  protectedStoreIdentity: 'obcs2.store.$_digestA',
);
final _scope = CloudKitWriterScope(accountFingerprint: _digestA);
final _cloudScope = CloudSyncScope(
  accountFingerprint: _digestA,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semanticV2,
);
const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);
const _migrationId =
    '3333333333333333333333333333333333333333333333333333333333333333';

CloudOutboxOperation _unknownOutcomeOperation({
  String zone = 'messageManateeZone',
  int payloadVersion = cloudSyncOutboundPayloadVersion,
  // Optional zone the operation id is bound to. When set, the id is
  // generated for that zone while the operation claims [zone], proving
  // cross-scope identities fail before any native lookup.
  String? operationIdZone,
}) {
  final logicalEntityKeyHash = _hash('L');
  final scope = CloudSyncScope(
    accountFingerprint: _digestA,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: zone,
    persistenceLane: CloudSyncPersistenceLane.semanticV2,
  );
  final idScope = operationIdZone == null
      ? scope
      : CloudSyncScope(
          accountFingerprint: _digestA,
          container: 'com.apple.messages.cloud',
          database: 'private',
          zone: operationIdZone,
          persistenceLane: CloudSyncPersistenceLane.semanticV2,
        );
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: idScope,
      logicalEntityKeyHash: logicalEntityKeyHash,
      payloadVersion: payloadVersion,
    ),
    logicalEntityKeyHash: logicalEntityKeyHash,
    action: CloudOutboxAction.save,
    payloadVersion: payloadVersion,
    mutationRevision: 1,
    checkpointGeneration: 1,
    encryptedPayloadReference: _reference('P'),
    payloadSha256: _sha('b'),
    serverRecordIdHash: _hash('S'),
    protectedLeaseReference: _lease('a'),
    appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
    dependencyOperationIds: const {},
    createdAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
    status: CloudOutboxStatus.unknownOutcome,
    attemptCount: 1,
  );
}

String _repeat(String character, int length) =>
    List.filled(length, character).join();
String _hash(String character) => _repeat(character, 43);
String _sha(String character) => _repeat(character, 64);
String _reference(String character) => 'obcs2.ref.${_hash(character)}';
String _lease(String character) => 'obcs2.lease.${_repeat(character, 32)}';
