import 'dart:convert';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_record_observation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CloudSyncReceivedRecordObservation value(
    CloudSyncReceivedRecordState state,
  ) => CloudSyncReceivedRecordObservation(
    state: state,
    accountFingerprint: 'A' * 43,
    protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
    messageGuidHash: 'c' * 64,
    sourceSha256: 'd' * 64,
    logicalEntityKeyHash: 'L' * 43,
    serverRecordIdHash: 'R' * 43,
    generation: 7,
    parentBinding: 'parent-proof',
    observedAtMs: 100,
    etagHash: state.index < 3 ? 'E' * 43 : null,
    rawReference: state.index < 3 ? 'obcs2.ref.${'W' * 43}' : null,
    rawLeaseReference: state.index < 3 ? 'obcs2.lease.${'f' * 32}' : null,
  );
  for (final state in CloudSyncReceivedRecordState.values) {
    test('${state.name} has a canonical redacted bound representation', () {
      final original = value(state);
      final decoded = CloudSyncReceivedRecordObservation.decode(
        original.encode(),
      );
      expect(decoded.encode(), original.encode());
      expect(decoded.toString(), isNot(contains('parent-proof')));
    });
  }
  test('found needs raw version, absence cannot carry one', () {
    final encoded =
        jsonDecode(value(CloudSyncReceivedRecordState.equivalent).encode())
            as List;
    for (final index in [11, 12, 13]) {
      final changed = List.of(encoded)..[index] = null;
      expect(
        () => CloudSyncReceivedRecordObservation.decode(jsonEncode(changed)),
        throwsStateError,
      );
    }
    encoded[1] = CloudSyncReceivedRecordState.absent.index;
    expect(
      () => CloudSyncReceivedRecordObservation.decode(jsonEncode(encoded)),
      throwsStateError,
    );
  });

  test(
    'construction cannot persist an escaped binding the decoder rejects',
    () {
      expect(
        () => CloudSyncReceivedRecordObservation(
          state: CloudSyncReceivedRecordState.absent,
          accountFingerprint: 'A' * 43,
          protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
          messageGuidHash: 'c' * 64,
          sourceSha256: 'd' * 64,
          logicalEntityKeyHash: 'L' * 43,
          serverRecordIdHash: 'R' * 43,
          generation: 7,
          parentBinding: '\u0000' * 1536,
          observedAtMs: 100,
        ),
        throwsStateError,
      );
    },
  );
}
