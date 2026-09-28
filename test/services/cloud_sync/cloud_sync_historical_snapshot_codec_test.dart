import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure codec tests: no Store is opened and no native bridge is touched.
/// Views are built directly; eligibility behavior is checked through the
/// existing pure assessHistoricalArchiveRow.
String _t(String c) => List.filled(43, c).join();
String _h(String c) => List.filled(64, c).join();

const _snapshot =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _nowMs = 1700000000000;

CloudSyncHistoricalChatView _chat({
  int? style = 45,
  bool isRpSms = false,
  int participantCount = 1,
}) => CloudSyncHistoricalChatView(
  id: 11,
  guid: 'iMessage;-;peer@example.com',
  style: style,
  chatIdentifier: 'peer@example.com',
  isRoutingStub: false,
  dateDeletedPresent: false,
  isRpSms: isRpSms,
  participantCount: participantCount,
  participantAddress: 'peer@example.com',
  participantService: 'iMessage',
);

CloudSyncHistoricalRowView _row({
  String? text = 'hello history',
  List<AttributedBody>? bodies,
  bool? isFromMe = false,
  String? senderAddress = 'peer@example.com',
  CloudSyncHistoricalChatView? chat,
  bool hasAttachments = false,
  int attachmentCount = 0,
  bool hasActualEditOrUnsend = false,
  bool dateEditedPresent = false,
  bool associationPresent = false,
  bool threadOriginatorPresent = false,
  bool dateScheduledPresent = false,
  bool subjectPresent = false,
  bool expressiveSendStyleIdPresent = false,
  bool balloonBundleIdPresent = false,
  bool payloadDataPresent = false,
  bool hasApplePayloadData = false,
  bool amkSessionIdPresent = false,
  String? groupTitle,
}) {
  final resolvedText = text ?? '';
  return CloudSyncHistoricalRowView(
    guid: 'row-guid-1',
    text: text,
    attributedBodies: bodies ?? [AttributedBody.raw(resolvedText)],
    hasActualEditOrUnsend: hasActualEditOrUnsend,
    dateEditedPresent: dateEditedPresent,
    associationPresent: associationPresent,
    isFromMe: isFromMe,
    senderAddress: senderAddress,
    chat: chat ?? _chat(),
    dateCreatedMs: _nowMs,
    error: 0,
    isTemp: false,
    stagingGuid: null,
    sendingServiceId: null,
    hasBeenForwarded: false,
    verificationFailed: false,
    ckRecordId: null,
    ckSyncState: false,
    messageId: 42,
    itemType: 0,
    groupActionType: 0,
    groupTitle: groupTitle,
    isDeleted: false,
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
    rowSnapshotSha256: _snapshot,
  );
}

CloudSyncHistoricalSourceManifest _manifest() =>
    const CloudSyncHistoricalSourceManifest(
      snapshotSha256: _snapshot,
      accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      accountHandles: ['me@example.com'],
      messageCount: 1,
      capturedAtMs: _nowMs,
    );

CloudSyncHistoricalAccountBinding _account() =>
    CloudSyncHistoricalAccountBinding(
      accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      protectedStoreIdentity: 'obcs2.store.${_t('S')}',
    );

void main() {
  test('eligible row roundtrips with identical eligibility', () {
    final view = _row();
    final encoded = encodeHistoricalSnapshotRow(view);
    final decoded = decodeHistoricalSnapshotRow(
      encoded,
      snapshotSha256: _snapshot,
    );
    expect(encodeHistoricalSnapshotRow(decoded), encoded);
    expect(decoded.rowSnapshotSha256, _snapshot);
    expect(decoded.isFromMe, isFalse);
    expect(decoded.senderAddress, 'peer@example.com');
    expect(decoded.chat.participantAddress, 'peer@example.com');
    expect(decoded.attributedBodies.single.string, 'hello history');
    final before = assessHistoricalArchiveRow(
      view,
      _manifest(),
      _account(),
      nowMs: _nowMs,
    );
    final after = assessHistoricalArchiveRow(
      decoded,
      _manifest(),
      _account(),
      nowMs: _nowMs,
    );
    expect(before, isA<CloudSyncHistoricalArchiveEligible>());
    expect(after, isA<CloudSyncHistoricalArchiveEligible>());
    final beforeRequest =
        (before as CloudSyncHistoricalArchiveEligible).request;
    final afterRequest = (after as CloudSyncHistoricalArchiveEligible).request;
    expect(afterRequest.sourceSha256, beforeRequest.sourceSha256);
    expect(afterRequest.guidHash, beforeRequest.guidHash);
    expect(afterRequest.textSha256, beforeRequest.textSha256);
    expect(afterRequest.origin, beforeRequest.origin);
    expect(afterRequest.senderAddress, beforeRequest.senderAddress);
    expect(afterRequest.peerAddress, beforeRequest.peerAddress);
  });

  test('unsupported markers survive the roundtrip unchanged', () {
    final view = _row(
      isFromMe: null,
      senderAddress: null,
      hasAttachments: true,
      attachmentCount: 2,
      bodies: [
        AttributedBody(
          string: 'hello history',
          runs: [
            Run(
              range: [0, 13],
              attributes: Attributes(
                messagePart: 0,
                attachmentGuid: 'attach-1',
                mention: 'peer@example.com',
                bold: true,
              ),
            ),
          ],
        ),
      ],
      hasActualEditOrUnsend: true,
      dateEditedPresent: true,
      associationPresent: true,
      threadOriginatorPresent: true,
      dateScheduledPresent: true,
      subjectPresent: true,
      expressiveSendStyleIdPresent: true,
      balloonBundleIdPresent: true,
      payloadDataPresent: true,
      hasApplePayloadData: true,
      amkSessionIdPresent: true,
      groupTitle: 'renamed group',
    );
    final encoded = encodeHistoricalSnapshotRow(view);
    final decoded = decodeHistoricalSnapshotRow(
      encoded,
      snapshotSha256: _snapshot,
    );
    expect(encodeHistoricalSnapshotRow(decoded), encoded);
    expect(decoded.isFromMe, isNull);
    expect(decoded.senderAddress, isNull);
    expect(decoded.hasAttachments, isTrue);
    expect(decoded.attachmentCount, 2);
    expect(decoded.hasActualEditOrUnsend, isTrue);
    expect(decoded.dateEditedPresent, isTrue);
    expect(decoded.associationPresent, isTrue);
    expect(decoded.threadOriginatorPresent, isTrue);
    expect(decoded.subjectPresent, isTrue);
    expect(decoded.hasApplePayloadData, isTrue);
    expect(decoded.amkSessionIdPresent, isTrue);
    expect(decoded.groupTitle, 'renamed group');
    final run = decoded.attributedBodies.single.runs.single;
    expect(run.attributes!.attachmentGuid, 'attach-1');
    expect(run.attributes!.mention, 'peer@example.com');
    expect(run.attributes!.bold, isTrue);
    final before = assessHistoricalArchiveRow(
      view,
      _manifest(),
      _account(),
      nowMs: _nowMs,
    );
    final after = assessHistoricalArchiveRow(
      decoded,
      _manifest(),
      _account(),
      nowMs: _nowMs,
    );
    expect(before, isA<CloudSyncHistoricalArchiveIneligible>());
    expect(after, isA<CloudSyncHistoricalArchiveIneligible>());
    expect(
      (before as CloudSyncHistoricalArchiveIneligible).reason,
      (after as CloudSyncHistoricalArchiveIneligible).reason,
    );
  });

  test('decoded views share no mutable state with their source', () {
    final view = _row();
    final encoded = encodeHistoricalSnapshotRow(view);
    final first = decodeHistoricalSnapshotRow(
      encoded,
      snapshotSha256: _snapshot,
    );
    expect(identical(first.attributedBodies, view.attributedBodies), isFalse);
    first.attributedBodies.add(AttributedBody.raw('mutation'));
    first.attributedBodies.first.runs.add(
      Run(range: [0, 1], attributes: Attributes(messagePart: 9)),
    );
    final second = decodeHistoricalSnapshotRow(
      encoded,
      snapshotSha256: _snapshot,
    );
    expect(second.attributedBodies, hasLength(1));
    expect(second.attributedBodies.single.runs, hasLength(1));
    expect(encodeHistoricalSnapshotRow(second), encoded);
  });

  test('malformed, tampered, truncated and noncanonical rows rejected', () {
    final encoded = encodeHistoricalSnapshotRow(_row());
    final base = List<dynamic>.of(jsonDecode(encoded) as List);
    String withSlot(int slot, Object? value) {
      final copy = List<dynamic>.of(base);
      copy[slot] = value;
      return jsonEncode(copy);
    }

    final bodies = List<dynamic>.of(base[4] as List);
    final tamperedBody = Map<String, dynamic>.of(
      bodies.single as Map<String, dynamic>,
    );
    tamperedBody['unknownFutureKey'] = 'x';
    final bodiesWithUnknown = List<dynamic>.of(bodies)..[0] = tamperedBody;
    final bad = <String>[
      'not json',
      jsonEncode({'row': 'object not list'}),
      jsonEncode(base.sublist(0, 34)),
      jsonEncode([...base, 'extra']),
      withSlot(0, 2),
      withSlot(1, 'wrongTag'),
      withSlot(2, 7),
      withSlot(8, 'not-a-bool'),
      withSlot(20, '42'),
      withSlot(10, {'chat': 'object not list'}),
      withSlot(4, 'bodies not a list'),
      withSlot(4, bodiesWithUnknown),
      encoded.substring(0, encoded.length - 10),
      '',
    ];
    for (final candidate in bad) {
      expect(
        () => decodeHistoricalSnapshotRow(candidate, snapshotSha256: _snapshot),
        throwsStateError,
      );
    }
  });

  test('oversize rows rejected on encode and decode', () {
    final big = _row(text: 'y' * (1024 * 1024));
    expect(() => encodeHistoricalSnapshotRow(big), throwsStateError);
    expect(
      () => decodeHistoricalSnapshotRow(
        'x' * (1024 * 1024 + 1),
        snapshotSha256: _snapshot,
      ),
      throwsStateError,
    );
  });

  test('caller digest is shape-checked but never proves ownership', () {
    final encoded = encodeHistoricalSnapshotRow(_row());
    expect(
      () => decodeHistoricalSnapshotRow(encoded, snapshotSha256: 'zz'),
      throwsStateError,
    );
    expect(
      () => decodeHistoricalSnapshotRow(encoded, snapshotSha256: _h('b')),
      returnsNormally,
    );
    final restamped = decodeHistoricalSnapshotRow(
      encoded,
      snapshotSha256: _h('b'),
    );
    expect(restamped.rowSnapshotSha256, _h('b'));
    expect(encodeHistoricalSnapshotRow(restamped), encoded);
    final mismatched = assessHistoricalArchiveRow(
      restamped,
      _manifest(),
      _account(),
      nowMs: _nowMs,
    );
    expect(mismatched, isA<CloudSyncHistoricalArchiveIneligible>());
    expect(
      (mismatched as CloudSyncHistoricalArchiveIneligible).reason,
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
  });

  test('empty body list roundtrips without gaining a body', () {
    final view = _row(text: null, bodies: []);
    final encoded = encodeHistoricalSnapshotRow(view);
    final decoded = decodeHistoricalSnapshotRow(
      encoded,
      snapshotSha256: _snapshot,
    );
    expect(encodeHistoricalSnapshotRow(decoded), encoded);
    expect(decoded.text, isNull);
    expect(decoded.attributedBodies, isEmpty);
  });

  test('non-JSON sticker data reports only the fixed failure code', () {
    final view = _row(
      bodies: [
        AttributedBody(
          string: 'private source',
          runs: [
            Run(
              range: [0, 14],
              attributes: Attributes(
                stickerData: StickerData(
                  msgWidth: double.nan,
                  rotation: 0,
                  sai: 0,
                  scale: 1,
                  update: null,
                  sli: 0,
                  normalizedX: 0,
                  normalizedY: 0,
                  version: 1,
                  hash: 'private-sticker-hash',
                  safi: 0,
                  effectType: 0,
                  stickerId: 'private-id',
                ),
              ),
            ),
          ],
        ),
      ],
    );
    expect(
      () => encodeHistoricalSnapshotRow(view),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'reason',
          'cloud_sync_historical_snapshot_row_invalid',
        ),
      ),
    );
  });
}
