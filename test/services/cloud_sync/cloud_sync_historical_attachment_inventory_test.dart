import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_attachment_inventory.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure inventory tests: no database, no native bridge, no file access.
/// Capture is source evidence only and never authorizes an upload.
const _invalid = 'cloud_sync_historical_attachment_inventory_invalid';

Attachment _attachment({
  int? id,
  int? originalRowId,
  String? guid,
  String? uti = 'public.jpeg',
  String? mimeType = 'image/jpeg',
  bool? isOutgoing = true,
  String? transferName = 'photo.jpg',
  int? totalBytes = 128,
  int? height = 2,
  int? width = 1,
  String? webUrl,
  bool hasLivePhoto = false,
  String? ckRecordId,
  Map<String, dynamic>? metadata,
}) => Attachment(
  id: id,
  originalROWID: originalRowId,
  guid: guid,
  uti: uti,
  mimeType: mimeType,
  isOutgoing: isOutgoing,
  transferName: transferName,
  totalBytes: totalBytes,
  height: height,
  width: width,
  metadata: metadata,
  webUrl: webUrl,
  hasLivePhoto: hasLivePhoto,
)..ckRecordId = ckRecordId;

void _expectInvalid(Object? Function() run) {
  try {
    run();
  } on StateError catch (error) {
    expect(error.message, _invalid);
    return;
  }
  fail('expected StateError($_invalid)');
}

class _UnexpectedJson {
  var called = false;
  Object toJson() {
    called = true;
    return {'unexpected': true};
  }
}

void main() {
  test('capture preserves every stored field including owner ids', () {
    final attachment = _attachment(
      id: 9,
      originalRowId: 102,
      guid: 'abc123',
      ckRecordId: 'ck1',
      metadata: {'b': 2, 'a': 1},
    )..message.targetId = 42;
    final inventory = CloudSyncHistoricalAttachmentInventory.capture([
      attachment,
    ]);
    expect(inventory.attachments, hasLength(1));
    final state = inventory.attachments.single;
    expect(state.id, 9);
    expect(state.originalRowId, 102);
    expect(state.guid, 'abc123');
    expect(state.messageId, 42);
    expect(state.uti, 'public.jpeg');
    expect(state.mimeType, 'image/jpeg');
    expect(state.isOutgoing, isTrue);
    expect(state.transferName, 'photo.jpg');
    expect(state.totalBytes, 128);
    expect(state.height, 2);
    expect(state.width, 1);
    expect(state.webUrl, isNull);
    expect(state.hasLivePhoto, isFalse);
    expect(state.ckRecordId, 'ck1');
    expect(state.metadataJson, '{"a":1,"b":2}');
  });

  test('null and odd stored values are preserved as evidence', () {
    final attachment = _attachment(
      uti: '',
      mimeType: null,
      isOutgoing: null,
      transferName: '',
      totalBytes: 0,
      height: null,
      width: -1,
    );
    final state = CloudSyncHistoricalAttachmentInventory.capture([
      attachment,
    ]).attachments.single;
    expect(state.id, isNull);
    expect(state.originalRowId, isNull);
    expect(state.guid, isNull);
    expect(state.uti, '');
    expect(state.mimeType, isNull);
    expect(state.isOutgoing, isNull);
    expect(state.transferName, '');
    expect(state.totalBytes, 0);
    expect(state.height, isNull);
    expect(state.width, -1);
    expect(state.metadataJson, isNull);
  });

  test('metadata keeps exact strings and detaches from later mutation', () {
    const xml =
        '<plist version="1.0"><dict><key>k</key><string>v \u00e9</string></dict></plist>';
    final nested = {
      'list': [1, 'x'],
      'map': {'inner': true},
    };
    final metadata = <String, dynamic>{'xml': xml, 'nested': nested};
    final attachment = _attachment(metadata: metadata);
    final inventory = CloudSyncHistoricalAttachmentInventory.capture([
      attachment,
    ]);
    final before = inventory.attachments.single.metadataJson!;
    expect(jsonDecode(before)['xml'], xml);
    (nested['list'] as List).add('mutated');
    (nested['map'] as Map)['inner'] = false;
    metadata['xml'] = 'replaced';
    expect(inventory.attachments.single.metadataJson, before);
    final roundtrip = CloudSyncHistoricalAttachmentInventory.fromWire(
      inventory.toWire(),
    );
    expect(roundtrip.attachments.single.metadataJson, before);
  });

  test('wire roundtrip preserves the full inventory', () {
    final inventory = CloudSyncHistoricalAttachmentInventory.capture([
      _attachment(id: 1, guid: 'a', metadata: {'k': 'v'}),
      _attachment(id: null, guid: null),
    ]);
    final wire = inventory.toWire();
    expect(wire[0], 1);
    expect((wire[1] as List), hasLength(2));
    final restored = CloudSyncHistoricalAttachmentInventory.fromWire(wire);
    expect(restored.attachments, hasLength(2));
    expect(restored.attachments[0].id, 1);
    expect(restored.attachments[0].guid, 'a');
    expect(restored.attachments[0].metadataJson, '{"k":"v"}');
    expect(restored.attachments[1].id, isNull);
    expect(
      CloudSyncHistoricalAttachmentInventory.fromWire(
        restored.toWire(),
      ).toWire(),
      wire,
    );
  });

  test('collections are immutable and wire output is detached', () {
    final inventory = CloudSyncHistoricalAttachmentInventory.capture([
      _attachment(guid: 'a'),
    ]);
    expect(
      () => inventory.attachments.add(inventory.attachments.single),
      throwsUnsupportedError,
    );
    final first = inventory.toWire();
    ((first[1] as List).single as List)[3] = 'mutated';
    expect(inventory.attachments.single.guid, 'a');
    expect((inventory.toWire()[1] as List).single[3], 'a');
  });

  test('malformed wire values are rejected with the fixed redacted error', () {
    _expectInvalid(() => CloudSyncHistoricalAttachmentInventory.fromWire('x'));
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire([2, []]),
    );
    _expectInvalid(() => CloudSyncHistoricalAttachmentInventory.fromWire([1]));
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire([1, [], 'extra']),
    );
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire([
        1,
        [[]],
      ]),
    );
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire([
        1,
        [
          [2],
        ],
      ]),
    );
    final good = CloudSyncHistoricalAttachmentInventory.capture([
      _attachment(guid: 'a'),
    ]).toWire();
    final states = good[1] as List;
    final state = List<Object?>.of(states.single as List);
    final wrongVersion = [
      2,
      [state],
    ];
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire(wrongVersion),
    );
    final wrongStateVersion = [
      1,
      [List<Object?>.of(state)..[0] = 2],
    ];
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire(wrongStateVersion),
    );
    final short = [
      1,
      [state.sublist(0, 15)],
    ];
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire(short),
    );
    final nullMessage = [
      1,
      [List<Object?>.of(state)..[4] = null],
    ];
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire(nullMessage),
    );
    final nullLivePhoto = [
      1,
      [List<Object?>.of(state)..[13] = null],
    ];
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire(nullLivePhoto),
    );
    final nonCanonical = [
      1,
      [List<Object?>.of(state)..[15] = '{"z":1,"a":2}'],
    ];
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire(nonCanonical),
    );
    final nonStringMetadata = [
      1,
      [List<Object?>.of(state)..[15] = 7],
    ];
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.fromWire(nonStringMetadata),
    );
  });

  test('bounds reject oversized inventories and metadata', () {
    final sixtyFour = CloudSyncHistoricalAttachmentInventory.capture(
      List.generate(64, (i) => _attachment(guid: 'g$i')),
    );
    expect(sixtyFour.attachments, hasLength(64));
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.capture(
        List.generate(65, (i) => _attachment(guid: 'g$i')),
      ),
    );
    final big = 'x' * (1024 * 1024 + 1);
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.capture([
        _attachment(metadata: {'big': big}),
      ]),
    );
    Map<String, dynamic> deep = {'leaf': 1};
    for (var i = 0; i < 17; i++) {
      deep = {'nest': deep};
    }
    _expectInvalid(
      () => CloudSyncHistoricalAttachmentInventory.capture([
        _attachment(metadata: deep),
      ]),
    );
  });

  test(
    'capture and decode reject custom serialization without invoking it',
    () {
      final opaque = _UnexpectedJson();
      _expectInvalid(
        () => CloudSyncHistoricalAttachmentInventory.capture([
          _attachment(metadata: {'opaque': opaque}),
        ]),
      );
      expect(opaque.called, isFalse);
      final state = CloudSyncHistoricalAttachmentInventory.capture([
        _attachment(),
      ]).attachments.single.toWire()..[15] = opaque;
      _expectInvalid(
        () => CloudSyncHistoricalAttachmentInventory.fromWire([
          1,
          [state],
        ]),
      );
      expect(opaque.called, isFalse);
    },
  );

  test('descriptions redact stored identifiers and names', () {
    final inventory = CloudSyncHistoricalAttachmentInventory.capture([
      _attachment(guid: 'secret-guid', transferName: 'secret.jpg'),
    ]);
    expect(
      inventory.toString(),
      'CloudSyncHistoricalAttachmentInventory(redacted)',
    );
    expect(
      inventory.attachments.single.toString(),
      'CloudSyncHistoricalAttachmentState(redacted)',
    );
    expect(inventory.attachments.single.toString().contains('secret'), isFalse);
  });
}
