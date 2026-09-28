import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_chat_state.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _snapshot =
    'ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34';
const _account = 'account-fp-xyz789';
const _nowMs = 1700000000000;
const _createdMs = 1699000000000;
const _text = 'hello from before the upgrade';
const _guid = 'A1B2C3D4-E5F6-4A7B-8C9D-E0F1A2B3C4D5';

CloudSyncHistoricalSourceManifest _manifest({
  String snapshotSha256 = _snapshot,
  String accountFingerprint = _account,
  List<String> accountHandles = const ['me@example.com'],
  int messageCount = 13393,
  int capturedAtMs = 1699500000000,
}) {
  return CloudSyncHistoricalSourceManifest(
    snapshotSha256: snapshotSha256,
    accountFingerprint: accountFingerprint,
    accountHandles: accountHandles,
    messageCount: messageCount,
    capturedAtMs: capturedAtMs,
  );
}

CloudSyncHistoricalChatView _chat({
  int id = 7,
  String guid = 'iMessage;-;friend@example.com',
  int? style = 45,
  String? chatIdentifier = 'friend@example.com',
  bool isRoutingStub = false,
  bool dateDeletedPresent = false,
  bool isRpSms = false,
  int participantCount = 1,
  String participantAddress = 'friend@example.com',
  String participantService = 'iMessage',
  CloudSyncHistoricalGroupMetadata? groupMetadata,
  CloudSyncHistoricalChatState? parentState,
}) {
  return CloudSyncHistoricalChatView(
    id: id,
    guid: guid,
    style: style,
    chatIdentifier: chatIdentifier,
    isRoutingStub: isRoutingStub,
    dateDeletedPresent: dateDeletedPresent,
    isRpSms: isRpSms,
    participantCount: participantCount,
    participantAddress: participantAddress,
    participantService: participantService,
    groupMetadata: groupMetadata,
    parentState: parentState,
  );
}

CloudSyncHistoricalAccountBinding _accountBinding({
  String accountFingerprint = _account,
  String protectedStoreIdentity = 'store-1',
}) {
  return CloudSyncHistoricalAccountBinding(
    accountFingerprint: accountFingerprint,
    protectedStoreIdentity: protectedStoreIdentity,
  );
}

CloudSyncHistoricalRowView _row({
  String guid = _guid,
  String? text = _text,
  List<AttributedBody>? attributedBodies,
  bool hasActualEditOrUnsend = false,
  bool dateEditedPresent = false,
  bool associationPresent = false,
  bool? isFromMe = false,
  String? senderAddress = 'friend@example.com',
  CloudSyncHistoricalChatView? chat,
  int dateCreatedMs = _createdMs,
  int error = 0,
  bool isTemp = false,
  String? stagingGuid,
  String? sendingServiceId,
  bool hasBeenForwarded = false,
  bool verificationFailed = false,
  String? ckRecordId,
  bool ckSyncState = false,
  int messageId = 11,
  int itemType = 0,
  int groupActionType = 0,
  String? groupTitle,
  bool isDeleted = false,
  bool dateScheduledPresent = false,
  bool threadOriginatorPresent = false,
  bool hasAttachments = false,
  int attachmentCount = 0,
  bool subjectPresent = false,
  bool expressiveSendStyleIdPresent = false,
  bool balloonBundleIdPresent = false,
  bool payloadDataPresent = false,
  bool hasApplePayloadData = false,
  bool amkSessionIdPresent = false,
  String rowSnapshotSha256 = _snapshot,
}) {
  final body = text ?? '';
  return CloudSyncHistoricalRowView(
    guid: guid,
    text: text,
    attributedBodies: attributedBodies ?? [AttributedBody.raw(body)],
    hasActualEditOrUnsend: hasActualEditOrUnsend,
    dateEditedPresent: dateEditedPresent,
    associationPresent: associationPresent,
    isFromMe: isFromMe,
    senderAddress: senderAddress,
    chat: chat ?? _chat(),
    dateCreatedMs: dateCreatedMs,
    error: error,
    isTemp: isTemp,
    stagingGuid: stagingGuid,
    sendingServiceId: sendingServiceId,
    hasBeenForwarded: hasBeenForwarded,
    verificationFailed: verificationFailed,
    ckRecordId: ckRecordId,
    ckSyncState: ckSyncState,
    messageId: messageId,
    itemType: itemType,
    groupActionType: groupActionType,
    groupTitle: groupTitle,
    isDeleted: isDeleted,
    dateScheduledPresent: dateScheduledPresent,
    threadOriginatorPresent: threadOriginatorPresent,
    hasAttachments: hasAttachments,
    attachmentCount: attachmentCount,
    subjectPresent: subjectPresent,
    expressiveSendStyleIdPresent: expressiveSendStyleIdPresent,
    balloonBundleIdPresent: balloonBundleIdPresent,
    payloadDataPresent: payloadDataPresent,
    hasApplePayloadData: hasApplePayloadData,
    amkSessionIdPresent: amkSessionIdPresent,
    rowSnapshotSha256: rowSnapshotSha256,
  );
}

CloudSyncHistoricalArchiveRequest _eligible(
  CloudSyncHistoricalRowView row, [
  CloudSyncHistoricalSourceManifest? manifest,
  CloudSyncHistoricalAccountBinding? account,
]) {
  final assessment = assessHistoricalArchiveRow(
    row,
    manifest ?? _manifest(),
    account ?? _accountBinding(),
    nowMs: _nowMs,
  );
  expect(assessment, isA<CloudSyncHistoricalArchiveEligible>());
  return (assessment as CloudSyncHistoricalArchiveEligible).request;
}

String _reason(
  CloudSyncHistoricalRowView row, [
  CloudSyncHistoricalSourceManifest? manifest,
  CloudSyncHistoricalAccountBinding? account,
]) {
  final assessment = assessHistoricalArchiveRow(
    row,
    manifest ?? _manifest(),
    account ?? _accountBinding(),
    nowMs: _nowMs,
  );
  expect(assessment, isA<CloudSyncHistoricalArchiveIneligible>());
  return (assessment as CloudSyncHistoricalArchiveIneligible).reason;
}

CloudSyncHistoricalChatState _parentState(List<dynamic> wire) =>
    CloudSyncHistoricalChatState(
      cloudGuid: wire[1] as String?,
      usingHandle: wire[2] as String?,
      displayName: wire[3] as String?,
      groupVersion: wire[4] as int?,
      lastReadMessageGuid: wire[5] as String?,
      latestMessageDateMs: wire[6] as int?,
      photoAttachmentGuid: wire[7] as String?,
      customAvatarPresent: wire[8] as bool,
      ckRecordId: wire[9] as String?,
      ckSyncState: wire[10] as bool,
      cloudDataBase64: wire[11] as String?,
      guidRefs: (wire[12] as List).cast<String>(),
    );

void main() {
  final vectors = [
    for (final version in [1, 2, 3])
      ...(jsonDecode(File(
        'test/fixtures/cloud_sync/historical_source_v$version.json',
      ).readAsStringSync()) as List).cast<Map<String, dynamic>>(),
  ];
  for (final vector in vectors) {
    test('native shared wire vector ${vector['name']}', () {
      final payload =
          jsonDecode(vector['canonicalPayload'] as String)
              as Map<String, dynamic>;
      final text = payload['text'] as String;
      final group = payload['groupMetadata'] as List?;
      final parent = payload['parentState'] as List?;
      final parentState = parent == null ? null : _parentState(parent);
      final request = _eligible(
        _row(
          guid: payload['guid'] as String,
          text: text,
          senderAddress: payload['senderAddress'] as String,
          isFromMe: payload['isFromMe'] as bool,
          chat: group == null ? _chat(parentState: parentState) : _chat(
            guid: payload['chatGuid'] as String,
            style: 43,
            chatIdentifier: 'historical-group',
            participantCount: (group[2] as List).length,
            parentState: parentState,
            groupMetadata: CloudSyncHistoricalGroupMetadata(
              cloudGuid: group[1] as String?,
              participants: (group[2] as List).map((member) =>
                CloudSyncHistoricalParticipantView(
                  address: member[0] as String, service: member[1] as String)),
            ),
          ),
        ),
      );
      expect(request.guidHash, vector['guidHash']);
      expect(request.sourceSha256, vector['sourceSha256']);
      expect(
        jsonEncode(stagedHistoricalPayload(request: request, text: text)),
        vector['canonicalPayload'],
      );
    });
  }

  test('frozen parent state is bound without reinterpreting the endpoint', () {
    final wire = (jsonDecode(vectors.last['canonicalPayload'] as String)
        as Map<String, dynamic>)['parentState'] as List;
    final original = _row(chat: _chat(parentState: _parentState(wire)));
    final request = _eligible(original);
    expect(stagedHistoricalPayload(request: request, text: _text)['format'],
        'cloud-sync-historical-source-v3');
    expect(request.senderAddress, 'friend@example.com');
    expect(request.peerAddress, 'friend@example.com');
    final changedWire = List<dynamic>.of(wire)..[3] = 'Newer title';
    final changed = _row(chat: _chat(parentState: _parentState(changedWire)));
    expect(_eligible(changed).sourceSha256, isNot(request.sourceSha256));
    expect(() => encodeHistoricalSource(request: request, currentRow: changed,
        manifest: _manifest(), account: _accountBinding(), nowMs: _nowMs),
        throwsStateError);
    // Current-row veto still checks the message/route. It does not replace the
    // parent's immutable conversion input with newer display/cloud metadata.
    expect(historicalArchiveRowMatchesRequest(changed, request, nowMs: _nowMs),
        isTrue);
    expect(historicalArchiveRowMatchesRequest(
        _row(text: 'newer message', chat: changed.chat), request, nowMs: _nowMs),
        isFalse);
  });

  test('older sources still match rows that now capture parent metadata', () {
    final wire = (jsonDecode(vectors.last['canonicalPayload'] as String)
        as Map<String, dynamic>)['parentState'] as List;
    final request = _eligible(_row());
    final current = _row(chat: _chat(parentState: _parentState(wire)));
    expect(request.parentState, isNull);
    expect(historicalArchiveRowMatchesRequest(current, request, nowMs: _nowMs),
        isTrue);
    expect(historicalArchiveRowMatchesRequest(
        _row(chat: _chat(guid: 'iMessage;-;other@example.com',
            chatIdentifier: 'other@example.com', participantAddress: 'other@example.com',
            parentState: _parentState(wire))), request, nowMs: _nowMs), isFalse);
  });

  CloudSyncHistoricalGroupMetadata groupMetadata({
    String? cloudGuid = 'opaque-group-id',
    String second = 'other@example.com',
    String service = 'iMessage',
  }) => CloudSyncHistoricalGroupMetadata(
    cloudGuid: cloudGuid,
    participants: [
      const CloudSyncHistoricalParticipantView(address: 'friend@example.com', service: 'iMessage'),
      CloudSyncHistoricalParticipantView(address: second, service: service),
    ],
  );
  CloudSyncHistoricalChatView groupChat(CloudSyncHistoricalGroupMetadata? group) => _chat(
    guid: 'iMessage;+;historical-group', style: 43,
    chatIdentifier: 'historical-group', participantCount: 2, groupMetadata: group,
  );

  test('group context is preserved without claiming historical membership', () {
    final request = _eligible(_row(
      chat: groupChat(groupMetadata()), senderAddress: 'departed@example.com'));
    expect(request.origin, CloudSyncHistoricalArchiveOrigin.historicalReceived);
    expect(request.senderAddress, 'departed@example.com');
    expect(request.groupMetadata!.participants, hasLength(2));
    expect(stagedHistoricalPayload(request: request, text: _text)['format'],
        'cloud-sync-historical-source-v2');
  });

  test('old or contradictory group metadata remains ineligible', () {
    for (final group in [null, groupMetadata(second: 'friend@example.com'),
      groupMetadata(service: 'SMS'), groupMetadata(cloudGuid: ' ')]) {
      expect(_reason(_row(chat: groupChat(group))), CloudSyncHistoricalArchiveReasons.group);
    }
  });

  test('all captured group members and optional ID are bound to source', () {
    final original = _eligible(_row(chat: groupChat(groupMetadata())));
    for (final group in [groupMetadata(second: 'changed@example.com'),
      groupMetadata(cloudGuid: 'changed'), groupMetadata(cloudGuid: null)]) {
      final changed = _eligible(_row(chat: groupChat(group)));
      expect(changed.sourceSha256, isNot(original.sourceSha256));
      expect(() => encodeHistoricalSource(request: original,
        currentRow: _row(chat: groupChat(group)), manifest: _manifest(),
        account: _accountBinding(), nowMs: _nowMs), throwsStateError);
    }
  });

  test('stored original group UUID is preserved for exact parent lookup', () {
    final request = _eligible(_row(chat: _chat(
      guid: _guid, style: null, chatIdentifier: null, participantCount: 2,
      groupMetadata: groupMetadata(cloudGuid: null))));
    expect(request.chatGuid, _guid);
    expect(request.groupMetadata!.cloudGuid, isNull);
  });

  test('NUL body is ineligible before native staging', () {
    expect(
      _reason(_row(text: 'before\u0000after')),
      CloudSyncHistoricalArchiveReasons.body,
    );
  });

  test('timestamps roundtrip in Unix milliseconds', () {
    const ms = _createdMs;
    final roundtrip = DateTime.fromMillisecondsSinceEpoch(
      ms,
      isUtc: true,
    ).millisecondsSinceEpoch;
    expect(roundtrip, ms);
    expect(ms, greaterThan(946684800000));
    expect(ms, lessThan(_nowMs + 86400000));
    final request = _eligible(_row(), _manifest());
    expect(request.dateCreatedMs, ms);
  });

  test('incoming row maps with preserved direction and binding', () {
    final request = _eligible(_row(), _manifest());
    expect(request.origin, CloudSyncHistoricalArchiveOrigin.historicalReceived);
    expect(request.isFromMe, isFalse);
    expect(request.guid, _guid);
    expect(request.chatGuid, 'iMessage;-;friend@example.com');
    expect(request.dateCreatedMs, _createdMs);
    expect(request.snapshotSha256, _snapshot);
    expect(request.accountFingerprint, _account);
    expect(request.guidHash, hasLength(64));
    expect(request.sourceSha256, hasLength(64));
  });

  test('sent row maps only with its sender in the manifest handles', () {
    final request = _eligible(
      _row(isFromMe: true, senderAddress: 'me@example.com'),
      _manifest(),
    );
    expect(request.origin, CloudSyncHistoricalArchiveOrigin.historicalSent);
    expect(request.isFromMe, isTrue);
    expect(
      _reason(
        _row(isFromMe: true, senderAddress: 'stranger@example.com'),
        _manifest(),
      ),
      CloudSyncHistoricalArchiveReasons.identity,
    );
    expect(
      _reason(
        _row(isFromMe: false, senderAddress: 'me@example.com'),
        _manifest(),
      ),
      CloudSyncHistoricalArchiveReasons.directionMismatch,
    );
  });

  test('unknown direction is not reclassified as incoming', () {
    expect(
      _reason(_row(isFromMe: null)),
      CloudSyncHistoricalArchiveReasons.directionMismatch,
    );
  });

  test('native-invalid identifiers and blank text are retained', () {
    expect(
      _reason(_row(guid: 'guid\u0000suffix')),
      CloudSyncHistoricalArchiveReasons.tempGuid,
    );
    expect(
      _reason(_row(text: ' \t\n\uFEFF')),
      CloudSyncHistoricalArchiveReasons.body,
    );
  });

  test('plain structural attributedBody passes; styled bodies reject', () {
    final plain = _eligible(_row(), _manifest());
    expect(plain.guid, _guid);
    final styled = AttributedBody(
      string: _text,
      runs: [
        Run(
          range: const [0, 5],
          attributes: Attributes(messagePart: 0, bold: true),
        ),
        Run(range: const [5, 27], attributes: Attributes(messagePart: 0)),
      ],
    );
    expect(
      _reason(_row(attributedBodies: [styled]), _manifest()),
      CloudSyncHistoricalArchiveReasons.body,
    );
  });

  test('digests never collide with the live-receive lane namespace', () {
    final request = _eligible(_row(), _manifest());
    final liveGuidHash = sha256
        .convert(
          utf8.encode(
            jsonEncode(['cloud-sync-received-archive-guid-v1', _guid]),
          ),
        )
        .toString();
    expect(request.guidHash, isNot(liveGuidHash));
  });

  test('same row is idempotent, new snapshot changes the source binding', () {
    final manifest = _manifest();
    final first = _eligible(_row(), manifest);
    final second = _eligible(_row(), manifest);
    expect(second.guidHash, first.guidHash);
    expect(second.sourceSha256, first.sourceSha256);
    const other =
        'cc12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34';
    final rebound = _eligible(
      _row(rowSnapshotSha256: other),
      _manifest(snapshotSha256: other),
    );
    expect(rebound.guidHash, first.guidHash);
    expect(rebound.sourceSha256, isNot(first.sourceSha256));
  });

  test('manifest shape and snapshot match fail closed', () {
    expect(
      _reason(_row(), _manifest(snapshotSha256: 'short')),
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
    expect(
      _reason(
        _row(),
        _manifest(
          snapshotSha256:
              'AB12CD34AB12CD34AB12CD34AB12CD34AB12CD34AB12CD34AB12CD34AB12CD34',
        ),
      ),
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
    expect(
      _reason(_row(), _manifest(accountHandles: const [])),
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
    expect(
      _reason(_row(), _manifest(messageCount: 0)),
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
    expect(
      _reason(
        _row(
          rowSnapshotSha256:
              'cc12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34',
        ),
        _manifest(),
      ),
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
  });

  test('temp GUIDs, failures, and tombstones reject', () {
    final manifest = _manifest();
    expect(
      _reason(_row(guid: 'temp-123'), manifest),
      CloudSyncHistoricalArchiveReasons.tempGuid,
    );
    expect(
      _reason(_row(error: 1), manifest),
      CloudSyncHistoricalArchiveReasons.sendState,
    );
    expect(
      _reason(_row(isDeleted: true), manifest),
      CloudSyncHistoricalArchiveReasons.tombstone,
    );
    expect(
      _reason(_row(isTemp: true), manifest),
      CloudSyncHistoricalArchiveReasons.sendState,
    );
  });

  test(
    'edits, summaries, and associations are retained as mutation or reaction',
    () {
      final manifest = _manifest();
      expect(
        _reason(_row(dateEditedPresent: true), manifest),
        CloudSyncHistoricalArchiveReasons.mutation,
      );
      expect(
        _reason(_row(hasActualEditOrUnsend: true), manifest),
        CloudSyncHistoricalArchiveReasons.mutation,
      );
      expect(
        _reason(_row(associationPresent: true), manifest),
        CloudSyncHistoricalArchiveReasons.reaction,
      );
    },
  );

  test('scheduled, system, SMS, group, reply, and media rows reject', () {
    final manifest = _manifest();
    expect(
      _reason(_row(dateScheduledPresent: true), manifest),
      CloudSyncHistoricalArchiveReasons.scheduled,
    );
    expect(
      _reason(_row(itemType: 1), manifest),
      CloudSyncHistoricalArchiveReasons.systemMessage,
    );
    expect(
      _reason(_row(chat: _chat(isRpSms: true)), manifest),
      CloudSyncHistoricalArchiveReasons.sms,
    );
    expect(
      _reason(_row(chat: _chat(participantCount: 2)), manifest),
      CloudSyncHistoricalArchiveReasons.group,
    );
    expect(
      _reason(_row(threadOriginatorPresent: true), manifest),
      CloudSyncHistoricalArchiveReasons.reply,
    );
    expect(
      _reason(_row(hasAttachments: true, attachmentCount: 2), manifest),
      CloudSyncHistoricalArchiveReasons.media,
    );
  });

  test('rich payloads and bad timestamps reject', () {
    final manifest = _manifest();
    expect(
      _reason(_row(subjectPresent: true), manifest),
      CloudSyncHistoricalArchiveReasons.richPayload,
    );
    expect(
      _reason(_row(balloonBundleIdPresent: true), manifest),
      CloudSyncHistoricalArchiveReasons.richPayload,
    );
    expect(
      _reason(_row(dateCreatedMs: 0), manifest),
      CloudSyncHistoricalArchiveReasons.timestamp,
    );
    expect(
      _reason(_row(dateCreatedMs: 946684799999), manifest),
      CloudSyncHistoricalArchiveReasons.timestamp,
    );
    expect(
      _reason(_row(dateCreatedMs: _nowMs + 86400001), manifest),
      CloudSyncHistoricalArchiveReasons.timestamp,
    );
  });

  test('dedupe keys on the exact GUID string', () {
    expect(
      resolveHistoricalDedupe(
        guid: _guid,
        ownedGuids: {_guid},
        conflictGuids: const {},
      ),
      CloudSyncHistoricalDedupeVerdict.skipOwned,
    );
    expect(
      resolveHistoricalDedupe(
        guid: _guid,
        ownedGuids: const {},
        conflictGuids: {_guid},
      ),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
    expect(
      resolveHistoricalDedupe(
        guid: _guid,
        ownedGuids: {_guid},
        conflictGuids: {_guid},
      ),
      CloudSyncHistoricalDedupeVerdict.retainConflict,
    );
    expect(
      resolveHistoricalDedupe(
        guid: _guid,
        ownedGuids: const {},
        conflictGuids: const {},
      ),
      CloudSyncHistoricalDedupeVerdict.proceed,
    );
  });

  test('reason codes leak no row content', () {
    final manifest = _manifest();
    final reasons = <String>[
      _reason(_row(hasAttachments: true), manifest),
      _reason(_row(isDeleted: true), manifest),
      _reason(_row(chat: _chat(participantCount: 2)), manifest),
    ];
    for (final reason in reasons) {
      expect(reason, isNot(contains(_text)));
      expect(reason, isNot(contains(_guid)));
      expect(reason, isNot(contains('friend@example.com')));
    }
  });

  test('same snapshot with a different current account fails closed', () {
    final manifest = _manifest();
    expect(
      _reason(
        _row(),
        manifest,
        _accountBinding(accountFingerprint: 'other-account'),
      ),
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
    expect(
      _reason(
        _row(),
        _manifest(accountFingerprint: 'other-account'),
        _accountBinding(),
      ),
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
    expect(
      _reason(_row(), manifest, _accountBinding(protectedStoreIdentity: '')),
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
  });

  test('request binds exact text, sender, and peer route', () {
    final request = _eligible(_row(), _manifest());
    expect(request.senderAddress, 'friend@example.com');
    expect(request.peerAddress, 'friend@example.com');
    expect(request.textSha256, historicalTextDigest(_text));
    expect(request.textSha256, hasLength(64));
    expect(request.protectedStoreIdentity, 'store-1');
  });

  test('native epoch and UTF-8 bounds reject unrepresentable input', () {
    expect(
      _reason(_row(dateCreatedMs: 978307200000)),
      CloudSyncHistoricalArchiveReasons.timestamp,
    );
    expect(
      _eligible(_row(dateCreatedMs: 978307200001)).dateCreatedMs,
      978307200001,
    );
    expect(
      _reason(_row(text: List.filled(131073, '\u00e9').join())),
      CloudSyncHistoricalArchiveReasons.body,
    );
    expect(
      _reason(_row(guid: List.filled(4097, 'x').join())),
      CloudSyncHistoricalArchiveReasons.tempGuid,
    );
  });

  test('ordinary empty summary metadata does not reject plain text', () {
    final request = _eligible(_row(hasActualEditOrUnsend: false), _manifest());
    expect(request.guid, _guid);
  });

  for (final structured in [false, true]) {
    test('mapped model fixture requires structured body: $structured', () {
      final peer = Handle(address: 'friend@example.com', service: 'iMessage');
      final owner = Handle(address: 'me@example.com', service: 'iMessage');
      final chat = Chat(
        id: 7,
        guid: 'iMessage;-;friend@example.com',
        chatIdentifier: 'friend@example.com',
        style: 45,
        participants: [peer],
      )..handles.add(peer);
      final message = Message(
        id: 11,
        guid: _guid,
        text: _text,
        isFromMe: true,
        handle: owner,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(_createdMs),
        attributedBody: structured ? [AttributedBody.raw(_text)] : [],
      );
      final assessed = assessHistoricalArchiveRow(
        mapHistoricalRow(
          message: message,
          chat: mapHistoricalChat(chat),
          rowSnapshotSha256: _snapshot,
        ),
        _manifest(),
        _accountBinding(),
        nowMs: _nowMs,
      );
      if (structured) {
        expect(assessed, isA<CloudSyncHistoricalArchiveEligible>());
      } else {
        expect(
          (assessed as CloudSyncHistoricalArchiveIneligible).reason,
          CloudSyncHistoricalArchiveReasons.body,
        );
      }
    });
  }

  test(
    'local comparison preserves incoming origin without a guessed account',
    () {
      final original = _eligible(_row());
      expect(
        historicalArchiveRowMatchesRequest(_row(), original, nowMs: _nowMs),
        isTrue,
      );
      expect(original.peerAddress, original.senderAddress);
    },
  );

  test('local comparison preserves the original qualified sent identity', () {
    final row = _row(isFromMe: true, senderAddress: 'me@example.com');
    final original = _eligible(row);
    expect(
      historicalArchiveRowMatchesRequest(row, original, nowMs: _nowMs),
      isTrue,
    );
  });

  final changedRows = <String, CloudSyncHistoricalRowView>{
    'text': _row(text: 'changed'),
    'sender': _row(senderAddress: 'other@example.com'),
    'direction': _row(isFromMe: true),
    'timestamp': _row(dateCreatedMs: _createdMs + 1),
    'structured body': _row(attributedBodies: []),
    'edit': _row(hasActualEditOrUnsend: true),
    'unsend': _row(isDeleted: true),
    'legacy owner': _row(ckSyncState: true),
    'attachment': _row(attachmentCount: 1),
    'subject': _row(subjectPresent: true),
    'reply': _row(threadOriginatorPresent: true),
    'snapshot': _row(rowSnapshotSha256: '0' * 64),
  };
  for (final changed in changedRows.entries) {
    test('local comparison rejects changed ${changed.key}', () {
      expect(
        historicalArchiveRowMatchesRequest(
          changed.value,
          _eligible(_row()),
          nowMs: _nowMs,
        ),
        isFalse,
      );
    });
  }
}
