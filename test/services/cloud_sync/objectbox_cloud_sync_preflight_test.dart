import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_preflight.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

void main() {
  late Directory temporaryDirectory;
  late Store store;
  late ObjectBoxCloudSyncPreflightReader reader;
  final now = DateTime.utc(2026, 8, 2);

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'cloud-sync-preflight-objectbox-',
    );
    store = Store(getObjectBoxModel(), directory: temporaryDirectory.path);
    reader = ObjectBoxCloudSyncPreflightReader(store: store, now: () => now);
  });

  tearDown(() {
    if (!store.isClosed()) store.close();
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test('empty store is one coherent ready snapshot', () {
    final state = reader.read();

    expect(state.objectBoxReady, isTrue);
    expect(state.coordinatorLeaseActive, isFalse);
    expect(state.outboxCount, 0);
  });

  test('only an unexpired coordinator lease blocks the sampler', () {
    final leases = store.box<CloudSyncLeaseEntity>();
    leases.put(
      CloudSyncLeaseEntity(
        leaseKey: 'expired',
        scopeKey: 'scope',
        accountFingerprint: _fingerprint,
        ownerIdHash: 'owner',
        generation: 1,
        acquiredAtMs: now
            .subtract(const Duration(minutes: 2))
            .millisecondsSinceEpoch,
        expiresAtMs: now
            .subtract(const Duration(seconds: 1))
            .millisecondsSinceEpoch,
      ),
    );
    expect(reader.read().coordinatorLeaseActive, isFalse);

    leases.put(
      CloudSyncLeaseEntity(
        leaseKey: 'active',
        scopeKey: 'scope',
        accountFingerprint: _fingerprint,
        ownerIdHash: 'owner',
        generation: 2,
        acquiredAtMs: now.millisecondsSinceEpoch,
        expiresAtMs: now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      ),
    );
    expect(reader.read().coordinatorLeaseActive, isTrue);
  });

  test('counts every durable V2 outbox row', () {
    store.box<CloudOutboxOperationEntity>().put(
      CloudOutboxOperationEntity(
        operationId: 'operation',
        scopeKey: 'scope',
        accountFingerprint: _fingerprint,
        zone: 'messageManateeZone',
        logicalEntityKeyHash: 'logical',
        action: 0,
        mutationRevision: 1,
        createdAtMs: now.millisecondsSinceEpoch,
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );

    expect(reader.read().outboxCount, 1);
  });

  test(
    'closed-store failure becomes a fully blocking production state',
    () async {
      store.close();
      final probe = CloudSyncProductionPreflightProbe(
        platformSupported: () => true,
        uiIsolate: () => true,
        rustPushReady: () => true,
        localState: reader.read,
        privateStorageExists: () => true,
        logoutActive: () => false,
        legacySyncEnabled: () => false,
        legacySyncActive: () => false,
        protectorSentinelValid: () => true,
      );

      final state = await probe.read();
      expect(state.objectBoxReady, isFalse);
      expect(state.coordinatorLeaseActive, isTrue);
      expect(state.outboxCount, -1);
    },
  );
}

const _fingerprint = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
