import 'dart:convert';

import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

import 'windows_chat_source_inspection.dart';

void main() {
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
