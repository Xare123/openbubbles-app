import 'dart:convert';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_source_binding.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

String _a43(String c) => List.filled(43, c).join();
String _h64(String c) => List.filled(64, c).join();
String _lease(String c) => 'obcs2.lease.${List.filled(32, c).join()}';
void main() {
  test(
    'sealed retry seed owns ciphertext, never a fabricated file reference',
    () {
      final seed = CloudSyncReceivedArchiveSourceBinding.sealed(
        accountFingerprint: _a43('A'),
        protectedStoreIdentity: 'obcs2.store.${_a43('B')}',
        messageGuidHash: _h64('a'),
        sourceSha256: _h64('b'),
        ciphertext: 'obcs2.test.U3ludGhldGlj',
      );
      final restored = CloudSyncReceivedArchiveSourceBinding.decode(
        seed.encode(),
      );
      expect(restored.isSeed, isTrue);
      expect(restored.sealedSource, seed.sealedSource);
      expect(restored.protectedReference, isEmpty);
      expect(restored.leaseReference, isEmpty);
      expect(restored.toString(), isNot(contains(seed.sealedSource!)));
      final fields = jsonDecode(seed.encode()) as List;
      for (final edit in <int, Object>{
        0: 1,
        1: 'idsReceivedArchiveSource',
        6: 'raw text',
        7: _lease('a'),
        8: _h64('f'),
        9: seed.payloadLength + 1,
      }.entries) {
        final changed = List.of(fields)..[edit.key] = edit.value;
        expect(
          () =>
              CloudSyncReceivedArchiveSourceBinding.decode(jsonEncode(changed)),
          throwsStateError,
        );
      }
    },
  );
  final original = CloudSyncReceivedArchiveSourceBinding(
    accountFingerprint: _a43('A'),
    protectedStoreIdentity: 'obcs2.store.${_a43('B')}',
    messageGuidHash: _h64('a'),
    sourceSha256: _h64('b'),
    protectedReference: 'obcs2.ref.${_a43('C')}',
    leaseReference: _lease('d'),
    payloadSha256: _h64('e'),
    payloadLength: 500,
  );
  test('exact content-free received source binding round trips', () {
    expect(
      CloudSyncReceivedArchiveSourceBinding.decode(original.encode()).encode(),
      original.encode(),
    );
    expect(
      original.toString(),
      'CloudSyncReceivedArchiveSourceBinding(redacted)',
    );
  });
  test('native bridge descriptor keeps every bound field', () {
    final native = api.CloudSyncNativeReceivedArchiveSourceBinding(
      accountFingerprint: original.accountFingerprint,
      protectedStoreIdentity: original.protectedStoreIdentity,
      messageGuidHash: original.messageGuidHash,
      sourceSha256: original.sourceSha256,
      protectedReference: original.protectedReference,
      leaseReference: original.leaseReference,
      payloadSha256: original.payloadSha256,
      payloadLength: original.payloadLength,
    );
    expect(
      CloudSyncReceivedArchiveSourceBinding.fromNative(native).encode(),
      original.encode(),
    );
  });
  test('received binding rejects local-send tag', () {
    final fields = jsonDecode(original.encode()) as List;
    fields[1] = 'idsAttachmentSource';
    expect(
      () => CloudSyncReceivedArchiveSourceBinding.decode(jsonEncode(fields)),
      throwsStateError,
    );
  });
  test('rejects malformed fields', () {
    final base = jsonDecode(original.encode()) as List;
    final bad = <int, Object>{
      0: 2,
      1: 'outboundMessage',
      2: 'raw-account@example.test',
      3: 'C:/credentials',
      4: 'raw-guid',
      5: _h64('A'),
      6: 'obcs2.ref.../file',
      7: _lease('X'),
      8: 'invalid',
      9: 1024 * 1024 + 1,
    };
    for (final e in bad.entries) {
      final fields = List.of(base);
      fields[e.key] = e.value;
      expect(
        () => CloudSyncReceivedArchiveSourceBinding.decode(jsonEncode(fields)),
        throwsStateError,
        reason: 'field ${e.key}',
      );
    }
  });
  test('rejects noncanonical extra missing oversized invalid', () {
    final fields = jsonDecode(original.encode()) as List;
    final long = List.filled(2049, 'x').join();
    for (final value in <String>[
      ' ${original.encode()}',
      jsonEncode([...fields, 'extra']),
      jsonEncode(fields.sublist(1)),
      long,
      '{',
      'null',
      jsonEncode([...fields.take(9), 0]),
    ]) {
      expect(
        () => CloudSyncReceivedArchiveSourceBinding.decode(value),
        throwsStateError,
      );
    }
  });
  test('requireOrigin refuses differing origin', () {
    expect(
      () => original.requireOrigin(
        accountFingerprint: _a43('B'),
        messageGuidHash: _h64('a'),
        sourceSha256: _h64('b'),
      ),
      throwsStateError,
    );
    expect(
      () => original.requireOrigin(
        accountFingerprint: _a43('A'),
        messageGuidHash: _h64('f'),
        sourceSha256: _h64('b'),
      ),
      throwsStateError,
    );
    original.requireOrigin(
      accountFingerprint: _a43('A'),
      messageGuidHash: _h64('a'),
      sourceSha256: _h64('b'),
      protectedStoreIdentity: 'obcs2.store.${_a43('B')}',
    );
  });
}
