import 'dart:convert';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncLocalMutationSourceBinding validBinding({
  String? accountFingerprint,
  String? protectedStoreIdentity,
  String? mutationGuidHash,
  String? targetGuidHash,
  int? targetPart,
  String? sourceSha256,
  String? protectedReference,
  String? leaseReference,
  String? payloadSha256,
  int? payloadLength,
}) {
  return CloudSyncLocalMutationSourceBinding(
    accountFingerprint: accountFingerprint ?? 'A' * 43,
    protectedStoreIdentity: protectedStoreIdentity ?? 'obcs2.store.${'B' * 43}',
    mutationGuidHash: mutationGuidHash ?? 'a' * 64,
    targetGuidHash: targetGuidHash ?? 'b' * 64,
    targetPart: targetPart ?? 3,
    sourceSha256: sourceSha256 ?? 'c' * 64,
    protectedReference: protectedReference ?? 'obcs2.ref.${'C' * 43}',
    leaseReference: leaseReference ?? 'obcs2.lease.${'d' * 32}',
    payloadSha256: payloadSha256 ?? 'e' * 64,
    payloadLength: payloadLength ?? 500,
  );
}

void main() {
  test('exact content-free mutation source binding round trips', () {
    final original = validBinding();
    expect(
      CloudSyncLocalMutationSourceBinding.decode(original.encode()).encode(),
      original.encode(),
    );
    final decoded = CloudSyncLocalMutationSourceBinding.decode(
      original.encode(),
    );
    expect(decoded.accountFingerprint, original.accountFingerprint);
    expect(decoded.protectedStoreIdentity, original.protectedStoreIdentity);
    expect(decoded.mutationGuidHash, original.mutationGuidHash);
    expect(decoded.targetGuidHash, original.targetGuidHash);
    expect(decoded.targetPart, original.targetPart);
    expect(decoded.sourceSha256, original.sourceSha256);
    expect(decoded.protectedReference, original.protectedReference);
    expect(decoded.leaseReference, original.leaseReference);
    expect(decoded.payloadSha256, original.payloadSha256);
    expect(decoded.payloadLength, original.payloadLength);
  });

  test('toString is redacted and leaks no routing or body', () {
    final original = validBinding();
    final rendered = original.toString();
    expect(rendered, 'CloudSyncLocalMutationSourceBinding(redacted)');
    for (final secret in <String>[
      original.accountFingerprint,
      original.protectedStoreIdentity,
      original.mutationGuidHash,
      original.targetGuidHash,
      original.sourceSha256,
      original.protectedReference,
      original.leaseReference,
      original.payloadSha256,
    ]) {
      expect(rendered.contains(secret), isFalse);
    }
  });

  test('constructor rejects invalid field shapes', () {
    expect(
      () => validBinding(accountFingerprint: 'raw-account@example.test'),
      throwsStateError,
    );
    expect(() => validBinding(accountFingerprint: ''), throwsStateError);
    expect(
      () => validBinding(protectedStoreIdentity: 'C:/credentials'),
      throwsStateError,
    );
    expect(
      () => validBinding(protectedStoreIdentity: 'obcs2.store.short'),
      throwsStateError,
    );
    expect(() => validBinding(mutationGuidHash: 'raw-guid'), throwsStateError);
    expect(() => validBinding(targetGuidHash: 'raw-guid'), throwsStateError);
    expect(() => validBinding(mutationGuidHash: 'A' * 64), throwsStateError);
    expect(() => validBinding(targetGuidHash: 'B' * 64), throwsStateError);
    expect(
      () => validBinding(mutationGuidHash: 'a' * 64, targetGuidHash: 'a' * 64),
      throwsStateError,
    );
    expect(() => validBinding(targetPart: -1), throwsStateError);
    expect(() => validBinding(targetPart: 9007199254740992), throwsStateError);
    expect(() => validBinding(sourceSha256: 'invalid'), throwsStateError);
    expect(
      () => validBinding(protectedReference: 'obcs2.ref.../file'),
      throwsStateError,
    );
    expect(
      () => validBinding(leaseReference: 'obcs2.lease.${'X' * 32}'),
      throwsStateError,
    );
    expect(
      () => validBinding(leaseReference: 'obcs2.lease.short'),
      throwsStateError,
    );
    expect(() => validBinding(payloadSha256: 'invalid'), throwsStateError);
    expect(() => validBinding(payloadLength: 0), throwsStateError);
    expect(
      () => validBinding(payloadLength: 1024 * 1024 + 1),
      throwsStateError,
    );
  });

  test('constructor accepts boundary payload and part values', () {
    expect(validBinding(payloadLength: 1).payloadLength, 1);
    expect(validBinding(payloadLength: 1024 * 1024).payloadLength, 1024 * 1024);
    expect(validBinding(targetPart: 0).targetPart, 0);
    expect(
      validBinding(targetPart: 9007199254740991).targetPart,
      9007199254740991,
    );
  });

  test('decode rejects malformed version purpose and field types', () {
    final original = validBinding();
    final fields = jsonDecode(original.encode()) as List;
    final mutations = <int, Object>{
      0: 2,
      1: 'idsAttachmentSource',
      2: 'raw-account@example.test',
      3: 'C:/credentials',
      4: 'raw-guid',
      5: 'raw-guid',
      6: -1,
      7: 'invalid',
      8: 'obcs2.ref.../file',
      9: 'obcs2.lease.invalid',
      10: 'invalid',
      11: 1024 * 1024 + 1,
    };
    for (final entry in mutations.entries) {
      final mutated = List.of(fields);
      mutated[entry.key] = entry.value;
      expect(
        () => CloudSyncLocalMutationSourceBinding.decode(jsonEncode(mutated)),
        throwsStateError,
      );
    }
  });

  test('decode rejects mistyped part and length slots', () {
    final original = validBinding();
    final fields = jsonDecode(original.encode()) as List;
    final badSlots = <List<Object>>[
      [6, '3'],
      [6, 3.0],
      [6, 9007199254740992],
      [11, '500'],
      [11, 500.0],
      [11, 0],
      [0, '1'],
      [1, 'idsmutationsource'],
      [1, ' idsMutationSource'],
      [1, ''],
    ];
    for (final slot in badSlots) {
      final mutated = List.of(fields);
      mutated[slot[0] as int] = slot[1];
      expect(
        () => CloudSyncLocalMutationSourceBinding.decode(jsonEncode(mutated)),
        throwsStateError,
      );
    }
  });

  test('decode rejects identical mutation and target hashes', () {
    final original = validBinding();
    final fields = jsonDecode(original.encode()) as List;
    final mutated = List.of(fields);
    mutated[5] = mutated[4];
    expect(
      () => CloudSyncLocalMutationSourceBinding.decode(jsonEncode(mutated)),
      throwsStateError,
    );
  });

  test('decode rejects noncanonical extra missing oversized invalid JSON', () {
    final original = validBinding();
    final fields = jsonDecode(original.encode()) as List;
    final spaced = original.encode().replaceFirst(',', ', ');
    expect(spaced != original.encode(), isTrue);
    for (final value in <String>[
      ' ${original.encode()}',
      '${original.encode()} ',
      spaced,
      jsonEncode(<Object>[...fields, 'extra']),
      jsonEncode((List.of(fields)..removeLast())),
      jsonEncode(fields.sublist(1)),
      'x' * 4097,
      '{',
      'null',
      '{}',
      '[]',
      jsonEncode(<Object>[...fields.take(11), 0]),
      jsonEncode(<Object>[...fields.take(11), 1.5]),
      jsonEncode(<Object>[...fields.take(6), -1, ...fields.skip(7)]),
      jsonEncode(<Object>[...fields.take(6), 3.0, ...fields.skip(7)]),
    ]) {
      expect(
        () => CloudSyncLocalMutationSourceBinding.decode(value),
        throwsStateError,
      );
    }
  });

  test('decode accepts boundary payloads and parts rejects outside', () {
    List<dynamic> fieldsFor({
      required int payloadLength,
      required int targetPart,
    }) {
      final base = jsonDecode(validBinding().encode()) as List;
      base[6] = targetPart;
      base[11] = payloadLength;
      return base;
    }

    for (final good in <List<dynamic>>[
      fieldsFor(payloadLength: 1, targetPart: 0),
      fieldsFor(payloadLength: 1024 * 1024, targetPart: 0),
      fieldsFor(payloadLength: 500, targetPart: 9007199254740991),
    ]) {
      expect(
        CloudSyncLocalMutationSourceBinding.decode(jsonEncode(good)).encode(),
        jsonEncode(good),
      );
    }
    for (final bad in <List<dynamic>>[
      fieldsFor(payloadLength: 0, targetPart: 0),
      fieldsFor(payloadLength: 1024 * 1024 + 1, targetPart: 0),
      fieldsFor(payloadLength: 500, targetPart: -1),
      fieldsFor(payloadLength: 500, targetPart: 9007199254740992),
    ]) {
      expect(
        () => CloudSyncLocalMutationSourceBinding.decode(jsonEncode(bad)),
        throwsStateError,
      );
    }
  });

  test('requireOrigin pins every identity field including target part', () {
    final original = validBinding();
    expect(
      () => original.requireOrigin(
        accountFingerprint: original.accountFingerprint,
        mutationGuidHash: original.mutationGuidHash,
        targetGuidHash: original.targetGuidHash,
        targetPart: original.targetPart,
        sourceSha256: original.sourceSha256,
        protectedStoreIdentity: original.protectedStoreIdentity,
      ),
      returnsNormally,
    );
    expect(
      () => original.requireOrigin(
        accountFingerprint: original.accountFingerprint,
        mutationGuidHash: original.mutationGuidHash,
        targetGuidHash: original.targetGuidHash,
        targetPart: original.targetPart,
        sourceSha256: original.sourceSha256,
      ),
      returnsNormally,
    );
    expect(
      () => original.requireOrigin(
        accountFingerprint: 'Z' * 43,
        mutationGuidHash: original.mutationGuidHash,
        targetGuidHash: original.targetGuidHash,
        targetPart: original.targetPart,
        sourceSha256: original.sourceSha256,
        protectedStoreIdentity: original.protectedStoreIdentity,
      ),
      throwsStateError,
    );
    expect(
      () => original.requireOrigin(
        accountFingerprint: original.accountFingerprint,
        mutationGuidHash: original.mutationGuidHash,
        targetGuidHash: original.targetGuidHash,
        targetPart: original.targetPart,
        sourceSha256: original.sourceSha256,
        protectedStoreIdentity: 'obcs2.store.${'Z' * 43}',
      ),
      throwsStateError,
    );
    expect(
      () => original.requireOrigin(
        accountFingerprint: original.accountFingerprint,
        mutationGuidHash: 'f' * 64,
        targetGuidHash: original.targetGuidHash,
        targetPart: original.targetPart,
        sourceSha256: original.sourceSha256,
      ),
      throwsStateError,
    );
    expect(
      () => original.requireOrigin(
        accountFingerprint: original.accountFingerprint,
        mutationGuidHash: original.mutationGuidHash,
        targetGuidHash: 'f' * 64,
        targetPart: original.targetPart,
        sourceSha256: original.sourceSha256,
      ),
      throwsStateError,
    );
    expect(
      () => original.requireOrigin(
        accountFingerprint: original.accountFingerprint,
        mutationGuidHash: original.mutationGuidHash,
        targetGuidHash: original.targetGuidHash,
        targetPart: original.targetPart + 1,
        sourceSha256: original.sourceSha256,
      ),
      throwsStateError,
    );
    expect(
      () => original.requireOrigin(
        accountFingerprint: original.accountFingerprint,
        mutationGuidHash: original.mutationGuidHash,
        targetGuidHash: original.targetGuidHash,
        targetPart: original.targetPart,
        sourceSha256: 'f' * 64,
      ),
      throwsStateError,
    );
  });
}
