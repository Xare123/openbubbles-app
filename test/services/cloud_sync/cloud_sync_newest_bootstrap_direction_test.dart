import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late Directory directory;
  late Store objectBox;
  late _DirectionTestProtector protector;
  late ObjectBoxCloudSyncStore store;
  final now = DateTime.utc(2026, 9, 15, 12);

  Future<void> reopen() async {
    objectBox.close();
    objectBox = await openStore(directory: directory.path);
    store = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: protector,
      clock: () => now,
    );
  }

  CloudSyncCheckpointEntity persisted(CloudSyncScope scope) =>
      objectBox.box<CloudSyncCheckpointEntity>().getAll().singleWhere(
        (row) =>
            row.accountFingerprint == scope.accountFingerprint &&
            row.container == scope.container &&
            row.database == scope.database &&
            row.zone == scope.zone &&
            row.streamKind == scope.streamKind.name &&
            row.schemaVersion == scope.schemaVersion &&
            row.persistenceLane == scope.persistenceLane.name,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-direction-',
    );
    objectBox = await openStore(directory: directory.path);
    protector = _DirectionTestProtector();
    store = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: protector,
      clock: () => now,
    );
  });

  tearDown(() async {
    if (!objectBox.isClosed()) objectBox.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('only fresh semantic V2 main zones start newest-first', () async {
    for (final zone in const <String>[
      'chatManateeZone',
      'messageManateeZone',
      'attachmentManateeZone',
    ]) {
      expect(
        (await store.readCheckpoint(_mainScope(zone: zone))).fetchDirection,
        CloudSyncFetchDirection.newestFirst,
        reason: zone,
      );
    }

    for (final scope in <CloudSyncScope>[
      _mainScope(
        zone: 'messageManateeZone',
        persistenceLane: CloudSyncPersistenceLane.shadow,
      ),
      _mainScope(zone: 'messageUpdateZone'),
      _mainScope(zone: 'messageManateeZone', container: 'other-container'),
      _mainScope(zone: 'messageManateeZone', schemaVersion: 1),
    ]) {
      expect(
        (await store.readCheckpoint(scope)).fetchDirection,
        CloudSyncFetchDirection.forward,
        reason: scope.storageKey,
      );
    }
  });

  test(
    'legacy null direction without read evidence binds newest-first durably',
    () async {
      final scope = _mainScope(zone: 'messageManateeZone');
      await store.readCheckpoint(scope);
      final row = persisted(scope)..fetchDirection = null;
      objectBox.box<CloudSyncCheckpointEntity>().put(row);

      expect(
        (await store.readCheckpoint(scope)).fetchDirection,
        CloudSyncFetchDirection.newestFirst,
      );
      expect(persisted(scope).fetchDirection, 'newestFirst');

      await reopen();
      expect(
        (await store.readCheckpoint(scope)).fetchDirection,
        CloudSyncFetchDirection.newestFirst,
      );
    },
  );

  test(
    'outbound-only revision evidence does not forfeit newest-first',
    () async {
      final scope = _mainScope(zone: 'chatManateeZone');
      await store.readCheckpoint(scope);
      final row = persisted(scope)
        ..fetchDirection = null
        ..mutationRevisionCounter = 9;
      objectBox.box<CloudSyncCheckpointEntity>().put(row);

      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchDirection, CloudSyncFetchDirection.newestFirst);
      expect(checkpoint.mutationRevisionCounter, 9);
    },
  );

  test('legacy null direction with a prior read token binds forward', () async {
    final scope = _mainScope(zone: 'attachmentManateeZone');
    await store.readCheckpoint(scope);
    final row = persisted(scope)
      ..fetchDirection = null
      ..fetchedTokenCiphertext = await protector.protect(
        scope: scope,
        kind: CloudSyncProtectedValueKind.checkpointToken,
        plaintext: 'existing-forward-token',
      );
    objectBox.box<CloudSyncCheckpointEntity>().put(row);

    final checkpoint = await store.readCheckpoint(scope);
    expect(checkpoint.fetchDirection, CloudSyncFetchDirection.forward);
    expect(checkpoint.fetchedToken, 'existing-forward-token');
    expect(persisted(scope).fetchDirection, 'forward');
  });

  test(
    'legacy null direction with prior attempt evidence binds forward',
    () async {
      final scope = _mainScope(
        zone: 'messageManateeZone',
        accountFingerprint: testAccountFingerprintB,
      );
      await store.readCheckpoint(scope);
      final row = persisted(scope)
        ..fetchDirection = null
        ..lastAttemptAtMs = 1;
      objectBox.box<CloudSyncCheckpointEntity>().put(row);

      expect(
        (await store.readCheckpoint(scope)).fetchDirection,
        CloudSyncFetchDirection.forward,
      );
    },
  );

  test('invalid persisted direction fails closed', () async {
    final scope = _mainScope(zone: 'messageManateeZone');
    await store.readCheckpoint(scope);
    objectBox.box<CloudSyncCheckpointEntity>().put(
      persisted(scope)..fetchDirection = 'sideways',
    );

    await expectLater(
      store.readCheckpoint(scope),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'checkpoint_fetch_direction_invalid',
        ),
      ),
    );
  });

  test('reset rebootstrap preserves the bound direction', () async {
    final scope = _mainScope(zone: 'messageManateeZone');
    final before = await store.readCheckpoint(scope);

    await store.rebootstrapAfterReset(
      CloudSyncResetRebootstrapRequest(
        scope: scope,
        transitionIdHash: '2' * 64,
        activeIdentityFingerprint: scope.accountFingerprint,
        expectedGeneration: before.generation,
        protectedRemoteStateProofReference: testProtectedReference('A'),
      ),
      now: now,
    );

    final after = await store.readCheckpoint(scope);
    expect(after.generation, before.generation + 1);
    expect(after.fetchDirection, CloudSyncFetchDirection.newestFirst);
    expect(persisted(scope).fetchDirection, 'newestFirst');
  });

  test('journal commit fence rejects a direction change', () async {
    final memory = InMemoryCloudSyncStore();
    final scope = _mainScope(zone: 'messageManateeZone');
    final checkpoint = await memory.readCheckpoint(scope);
    final fence = (await memory.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'direction-test',
      now: now,
      leaseDuration: const Duration(minutes: 1),
    ))!;

    await expectLater(
      memory.journalFetchedBatch(
        CloudFetchBatch(
          scope: scope,
          changes: const [],
          batchId: 'direction-mismatch-page',
          generation: checkpoint.generation,
          nextToken: null,
          hasMore: false,
        ),
        now: now,
        leaseFence: fence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
        expectedFetchDirection: CloudSyncFetchDirection.forward,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'checkpoint_fetch_direction_changed',
        ),
      ),
    );
    expect(await memory.inboxEntries(scope), isEmpty);
    expect(
      (await memory.readCheckpoint(scope)).fetchDirection,
      CloudSyncFetchDirection.newestFirst,
    );
  });
}

CloudSyncScope _mainScope({
  required String zone,
  String accountFingerprint = testAccountFingerprintA,
  String container = 'com.apple.messages.cloud',
  int schemaVersion = 2,
  CloudSyncPersistenceLane persistenceLane =
      CloudSyncPersistenceLane.semanticV2,
}) => CloudSyncScope(
  accountFingerprint: accountFingerprint,
  container: container,
  database: 'private',
  zone: zone,
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: schemaVersion,
  persistenceLane: persistenceLane,
);

final class _DirectionTestProtector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async => sha256
      .convert(utf8.encode('direction-test\u001f$rawAccountIdentifier'))
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
