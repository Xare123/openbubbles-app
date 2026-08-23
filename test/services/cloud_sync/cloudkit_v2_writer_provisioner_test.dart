import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late Directory objectBoxDirectory;
  late Directory privateStorageDirectory;
  late Store objectBox;
  late ObjectBoxCloudSyncStore cloudSyncStore;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitOperationInterlock interlock;
  late CloudKitWriterScope writerScope;
  late CloudSyncScope syncScope;
  late CloudSyncNativeAuthSnapshot expectedAuth;
  late CloudSyncNativeAuthSnapshot replacementAuth;
  late CloudKitV2WriterProvisioner provisioner;
  late Object expectedClient;
  late Object replacementClient;

  CloudKitWriterProvisioningMeasurements? suppliedMeasurements;
  var probeThrows = false;
  var quarantineThrows = false;
  var replaceAuthAfterFirstRead = false;
  var authReadCount = 0;

  final clock = DateTime.utc(2026, 8, 22, 12);
  const account = testAccountFingerprintA;
  const replacementAccount = testAccountFingerprintB;

  setUp(() async {
    objectBoxDirectory = await Directory.systemTemp.createTemp(
      'openbubbles-cloudkit-v2-provisioner-objectbox-',
    );
    privateStorageDirectory = await Directory.systemTemp.createTemp(
      'openbubbles-cloudkit-v2-provisioner-private-',
    );
    objectBox = await openStore(directory: objectBoxDirectory.path);
    cloudSyncStore = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: TestCloudSyncProtector(),
      clock: () => clock,
    );
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: objectBox,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    interlock = CloudKitOperationInterlock(
      privateStorageDirectory: privateStorageDirectory.path,
      fenceStore: cloudSyncStore,
      leaseDuration: const Duration(seconds: 5),
      heartbeatInterval: const Duration(seconds: 1),
    );
    writerScope = CloudKitWriterScope(accountFingerprint: account);
    syncScope = CloudSyncScope(
      accountFingerprint: account,
      container: 'messages-container',
      database: 'private',
      zone: 'message-zone',
      streamKind: CloudSyncStreamKind.messages,
    );

    expectedClient = Object();
    replacementClient = Object();
    expectedAuth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'session-a',
      accountFingerprint: account,
      protectedStoreIdentity: 'obcs2.store.${List.filled(43, 'A').join()}',
      cloudMessagesClient: expectedClient,
    );
    replacementAuth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'session-b',
      accountFingerprint: replacementAccount,
      protectedStoreIdentity: 'obcs2.store.${List.filled(43, 'B').join()}',
      cloudMessagesClient: replacementClient,
    );

    suppliedMeasurements = null;
    probeThrows = false;
    quarantineThrows = false;
    replaceAuthAfterFirstRead = false;
    authReadCount = 0;

    provisioner = CloudKitV2WriterProvisioner(
      authority: authority,
      interlock: interlock,
      readAuthSnapshot: () async {
        authReadCount++;
        if (replaceAuthAfterFirstRead && authReadCount >= 2) {
          return replacementAuth;
        }
        return expectedAuth;
      },
      quarantineLegacyDeletionQueues: () {
        if (quarantineThrows) {
          throw StateError('injected quarantine failure');
        }
      },
      readMeasurements: (scope) async {
        if (probeThrows) {
          throw StateError('injected probe failure');
        }
        final supplied = suppliedMeasurements;
        if (supplied != null) return supplied;
        return CloudKitWriterProvisioningMeasurements(
          objectBoxReady: true,
          legacySyncEnabled: false,
          legacySyncActive: false,
          backgroundSyncActive: false,
          coordinatorLeaseActive: false,
          pendingLegacyDeletionIntents: 0,
          legacyPreferenceQueueEntries: 0,
          unsyncedLegacyMessages: 0,
          unsyncedLegacyChats: 0,
          existingV2OutboxOperations: (await cloudSyncStore.readOutboxEntries(
            syncScope,
          )).length,
        );
      },
      clock: () => clock,
    );
  });

  tearDown(() async {
    if (!objectBox.isClosed()) objectBox.close();
    if (objectBoxDirectory.existsSync()) {
      await objectBoxDirectory.delete(recursive: true);
    }
    if (privateStorageDirectory.existsSync()) {
      await privateStorageDirectory.delete(recursive: true);
    }
  });

  test('fresh none to v2 persists epoch, readback, and permit', () async {
    final result = await provisioner.ensureV2Owned(expectedAuth: expectedAuth);

    expect(
      result.disposition,
      CloudKitV2WriterProvisioningDisposition.provisioned,
    );
    expect(result.snapshot.owner, CloudKitWriterOwner.v2);
    expect(result.snapshot.state, CloudKitWriterAuthorityState.stable);
    expect(result.snapshot.targetOwner, CloudKitWriterOwner.none);
    expect(result.snapshot.epoch, 2);
    expect(result.permit.owner, CloudKitWriterOwner.v2);
    expect(result.permit.epoch, 2);

    final readback = authority.read(writerScope);
    expect(readback?.owner, CloudKitWriterOwner.v2);
    expect(readback?.state, CloudKitWriterAuthorityState.stable);
    expect(readback?.epoch, 2);
    expect(authReadCount, 4);
  });

  test(
    'already-v2 is idempotent and returns the same epoch-bound permit',
    () async {
      final first = await provisioner.ensureV2Owned(expectedAuth: expectedAuth);
      final second = await provisioner.ensureV2Owned(
        expectedAuth: expectedAuth,
      );

      expect(
        second.disposition,
        CloudKitV2WriterProvisioningDisposition.alreadyOwned,
      );
      expect(second.snapshot.epoch, first.snapshot.epoch);
      expect(second.permit.epoch, first.permit.epoch);
      expect(second.snapshot.owner, CloudKitWriterOwner.v2);
    },
  );

  final failClosedCases =
      <
        ({
          String name,
          String safeCode,
          CloudKitWriterProvisioningMeasurements measurements,
        })
      >[
        (
          name: 'legacy sync enabled',
          safeCode: 'cloudkit_writer_transition_precondition_failed',
          measurements: _measurements(legacySyncEnabled: true),
        ),
        (
          name: 'background sync active',
          safeCode: 'cloudkit_writer_transition_precondition_failed',
          measurements: _measurements(backgroundSyncActive: true),
        ),
        (
          name: 'ObjectBox is unavailable',
          safeCode: 'cloudkit_writer_transition_precondition_failed',
          measurements: _measurements(objectBoxReady: false),
        ),
        (
          name: 'another coordinator is active',
          safeCode: 'cloudkit_writer_transition_precondition_failed',
          measurements: _measurements(coordinatorLeaseActive: true),
        ),
        (
          name: 'pending deletion count',
          safeCode: 'cloudkit_writer_transition_precondition_failed',
          measurements: _measurements(pendingLegacyDeletionIntents: 1),
        ),
        (
          name: 'legacy preference queue entries',
          safeCode: 'cloudkit_writer_transition_precondition_failed',
          measurements: _measurements(legacyPreferenceQueueEntries: 1),
        ),
      ];

  for (final failureCase in failClosedCases) {
    test('fails closed when ${failureCase.name}', () async {
      suppliedMeasurements = failureCase.measurements;

      await _expectFailure(
        provisioner.ensureV2Owned(expectedAuth: expectedAuth),
        failureCase.safeCode,
      );
      expect(authority.read(writerScope)?.owner, CloudKitWriterOwner.none);
    });
  }

  test(
    'unsynced markers stay diagnostic and inert under the V2-only build',
    () async {
      suppliedMeasurements = _measurements(
        unsyncedLegacyMessages: 7,
        unsyncedLegacyChats: 3,
      );

      final result = await provisioner.ensureV2Owned(
        expectedAuth: expectedAuth,
      );

      expect(
        result.disposition,
        CloudKitV2WriterProvisioningDisposition.provisioned,
      );
      expect(result.snapshot.owner, CloudKitWriterOwner.v2);
    },
  );

  test(
    'fails closed when an existing V2 outbox operation is present',
    () async {
      await cloudSyncStore.enqueueOutbox(testOutboxOperation(syncScope, 1));

      await _expectFailure(
        provisioner.ensureV2Owned(expectedAuth: expectedAuth),
        'cloudkit_writer_transition_precondition_failed',
      );
      expect((await cloudSyncStore.readOutboxEntries(syncScope)), hasLength(1));
      expect(authority.read(writerScope)?.owner, CloudKitWriterOwner.none);
    },
  );

  test('fails closed on an invalid negative preflight count', () async {
    suppliedMeasurements = _measurements(pendingLegacyDeletionIntents: -1);

    await _expectFailure(
      provisioner.ensureV2Owned(expectedAuth: expectedAuth),
      'cloudkit_writer_provisioning_measurements_invalid',
    );
    expect(authority.read(writerScope)?.owner, CloudKitWriterOwner.none);
  });

  test('fails closed when the preflight probe throws', () async {
    probeThrows = true;

    await _expectFailure(
      provisioner.ensureV2Owned(expectedAuth: expectedAuth),
      'cloudkit_writer_provisioning_probe_failed',
    );
    expect(authority.read(writerScope)?.owner, CloudKitWriterOwner.none);
  });

  test('fails closed when legacy queue quarantine throws', () async {
    quarantineThrows = true;

    await _expectFailure(
      provisioner.ensureV2Owned(expectedAuth: expectedAuth),
      'cloudkit_writer_legacy_queue_quarantine_failed',
    );
    expect(authority.read(writerScope)?.owner, CloudKitWriterOwner.none);
  });

  test('fails closed when the account or native client is replaced', () async {
    replaceAuthAfterFirstRead = true;

    await _expectFailure(
      provisioner.ensureV2Owned(expectedAuth: expectedAuth),
      'cloudkit_writer_identity_changed',
    );
    expect(authReadCount, 2);
    expect(authority.read(writerScope)?.owner, CloudKitWriterOwner.none);
  });

  test('requires manual recovery for a durable non-stable authority', () async {
    await interlock.runExclusive(
      kind: CloudKitOperationKind.writerTransition,
      action: () async {
        authority.initializeDisabled(writerScope, now: clock);
        final entity = objectBox
            .box<CloudKitWriterAuthorityEntity>()
            .getAll()
            .single;
        entity
          ..owner = 1
          ..state = 1
          ..targetOwner = 2
          ..transitionIdHash = testSha256('a')
          ..epoch = 2;
        objectBox.box<CloudKitWriterAuthorityEntity>().put(entity);
      },
    );

    await _expectFailure(
      provisioner.ensureV2Owned(expectedAuth: expectedAuth),
      'cloudkit_writer_authority_requires_manual_recovery',
    );
    expect(
      authority.read(writerScope)?.state,
      CloudKitWriterAuthorityState.migrationPrepared,
    );
  });
}

CloudKitWriterProvisioningMeasurements _measurements({
  bool objectBoxReady = true,
  bool legacySyncEnabled = false,
  bool legacySyncActive = false,
  bool backgroundSyncActive = false,
  bool coordinatorLeaseActive = false,
  int pendingLegacyDeletionIntents = 0,
  int legacyPreferenceQueueEntries = 0,
  int unsyncedLegacyMessages = 0,
  int unsyncedLegacyChats = 0,
  int existingV2OutboxOperations = 0,
}) => CloudKitWriterProvisioningMeasurements(
  objectBoxReady: objectBoxReady,
  legacySyncEnabled: legacySyncEnabled,
  legacySyncActive: legacySyncActive,
  backgroundSyncActive: backgroundSyncActive,
  coordinatorLeaseActive: coordinatorLeaseActive,
  pendingLegacyDeletionIntents: pendingLegacyDeletionIntents,
  legacyPreferenceQueueEntries: legacyPreferenceQueueEntries,
  unsyncedLegacyMessages: unsyncedLegacyMessages,
  unsyncedLegacyChats: unsyncedLegacyChats,
  existingV2OutboxOperations: existingV2OutboxOperations,
);

Future<void> _expectFailure(Future<Object?> operation, String safeCode) async {
  await expectLater(
    operation,
    throwsA(
      isA<CloudKitWriterAuthorityFailure>().having(
        (failure) => failure.safeCode,
        'safeCode',
        safeCode,
      ),
    ),
  );
}

final class TestCloudSyncProtector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async => sha256
      .convert(utf8.encode('test-hmac\u001f$rawAccountIdentifier'))
      .toString();

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async {
    final bound = '${scope.storageKey}\u001f${kind.name}\u001f$plaintext';
    return 'test-v1:${base64UrlEncode(utf8.encode(bound))}';
  }

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    if (!ciphertext.startsWith('test-v1:')) throw const FormatException();
    final decoded = utf8.decode(
      base64Url.decode(ciphertext.substring('test-v1:'.length)),
    );
    final prefix = '${scope.storageKey}\u001f${kind.name}\u001f';
    if (!decoded.startsWith(prefix)) throw const FormatException();
    return decoded.substring(prefix.length);
  }
}
