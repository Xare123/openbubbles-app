import 'dart:convert';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final original = CloudSyncLocalSendSourceBinding(
    accountFingerprint: 'A' * 43,
    protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
    messageGuidHash: 'a' * 64,
    sourceSha256: 'b' * 64,
    protectedReference: 'obcs2.ref.${'C' * 43}',
    leaseReference: 'obcs2.lease.${'d' * 32}',
    payloadSha256: 'e' * 64,
    payloadLength: 500,
  );
  test('exact content-free source binding round trips', () {
    expect(
      CloudSyncLocalSendSourceBinding.decode(original.encode()).encode(),
      original.encode(),
    );
    expect(original.toString(), 'CloudSyncLocalSendSourceBinding(redacted)');
  });
  final mutations = <int, Object>{
    0: 2,
    1: 'outboundMessage',
    2: 'raw-account@example.test',
    3: 'C:/credentials',
    4: 'raw-guid',
    5: 'A' * 64,
    6: 'obcs2.ref.../file',
    7: 'obcs2.lease.${'X' * 32}',
    8: 'invalid',
    9: 1024 * 1024 + 1,
  };
  for (final mutation in mutations.entries) {
    test('rejects malformed binding field ${mutation.key}', () {
      final fields = jsonDecode(original.encode()) as List;
      fields[mutation.key] = mutation.value;
      expect(
        () => CloudSyncLocalSendSourceBinding.decode(jsonEncode(fields)),
        throwsStateError,
      );
    });
  }
  test('rejects noncanonical, extra, missing, oversized and invalid JSON', () {
    final fields = jsonDecode(original.encode()) as List;
    for (final value in [
      ' ${original.encode()}',
      jsonEncode([...fields, 'extra']),
      jsonEncode(fields.sublist(1)),
      'x' * 2049,
      '{',
      'null',
      jsonEncode([...fields.take(9), 0]),
      jsonEncode([...fields.take(9), 1.5]),
    ]) {
      expect(
        () => CloudSyncLocalSendSourceBinding.decode(value),
        throwsStateError,
      );
    }
  });
}
