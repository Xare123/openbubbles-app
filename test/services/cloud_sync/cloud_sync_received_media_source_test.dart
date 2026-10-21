import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_media_source.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

// Synthetic DTOs and detached rows only. Positive ids are fixtures, not proof
// of a real store, authenticated receive, native seal, or upload authority.
const _guid = '11111111-2222-4333-8444-555555555555';
const _owner = 'mailto:owner@example.com';
const _remote = 'mailto:remote@example.com';
const _peer = 'remote@example.com';
const _group = '77777777-8888-4999-aaaa-bbbbbbbbbbbb';
const _timestamp = 1700000000000;
const _live = CloudSyncReceivedArchiveLiveContext(
  observedViaLiveReceive: true,
  observedLocalHandles: [_owner],
  receivedOnHandle: _owner,
);
const _flags = api.TextFormat.flags(
  api.TextFlags(
    bold: false,
    italic: false,
    underline: false,
    strikethrough: false,
  ),
);

// Shared with native incoming-direct. Complete UTF-8 jsonEncode bytes,
// including the trailing ASCII attachment space. All key material is synthetic.
const _nativeVector =
    '["cloud-sync-received-archive-source-v3","11111111-2222-4333-8444-555555555555","caption ","remote@example.com","mailto:remote@example.com","mailto:owner@example.com",1700000000000,"incoming","iMessage;-;remote@example.com",["mailto:owner@example.com","mailto:remote@example.com"],"","",[[0,"caption",0],[1,2,"public.heic","image/heic","photo.heic",false,[[7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7],[9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9],"object-media","https://example.invalid/mmcs/media",1234],7]]]';
const _nativeHash =
    '052435798c9b6bd01034da39c11740f3fb69c3b3aeccb90e5bc2d6f8967357da';

api.MMCSFile _file({
  List<int>? key,
  List<int>? signature,
  String object = 'object-media',
  String url = 'https://example.invalid/mmcs/media',
  int size = 1234,
}) => api.MMCSFile(
  key: Uint8List.fromList(key ?? List.filled(32, 7)),
  signature: Uint8List.fromList(signature ?? List.filled(21, 9)),
  object: object,
  url: url,
  size: size,
);

api.Attachment _attachment({
  int part = 2,
  String uti = 'public.heic',
  String mime = 'image/heic',
  String name = 'photo.heic',
  bool iris = false,
  api.MMCSFile? file,
  api.AttachmentType? type,
}) => api.Attachment(
  aType: type ?? api.AttachmentType.mmcs(file ?? _file()),
  part_: part,
  utiType: uti,
  mime: mime,
  name: name,
  iris: iris,
);

api.IndexedMessagePart _text(String value, {int? idx = 0}) =>
    api.IndexedMessagePart(
      part_: api.MessagePart.text(value, _flags),
      idx: idx,
    );

api.IndexedMessagePart _part(api.Attachment attachment, {int? idx = 7}) =>
    api.IndexedMessagePart(
      part_: api.MessagePart.attachment(attachment),
      idx: idx,
    );

final class _Fixture {
  _Fixture(this.chat, this.row, this.wire);
  final Chat chat;
  final Message row;
  final api.MessageInst wire;
}

_Fixture _fixture({
  bool mirrored = false,
  bool group = false,
  api.Attachment? primary,
  api.Attachment? secondary,
  String prefix = 'caption',
  String? suffix,
  int? prefixIndex = 0,
  int? attachmentIndex = 7,
  int? secondaryIndex = 8,
  int? suffixIndex = 9,
  int? messageId = 90,
}) {
  final first = primary ?? _attachment();
  final peers = [
    Handle(address: _peer, service: 'iMessage'),
    if (group) Handle(address: '+15550000002', service: 'iMessage'),
  ];
  final chat = Chat(
    id: 70,
    guid: group ? 'iMessage;+;local-group' : 'iMessage;-;$_peer',
    chatIdentifier: group ? 'local-group' : _peer,
    style: group ? 43 : 45,
    usingHandle: _owner,
    participants: peers,
    guidRefs: group ? [_group] : [],
  );
  chat.handles.addAll(peers);
  final parts = [
    _text(prefix, idx: prefixIndex),
    _part(first, idx: attachmentIndex),
    if (secondary != null) _part(secondary, idx: secondaryIndex),
    if (suffix != null) _text(suffix, idx: suffixIndex),
  ];
  final wire = api.MessageInst(
    id: _guid,
    sender: mirrored ? _owner : _remote,
    conversation: api.ConversationData(
      participants: [_owner, _remote, if (group) 'tel:+15550000002'],
      senderGuid: group ? _group : chat.guid,
    ),
    message: api.Message.message(
      api.NormalMessage(
        parts: api.MessageParts(field0: parts),
        service: const api.MessageType_IMessage(),
        voice: false,
      ),
    ),
    sentTimestamp: _timestamp,
    sendDelivered: false,
    verificationFailed: false,
    receivedOnHandle: _owner,
  );

  // Independent ordinary-row fixtures use non-overlapping explicit indices
  // (or equivalent null prefix/first-attachment indices). The golden test
  // additionally asserts the known runs. No native projection is invoked.
  final display = StringBuffer(prefix);
  final runs = [
    Run(
      range: [0, prefix.length],
      attributes: Attributes(messagePart: prefixIndex ?? 0),
    ),
  ];
  final attachments = <Attachment>[];
  void add(api.Attachment value, int? index, bool hasIris) {
    if (value.iris || value.mime == 'application/smil') return;
    final fieldIndex = index ?? attachments.length;
    final guid = '${_guid}_$fieldIndex';
    final file = (value.aType as api.AttachmentType_MMCS).field0;
    runs.add(
      Run(
        range: [display.length, 1],
        attributes: Attributes(messagePart: runs.length, attachmentGuid: guid),
      ),
    );
    attachments.add(
      Attachment(
        guid: guid,
        uti: value.utiType,
        mimeType: value.mime,
        transferName: value.name.replaceAll('/', '_').replaceAll('\\', '_'),
        totalBytes: file.size,
        isOutgoing: false,
        hasLivePhoto: hasIris,
        // Opaque native descriptor bytes are deliberately not faked or decoded.
      ),
    );
    display.write(' ');
  }

  add(first, attachmentIndex, secondary?.iris == true);
  if (secondary != null) add(secondary, secondaryIndex, false);
  if (suffix != null) {
    runs.add(
      Run(
        range: [display.length, suffix.length],
        attributes: Attributes(messagePart: suffixIndex ?? attachments.length),
      ),
    );
    display.write(suffix);
  }
  final row = Message(
    id: messageId,
    guid: _guid,
    text: display.toString(),
    dateCreated: DateTime.fromMillisecondsSinceEpoch(_timestamp, isUtc: true),
    isFromMe: mirrored,
    handle: Handle(
      address: mirrored ? 'owner@example.com' : _peer,
      service: 'iMessage',
    ),
    attributedBody: [AttributedBody(string: display.toString(), runs: runs)],
    attachments: attachments,
    hasAttachments: attachments.isNotEmpty,
  );
  row.chat.target = chat;
  return _Fixture(chat, row, wire);
}

api.NormalMessage _normal(api.MessageInst wire) =>
    (wire.message as api.Message_Message).field0;

CloudSyncReceivedArchiveCapture _capture(
  _Fixture fixture, {
  String? expected,
  CloudSyncReceivedArchiveLiveContext live = _live,
}) => CloudSyncReceivedArchiveIdentity.capture(
  message: fixture.row,
  chat: fixture.chat,
  wire: fixture.wire,
  liveContext: live,
  expectedSourceSha256: expected,
);

CloudSyncReceivedArchiveIdentity _eligible(
  _Fixture fixture, {
  String? expected,
}) {
  final result = _capture(fixture, expected: expected);
  expect(result, isA<CloudSyncReceivedArchiveEligible>());
  return (result as CloudSyncReceivedArchiveEligible).identity;
}

CloudSyncReceivedMediaSource? _body(List<api.IndexedMessagePart> parts) {
  final wire = _fixture().wire;
  _normal(wire).parts = api.MessageParts(field0: parts);
  return CloudSyncReceivedMediaSource.captureWire(wire);
}

String _vector(_Fixture fixture, CloudSyncReceivedArchiveIdentity identity) {
  final wire = fixture.wire;
  final conversation = wire.conversation!;
  final participants = conversation.participants.toList()..sort();
  return jsonEncode([
    'cloud-sync-received-archive-source-v3',
    wire.id,
    identity.mediaSource!.text,
    fixture.chat.style == 43 ? conversation.senderGuid : _peer,
    wire.sender,
    wire.receivedOnHandle,
    wire.sentTimestamp,
    identity.origin.name,
    conversation.senderGuid ?? '',
    participants,
    conversation.cvName ?? '',
    conversation.afterGuid ?? '',
    identity.mediaSource!.mediaManifest,
  ]);
}

void main() {
  _captureTests();
  _rowGateTests();
  _boundsTests();
}

void _rowGateTests() {
  test('empty subject preserves the native V3 hash', () {
    final fixture = _fixture();
    _normal(fixture.wire).subject = '';
    fixture.row.subject = '';
    expect(_eligible(fixture).sourceSha256, _nativeHash);
  });

  test('preview never waives persisted capture or recipient checks', () {
    final fixture = _fixture(messageId: null);
    expect(
      CloudSyncReceivedArchiveIdentity.preview(
        message: fixture.row,
        chat: fixture.chat,
        wire: fixture.wire,
        liveContext: _live,
      ),
      isA<CloudSyncReceivedArchiveEligible>(),
    );
    expect(_capture(fixture), isA<CloudSyncReceivedArchiveIneligible>());
  });

  test(
    'row identity, legacy/receive gates and exact media correspondence remain required',
    () {
      final changes = <String, void Function(_Fixture)>{
        'guid': (f) => f.row.guid = 'changed-guid',
        'timestamp': (f) => f.row.dateCreated = DateTime.utc(2026),
        'direction': (f) => f.row.isFromMe = true,
        'author': (f) => f.wire.sender = 'mailto:foreign@example.com',
        'legacy record': (f) => f.row.ckRecordId = 'legacy',
        'legacy state': (f) => f.row.ckSyncState = true,
        'send state': (f) => f.row.stagingGuid = 'local-send',
        'verification': (f) => f.wire.verificationFailed = true,
        'row verification': (f) => f.row.verificationFailed = true,
        'reply': (f) => _normal(f.wire).replyGuid = 'parent',
        'voice': (f) => _normal(f.wire).voice = true,
        'effect': (f) => _normal(f.wire).effect = 'effect',
        'subject': (f) => _normal(f.wire).subject = 'subject',
        'deleted route': (f) => f.chat.dateDeleted = DateTime.utc(2026),
        'different route': (f) => f.chat.guid = 'iMessage;-;foreign',
        'caption': (f) => f.row.text = 'caption',
        'attachment flag': (f) => f.row.hasAttachments = false,
        'attachment GUID': (f) => f.row.attachments.single!.guid = 'foreign_7',
        'attachment size': (f) => f.row.attachments.single!.totalBytes = 1,
        'attachment MIME': (f) =>
            f.row.attachments.single!.mimeType = 'wrong/type',
        'attachment UTI': (f) => f.row.attachments.single!.uti = 'wrong.uti',
        'attachment name': (f) =>
            f.row.attachments.single!.transferName = 'wrong',
        'attachment direction': (f) =>
            f.row.attachments.single!.isOutgoing = true,
        'body': (f) => f.row.attributedBody = [AttributedBody.raw('caption ')],
        'attachments missing': (f) => f.row.attachments = [],
      };
      for (final change in changes.entries) {
        final fixture = _fixture();
        change.value(fixture);
        expect(
          _capture(fixture),
          isA<CloudSyncReceivedArchiveIneligible>(),
          reason: change.key,
        );
      }
    },
  );

  test('stored relations work but contradictory attachment views fail', () {
    final fixture = _fixture();
    fixture.row.dbAttachments.addAll(
      fixture.row.attachments.cast<Attachment>(),
    );
    fixture.row.attachments = [];
    expect(_capture(fixture), isA<CloudSyncReceivedArchiveEligible>());
    fixture.row.attachments = [Attachment(guid: 'foreign')];
    expect(_capture(fixture), isA<CloudSyncReceivedArchiveIneligible>());
  });

  test(
    'receive context, certified endpoints and explicit destinations remain exact',
    () {
      final fixture = _fixture();
      expect(
        _capture(
          fixture,
          live: const CloudSyncReceivedArchiveLiveContext(
            observedViaLiveReceive: false,
            observedLocalHandles: [_owner],
            receivedOnHandle: _owner,
          ),
        ),
        isA<CloudSyncReceivedArchiveIneligible>(),
      );
      expect(
        _capture(
          fixture,
          live: const CloudSyncReceivedArchiveLiveContext(
            observedViaLiveReceive: true,
            observedLocalHandles: [_owner, 'tel:+15550000001'],
            receivedOnHandle: 'tel:+15550000001',
          ),
        ),
        isA<CloudSyncReceivedArchiveIneligible>(),
      );
      fixture.wire.certifiedContext = api.CertifiedContext(
        version: 1,
        receipt: Uint8List(1),
        sender: _remote,
        target: _owner,
        uuid: Uint8List(16),
        token: Uint8List(32),
      );
      expect(_eligible(fixture).sourceSha256, _nativeHash);
      fixture.wire.certifiedContext = api.CertifiedContext(
        version: 1,
        receipt: Uint8List(1),
        sender: _remote,
        target: 'foreign',
        uuid: Uint8List(16),
        token: Uint8List(32),
      );
      expect(_capture(fixture), isA<CloudSyncReceivedArchiveIneligible>());
      fixture.wire.certifiedContext = null;
      fixture.wire.target = [api.MessageTarget.token(Uint8List(32))];
      fixture.wire.sendDelivered = true;
      expect(_eligible(fixture).sourceSha256, _nativeHash);
      fixture.wire.target = [const api.MessageTarget.uuid(_guid)];
      expect(_capture(fixture), isA<CloudSyncReceivedArchiveIneligible>());
    },
  );

  test('caption alone never substitutes for a wire attachment', () {
    final fixture = _fixture();
    _normal(fixture.wire).parts = api.MessageParts(field0: [_text('caption ')]);
    expect(_capture(fixture), isA<CloudSyncReceivedArchiveIneligible>());
    expect(_body([_text('plain')]), isNull);
  });

  test(
    'all-hidden wire retains evidence but cannot bind an attachment row',
    () {
      final fixture = _fixture(primary: _attachment(iris: true));
      expect(CloudSyncReceivedMediaSource.captureWire(fixture.wire), isNotNull);
      expect(_capture(fixture), isA<CloudSyncReceivedArchiveIneligible>());
    },
  );

  test(
    'attachment order changes V3 identity even when caption is identical',
    () {
      final first = _attachment();
      final second = _attachment(part: 3, name: 'second.heic');
      final a = _fixture(primary: first, secondary: second);
      final b = _fixture(primary: second, secondary: first);
      expect(a.row.text, b.row.text);
      expect(_eligible(a).sourceSha256, isNot(_eligible(b).sourceSha256));
    },
  );
}

void _boundsTests() {
  test('malformed MMCS descriptors fail the body boundary', () {
    final malformed = <String, api.Attachment Function()>{
      'short key': () => _attachment(file: _file(key: List.filled(31, 7))),
      'long key': () => _attachment(file: _file(key: List.filled(33, 7))),
      'short signature': () =>
          _attachment(file: _file(signature: List.filled(20, 9))),
      'long signature': () =>
          _attachment(file: _file(signature: List.filled(22, 9))),
      'empty object': () => _attachment(file: _file(object: '')),
      'empty URL': () => _attachment(file: _file(url: '')),
      'object controls': () => _attachment(file: _file(object: 'a\u0085b')),
      'URL controls': () => _attachment(file: _file(url: 'https://invalid/\n')),
      'oversize object': () => _attachment(file: _file(object: 'a' * 8193)),
      'oversize URL': () => _attachment(file: _file(url: 'a' * 8193)),
      'empty UTI': () => _attachment(uti: ''),
      'empty MIME': () => _attachment(mime: ''),
      'empty name': () => _attachment(name: ''),
      'metadata controls': () => _attachment(name: 'a\u0000b'),
      'metadata UTF8 bound': () => _attachment(name: 'é' * 2049),
      'negative size': () => _attachment(file: _file(size: -1)),
      'size above 8GiB': () => _attachment(file: _file(size: 8589934593)),
      'negative part': () => _attachment(part: -1),
      'inline': () =>
          _attachment(type: api.AttachmentType.inline(Uint8List(2))),
    };
    for (final change in malformed.entries) {
      expect(_body([_part(change.value())]), isNull, reason: change.key);
    }
  });

  test('descriptor UTF8/size/part/index bounds are inclusive', () {
    final attachment = _attachment(
      part: CloudSyncReceivedMediaSource.maximumPart,
      uti: 'a' * 4096,
      mime: 'b' * 4096,
      name: 'é' * 2048,
      file: _file(object: 'c' * 8192, url: 'd' * 8192, size: 8589934592),
    );
    expect(
      _body([_part(attachment, idx: CloudSyncReceivedMediaSource.maximumPart)]),
      isNotNull,
    );
    expect(
      _body([_part(_attachment(file: _file(size: 0)), idx: 0)]),
      isNotNull,
    );
    expect(_body([_part(_attachment(), idx: -1)]), isNull);
    expect(_body([_text('', idx: -1), _part(_attachment())]), isNull);
  });

  test('attachment/part count and full capture UTF8 text bounds are exact', () {
    final attachment = _part(_attachment());
    expect(_body(List.filled(64, attachment)), isNotNull);
    expect(_body(List.filled(65, attachment)), isNull);
    expect(
      _body([...List.filled(64, _text('')), ...List.filled(64, attachment)]),
      isNotNull,
    );
    expect(
      _body([...List.filled(65, _text('')), ...List.filled(64, attachment)]),
      isNull,
    );
    expect(_body([_text('a' * 262143), attachment]), isNotNull);
    expect(_body([_text('a' * 262144), attachment]), isNull);
    expect(_body([_text('é' * 131072), attachment]), isNull);
    expect(
      _body([_text('a' * 131072), _text('b' * 131072), attachment]),
      isNull,
    );
    expect(_body([_text(String.fromCharCode(0xd800)), attachment]), isNull);
  });

  test(
    'mentions, objects, rich flags/effects and extensions stay unsupported',
    () {
      final attachment = _part(_attachment());
      final unsupported = [
        const api.IndexedMessagePart(
          part_: api.MessagePart.mention(_remote, 'peer'),
        ),
        const api.IndexedMessagePart(part_: api.MessagePart.object('object')),
        const api.IndexedMessagePart(
          part_: api.MessagePart.text(
            'rich',
            api.TextFormat.effect(api.TextEffect.big),
          ),
        ),
        for (var i = 0; i < 4; i++)
          api.IndexedMessagePart(
            part_: api.MessagePart.text(
              'rich',
              api.TextFormat.flags(
                api.TextFlags(
                  bold: i == 0,
                  italic: i == 1,
                  underline: i == 2,
                  strikethrough: i == 3,
                ),
              ),
            ),
          ),
        api.IndexedMessagePart(
          part_: api.MessagePart.attachment(_attachment()),
          ext: api.PartExtension.sticker(
            msgWidth: 1,
            rotation: 0,
            sai: BigInt.zero,
            scale: 1,
            sli: BigInt.zero,
            normalizedX: 0,
            normalizedY: 0,
            version: BigInt.one,
            hash: 'h',
            safi: BigInt.zero,
            effectType: 0,
            stickerId: 's',
          ),
        ),
      ];
      for (final part in unsupported) {
        expect(_body([part, attachment]), isNull);
      }
    },
  );
}

void _captureTests() {
  test('hardcoded complete native incoming-direct V3 vector', () {
    final fixture = _fixture();
    final identity = _eligible(fixture);
    expect(_vector(fixture, identity), _nativeVector);
    expect(identity.sourceSha256, _nativeHash);
    expect(
      identity.guidHash,
      'cd7c99cec32925c682dd556e85b3f86856765d9dadc8c3b5796f8f5f4deccf57',
    );
    expect(identity.hasMedia, isTrue);
    expect(fixture.row.text, 'caption ');
    expect(
      fixture.row.attributedBody.single.runs
          .map(
            (run) => [
              ...run.range,
              run.attributes!.messagePart,
              run.attributes!.attachmentGuid,
            ],
          )
          .toList(),
      [
        [0, 7, 0, null],
        [
          7,
          1,
          1,
          '$_guid'
              '_7',
        ],
      ],
    );
    expect(_eligible(fixture, expected: _nativeHash).sourceSha256, _nativeHash);
  });

  for (final group in [false, true]) {
    for (final mirrored in [false, true]) {
      test(
        'V3 direct/group=$group mirrored=$mirrored remains received evidence',
        () {
          final fixture = _fixture(group: group, mirrored: mirrored);
          final identity = _eligible(fixture);
          expect(
            identity.origin,
            mirrored
                ? CloudSyncReceivedArchiveOrigin.mirrored
                : CloudSyncReceivedArchiveOrigin.incoming,
          );
          expect(identity.mediaSource!.text, 'caption ');
          expect(fixture.row.isFromMe, mirrored);
        },
      );
    }
  }

  final descriptorChanges = <String, api.Attachment Function()>{
    'part': () => _attachment(part: 3),
    'UTI': () => _attachment(uti: 'public.data'),
    'MIME': () => _attachment(mime: 'application/octet-stream'),
    'name': () => _attachment(name: 'other.heic'),
    'key': () => _attachment(file: _file(key: [8, ...List.filled(31, 7)])),
    'signature': () =>
        _attachment(file: _file(signature: [10, ...List.filled(20, 9)])),
    'object': () => _attachment(file: _file(object: 'other-object')),
    'URL': () => _attachment(file: _file(url: 'https://example.invalid/other')),
    'size': () => _attachment(file: _file(size: 1235)),
  };
  for (final change in descriptorChanges.entries) {
    test('V3 binds exact descriptor ${change.key}', () {
      final changed = _fixture(primary: change.value());
      expect(_eligible(changed).sourceSha256, isNot(_nativeHash));
      final rejected = _capture(changed, expected: _nativeHash);
      expect(rejected, isA<CloudSyncReceivedArchiveIneligible>());
      expect(
        (rejected as CloudSyncReceivedArchiveIneligible).reason,
        CloudSyncReceivedArchiveIdentity.reasonSourceChanged,
      );
    });
  }

  test('iris and all ordered parts survive omitted UI metadata', () {
    final iris = _attachment(
      part: 3,
      uti: 'com.apple.quicktime-movie',
      mime: 'video/quicktime',
      name: 'live.mov',
      iris: true,
      file: _file(object: 'iris-object'),
    );
    final fixture = _fixture(secondary: iris, suffix: 'end');
    final identity = _eligible(fixture);
    final source = identity.mediaSource!;
    expect(source.text, 'caption  end');
    expect(fixture.row.text, 'caption end');
    expect(fixture.row.attachments, hasLength(1));
    expect(fixture.row.attachments.single!.hasLivePhoto, isTrue);
    expect(source.mediaManifest, hasLength(4));
    expect(source.mediaManifest[2][5], isTrue);
    expect((source.mediaManifest[2][6] as List)[2], 'iris-object');
    final visibleCompanion = _fixture(
      secondary: _attachment(
        part: 3,
        uti: iris.utiType,
        mime: iris.mime,
        name: iris.name,
        iris: false,
        file: (iris.aType as api.AttachmentType_MMCS).field0,
      ),
      suffix: 'end',
    );
    expect(
      _eligible(visibleCompanion).sourceSha256,
      isNot(identity.sourceSha256),
    );
    final changedIris = _fixture(
      secondary: _attachment(
        part: 3,
        uti: iris.utiType,
        mime: iris.mime,
        name: iris.name,
        iris: true,
        file: _file(object: 'changed-iris'),
      ),
      suffix: 'end',
    );
    expect(
      _capture(changedIris, expected: identity.sourceSha256),
      isA<CloudSyncReceivedArchiveIneligible>(),
    );
  });

  test('wire indices, null indices, empty text and text order are bound', () {
    final hashes = <String>{_nativeHash};
    for (final fixture in [
      _fixture(attachmentIndex: 10),
      _fixture(attachmentIndex: null),
      _fixture(prefixIndex: null),
      _fixture(prefixIndex: 10),
      _fixture(prefix: ''),
      _fixture(prefix: 'caption', suffix: ''),
      _fixture(prefix: 'end', suffix: 'caption'),
      _fixture(prefix: 'caption', suffix: 'end'),
      _fixture(prefix: 'caption', suffix: 'end', suffixIndex: 10),
    ]) {
      expect(hashes.add(_eligible(fixture).sourceSha256), isTrue);
    }
  });

  for (final mime in [
    'image/heic',
    'image/jpeg',
    'image/gif',
    'video/mp4',
    'application/pdf',
    'application/octet-stream',
    'audio/wav',
  ]) {
    test('normal iMessage MMCS MIME $mime is opaque data', () {
      final identity = _eligible(_fixture(primary: _attachment(mime: mime)));
      expect(identity.mediaSource!.mediaManifest[1][3], mime);
    });
  }

  test('SMIL is retained as data even when ordinary display omits it', () {
    final fixture = _fixture(
      secondary: _attachment(
        part: 3,
        mime: 'application/smil',
        name: 'display.smil',
      ),
    );
    final source = _eligible(fixture).mediaSource!;
    expect(source.text, 'caption  ');
    expect(source.mediaManifest.last[3], 'application/smil');
    expect(fixture.row.text, 'caption ');
  });

  test(
    'media-only and sanitized row filenames preserve original descriptor',
    () {
      final fixture = _fixture(
        prefix: '',
        primary: _attachment(name: 'a/b\\photo.heic'),
      );
      final source = _eligible(fixture).mediaSource!;
      expect(source.text, ' ');
      expect(source.mediaManifest[1][4], 'a/b\\photo.heic');
      expect(fixture.row.attachments.single!.transferName, 'a_b_photo.heic');
    },
  );

  test('MMCS bytes and nested manifest are detached and deeply immutable', () {
    final file = _file();
    final fixture = _fixture(primary: _attachment(file: file));
    final identity = _eligible(fixture);
    final source = identity.mediaSource!;
    file.key[0] = 42;
    file.signature[0] = 42;
    final descriptor = source.mediaManifest[1][6] as List<Object?>;
    expect((descriptor[0] as List).first, 7);
    expect((descriptor[1] as List).first, 9);
    expect(() => (descriptor[0] as List<int>)[0] = 1, throwsUnsupportedError);
    expect(() => descriptor[2] = 'changed', throwsUnsupportedError);
    expect(() => source.mediaManifest[1][1] = 8, throwsUnsupportedError);
    expect(() => source.mediaManifest.clear(), throwsUnsupportedError);
    expect(identity.sourceSha256, _nativeHash);
    expect(
      _capture(fixture, expected: _nativeHash),
      isA<CloudSyncReceivedArchiveIneligible>(),
    );
    expect(source.toString(), 'CloudSyncReceivedMediaSource(redacted)');
    expect(
      identity.toString(),
      'CloudSyncReceivedArchiveIdentity(origin=incoming, redacted)',
    );
  });
}
