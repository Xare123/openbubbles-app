import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_exact_message_reader.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncShadowPreflightState _state(int count, [String? fingerprint]) =>
    CloudSyncShadowPreflightState(
      platformSupported: true, uiIsolate: true, rustPushReady: true,
      objectBoxReady: true, privateStorageExists: true, logoutActive: false,
      legacySyncEnabled: false, legacySyncActive: false,
      coordinatorLeaseActive: false, outboxCount: count,
      protectorSentinelValid: true, settledOutboxFingerprint: fingerprint,
    );

Matcher _code(String code) => throwsA(isA<StateError>().having(
  (error) => error.message, 'closed code', code,
));

void main() {
  test('settled retained audit rows admit exactly one read without queue mutation', () async {
    final state = _state(30, 'a' * 64);
    var reads = 0;
    var probes = 0;
    final value = await withCloudSyncExactReadOutbox(
      readPreflight: () async { probes++; return state; },
      stillCurrent: () => true,
      read: () async { reads++; return CloudSyncExactMessageReadDisposition.retained; },
    );
    expect(value, CloudSyncExactMessageReadDisposition.retained);
    expect(reads, 1);
    expect(probes, 2);
    expect(state.outboxCount, 30);
    expect(state.settledOutboxFingerprint, 'a' * 64);
  });

  test('an empty outbox keeps the existing exact read path', () async {
    var reads = 0;
    expect(await withCloudSyncExactReadOutbox(
      readPreflight: () async => _state(0), stillCurrent: () => true,
      read: () async { reads++; return CloudSyncExactMessageReadDisposition.absent; },
    ), CloudSyncExactMessageReadDisposition.absent);
    expect(reads, 1);
  });

  test('unsettled malformed and unreportable snapshots never enter the read', () async {
    for (final state in [_state(1), _state(30, 'bad'), _state(65536, 'a' * 64), _state(-1, 'a' * 64)]) {
      var reads = 0;
      await expectLater(withCloudSyncExactReadOutbox(
        readPreflight: () async => state, stillCurrent: () => true,
        read: () async { reads++; return true; },
      ), _code('cloud_sync_exact_read_outbox_unsettled'));
      expect(reads, 0);
    }
  });

  test('count fingerprint and settlement changes trip the same post-read fence', () async {
    for (final after in [_state(29, 'a' * 64), _state(30, 'b' * 64), _state(30), _state(0)]) {
      var probes = 0;
      var reads = 0;
      await expectLater(withCloudSyncExactReadOutbox(
        readPreflight: () async => probes++ == 0 ? _state(30, 'a' * 64) : after,
        stillCurrent: () => true,
        read: () async { reads++; return true; },
      ), _code('cloud_sync_semantic_remote_write_tripwire'));
      expect(reads, 1);
      expect(probes, 2);
    }
  });

  test('account continuation loss still rejects the completed read', () async {
    await expectLater(withCloudSyncExactReadOutbox(
      readPreflight: () async => _state(30, 'a' * 64), stillCurrent: () => false,
      read: () async => true,
    ), _code('cloud_sync_semantic_remote_write_tripwire'));
  });

  test('read exceptions propagate without treating them as absence or success', () async {
    final failure = Object();
    var probes = 0;
    await expectLater(withCloudSyncExactReadOutbox(
      readPreflight: () async { probes++; return _state(30, 'a' * 64); },
      stillCurrent: () => true, read: () async => throw failure,
    ), throwsA(same(failure)));
    expect(probes, 1);
  });

  test('production ObjectBox settlement admits audits and rejects uncertain rows without changing them', () async {
    final directory = Directory.systemTemp.createTempSync('cloud-sync-exact-outbox-');
    final store = Store(getObjectBoxModel(), directory: directory.path);
    try {
      final box = store.box<CloudOutboxOperationEntity>();
      CloudOutboxOperationEntity audit() => CloudOutboxOperationEntity(
        operationId: 'audit', scopeKey: 'scope', accountFingerprint: 'A' * 43,
        zone: 'messageManateeZone', logicalEntityKeyHash: 'logical',
        action: 0, mutationRevision: 1, checkpointGeneration: 1, state: 2,
        encryptedPayloadRef: 'protected-payload', payloadSha256: 'payload-hash',
        serverRecordIdHash: 'server-hash', confirmedAtMs: 100,
        createdAtMs: 100, updatedAtMs: 100,
      );
      final id = box.put(audit());
      final reader = ObjectBoxCloudSyncPreflightReader(store: store);
      Future<CloudSyncShadowPreflightState> preflight() async {
        final local = reader.read();
        return _state(local.outboxCount, local.settledOutboxFingerprint);
      }
      final original = reader.read().settledOutboxFingerprint;
      expect(original, matches(r'^[a-f0-9]{64}$'));
      var reads = 0;
      expect(await withCloudSyncExactReadOutbox(
        readPreflight: preflight, stillCurrent: () => true,
        read: () async { reads++; return true; },
      ), true);
      expect(reads, 1);
      expect(reader.read().settledOutboxFingerprint, original);
      expect(box.count(), 1);
      for (final change in <void Function(CloudOutboxOperationEntity)>[
        (row) => row.state = 0,
        (row) => row.state = 1,
        (row) => row.state = 3,
        (row) => row.protectedLeaseReference = 'unacknowledged-lease',
        (row) => row.leaseIdHash = 'live-lease',
        (row) => row.lastErrorCategory = 'outcome_uncertain',
        (row) => row.confirmedAtMs = 0,
        (row) => row.serverRecordIdHash = null,
      ]) {
        final row = audit()..id = id;
        change(row);
        box.put(row);
        reads = 0;
        await expectLater(withCloudSyncExactReadOutbox(
          readPreflight: preflight, stillCurrent: () => true,
          read: () async { reads++; return true; },
        ), _code('cloud_sync_exact_read_outbox_unsettled'));
        expect(reads, 0);
        final retained = box.get(id)!;
        expect(retained.state, row.state);
        expect(retained.protectedLeaseReference, row.protectedLeaseReference);
        expect(retained.leaseIdHash, row.leaseIdHash);
        expect(retained.lastErrorCategory, row.lastErrorCategory);
        expect(retained.confirmedAtMs, row.confirmedAtMs);
        expect(retained.serverRecordIdHash, row.serverRecordIdHash);
        expect(box.count(), 1);
      }
    } finally {
      store.close();
      expect(directory.absolute.parent.path, Directory.systemTemp.absolute.path);
      expect(directory.uri.pathSegments.where((p) => p.isNotEmpty).last, startsWith('cloud-sync-exact-outbox-'));
      directory.deleteSync(recursive: true);
    }
  });
}
