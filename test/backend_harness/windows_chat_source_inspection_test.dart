import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_group_binding.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/api/cloud_sync_chat_identity.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show AnyhowException;
import 'package:flutter_test/flutter_test.dart';

import 'windows_chat_source_inspection.dart';

void main() {
  final reference = 'obcs2.ref.${'r' * 43}';
  Map<String, Object?> request({int schema = 1}) => {
    'schema': schema, 'launchId': 'a' * 32, 'source': 'b' * 40, 'pid': 42,
    'rowId': 4, 'generation': 1, 'sequence': 4,
    'changeIdHash': 'c' * 43, 'recordIdHash': 'd' * 43, 'etagHash': 'e' * 43,
    'payloadSha256': 'f' * 64,
    'referenceSha256': sha256.convert(utf8.encode(reference)).toString(),
    if (schema == 2) 'groupChatId': 773,
  };
  CloudInboxChangeEntity row() => CloudInboxChangeEntity(
    id: 4, changeKey: 'fixture-change', changeIdHash: 'c' * 43,
    scopeKey: 'fixture-scope', accountFingerprint: 'A' * 43,
    zone: 'chatManateeZone', serverRecordIdHash: 'd' * 43, etagHash: 'e' * 43,
    changeType: 'save', encryptedPayloadRef: reference, payloadSha256: 'f' * 64,
    batchId: 'fixture-batch', generation: 1, fetchSequence: 4,
    createdAtMs: 1, updatedAtMs: 1,
  );
  CloudSyncRestoredGroupChatProof proof({
    int generation = 1, Map<String, String> changed = const {},
  }) => CloudSyncRestoredGroupChatProof(
    binding: 'fixture-group-binding', generation: generation,
    logicalEntityKeyHash: 'L' * 43, routingMetadataDigest: 'a' * 64,
    source: CloudSyncChatIdentitySourceInput(
      changeIdHash: changed['changeIdHash'] ?? 'c' * 43,
      recordIdHash: changed['recordIdHash'] ?? 'd' * 43,
      etagHash: changed['etagHash'] ?? 'e' * 43,
      payloadSha256: changed['payloadSha256'] ?? 'f' * 64,
      protectedRawEnvelopeReference: changed['reference'] ?? reference,
    ),
  );

  test('schema1 keeps its exact request keys and decode-only result', () async {
    final legacy = {...request(), 'etagHash': null};
    expect(validWindowsChatSourceRequest(legacy), isTrue);
    expect(validWindowsChatSourceRequest({...legacy, 'groupChatId': 773}), isFalse);
    final summary = summarizeWindowsChatSource(api.CloudSyncTransientDecodeResult(
      generation: BigInt.one,
    ));
    final order = <String>[];
    final result = await decodeWindowsChatSourceWithGroupProofs<Object>(
      request: legacy,
      validate: () async { order.add('unexpected-validation'); },
      decode: () async { order.add('decode'); return summary; },
      openProof: () async { order.add('unexpected-proof'); return Object(); },
      disposeProof: (_) { order.add('unexpected-dispose'); },
      onStage: order.add,
    );
    expect(identical(result, summary), isTrue);
    expect(order, ['decode']);
    expect(result.containsKey('groupProofBefore'), isFalse);
    expect(result.containsKey('groupProofAfter'), isFalse);
  });

  test('schema2 requires only its extra positive integer group Chat ID', () {
    final group = request(schema: 2);
    expect(validWindowsChatSourceRequest(group), isTrue);
    final missing = {...group}..remove('groupChatId');
    expect(validWindowsChatSourceRequest(missing), isFalse);
    for (final value in <Object?>[null, 0, -1, 773.0, '773', true]) {
      expect(validWindowsChatSourceRequest({...group, 'groupChatId': value}), isFalse);
    }
    expect(validWindowsChatSourceRequest({...group, 'newerSource': true}), isFalse);
    expect(validWindowsChatSourceRequest({...group, 'schema': 3}), isFalse);
    expect(validWindowsChatSourceRequest({...group, 'schema': 2.0}), isFalse);
    expect(windowsChatSourceInspectionStages, containsAll([
      'group-proof-before', 'group-proof-after',
    ]));
    requireWindowsChatSourceGroupBinding(request: group, row: row(), proof: proof());
  });

  for (final field in [
    'generation', 'changeIdHash', 'recordIdHash', 'etagHash', 'payloadSha256', 'reference',
  ]) {
    test('schema2 refuses changed $field before any native proof or decode', () async {
      final changed = field == 'generation'
          ? proof(generation: 2) : proof(changed: {field: 'different-private-source'});
      var nativeCalls = 0;
      final stages = <String>[];
      await expectLater(decodeWindowsChatSourceWithGroupProofs<Object>(
        request: request(schema: 2),
        validate: () async {
          requireWindowsChatSourceGroupBinding(
            request: request(schema: 2), row: row(), proof: changed,
          );
        },
        openProof: () async { nativeCalls++; return Object(); },
        disposeProof: (_) {},
        decode: () async { nativeCalls++; return {}; },
        onStage: stages.add,
      ), throwsStateError);
      expect(nativeCalls, 0);
      expect(stages, isEmpty);
    });
  }

  test('same-pause probes expose unavailable then decode then ready and dispose', () async {
    final order = <String>[];
    final handle = Object();
    var opens = 0;
    final result = await decodeWindowsChatSourceWithGroupProofs<Object>(
      request: request(schema: 2),
      validate: () async {},
      openProof: () async {
        order.add('open-${++opens}');
        if (opens == 1) {
          throw AnyhowException('cloud_sync_attachment_parent_group_proof_unavailable');
        }
        return handle;
      },
      disposeProof: (proof) { expect(identical(proof, handle), isTrue); order.add('disposed'); },
      decode: () async { order.add('decode'); return {'rawContentExposed': false}; },
      onStage: order.add,
    );
    expect(order, [
      'group-proof-before', 'open-1', 'decode', 'group-proof-after', 'open-2', 'disposed',
    ]);
    expect(result, {
      'rawContentExposed': false, 'groupProofBefore': 'unavailable', 'groupProofAfter': 'ready',
    });
  });

  test('source drift during proof await disposes the handle and stops decode', () async {
    var current = proof();
    var disposed = 0;
    var decoded = false;
    await expectLater(decodeWindowsChatSourceWithGroupProofs<Object>(
      request: request(schema: 2),
      validate: () async {
        requireWindowsChatSourceGroupBinding(
          request: request(schema: 2), row: row(), proof: current,
        );
      },
      openProof: () async { current = proof(generation: 2); return Object(); },
      disposeProof: (_) { disposed++; },
      decode: () async { decoded = true; return {}; },
      onStage: (_) {},
    ), throwsStateError);
    expect(disposed, 1);
    expect(decoded, isFalse);
  });

  test('source drift during decode stops the after probe and releases the before proof', () async {
    var current = proof();
    var opens = 0;
    final order = <String>[];
    await expectLater(decodeWindowsChatSourceWithGroupProofs<Object>(
      request: request(schema: 2),
      validate: () async {
        requireWindowsChatSourceGroupBinding(
          request: request(schema: 2), row: row(), proof: current,
        );
      },
      openProof: () async { opens++; return Object(); },
      disposeProof: (_) { order.add('disposed'); },
      decode: () async {
        order.add('decode');
        current = proof(changed: {'etagHash': 'different-private-etag'});
        return {};
      },
      onStage: (_) {},
    ), throwsStateError);
    expect(opens, 1);
    expect(order, ['disposed', 'decode']);
  });

  test('group proof outcomes never copy arbitrary exception text', () {
    for (final code in ['unavailable', 'auth', 'scope', 'invalid', 'mismatch']) {
      expect(windowsChatSourceGroupProofOutcome(
        AnyhowException('cloud_sync_attachment_parent_group_proof_$code'),
      ), code);
    }
    for (final error in <Object>[
      AnyhowException('PRIVATE cloud_sync_attachment_parent_group_proof_unavailable'),
      StateError('PRIVATE-ACCOUNT-DATA'),
    ]) {
      expect(windowsChatSourceGroupProofOutcome(error), 'other');
    }
  });

  test(
    'projected member formats distinguish supported shapes without content',
    () {
      for (final entry in <String, String>{
        '12345': 'telephone',
        'tel:12345': 'telephone',
        'tel:+12345678901234567890': 'telephone',
        'BANK-ALERT': 'bareOpaque',
        'MAILTO:fixture@example.invalid': 'email',
        'urn:biz:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE': 'business',
        'future:private-scheme': 'unknownScheme',
        'urn:biz:invalid': 'unknownScheme',
        'tel:ALERT': 'malformed',
        'mailto:user@host': 'malformed',
        ' embedded space': 'malformed',
        'control\u0001value': 'malformed',
        'embedded\uFEFFvalue': 'malformed',
      }.entries) {
        expect(classifyWindowsChatSourceParticipant(entry.key), entry.value);
      }
      expect(
        classifyWindowsChatSourceParticipant(List.filled(513, 'a').join()),
        'malformed',
      );
    },
  );

  test('cold restored client is prepared before identity capture', () async {
    final client = Object();
    var warm = false;
    final order = <String>[];
    final result = await prepareWindowsChatSourceAuthentication<String>(
      client: client,
      readActiveClient: () => client,
      ensure: () async {
        order.add('ensure');
        warm = true;
      },
      capture: () async {
        order.add('capture');
        if (!warm) throw StateError('cold identity is not validated');
        return 'bound';
      },
    );
    expect(result, 'bound');
    expect(order, ['ensure', 'capture']);
  });

  test(
    'client replacement during preparation refuses before capture',
    () async {
      final original = Object();
      Object current = original;
      var captured = false;
      await expectLater(
        prepareWindowsChatSourceAuthentication<String>(
          client: original,
          readActiveClient: () => current,
          ensure: () async {
            current = Object();
          },
          capture: () async {
            captured = true;
            return 'wrong binding';
          },
        ),
        throwsStateError,
      );
      expect(captured, isFalse);
    },
  );

  test('failure receipt never reflects arbitrary native or state text', () {
    expect(
      safeWindowsChatSourceFailure(StateError('PRIVATE-ACCOUNT-DATA')),
      'backend_windows_chat_source_observation_failed',
    );
    expect(
      safeWindowsChatSourceFailure(
        StateError('backend_windows_chat_source_binding_changed'),
      ),
      'backend_windows_chat_source_binding_changed',
    );
  });

  test('transient content never enters the closed source summary', () {
    const chat = api.CloudSyncTransientChatPayload(
      logicalEntityKeyHash: 'PRIVATE-LOGICAL',
      canonicalGuid: 'PRIVATE-GUID',
      chatIdentifier: 'PRIVATE-CID',
      groupId: 'PRIVATE-GID',
      originalGroupId: 'PRIVATE-OGID',
      aliases: [],
      service: api.CloudSyncTransientService.iMessage,
      style: api.CloudSyncTransientChatStyle.direct,
      participantHandles: [
        'tel:+15555550101',
        'mailto:fixture@example.invalid',
        'urn:biz:fixture',
        'bare-opaque-fixture',
        ' invalid ',
      ],
      displayNameState: api.CloudSyncTransientFieldState.value,
      displayName: 'PRIVATE-TITLE',
      lastAddressedHandleState: api.CloudSyncTransientFieldState.value,
      lastAddressedHandle: 'PRIVATE-LAH',
      groupVersionState: api.CloudSyncTransientFieldState.absent,
      lastSeenMessageGuidState: api.CloudSyncTransientFieldState.value,
      lastSeenMessageGuid: 'PRIVATE-MESSAGE',
      groupPhotoGuidState: api.CloudSyncTransientFieldState.absent,
    );
    final summary = summarizeWindowsChatSource(
      api.CloudSyncTransientDecodeResult(
        generation: BigInt.one,
        protectedSourceReference: 'PRIVATE-REF',
        payload: const api.CloudSyncTransientPayload(chat: chat),
      ),
    );
    expect(summary['canonicalChatPresent'], isTrue);
    expect(summary['primaryIdentitiesValid'], isTrue);
    expect(summary['participantClasses'], {
      'phone': 1,
      'email': 1,
      'opaque': 2,
      'other': 1,
    });
    final encoded = jsonEncode(summary);
    for (final private in [
      'PRIVATE',
      '15555550101',
      'fixture@example',
      'urn:biz',
      'bare-opaque',
      ' invalid ',
    ]) {
      expect(encoded, isNot(contains(private)));
    }
    expect(summary.keys.toSet(), {
      'canonicalChatPresent',
      'failure',
      'deferred',
      'quarantine',
      'style',
      'service',
      'primaryIdentitiesValid',
      'participantClasses',
      'projectedParticipantClasses',
      'aliasCount',
      'rawContentExposed',
    });
  });

  test('failed canonical decode does not claim a usable source', () {
    final summary = summarizeWindowsChatSource(
      api.CloudSyncTransientDecodeResult(
        generation: BigInt.one,
        failureCode: api.CloudSyncTransientFailureCode.pcsUnavailable,
        quarantineDiagnosticSafeCode:
            'arbitrary native diagnostic must stay private',
      ),
    );
    expect(summary['canonicalChatPresent'], isFalse);
    expect(summary['primaryIdentitiesValid'], isFalse);
    expect(summary['failure'], 'pcsUnavailable');
    expect(jsonEncode(summary), isNot(contains('arbitrary native')));
  });
}
