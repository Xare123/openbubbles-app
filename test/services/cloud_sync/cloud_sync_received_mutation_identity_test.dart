import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_identity.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic DTOs only. Literal JSON/hashes are an independent native parity
// fixture, not native execution, authenticated receive proof or remote authority.
const _event = '2C174D2E-BAA7-4435-A8D5-88BF2C969A44';
const _target = '5BC3779B-7898-4A15-A768-2EA04D3ABAA0';
const _other = 'F47AC10B-58CC-4372-A567-0E02B2C3D479';
const _group = '77777777-8888-4999-aaaa-bbbbbbbbbbbb';
const _nil = '00000000-0000-0000-0000-000000000000';
const _owner = 'mailto:owner@example.test';
const _alias = 'tel:+15550000001';
const _remote = 'mailto:sender@example.test';
const _peer = 'tel:+15550000002';
const _timestamp = 1700000000000;
const _maxInt64 = 0x7fffffffffffffff;
const _editVector =
    '["cloud-sync-received-mutation-source-v1",'
    '"2C174D2E-BAA7-4435-A8D5-88BF2C969A44",'
    '"5BC3779B-7898-4A15-A768-2EA04D3ABAA0",2,'
    '"mailto:sender@example.test","mailto:owner@example.test",1700000000000,'
    '"incoming",["mailto:owner@example.test","mailto:sender@example.test"],'
    'null,"direct-route","","edit",'
    '[["Edited message",2,true,false,true,false],["",null,false,true,false,true]],'
    '["mailto:owner@example.test"]]';
const _editHash =
    'cc2c80f32a45c86c0146e00653996b2e35df9e12171e61c86ea81f5b50eaa96f';
const _unsendVector =
    '["cloud-sync-received-mutation-source-v1",'
    '"2C174D2E-BAA7-4435-A8D5-88BF2C969A44",'
    '"5BC3779B-7898-4A15-A768-2EA04D3ABAA0",2,'
    '"mailto:sender@example.test","mailto:owner@example.test",1700000000000,'
    '"incoming",["mailto:owner@example.test","mailto:sender@example.test"],'
    'null,"direct-route","","unsend",null,["mailto:owner@example.test"]]';
const _unsendHash =
    'c9fa3e68d92535c0eb4c176e08e2ad7c8d01dca7c43fca171abf26b88de74aa4';

String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

CloudSyncReceivedArchiveLiveContext _live({
  bool observed = true,
  List<String> handles = const [_owner],
  String recipient = _owner,
}) => CloudSyncReceivedArchiveLiveContext(
  observedViaLiveReceive: observed,
  observedLocalHandles: handles,
  receivedOnHandle: recipient,
);

api.IndexedMessagePart _text(
  String text, {
  int? idx = 2,
  bool bold = true,
  bool italic = false,
  bool underline = true,
  bool strikethrough = false,
  api.PartExtension? ext,
}) => api.IndexedMessagePart(
  part_: api.MessagePart.text(
    text,
    api.TextFormat.flags(
      api.TextFlags(
        bold: bold,
        italic: italic,
        underline: underline,
        strikethrough: strikethrough,
      ),
    ),
  ),
  idx: idx,
  ext: ext,
);

List<api.IndexedMessagePart> _parts() => [
  _text('Edited message'),
  _text(
    '',
    idx: null,
    bold: false,
    italic: true,
    underline: false,
    strikethrough: true,
  ),
];

api.MessageInst _wire({
  bool unsend = false,
  bool mirrored = false,
  bool group = false,
  String id = _event,
  String targetGuid = _target,
  int targetPart = 2,
  int timestamp = _timestamp,
  List<api.IndexedMessagePart>? parts,
  List<String>? participants,
  String? recipient = _owner,
  String? cvName,
  String? senderGuid = 'direct-route',
  String? afterGuid = '',
}) => api.MessageInst(
  id: id,
  sender: mirrored ? _owner : _remote,
  conversation: api.ConversationData(
    participants: participants ?? [_remote, if (group) _peer, _owner],
    cvName: cvName,
    senderGuid: group ? _group : senderGuid,
    afterGuid: afterGuid,
  ),
  message: unsend
      ? api.Message.unsend(
          api.UnsendMessage(tuuid: targetGuid, editPart: targetPart),
        )
      : api.Message.edit(
          api.EditMessage(
            tuuid: targetGuid,
            editPart: targetPart,
            newParts: api.MessageParts(field0: parts ?? _parts()),
          ),
        ),
  sentTimestamp: timestamp,
  sendDelivered: false,
  verificationFailed: false,
  receivedOnHandle: recipient,
);

api.CertifiedContext _certified({
  String sender = _remote,
  String target = _owner,
}) => api.CertifiedContext(
  version: 1,
  receipt: Uint8List(0),
  sender: sender,
  target: target,
  uuid: Uint8List(16),
  token: Uint8List(32),
);

CloudSyncReceivedMutationIdentity? _capture(
  api.MessageInst wire, {
  CloudSyncReceivedArchiveLiveContext? context,
  String? expected,
}) => CloudSyncReceivedMutationIdentity.captureWire(
  wire,
  liveContext: context ?? _live(),
  expectedSourceSha256: expected,
);

void main() {
  test(
    'literal edit fixture pins the exact cross-language array and hashes',
    () {
      final identity = _capture(_wire())!;
      expect(jsonEncode(jsonDecode(_editVector)), _editVector);
      expect(sha256.convert(utf8.encode(_editVector)).toString(), _editHash);
      expect(identity.sourceSha256, _editHash);
      expect(
        identity.guidHash,
        'e68c641bfd4822dd10a95017fdc5b4a7f13e2e991ddd57050a24776ec53d25da',
      );
      expect(
        identity.targetGuidHash,
        '48e756afd7472c07393dfd698d00dd9395797eda745478908538fcf95d4a2432',
      );
      expect(identity.kind, CloudSyncReceivedMutationKind.edit);
      expect(identity.origin, CloudSyncReceivedArchiveOrigin.incoming);
      expect(identity.targetPart, 2);
      expect(identity.sentTimestamp, _timestamp);
      expect(_capture(_wire(), expected: _editHash), isNotNull);
    },
  );

  test('unsend pins null editParts rather than an empty edit array', () {
    final vector = jsonDecode(_editVector) as List;
    vector[12] = 'unsend';
    vector[13] = null;
    final identity = _capture(_wire(unsend: true))!;
    expect(jsonEncode(vector), _unsendVector);
    expect(sha256.convert(utf8.encode(_unsendVector)).toString(), _unsendHash);
    expect(_digest(vector), _unsendHash);
    expect(identity.sourceSha256, _unsendHash);
    expect(identity.kind, CloudSyncReceivedMutationKind.unsend);
    expect(identity.guidHash, _capture(_wire())!.guidHash);
    expect(identity.targetGuidHash, _capture(_wire())!.targetGuidHash);
    vector[13] = <Object>[];
    expect(identity.sourceSha256, isNot(_digest(vector)));
  });

  for (final mirrored in [false, true]) {
    for (final group in [false, true]) {
      for (final unsend in [false, true]) {
        test('captures mirrored=$mirrored group=$group unsend=$unsend', () {
          final wire = _wire(mirrored: mirrored, group: group, unsend: unsend);
          final identity = _capture(wire)!;
          expect(
            identity.origin,
            mirrored
                ? CloudSyncReceivedArchiveOrigin.mirrored
                : CloudSyncReceivedArchiveOrigin.incoming,
          );
          expect(
            identity.kind,
            unsend
                ? CloudSyncReceivedMutationKind.unsend
                : CloudSyncReceivedMutationKind.edit,
          );
          expect(
            identity.targetGuidHash,
            _digest(['cloud-sync-received-archive-guid-v1', _target]),
          );
        });
      }
    }
  }

  test(
    'requires live recipient observation even when the wire looks mirrored',
    () {
      for (final mirrored in [false, true]) {
        final wire = _wire(mirrored: mirrored);
        for (final context in [
          _live(observed: false),
          _live(handles: []),
          _live(handles: [_alias]),
          _live(recipient: _alias, handles: [_alias, _owner]),
        ]) {
          expect(_capture(wire, context: context), isNull);
        }
        expect(_capture(_wire(mirrored: mirrored, recipient: null)), isNull);
        expect(_capture(_wire(mirrored: mirrored, recipient: '')), isNull);
        expect(_capture(wire..verificationFailed = true), isNull);
      }
    },
  );

  test('accepts only absent empty or a single 32-byte reply token', () {
    final original = _capture(_wire())!.sourceSha256;
    for (final targets in <List<api.MessageTarget>?>[
      null,
      [],
      [api.MessageTarget.token(Uint8List(32))],
      [api.MessageTarget.token(Uint8List.fromList(List.filled(32, 255)))],
    ]) {
      expect(_capture(_wire()..target = targets)!.sourceSha256, original);
    }
    for (final targets in <List<api.MessageTarget>>[
      [const api.MessageTarget.uuid(_other)],
      [api.MessageTarget.token(Uint8List(31))],
      [api.MessageTarget.token(Uint8List(33))],
      [api.MessageTarget.token(Uint8List(0))],
      [
        api.MessageTarget.token(Uint8List(32)),
        api.MessageTarget.token(Uint8List(32)),
      ],
      [
        api.MessageTarget.token(Uint8List(32)),
        const api.MessageTarget.uuid(_other),
      ],
    ]) {
      expect(_capture(_wire()..target = targets), isNull);
    }
    expect(_capture(_wire()..sendDelivered = true)!.sourceSha256, original);
  });

  test('certified context must match exact sender and recipient', () {
    final original = _capture(_wire())!.sourceSha256;
    expect(
      _capture(_wire()..certifiedContext = _certified())!.sourceSha256,
      original,
    );
    for (final certified in [
      _certified(sender: _owner),
      _certified(target: _alias),
      _certified(sender: _remote.toUpperCase()),
      _certified(target: _owner.toUpperCase()),
    ]) {
      expect(_capture(_wire()..certifiedContext = certified), isNull);
    }
    final mirrored = _wire(mirrored: true)
      ..certifiedContext = _certified(sender: _owner);
    expect(_capture(mirrored)!.origin, CloudSyncReceivedArchiveOrigin.mirrored);
  });

  test('UUIDs are nonnil hyphenated distinct values with preserved case', () {
    for (final bad in [
      '',
      'temp-$_event',
      _nil,
      _event.replaceAll('-', ''),
      '{$_event}',
      'urn:uuid:$_event',
      '$_event\n',
      ' $_event',
      '${_event}0',
    ]) {
      expect(_capture(_wire(id: bad)), isNull, reason: 'event=$bad');
      expect(_capture(_wire(targetGuid: bad)), isNull, reason: 'target=$bad');
    }
    expect(_capture(_wire(targetGuid: _event.toLowerCase())), isNull);
    final original = _capture(_wire())!;
    final changedEvent = _capture(_wire(id: _event.toLowerCase()))!;
    final changedTarget = _capture(_wire(targetGuid: _target.toLowerCase()))!;
    expect(changedEvent.guidHash, isNot(original.guidHash));
    expect(changedEvent.sourceSha256, isNot(original.sourceSha256));
    expect(changedTarget.targetGuidHash, isNot(original.targetGuidHash));
    expect(changedTarget.sourceSha256, isNot(original.sourceSha256));
  });

  test('timestamps parts and indexes stay within the signed 64-bit domain', () {
    for (final unsend in [false, true]) {
      expect(_capture(_wire(unsend: unsend, timestamp: 0)), isNull);
      expect(_capture(_wire(unsend: unsend, timestamp: -1)), isNull);
      expect(_capture(_wire(unsend: unsend, targetPart: -1)), isNull);
      final max = _capture(
        _wire(unsend: unsend, timestamp: _maxInt64, targetPart: _maxInt64),
      )!;
      expect(max.sentTimestamp, _maxInt64);
      expect(max.targetPart, _maxInt64);
      expect(
        _capture(_wire(unsend: unsend, timestamp: 1, targetPart: 0)),
        isNotNull,
      );
    }
    expect(_capture(_wire(parts: [_text('', idx: _maxInt64)])), isNotNull);
    expect(_capture(_wire(parts: [_text('', idx: 0)])), isNotNull);
    expect(_capture(_wire(parts: [_text('', idx: -1)])), isNull);
  });

  test('sender conversation and an external counterpart are required', () {
    expect(_capture(_wire()..sender = null), isNull);
    expect(_capture(_wire()..conversation = null), isNull);
    expect(_capture(_wire(participants: [])), isNull);
    expect(_capture(_wire(participants: [_owner])), isNull);
    expect(_capture(_wire(mirrored: true, participants: [_owner])), isNull);
    expect(
      _capture(_wire(participants: [_owner, _peer])),
      isNull,
      reason: 'incoming sender must be an exact external participant',
    );
    expect(_capture(_wire()..sender = _remote.toUpperCase()), isNull);
    expect(_capture(_wire(participants: [_remote])), isNotNull);
    expect(_capture(_wire(mirrored: true, participants: [_remote])), isNotNull);
    expect(
      _capture(
        _wire()..sender = _alias,
        context: _live(handles: [_alias, _owner]),
      )!.origin,
      CloudSyncReceivedArchiveOrigin.mirrored,
    );
  });

  test(
    'participants are unique bounded and group routes require an exact UUID',
    () {
      expect(_capture(_wire(participants: [_remote, _remote])), isNull);
      final maximum = [
        _remote,
        ...List.generate(63, (index) => 'mailto:peer$index@example.test'),
      ];
      expect(
        _capture(_wire(participants: maximum, senderGuid: _group)),
        isNotNull,
      );
      expect(
        _capture(_wire(participants: [...maximum, _owner], senderGuid: _group)),
        isNull,
      );
      for (final label in <String?>[
        null,
        '',
        'opaque-direct',
        _nil,
        _group.replaceAll('-', ''),
        '{$_group}',
        '$_group ',
      ]) {
        expect(
          _capture(_wire(participants: [_remote, _peer], senderGuid: label)),
          isNull,
        );
      }
      expect(
        _capture(_wire(participants: [_remote, _peer], senderGuid: _group)),
        isNotNull,
      );
      for (final label in <String?>[
        null,
        '',
        'opaque-direct',
        _nil,
        ' chat alias ',
      ]) {
        expect(_capture(_wire(senderGuid: label)), isNotNull);
      }
    },
  );

  test('all observed local handles must be valid even when unreferenced', () {
    for (final bad in ['', 'mailto:', 'tel:', 'bare@example.test', 'tel:1 2']) {
      expect(_capture(_wire(), context: _live(handles: [_owner, bad])), isNull);
    }
  });

  test('observed local handles are bounded to 64 before deduplication', () {
    final maximum = [
      _owner,
      ...List.generate(63, (index) => 'mailto:local$index@example.test'),
    ];
    for (final mirrored in [false, true]) {
      for (final unsend in [false, true]) {
        final wire = _wire(mirrored: mirrored, unsend: unsend);
        expect(
          _capture(wire, context: _live(handles: maximum))!.sourceSha256,
          _capture(wire)!.sourceSha256,
        );
        expect(
          _capture(wire, context: _live(handles: [...maximum, _alias])),
          isNull,
        );
        expect(
          _capture(wire, context: _live(handles: List.filled(65, _owner))),
          isNull,
        );
      }
    }
  });

  test(
    'raw external aliases sharing a bare suffix still require a group UUID',
    () {
      const aliases = [_peer, 'mailto:+15550000002'];
      for (final mirrored in [false, true]) {
        for (final unsend in [false, true]) {
          api.MessageInst wire(String? senderGuid) => _wire(
            mirrored: mirrored,
            unsend: unsend,
            participants: [_owner, ...aliases],
            senderGuid: senderGuid,
          )..sender = mirrored ? _owner : _peer;

          for (final senderGuid in <String?>[null, '', 'direct-route']) {
            expect(_capture(wire(senderGuid)), isNull);
          }
          expect(_capture(wire(_group)), isNotNull);
        }
      }
    },
  );

  test(
    'handles reject whitespace and controls in sender recipient and members',
    () {
      for (final code in [
        0,
        0x1f,
        0x20,
        0x7f,
        0x85,
        0x9f,
        0xa0,
        0x1680,
        0x2000,
        0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
      ]) {
        final bad = 'mailto:a${String.fromCharCode(code)}b@example.test';
        final context = _live(handles: [bad], recipient: bad);
        expect(_capture(_wire(recipient: bad), context: context), isNull);
        expect(
          _capture(_wire(participants: [_owner, bad])..sender = bad),
          isNull,
        );
        expect(
          _capture(_wire(participants: [_remote, bad], senderGuid: _group)),
          isNull,
        );
      }
      // BOM is neither Unicode White_Space nor a C0/C1 control.
      const bom = 'mailto:a\ufeffb@example.test';
      expect(_capture(_wire(participants: [bom])..sender = bom), isNotNull);
    },
  );

  test(
    'handle byte bounds apply to sender recipient participants and local context',
    () {
      final exact = 'mailto:${'é' * 2044}x';
      expect(utf8.encode(exact), hasLength(4096));
      final oversized = '${exact}x';
      expect(_capture(_wire(participants: [exact])..sender = exact), isNotNull);
      expect(
        _capture(_wire(participants: [oversized])..sender = oversized),
        isNull,
      );
      expect(
        _capture(
          _wire(recipient: exact, participants: [_remote, exact]),
          context: _live(handles: [exact], recipient: exact),
        ),
        isNotNull,
      );
      expect(
        _capture(
          _wire(recipient: oversized, participants: [_remote, oversized]),
          context: _live(handles: [oversized], recipient: oversized),
        ),
        isNull,
      );
      expect(
        _capture(_wire(), context: _live(handles: [_owner, exact])),
        isNotNull,
      );
      expect(
        _capture(_wire(), context: _live(handles: [_owner, oversized])),
        isNull,
      );
      expect(
        _capture(_wire(participants: [_remote, exact], senderGuid: _group)),
        isNotNull,
      );
      expect(
        _capture(_wire(participants: [_remote, oversized], senderGuid: _group)),
        isNull,
      );
      for (final bad in [
        'sender@example.test',
        'mailto:',
        'tel:',
        'MAILTO:a',
      ]) {
        expect(_capture(_wire(participants: [bad])..sender = bad), isNull);
      }
    },
  );

  test(
    'nullable labels preserve null and empty and enforce byte/control bounds',
    () {
      for (final field in ['cvName', 'senderGuid', 'afterGuid']) {
        void setLabel(api.MessageInst wire, String? value) {
          switch (field) {
            case 'cvName':
              wire.conversation!.cvName = value;
            case 'senderGuid':
              wire.conversation!.senderGuid = value;
            case 'afterGuid':
              wire.conversation!.afterGuid = value;
          }
        }

        final absent = _wire();
        setLabel(absent, null);
        final empty = _wire();
        setLabel(empty, '');
        expect(
          _capture(absent)!.sourceSha256,
          isNot(_capture(empty)!.sourceSha256),
          reason: field,
        );
        for (final value in ['é' * 2048, ' whitespace is allowed ', '\u00a0']) {
          final wire = _wire();
          setLabel(wire, value);
          expect(_capture(wire), isNotNull, reason: field);
        }
        for (final value in [
          '${'é' * 2048}x',
          '\u0000',
          '\n',
          '\u007f',
          '\u009f',
        ]) {
          final wire = _wire();
          setLabel(wire, value);
          expect(_capture(wire), isNull, reason: field);
        }
      }
    },
  );

  test('participant and self-handle order follows Dart UTF16 comparison', () {
    const astral = 'mailto:\u{10000}@example.test';
    const bmp = 'mailto:\ue000@example.test';
    final wire = _wire(
      participants: [bmp, _owner, _remote, astral],
      senderGuid: _group,
    );
    final members = [...wire.conversation!.participants];
    final identity = _capture(wire)!;
    final expected = jsonDecode(_editVector) as List;
    expected[8] = [_owner, _remote, astral, bmp];
    expected[10] = _group;
    expect(identity.sourceSha256, _digest(expected));
    expect(
      wire.conversation!.participants,
      members,
      reason: 'capture must not sort the mutable DTO in place',
    );
    final reordered = _wire(
      participants: members.reversed.toList(),
      senderGuid: _group,
    );
    expect(_capture(reordered)!.sourceSha256, identity.sourceSha256);
    final mirrored = _wire(
      mirrored: true,
      participants: [_remote, bmp, astral],
    );
    final mirroredContext = _live(handles: [bmp, _owner, astral, bmp]);
    final mirroredExpected = jsonDecode(_editVector) as List;
    mirroredExpected[4] = _owner;
    mirroredExpected[7] = 'mirrored';
    mirroredExpected[8] = [_remote, astral, bmp];
    mirroredExpected[14] = [_owner, astral, bmp];
    expect(
      _capture(mirrored, context: mirroredContext)!.sourceSha256,
      _digest(mirroredExpected),
    );
  });

  test('self handles include only unique referenced local aliases', () {
    final base = _capture(_wire())!;
    expect(
      _capture(
        _wire(),
        context: _live(
          handles: [_alias, _owner, _owner, 'mailto:unused@example.test'],
        ),
      )!.sourceSha256,
      base.sourceSha256,
    );
    final wire = _wire(
      participants: [_alias, _remote, _owner],
      senderGuid: _group,
    );
    final expected = jsonDecode(_editVector) as List;
    expected[8] = [_owner, _remote, _alias];
    expected[10] = _group;
    expected[14] = [_owner, _alias];
    expect(
      _capture(wire, context: _live(handles: [_alias, _owner]))!.sourceSha256,
      _digest(expected),
    );
    expect(
      _capture(wire)!.sourceSha256,
      isNot(
        _capture(wire, context: _live(handles: [_alias, _owner]))!.sourceSha256,
      ),
    );
  });

  test('edits preserve empty text indexes all flags and part order', () {
    final original = _capture(_wire())!;
    for (final parts in [
      [_text('Edited messagE'), _parts()[1]],
      [_text('Edited message', idx: null), _parts()[1]],
      [_text('Edited message', bold: false), _parts()[1]],
      [_text('Edited message', italic: true), _parts()[1]],
      [_text('Edited message', underline: false), _parts()[1]],
      [_text('Edited message', strikethrough: true), _parts()[1]],
      _parts().reversed.toList(),
    ]) {
      final wire = _wire(parts: parts);
      expect(_capture(wire), isNotNull);
      expect(_capture(wire, expected: original.sourceSha256), isNull);
    }
    final empty = _capture(_wire(parts: [_text('', idx: null)]));
    expect(empty, isNotNull);
    final whitespace = _capture(_wire(parts: [_text(' \n\u0000', idx: null)]));
    expect(whitespace, isNotNull, reason: 'text is not a routing label');
  });

  test('edit bounds count UTF8 total across all 1 through 128 parts', () {
    expect(_capture(_wire(parts: [])), isNull);
    expect(
      _capture(_wire(parts: List.generate(128, (_) => _text('')))),
      isNotNull,
    );
    expect(
      _capture(_wire(parts: List.generate(129, (_) => _text('')))),
      isNull,
    );
    expect(_capture(_wire(parts: [_text('é' * 131072)])), isNotNull);
    expect(_capture(_wire(parts: [_text('é' * 131072), _text('x')])), isNull);
    expect(
      _capture(_wire(parts: [_text('é' * 65536), _text('é' * 65536)])),
      isNotNull,
    );
    expect(_capture(_wire(parts: [_text('é' * 131073)])), isNull);
  });

  test('unsupported replacement types formats and extensions are rejected', () {
    for (final part in <api.MessagePart>[
      api.MessagePart.attachment(
        api.Attachment(
          aType: api.AttachmentType.inline(Uint8List(0)),
          part_: 0,
          utiType: 'public.data',
          mime: 'application/octet-stream',
          name: 'synthetic',
          iris: false,
        ),
      ),
      const api.MessagePart.mention('person', 'identifier'),
      const api.MessagePart.object('object'),
      const api.MessagePart.text(
        'effect',
        api.TextFormat.effect(api.TextEffect.big),
      ),
    ]) {
      expect(
        _capture(_wire(parts: [api.IndexedMessagePart(part_: part)])),
        isNull,
      );
    }
    final ext = api.PartExtension.sticker(
      msgWidth: 1,
      rotation: 0,
      sai: BigInt.zero,
      scale: 1,
      sli: BigInt.zero,
      normalizedX: 0,
      normalizedY: 0,
      version: BigInt.one,
      hash: 'synthetic',
      safi: BigInt.zero,
      effectType: 0,
      stickerId: 'synthetic',
    );
    expect(_capture(_wire(parts: [_text('text', ext: ext)])), isNull);
    expect(_capture(_wire()..message = const api.Message.read()), isNull);
    expect(_capture(_wire()..message = const api.Message.delivered()), isNull);
  });

  test(
    'every source field and origin change invalidates the pinned digest',
    () {
      final baseline = _capture(_wire())!.sourceSha256;
      final cases = <api.MessageInst>[
        _wire(id: _other),
        _wire(targetGuid: _other),
        _wire(targetPart: 3),
        _wire(timestamp: _timestamp + 1),
        _wire(cvName: ''),
        _wire(senderGuid: 'different-route'),
        _wire(afterGuid: null),
        _wire(unsend: true),
        _wire(mirrored: true),
        _wire(parts: [_text('different text')]),
        _wire(participants: [_remote, _peer], senderGuid: _group),
      ];
      for (final wire in cases) {
        expect(_capture(wire), isNotNull);
        expect(_capture(wire, expected: baseline), isNull);
      }
      final otherSender = _wire(participants: [_peer])..sender = _peer;
      expect(_capture(otherSender), isNotNull);
      expect(_capture(otherSender, expected: baseline), isNull);
      expect(
        _capture(
          _wire(recipient: _alias),
          context: _live(handles: [_alias], recipient: _alias),
          expected: baseline,
        ),
        isNull,
      );
      for (final digest in ['', '0' * 64, baseline.toUpperCase()]) {
        expect(_capture(_wire(), expected: digest), isNull);
      }
    },
  );

  test(
    'received identifiers cannot substitute outgoing or initial-receive namespaces',
    () {
      final identity = _capture(_wire())!;
      expect(
        identity.guidHash,
        isNot(_digest(['cloud-sync-local-send-guid-v1', _event])),
      );
      expect(
        identity.targetGuidHash,
        isNot(_digest(['cloud-sync-local-send-guid-v1', _target])),
      );
      expect(
        identity.guidHash,
        isNot(_digest(['cloud-sync-received-archive-guid-v1', _event])),
      );
      final outgoingVector = [
        'cloud-sync-local-mutation-source-v1',
        _event,
        _target,
        2,
        _remote,
        [_remote, _owner],
        null,
        'direct-route',
        '',
        _timestamp,
        false,
        'edit',
        [
          ['Edited message', 2, true, false, true, false],
          ['', null, false, true, false, true],
        ],
      ];
      expect(identity.sourceSha256, isNot(_digest(outgoingVector)));
      expect(
        _capture(_wire(recipient: null)),
        isNull,
        reason: 'an outgoing-shaped DTO is never reinterpreted as received',
      );
    },
  );

  test(
    'identity is immutable redacted and independent of later DTO mutation',
    () {
      final wire = _wire();
      final identity = _capture(wire)!;
      wire.id = _other;
      wire.sender = _peer;
      wire.conversation!.participants.clear();
      (wire.message as api.Message_Edit).field0.newParts.field0.clear();
      expect(identity.sourceSha256, _editHash);
      expect(
        identity.guidHash,
        'e68c641bfd4822dd10a95017fdc5b4a7f13e2e991ddd57050a24776ec53d25da',
      );
      expect(
        identity.toString(),
        'CloudSyncReceivedMutationIdentity(redacted)',
      );
      for (final secret in [
        _event,
        _target,
        _remote,
        _owner,
        'Edited message',
        _editHash,
      ]) {
        expect(identity.toString(), isNot(contains(secret)));
      }
    },
  );
}
