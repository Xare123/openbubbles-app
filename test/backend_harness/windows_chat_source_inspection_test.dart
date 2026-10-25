import 'dart:convert';

import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

import 'windows_chat_source_inspection.dart';

void main() {
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
