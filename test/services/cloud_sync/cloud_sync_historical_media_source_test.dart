import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_attachment_inventory.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_media_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure media-source tests: no database, no native bridge, no file access.
/// Capture is source evidence only and never authorizes an upload.
const _invalid = 'cloud_sync_historical_media_source_invalid';

const _chat = CloudSyncHistoricalChatView(
  id: 1,
  guid: 'chat-guid',
  style: 45,
  chatIdentifier: 'peer@example.invalid',
  isRoutingStub: false,
  dateDeletedPresent: false,
  isRpSms: false,
  participantCount: 1,
  participantAddress: 'peer@example.invalid',
  participantService: 'iMessage',
);

Attachment _part({
  required int id,
  required String guid,
  required int messageId,
  Map<String, dynamic>? metadata,
}) {
  final attachment = Attachment(
    id: id,
    guid: guid,
    uti: 'public.jpeg',
    mimeType: 'image/jpeg',
    isOutgoing: true,
    transferName: 'photo.jpg',
    totalBytes: 128,
    metadata: metadata,
  );
  attachment.message.targetId = messageId;
  return attachment;
}

CloudSyncHistoricalAttachmentInventory _inventoryOf(List<Attachment> parts) =>
    CloudSyncHistoricalAttachmentInventory.capture(parts);

CloudSyncHistoricalRowView _row({
  required int messageId,
  String guid = 'row-guid',
  String? text,
  List<AttributedBody> bodies = const [],
  CloudSyncHistoricalAttachmentInventory? inventory,
  bool hasAttachments = false,
  int attachmentCount = 0,
}) => CloudSyncHistoricalRowView(
  guid: guid,
  text: text,
  attributedBodies: bodies,
  hasActualEditOrUnsend: false,
  dateEditedPresent: false,
  associationPresent: false,
  isFromMe: true,
  senderAddress: 'owner@example.invalid',
  chat: _chat,
  dateCreatedMs: 1700000000000,
  error: 0,
  isTemp: false,
  stagingGuid: null,
  sendingServiceId: null,
  hasBeenForwarded: false,
  verificationFailed: false,
  ckRecordId: null,
  ckSyncState: false,
  messageId: messageId,
  itemType: 0,
  groupActionType: 0,
  groupTitle: null,
  isDeleted: false,
  dateScheduledPresent: false,
  threadOriginatorPresent: false,
  hasAttachments: hasAttachments,
  attachmentCount: attachmentCount,
  subjectPresent: false,
  expressiveSendStyleIdPresent: false,
  balloonBundleIdPresent: false,
  payloadDataPresent: false,
  hasApplePayloadData: false,
  amkSessionIdPresent: false,
  rowSnapshotSha256: 'a' * 64,
  attachmentInventory: inventory,
);

AttributedBody _textBody(String value, {int part = 0}) => AttributedBody(
  string: value,
  runs: [
    Run(
      range: [0, value.length],
      attributes: Attributes(messagePart: part),
    ),
  ],
);

AttributedBody _markerBody(List<String> guids, {int firstPart = 0}) {
  final runs = <Run>[];
  for (var i = 0; i < guids.length; i++) {
    runs.add(
      Run(
        range: [i, 1],
        attributes: Attributes(
          messagePart: firstPart + i,
          attachmentGuid: guids[i],
        ),
      ),
    );
  }
  return AttributedBody(string: ' ' * guids.length, runs: runs);
}

void _expectInvalid(Object? Function() run) {
  try {
    run();
  } on StateError catch (error) {
    expect(error.message, _invalid);
    return;
  }
  fail('expected StateError($_invalid)');
}

void main() {
  test('photo-only null text captures and roundtrips', () {
    final inventory = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
    ]);
    final source = CloudSyncHistoricalMediaSource.capture(
      _row(
        messageId: 7,
        bodies: [_markerBody(['row-guid_0'])],
        inventory: inventory,
        hasAttachments: true,
        attachmentCount: 1,
      ),
    );
    expect(source.messageId, 7);
    expect(source.originalText, isNull);
    expect(source.inventory.attachments.single.guid, 'row-guid_0');
    final wire = source.toWire();
    expect(wire[0], 1);
    expect(wire[1], 7);
    final restored = CloudSyncHistoricalMediaSource.fromWire(wire);
    expect(restored.toWire(), wire);
    expect(restored.inventory.attachments.single.id, 1);
  });

  test('emoji caption tiles surrogate pairs without splitting', () {
    const caption = 'hi \u{1F600}';
    final inventory = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
    ]);
    final source = CloudSyncHistoricalMediaSource.capture(
      _row(
        messageId: 7,
        text: caption,
        bodies: [_textBody(caption), _markerBody(['row-guid_0'])],
        inventory: inventory,
        hasAttachments: true,
        attachmentCount: 1,
      ),
    );
    expect(source.originalText, caption);
    expect(
      CloudSyncHistoricalMediaSource.fromWire(source.toWire()).originalText,
      caption,
    );
    final split = AttributedBody(
      string: caption,
      runs: [
        Run(range: [0, 4], attributes: Attributes(messagePart: 0)),
        Run(range: [4, 1], attributes: Attributes(messagePart: 1)),
      ],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          text: caption,
          bodies: [split, _markerBody(['row-guid_0'])],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          text: 'a\uD800b',
          bodies: [_textBody('a\uD800b'), _markerBody(['row-guid_0'])],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          text: 'a\u0000b',
          bodies: [_textBody('a\u0000b'), _markerBody(['row-guid_0'])],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
  });

  test('multiattachment multipart order is preserved', () {
    final inventory = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
      _part(id: 2, guid: 'row-guid_1', messageId: 7),
    ]);
    final first = AttributedBody(
      string: 'a ',
      runs: [
        Run(range: [0, 1], attributes: Attributes(messagePart: 0)),
        Run(
          range: [1, 1],
          attributes: Attributes(messagePart: 1, attachmentGuid: 'row-guid_0'),
        ),
      ],
    );
    final second = AttributedBody(
      string: 'b ',
      runs: [
        Run(range: [0, 1], attributes: Attributes(messagePart: 2)),
        Run(
          range: [1, 1],
          attributes: Attributes(messagePart: 3, attachmentGuid: 'row-guid_1'),
        ),
      ],
    );
    final source = CloudSyncHistoricalMediaSource.capture(
      _row(
        messageId: 7,
        text: 'a b ',
        bodies: [first, second],
        inventory: inventory,
        hasAttachments: true,
        attachmentCount: 2,
      ),
    );
    final decoded = (jsonDecode(source.bodyJson) as List)
        .map((entry) => AttributedBody.fromMap((entry as Map).cast<String, Object>()))
        .toList();
    expect(decoded, hasLength(2));
    expect(decoded[0].string, 'a ');
    expect(decoded[1].string, 'b ');
    expect(
      decoded[1].runs[1].attributes?.attachmentGuid,
      'row-guid_1',
    );
    expect(
      CloudSyncHistoricalMediaSource.fromWire(source.toWire()).bodyJson,
      source.bodyJson,
    );
  });

  test('mutation of original models after capture changes nothing', () {
    final attachment = _part(
      id: 1,
      guid: 'row-guid_0',
      messageId: 7,
      metadata: {'nested': {'a': 1}},
    );
    final inventory = _inventoryOf([attachment]);
    final body = _markerBody(['row-guid_0']);
    final source = CloudSyncHistoricalMediaSource.capture(
      _row(
        messageId: 7,
        bodies: [body],
        inventory: inventory,
        hasAttachments: true,
        attachmentCount: 1,
      ),
    );
    final frozen = source.toWire();
    (attachment.metadata!['nested'] as Map)['a'] = 999;
    body.runs.single.range[0] = 5;
    expect(source.toWire(), frozen);
    expect(source.inventory.attachments.single.metadataJson, isNotNull);
  });

  test('backlink count and reference conflicts fail closed', () {
    final inventory = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
    ]);
    final body = _markerBody(['row-guid_0']);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 9,
          bodies: [body],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    final two = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
      _part(id: 2, guid: 'row-guid_1', messageId: 7),
    ]);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['row-guid_0'])],
          inventory: two,
          hasAttachments: true,
          attachmentCount: 2,
        ),
      ),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['unknown_9'])],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['other_0'])],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['row-guid_0'])],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 2,
        ),
      ),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [
            AttributedBody(
              string: '  ',
              runs: [
                Run(
                  range: [0, 1],
                  attributes: Attributes(messagePart: 0, attachmentGuid: 'row-guid_0'),
                ),
                Run(
                  range: [1, 1],
                  attributes: Attributes(messagePart: 1, attachmentGuid: 'row-guid_0'),
                ),
              ],
            ),
          ],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    final foreign = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 9),
    ]);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['row-guid_0'])],
          inventory: foreign,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
  });

  test('aliased guids match including underscores, mismatched owners fail', () {
    final inventory = _inventoryOf([
      _part(id: 1, guid: 'a_b_c_2', messageId: 7),
    ]);
    final apple = CloudSyncHistoricalMediaSource.capture(
      _row(
        guid: 'a_b_c',
        messageId: 7,
        bodies: [_markerBody(['at_2_a_b_c'])],
        inventory: inventory,
        hasAttachments: true,
        attachmentCount: 1,
      ),
    );
    expect(apple.inventory.attachments.single.guid, 'a_b_c_2');
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          guid: 'a_b_c',
          messageId: 7,
          bodies: [_markerBody(['x_y_2'])],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          guid: 'a_b_c',
          messageId: 7,
          bodies: [_markerBody(['a_b_c_3'])],
          inventory: inventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
  });

  test('malformed spans gaps overlap and markers are rejected', () {
    final dummy = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
    ]);
    CloudSyncHistoricalRowView defective({
      String? text,
      required List<AttributedBody> bodies,
    }) => _row(
      messageId: 7,
      text: text,
      bodies: bodies,
      inventory: dummy,
      hasAttachments: true,
      attachmentCount: 1,
    );
    AttributedBody gap(String value) => AttributedBody(
      string: value,
      runs: [
        Run(range: [0, 1], attributes: Attributes(messagePart: 0)),
        Run(range: [2, 1], attributes: Attributes(messagePart: 1)),
      ],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        defective(text: 'abc', bodies: [gap('abc')]),
      ),
    );
    final overlap = AttributedBody(
      string: 'abc',
      runs: [
        Run(range: [0, 2], attributes: Attributes(messagePart: 0)),
        Run(range: [1, 2], attributes: Attributes(messagePart: 1)),
      ],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        defective(text: 'abc', bodies: [overlap]),
      ),
    );
    final zero = AttributedBody(
      string: 'abc',
      runs: [
        Run(range: [0, 0], attributes: Attributes(messagePart: 0)),
        Run(range: [0, 3], attributes: Attributes(messagePart: 1)),
      ],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        defective(text: 'abc', bodies: [zero]),
      ),
    );
    final bareReplacement = AttributedBody(
      string: 'a\uFFFCb',
      runs: [Run(range: [0, 3], attributes: Attributes(messagePart: 0))],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        defective(text: 'ab', bodies: [bareReplacement]),
      ),
    );
    final longMarker = AttributedBody(
      string: '  ',
      runs: [
        Run(
          range: [0, 2],
          attributes: Attributes(messagePart: 0, attachmentGuid: 'row-guid_0'),
        ),
      ],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [longMarker],
          inventory: dummy,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    final wrongChar = AttributedBody(
      string: 'x',
      runs: [
        Run(
          range: [0, 1],
          attributes: Attributes(messagePart: 0, attachmentGuid: 'row-guid_0'),
        ),
      ],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [wrongChar],
          inventory: dummy,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    final noPart = AttributedBody(
      string: 'abc',
      runs: [Run(range: [0, 3], attributes: Attributes())],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        defective(text: 'abc', bodies: [noPart]),
      ),
    );
    final mentioned = AttributedBody(
      string: 'abc',
      runs: [
        Run(
          range: [0, 3],
          attributes: Attributes(messagePart: 0, mention: 'peer'),
        ),
      ],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        defective(text: 'abc', bodies: [mentioned]),
      ),
    );
    final styled = AttributedBody(
      string: 'abc',
      runs: [
        Run(range: [0, 3], attributes: Attributes(messagePart: 0, bold: true)),
      ],
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        defective(text: 'abc', bodies: [styled]),
      ),
    );
  });

  test('duplicate inventory ids guids and double references fail', () {
    final dupIds = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
      _part(id: 1, guid: 'row-guid_1', messageId: 7),
    ]);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['row-guid_0', 'row-guid_1'])],
          inventory: dupIds,
          hasAttachments: true,
          attachmentCount: 2,
        ),
      ),
    );
    final dupGuids = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
      _part(id: 2, guid: 'row-guid_0', messageId: 7),
    ]);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['row-guid_0'])],
          inventory: dupGuids,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    final aliasDup = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
      _part(id: 2, guid: 'at_0_row-guid', messageId: 7),
    ]);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['row-guid_0', 'at_0_row-guid'])],
          inventory: aliasDup,
          hasAttachments: true,
          attachmentCount: 2,
        ),
      ),
    );
    final missingId = CloudSyncHistoricalAttachmentInventory.capture([
      Attachment(guid: 'row-guid_0')..message.targetId = 7,
    ]);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['row-guid_0'])],
          inventory: missingId,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
  });

  test('empty bodies inventory and text require real attachments', () {
    _expectInvalid(() => CloudSyncHistoricalMediaSource.capture(_row(messageId: 7)));
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(_row(messageId: 7, text: '')),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(messageId: 7, text: 'hello'),
      ),
    );
    _expectInvalid(() => CloudSyncHistoricalMediaSource.capture(_row(messageId: 0, text: 'x')));
  });

  test('malformed wire and non-canonical bodies are rejected', () {
    final inventory = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
    ]);
    final source = CloudSyncHistoricalMediaSource.capture(
      _row(
        messageId: 7,
        bodies: [_markerBody(['row-guid_0'])],
        inventory: inventory,
        hasAttachments: true,
        attachmentCount: 1,
      ),
    );
    final wire = source.toWire();
    _expectInvalid(() => CloudSyncHistoricalMediaSource.fromWire('x'));
    _expectInvalid(() => CloudSyncHistoricalMediaSource.fromWire([2, 7, null, '[]', wire[4]]));
    _expectInvalid(() => CloudSyncHistoricalMediaSource.fromWire([1.0, 7, null, source.bodyJson, wire[4]]));
    _expectInvalid(() => CloudSyncHistoricalMediaSource.fromWire([1, 7, null]));
    _expectInvalid(() => CloudSyncHistoricalMediaSource.fromWire([1, 0, null, '[]', wire[4]]));
    _expectInvalid(() => CloudSyncHistoricalMediaSource.fromWire([1, 7, 5, '[]', wire[4]]));
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.fromWire(
        [1, 7, null, source.bodyJson, wire[4]],
        messageGuid: 'other-guid',
      ),
    );
    expect(
      CloudSyncHistoricalMediaSource.fromWire(
        [1, 7, null, source.bodyJson, wire[4]],
        messageGuid: 'row-guid',
      ).toWire(),
      wire,
    );
    final bodies = (jsonDecode(source.bodyJson) as List).toList();
    final reordered = jsonEncode(
      bodies.map((entry) {
        final map = Map<String, Object?>.of(entry as Map<String, dynamic>);
        return Map.fromEntries(map.entries.toList().reversed);
      }).toList(),
    );
    expect(reordered, isNot(source.bodyJson));
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.fromWire([1, 7, null, reordered, wire[4]]),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.fromWire([1, 7, null, '[]', wire[4]]),
    );
  });

  test('metadata survives and descriptions stay redacted', () {
    final inventory = _inventoryOf([
      _part(
        id: 1,
        guid: 'row-guid_0',
        messageId: 7,
        metadata: {'rustpush': '<plist>a</plist>'},
      ),
    ]);
    final source = CloudSyncHistoricalMediaSource.capture(
      _row(
        messageId: 7,
        bodies: [_markerBody(['row-guid_0'])],
        inventory: inventory,
        hasAttachments: true,
        attachmentCount: 1,
      ),
    );
    final stored = source.inventory.attachments.single.metadataJson!;
    expect(jsonDecode(stored)['rustpush'], '<plist>a</plist>');
    expect(
      CloudSyncHistoricalMediaSource.fromWire(source.toWire())
          .inventory
          .attachments
          .single
          .metadataJson,
      stored,
    );
    expect(source.toString(), 'CloudSyncHistoricalMediaSource(redacted)');
    expect(source.toString().contains('upload'), isFalse);
  });

  test('body bounds reject oversized layouts', () {
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          text: 'x',
          bodies: List.generate(17, (_) => _textBody('x')),
        ),
      ),
    );
    final manyRuns = AttributedBody(
      string: 'y' * 129,
      runs: List.generate(129, (i) => Run(range: [i, 1], attributes: Attributes(messagePart: i))),
    );
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(messageId: 7, text: 'y', bodies: [manyRuns]),
      ),
    );
    final big = 'z' * (256 * 1024 + 1);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(messageId: 7, text: big, bodies: [_textBody(big)]),
      ),
    );
  });

  test('guid shapes reject empty control malformed and overflow parts', () {
    for (final bad in ['', 'has space', 'at_', 'at__x', 'at_01_x']) {
      final inventory = _inventoryOf([
        _part(id: 1, guid: 'row-guid_0', messageId: 7),
      ]);
      _expectInvalid(
        () => CloudSyncHistoricalMediaSource.capture(
          _row(
            messageId: 7,
            bodies: [_markerBody([bad])],
            inventory: inventory,
            hasAttachments: true,
            attachmentCount: 1,
          ),
        ),
      );
    }
    final overflow = _inventoryOf([
      _part(id: 1, guid: 'row-guid_0', messageId: 7),
    ]);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['row-guid_4294967296'])],
          inventory: overflow,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
    final badInventory = _inventoryOf([
      _part(id: 1, guid: 'at__broken', messageId: 7),
    ]);
    _expectInvalid(
      () => CloudSyncHistoricalMediaSource.capture(
        _row(
          messageId: 7,
          bodies: [_markerBody(['at__broken'])],
          inventory: badInventory,
          hasAttachments: true,
          attachmentCount: 1,
        ),
      ),
    );
  });
}
