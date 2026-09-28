import 'dart:convert';

import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_chat_state.dart';
import 'cloud_sync_historical_attachment_inventory.dart';

/// Canonical v1 snapshot codec with additive group, parent and attachment fields.
/// Existing ten/eleven-field chat rows re-encode byte-exactly; missing metadata
/// is never reconstructed from current state. These fields grant no upload.
///
/// The encoder preserves every row/chat field the eligibility check reads,
/// including unsupported markers (unknown direction, attachments, edits,
/// groups, SMS, rich payloads): it never filters, only records. Attributed
/// bodies travel through the existing [AttributedBody] toMap/fromMap.
/// [CloudSyncHistoricalRowView.rowSnapshotSha256] is excluded from the
/// encoded content so the snapshot hash never describes itself; the decoder
/// stamps the caller-qualified snapshot hash after shape validation only,
/// which never authenticates ownership. Decoded views share no mutable
/// state with the input: bodies and nested runs are rebuilt via fromMap.
/// All failures use one fixed content-free code; no row content ever
/// appears in an error.
const String _invalid = 'cloud_sync_historical_snapshot_row_invalid';

/// Bound for the UTF-8 bytes of one encoded row, applied before decode and
/// before returning an encoding.
const int _maxRowBytes = 1024 * 1024;

const String _tag = 'historicalSnapshotRow';

/// 2 envelope slots plus 33 row slots (chat nested); rowSnapshotSha256 is
/// deliberately not among them. A final optional inventory preserves stored
/// attachment metadata. Old 35-field rows retain their exact representation.
const int _fieldCount = 35;
const int _chatFieldCount = 10;

final RegExp _digest = RegExp(r'^[a-f0-9]{64}$');

/// Encodes one row view into its canonical string form.
String encodeHistoricalSnapshotRow(CloudSyncHistoricalRowView view) {
  try {
    final encoded = jsonEncode(_rowFields(view));
    if (encoded.length > _maxRowBytes ||
        utf8.encode(encoded).length > _maxRowBytes) {
      throw StateError(_invalid);
    }
    return encoded;
  } catch (_) {
    // Bad stored rich metadata must not leak content through JSON's exception.
    throw StateError(_invalid);
  }
}

/// Decodes one canonical row and stamps the caller-qualified snapshot hash.
/// The hash is shape-validated only; this never proves snapshot ownership.
CloudSyncHistoricalRowView decodeHistoricalSnapshotRow(
  String encoded, {
  required String snapshotSha256,
}) {
  if (!_digest.hasMatch(snapshotSha256)) {
    throw StateError(_invalid);
  }
  if (encoded.length > _maxRowBytes ||
      utf8.encode(encoded).length > _maxRowBytes) {
    throw StateError(_invalid);
  }
  final dynamic value;
  try {
    value = jsonDecode(encoded);
  } on FormatException {
    throw StateError(_invalid);
  }
  final CloudSyncHistoricalRowView view;
  try {
    view = _rowView(value, snapshotSha256);
  } catch (error) {
    if (error is StateError && error.message == _invalid) rethrow;
    throw StateError(_invalid);
  }
  if (encodeHistoricalSnapshotRow(view) != encoded) {
    throw StateError(_invalid);
  }
  return view;
}

List<Object?> _rowFields(CloudSyncHistoricalRowView view) => <Object?>[
  1,
  _tag,
  view.guid,
  view.text,
  view.attributedBodies.map((body) => body.toMap()).toList(),
  view.hasActualEditOrUnsend,
  view.dateEditedPresent,
  view.associationPresent,
  view.isFromMe,
  view.senderAddress,
  _chatFields(view.chat),
  view.dateCreatedMs,
  view.error,
  view.isTemp,
  view.stagingGuid,
  view.sendingServiceId,
  view.hasBeenForwarded,
  view.verificationFailed,
  view.ckRecordId,
  view.ckSyncState,
  view.messageId,
  view.itemType,
  view.groupActionType,
  view.groupTitle,
  view.isDeleted,
  view.dateScheduledPresent,
  view.threadOriginatorPresent,
  view.hasAttachments,
  view.attachmentCount,
  view.subjectPresent,
  view.expressiveSendStyleIdPresent,
  view.balloonBundleIdPresent,
  view.payloadDataPresent,
  view.hasApplePayloadData,
  view.amkSessionIdPresent,
  if (view.attachmentInventory case final inventory?) inventory.toWire(),
];

List<Object?> _chatFields(CloudSyncHistoricalChatView chat) => <Object?>[
  chat.id,
  chat.guid,
  chat.style,
  chat.chatIdentifier,
  chat.isRoutingStub,
  chat.dateDeletedPresent,
  chat.isRpSms,
  chat.participantCount,
  chat.participantAddress,
  chat.participantService,
  if (chat.groupMetadata != null || chat.parentState != null)
    chat.groupMetadata?.toWire(),
  if (chat.parentState case final parent?) parent.toWire(),
];

CloudSyncHistoricalRowView _rowView(Object? value, String snapshotSha256) {
  if (value is! List ||
      (value.length != _fieldCount && value.length != _fieldCount + 1) ||
      value[0] != 1 ||
      value[1] != _tag) {
    throw StateError(_invalid);
  }
  return CloudSyncHistoricalRowView(
    guid: _string(value[2]),
    text: _optionalString(value[3]),
    attributedBodies: _bodies(value[4]),
    hasActualEditOrUnsend: _boolean(value[5]),
    dateEditedPresent: _boolean(value[6]),
    associationPresent: _boolean(value[7]),
    isFromMe: _optionalBoolean(value[8]),
    senderAddress: _optionalString(value[9]),
    chat: _chat(value[10]),
    dateCreatedMs: _integer(value[11]),
    error: _integer(value[12]),
    isTemp: _boolean(value[13]),
    stagingGuid: _optionalString(value[14]),
    sendingServiceId: _optionalString(value[15]),
    hasBeenForwarded: _boolean(value[16]),
    verificationFailed: _boolean(value[17]),
    ckRecordId: _optionalString(value[18]),
    ckSyncState: _boolean(value[19]),
    messageId: _integer(value[20]),
    itemType: _integer(value[21]),
    groupActionType: _integer(value[22]),
    groupTitle: _optionalString(value[23]),
    isDeleted: _boolean(value[24]),
    dateScheduledPresent: _boolean(value[25]),
    threadOriginatorPresent: _boolean(value[26]),
    hasAttachments: _boolean(value[27]),
    attachmentCount: _integer(value[28]),
    subjectPresent: _boolean(value[29]),
    expressiveSendStyleIdPresent: _boolean(value[30]),
    balloonBundleIdPresent: _boolean(value[31]),
    payloadDataPresent: _boolean(value[32]),
    hasApplePayloadData: _boolean(value[33]),
    amkSessionIdPresent: _boolean(value[34]),
    rowSnapshotSha256: snapshotSha256,
    attachmentInventory: value.length == _fieldCount + 1
        ? CloudSyncHistoricalAttachmentInventory.fromWire(value[35])
        : null,
  );
}

CloudSyncHistoricalChatView _chat(Object? value) {
  if (value is! List ||
      (value.length < _chatFieldCount || value.length > _chatFieldCount + 2)) {
    throw StateError(_invalid);
  }
  return CloudSyncHistoricalChatView(
    id: _integer(value[0]),
    guid: _string(value[1]),
    style: _optionalInteger(value[2]),
    chatIdentifier: _optionalString(value[3]),
    isRoutingStub: _boolean(value[4]),
    dateDeletedPresent: _boolean(value[5]),
    isRpSms: _boolean(value[6]),
    participantCount: _integer(value[7]),
    participantAddress: _string(value[8]),
    participantService: _string(value[9]),
    groupMetadata:
        value.length == _chatFieldCount ||
            (value.length == _chatFieldCount + 2 && value[10] == null)
        ? null
        : _groupMetadata(value[10]),
    parentState: value.length == _chatFieldCount + 2
        ? _parentState(value[11])
        : null,
  );
}

CloudSyncHistoricalChatState _parentState(Object? value) {
  if (value is! List ||
      value.length != 13 ||
      value[0] != 1 ||
      value[12] is! List) {
    throw StateError(_invalid);
  }
  final cloudData = _optionalString(value[11]);
  if (cloudData != null &&
      base64.encode(base64.decode(cloudData)) != cloudData) {
    throw StateError(_invalid);
  }
  return CloudSyncHistoricalChatState(
    cloudGuid: _optionalString(value[1]),
    usingHandle: _optionalString(value[2]),
    displayName: _optionalString(value[3]),
    groupVersion: _optionalInteger(value[4]),
    lastReadMessageGuid: _optionalString(value[5]),
    latestMessageDateMs: _optionalInteger(value[6]),
    photoAttachmentGuid: _optionalString(value[7]),
    customAvatarPresent: _boolean(value[8]),
    ckRecordId: _optionalString(value[9]),
    ckSyncState: _boolean(value[10]),
    cloudDataBase64: cloudData,
    guidRefs: (value[12] as List).map(_string),
  );
}

CloudSyncHistoricalGroupMetadata _groupMetadata(Object? value) {
  if (value is! List ||
      value.length != 3 ||
      value[0] != 1 ||
      value[2] is! List) {
    throw StateError(_invalid);
  }
  return CloudSyncHistoricalGroupMetadata(
    cloudGuid: _optionalString(value[1]),
    participants: (value[2] as List).map((member) {
      if (member is! List || member.length != 2) throw StateError(_invalid);
      return CloudSyncHistoricalParticipantView(
        address: _string(member[0]),
        service: _string(member[1]),
      );
    }),
  );
}

/// Rebuilt bodies share no mutable state with the encoded input: every body
/// and nested run is reconstructed through fromMap into fresh objects.
List<AttributedBody> _bodies(Object? value) {
  if (value is! List) throw StateError(_invalid);
  return List<AttributedBody>.of(
    value.map((body) {
      if (body is! Map) throw StateError(_invalid);
      return AttributedBody.fromMap(
        Map<String, dynamic>.of(
          body.map((key, entry) => MapEntry(key as String, entry)),
        ),
      );
    }),
  );
}

String _string(Object? value) {
  if (value is! String) throw StateError(_invalid);
  _bound(value);
  return value;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  return _string(value);
}

bool _boolean(Object? value) {
  if (value is! bool) throw StateError(_invalid);
  return value;
}

bool? _optionalBoolean(Object? value) {
  if (value == null) return null;
  return _boolean(value);
}

int _integer(Object? value) {
  if (value is! int) throw StateError(_invalid);
  return value;
}

int? _optionalInteger(Object? value) {
  if (value == null) return null;
  return _integer(value);
}

void _bound(String value) {
  // Length only: NUL and other controls travel through JSON escapes
  // canonically, and ineligible rows must remain archivable.
  if (utf8.encode(value).length > _maxRowBytes) {
    throw StateError(_invalid);
  }
}
