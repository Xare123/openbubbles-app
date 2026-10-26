import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_group_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
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
    if (schema == 2 || schema == 4) 'groupChatId': 773,
    if (schema == 4) ...{
      'messageOperationId': 'op1:${'a' * 64}', 'messageIntentId': 19, 'messageId': 42,
      'messageSourceSha256': 'b' * 64, 'messageSnapshotSha256': 'c' * 64,
    },
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

  test('schema4 pins only an exact existing Message and refuses retired probe or write flags', () {
    final exact = request(schema: 4);
    expect(validWindowsChatSourceRequest(exact), isTrue);
    for (final key in ['groupChatId', 'messageOperationId', 'messageIntentId', 'messageId',
      'messageSourceSha256', 'messageSnapshotSha256']) {
      expect(validWindowsChatSourceRequest({...exact}..remove(key)), isFalse, reason: key);
    }
    for (final bad in [
      {...exact, 'schema': 3}, {...exact, 'schema': 4.0},
      {...exact, 'messageOperationId': 'raw GUID'}, {...exact, 'messageId': 42.0},
      {...exact, 'messageIntentId': 0}, {...exact, 'groupChatId': -1},
      {...exact, 'messageSnapshotSha256': 'private text'},
      {...exact, 'resend': true}, {...exact, 'consume': true}, {...exact, 'save': true},
      {...exact, 'allowMessagePreparationRecovery': true},
    ]) { expect(validWindowsChatSourceRequest(bad), isFalse); }
  });

  test('preparation-only helper releases, settles and retains without a mutation callback', () async {
    final events = <String>[];
    final prepared = Object();
    final result = await prepareWindowsMessageWithoutMutation<Object>(
      prepare: () async { events.add('prepare'); return prepared; },
      release: (value) async { expect(identical(value, prepared), isTrue); events.add('release'); return true; },
      quiesce: () async { events.add('quiesce'); },
      retain: () async { events.add('retain'); }, onStage: events.add);
    expect(events, ['message-prepare-started', 'prepare', 'release', 'message-prepared-released',
      'quiesce', 'message-prepare-settled', 'retain', 'message-owner-retained']);
    expect(result['prepared'], isTrue);
    expect(result['preparedSubmissionConsumed'], isFalse);
    expect(result['cloudWritesRequested'], isFalse);
    expect(result['idsSendsRequested'], isFalse);
    expect(result['readbackReceiptApplied'], isFalse);
  });

  test('failed no-save preflight becomes settled only after quiesce and retained validation', () async {
    final events = <String>[];
    final result = await prepareWindowsMessageWithoutMutation<Object>(
      prepare: () async => throw StateError('private message content'),
      release: (_) async { fail('no prepared owner exists'); },
      quiesce: () async { events.add('quiesce'); },
      retain: () async { events.add('retain'); }, onStage: events.add);
    expect(events, ['message-prepare-started', 'quiesce', 'message-prepare-settled', 'retain', 'message-owner-retained']);
    expect(result['prepared'], isFalse);
    expect(result['preflightFailure'], 'cloud_sync_unknown_failure');
    expect(jsonEncode(result), isNot(contains('private message content')));
  });

  for (final stage in ['release', 'quiesce', 'retain']) {
    test('uncertain $stage cannot report completed preparation-only settlement', () async {
      final events = <String>[];
      await expectLater(prepareWindowsMessageWithoutMutation<Object>(
        prepare: () async => Object(),
        release: (_) async { events.add('release'); if (stage == 'release') throw StateError('synthetic'); return true; },
        quiesce: () async { events.add('quiesce'); if (stage == 'quiesce') throw StateError('synthetic'); },
        retain: () async { events.add('retain'); throw StateError('synthetic'); },
        onStage: events.add), throwsStateError);
      expect(events, contains('quiesce'));
      expect(events.contains('message-owner-retained'), isFalse);
      if (stage != 'retain') expect(events.contains('retain'), isFalse);
    });
  }

  test('message recovery failure details never expose arbitrary errors', () {
    expect(windowsMessagePreparationFailureDetails(StateError('private body')),
      {'messageRecoverySafeCode': 'cloud_sync_unknown_failure'});
    expect(windowsMessagePreparationFailureDetails(
      StateError('cloud_sync_message_preparation_recovery_changed')),
      {'messageRecoverySafeCode': 'cloud_sync_message_preparation_recovery_changed'});
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

  Future<String> failureOf<T>(Future<T> action) async {
    Object? failure;
    try {
      await action;
    } catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    return safeWindowsChatSourceFailure(failure!);
  }

  test('preparation failure publishes only a fixed phase and known auth code', () async {
    final client = Object();
    var captured = false;
    final code = await failureOf(prepareWindowsChatSourceAuthentication<String>(
      client: client,
      readActiveClient: () => client,
      ensure: () async {
        throw StateError('cloud_sync_native_auth_refresh_session_missing');
      },
      capture: () async { captured = true; return 'unused'; },
    ));
    expect(code, 'backend_windows_chat_source_preparation__cloud_sync_native_auth_refresh_session_missing');
    expect(captured, isFalse);
  });

  test('known bridge and interlock codes survive only exact matches', () {
    for (final code in [
      'cloud_sync_native_auth_messages_container_failed',
      'cloud_sync_native_auth_keychain_container_failed',
      'cloud_sync_native_auth_security_container_failed',
      'cloud_sync_native_auth_pcs_zones_failed',
      'cloud_sync_native_auth_cloudkit_token_failed',
      'cloud_sync_native_auth_warm_timeout',
      'cloud_sync_native_auth_writer_pause_scope_failed',
      'cloud_sync_native_writer_pause_already_active',
      'cloud_sync_native_writer_pause_timeout',
      'cloud_sync_native_writer_resume_token_invalid',
    ]) {
      expect(safeWindowsChatSourceFailure(StateError(code)), code);
      expect(safeWindowsChatSourceFailure(AnyhowException(code)), code);
      expect(safeWindowsChatSourceFailure(AnyhowException('$code PRIVATE-TOKEN')),
        'backend_windows_chat_source_observation_failed');
    }
    expect(safeWindowsChatSourceFailure(const CloudKitOperationInterlockException(
      'cloudkit_interlock_fence_lost',
    )), 'cloudkit_interlock_fence_lost');
    for (final error in <Object>[
      AnyhowException('PRIVATE-PAYLOAD'), Exception('PRIVATE-TOKEN'),
      StateError('cloud_sync_native_auth_pcs_zones_failed\nPRIVATE-HANDLE'),
      const CloudKitOperationInterlockException('PRIVATE-PROFILE'),
    ]) {
      expect(safeWindowsChatSourceFailure(error), 'backend_windows_chat_source_observation_failed');
    }
  });

  group('read-window diagnostic callbacks use the real identity session', () {
    late Directory scratch;
    late CloudKitOperationInterlock interlock;
    late _InspectionPause pause;
    setUp(() {
      scratch = Directory.systemTemp.createTempSync('chat-source-diagnostic-');
      interlock = CloudKitOperationInterlock(
        privateStorageDirectory: scratch.path, fenceStore: InMemoryCloudSyncStore(),
      );
      pause = _InspectionPause();
    });
    tearDown(() async {
      await CloudKitOperationInterlock.debugResetPoisonedLocksForTesting();
      scratch.deleteSync(recursive: true);
    });
    Future<T> read<T>({
      Future<void> Function()? validate,
      Future<void> Function()? ensure,
      Future<void> Function(BigInt)? warm,
      required Future<T> Function(BigInt) observe,
    }) => interlock.runExclusive(
      kind: CloudKitOperationKind.v2ReadWrite,
      action: () => runWindowsChatSourceReadWindow(
        exclusion: interlock, nativePause: pause,
        validate: validate ?? () async {},
        ensureReadAuthentication: ensure ?? () async {},
        warmReadAuthentication: warm ?? (_) async {}, observe: observe,
      ),
    );

    test('missing interlock is classified before any callback or pause', () async {
      final code = await failureOf(runWindowsChatSourceReadWindow(
        exclusion: interlock, nativePause: pause,
        validate: () async => fail('validation requires interlock'),
        ensureReadAuthentication: () async => fail('ensure requires interlock'),
        warmReadAuthentication: (_) async => fail('warm requires interlock'),
        observe: (_) async => fail('observation requires interlock'),
      ));
      expect(code, 'backend_windows_chat_source_read_validation__cloudkit_interlock_required');
      expect(pause.calls, isEmpty);
    });

    test('initial validation and ensure failures never pause or observe', () async {
      for (final step in ['validation', 'ensure']) {
        var observed = false;
        final code = await failureOf(read(
          validate: () async {
            if (step == 'validation') {
              throw StateError('cloud_sync_native_auth_metadata_invalid');
            }
          },
          ensure: () async {
            throw StateError('cloud_sync_native_auth_refresh_writer_busy');
          },
          observe: (_) async { observed = true; return 'unused'; },
        ));
        expect(code, step == 'validation'
          ? 'backend_windows_chat_source_read_validation__cloud_sync_native_auth_metadata_invalid'
          : 'backend_windows_chat_source_read_ensure__cloud_sync_native_auth_refresh_writer_busy');
        expect(observed, isFalse);
        expect(pause.calls, isEmpty);
      }
    });

    test('pause rejection never warms or enters observation', () async {
      pause.pauseError = StateError('cloud_sync_native_writer_pause_already_active');
      var warmed = false;
      var observed = false;
      final code = await failureOf(read(
        warm: (_) async { warmed = true; },
        observe: (_) async { observed = true; return 'unused'; },
      ));
      expect(code, 'backend_windows_chat_source_read_pause__cloud_sync_native_writer_pause_already_active');
      expect(pause.calls, ['pause']);
      expect(warmed || observed, isFalse);
    });

    test('warm failure before proof observation survives successful resume', () async {
      final stages = <String>[];
      var nativeProofCalls = 0;
      final code = await failureOf(read(
        warm: (token) async {
          expect(pause.active, isTrue);
          expect(token, pause.token);
          throw StateError('cloud_sync_native_auth_pcs_zones_failed');
        },
        observe: (_) => decodeWindowsChatSourceWithGroupProofs<Object>(
          request: request(schema: 2), validate: () async {},
          decode: () async => {}, onStage: stages.add,
          openProof: () async { nativeProofCalls++; return Object(); },
          disposeProof: (_) {},
        ),
      ));
      expect(code, 'backend_windows_chat_source_read_warm__cloud_sync_native_auth_pcs_zones_failed');
      expect(pause.calls, ['pause', 'resume']);
      expect(pause.active, isFalse);
      expect(stages, isEmpty);
      expect(nativeProofCalls, 0);
    });

    test('validation after pause releases without reporting resume as the fault', () async {
      var validations = 0;
      var observed = false;
      final code = await failureOf(read(
        validate: () async {
          if (++validations == 3) {
            throw StateError('backend_windows_chat_source_binding_changed');
          }
        },
        observe: (_) async { observed = true; return 'unused'; },
      ));
      expect(code, 'backend_windows_chat_source_read_validation__backend_windows_chat_source_binding_changed');
      expect(pause.calls, ['pause', 'resume']);
      expect(pause.active || observed, isFalse);
    });

    test('resume failure overrides warm failure and retains the poisoned exclusion', () async {
      pause.resumeError = StateError('cloud_sync_native_writer_resume_failed');
      final code = await failureOf(read(
        warm: (_) async { throw StateError('cloud_sync_native_auth_warm_timeout'); },
        observe: (_) async => fail('observation must not run'),
      ));
      expect(code, 'backend_windows_chat_source_read_resume__cloud_sync_native_writer_resume_failed');
      expect(pause.active, isTrue);
      await expectLater(interlock.runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: () async => fail('poisoned exclusion must not reenter'),
      ), throwsA(isA<CloudKitOperationInterlockException>()));
    });

    test('uncertain pause retains its type until the real session poisons', () async {
      pause.pauseError = const CloudSyncNativeWriterPauseUncertain();
      final code = await failureOf(read(
        observe: (_) async => fail('observation must not run'),
      ));
      expect(code, 'backend_windows_chat_source_read_pause__cloud_sync_native_writer_pause_resume_unconfirmed');
      await expectLater(interlock.runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: () async => fail('uncertain pause must poison exclusion'),
      ), throwsA(isA<CloudKitOperationInterlockException>()));
    });

    test('unknown callback errors expose only their fixed phase and generic code', () async {
      final code = await failureOf(read(
        warm: (_) async { throw AnyhowException('PRIVATE-TOKEN PRIVATE-PAYLOAD'); },
        observe: (_) async => fail('observation must not run'),
      ));
      expect(code, 'backend_windows_chat_source_read_warm__backend_windows_chat_source_observation_failed');
      expect(code, isNot(contains('PRIVATE')));
      expect(code, isNot(contains(pause.token.toString())));
      expect(pause.active, isFalse);
    });

    test('successful observation keeps the same token and releases before returning', () async {
      final result = await read(observe: (token) async {
        expect(token, pause.token);
        expect(pause.active, isTrue);
        return 'content-free-result';
      });
      expect(result, 'content-free-result');
      expect(pause.calls, ['pause', 'resume']);
      expect(pause.active, isFalse);
    });
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

final class _InspectionPause implements CloudSyncNativeWriterPause {
  final token = BigInt.from(424242);
  final calls = <String>[];
  Object? pauseError;
  Object? resumeError;
  var active = false;

  @override
  Future<Object> pause() async {
    calls.add('pause');
    final error = pauseError;
    if (error != null) {
      throw error;
    }
    active = true;
    return token;
  }

  @override
  Future<void> resume(Object value) async {
    expect(value, token);
    calls.add('resume');
    final error = resumeError;
    if (error != null) {
      throw error;
    }
    active = false;
  }
}
