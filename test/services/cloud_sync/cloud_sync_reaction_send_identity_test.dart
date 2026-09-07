import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_reaction_send_identity.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

const _reactionGuid = 'EA6165FC-EFF7-40A7-8F11-C0D3D397597B';
const _parentGuid = 'B3E7A1C4-9D2F-4B6E-8A1C-5F0E9D2C7B3A';
const _otherGuid = 'C4D8B2E5-1A3F-4C7D-9B2E-6A1F8C3D5E7B';

const _recipient = 'recipient@example.com';
const _sender = 'mailto:sender@example.com';
const _chatGuid = 'iMessage;-;recipient@example.com';

const _bases = <String>[
  'love',
  'like',
  'dislike',
  'laugh',
  'emphasize',
  'question',
];

Chat _directChat() {
  final recipient = Handle(address: _recipient, service: 'iMessage');
  final chat = Chat(
    guid: _chatGuid,
    chatIdentifier: _recipient,
    usingHandle: _sender,
    style: 45,
    participants: [recipient],
  );
  chat.handles.add(recipient);
  return chat;
}

Message _reactionRow({
  String stableGuid = _reactionGuid,
  String? parentGuid = _parentGuid,
  int? part = 0,
  String? type = 'love',
  Chat? chat,
}) {
  final row = Message(
    guid: stableGuid,
    isFromMe: true,
    dateCreated: DateTime.utc(2026, 9, 7),
    associatedMessageGuid: parentGuid,
    associatedMessagePart: part,
    associatedMessageType: type,
  );
  row.chat.target = chat ?? _directChat();
  return row;
}

api.Reaction _nativeFor(String base) {
  switch (base) {
    case 'love':
      return const api.Reaction.heart();
    case 'like':
      return const api.Reaction.like();
    case 'dislike':
      return const api.Reaction.dislike();
    case 'laugh':
      return const api.Reaction.laugh();
    case 'emphasize':
      return const api.Reaction.emphasize();
    case 'question':
      return const api.Reaction.question();
    default:
      throw ArgumentError('unsupported base: $base');
  }
}

api.MessageInst _wire({
  String id = _reactionGuid,
  String? sender = _sender,
  String? senderGuid = _chatGuid,
  bool omitConversation = false,
  List<String>? participants,
  String toUuid = _parentGuid,
  int? toPart = 0,
  api.Reaction? reaction,
  String base = 'love',
  bool enable = true,
  bool verificationFailed = false,
  bool withTarget = false,
  api.Message? messageOverride,
}) {
  return api.MessageInst(
    id: id,
    sender: sender,
    conversation: omitConversation
        ? null
        : api.ConversationData(
            participants:
                participants ?? ['mailto:recipient@example.com', _sender],
            senderGuid: senderGuid,
          ),
    message:
        messageOverride ??
        api.Message.react(
          api.ReactMessage(
            toUuid: toUuid,
            toPart: toPart,
            reaction: api.ReactMessageType.react(
              reaction: reaction ?? _nativeFor(base),
              enable: enable,
            ),
            toText: 'parent snapshot',
          ),
        ),
    sentTimestamp: DateTime.utc(2026, 9, 7).millisecondsSinceEpoch,
    target: withTarget ? [const api.MessageTarget.uuid('target-guid')] : null,
    sendDelivered: false,
    verificationFailed: verificationFailed,
  );
}

void main() {
  group('local reaction row capture', () {
    test('accepts the standard six as add and remove', () {
      for (final base in _bases) {
        for (final type in [base, '-$base']) {
          final chat = _directChat();
          expect(
            CloudSyncReactionSendIdentity.capture(
              _reactionRow(type: type, chat: chat),
              chat,
              _reactionGuid,
            ),
            isNotNull,
            reason: type,
          );
        }
      }
    });

    test('capture is stable and revalidates the source hash', () {
      final chat = _directChat();
      final first = CloudSyncReactionSendIdentity.capture(
        _reactionRow(chat: chat),
        chat,
        _reactionGuid,
      )!;
      final second = CloudSyncReactionSendIdentity.capture(
        _reactionRow(chat: chat),
        chat,
        _reactionGuid,
      )!;
      expect(second.sourceSha256, first.sourceSha256);
      expect(second.guidHash, first.guidHash);
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(chat: chat),
          chat,
          _reactionGuid,
          expectedSourceSha256: first.sourceSha256,
        ),
        isNotNull,
      );
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(type: 'like', chat: chat),
          chat,
          _reactionGuid,
          expectedSourceSha256: first.sourceSha256,
        ),
        isNull,
      );
    });

    test('null and zero parts are distinct valid targets', () {
      final chat = _directChat();
      final nullPart = CloudSyncReactionSendIdentity.capture(
        _reactionRow(part: null, chat: chat),
        chat,
        _reactionGuid,
      );
      final zeroPart = CloudSyncReactionSendIdentity.capture(
        _reactionRow(part: 0, chat: chat),
        chat,
        _reactionGuid,
      );
      expect(nullPart, isNotNull);
      expect(zeroPart, isNotNull);
      expect(nullPart!.sourceSha256, isNot(zeroPart!.sourceSha256));
    });

    test('rejects emoji, stickerback, and malformed types', () {
      final chat = _directChat();
      for (final type in [
        'emoji',
        '-emoji',
        'stickerback',
        '-stickerback',
        'sticker',
        'meta',
        '',
        'LOVE',
        '--like',
        '-',
      ]) {
        expect(
          CloudSyncReactionSendIdentity.capture(
            _reactionRow(type: type, chat: chat),
            chat,
            _reactionGuid,
          ),
          isNull,
          reason: type,
        );
      }
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(type: null, chat: chat),
          chat,
          _reactionGuid,
        ),
        isNull,
      );
      final row = _reactionRow(chat: chat)
        ..associatedMessageEmoji = 'red-heart';
      expect(
        CloudSyncReactionSendIdentity.capture(row, chat, _reactionGuid),
        isNull,
      );
    });

    test('rejects non-direct and misrouted chats', () {
      final groupFirst = Handle(address: _recipient, service: 'iMessage');
      final groupSecond = Handle(
        address: 'other@example.com',
        service: 'iMessage',
      );
      final group = Chat(
        guid: 'iMessage;+;group',
        chatIdentifier: 'group',
        usingHandle: _sender,
        style: 43,
        participants: [groupFirst, groupSecond],
      );
      group.handles.add(groupFirst);
      group.handles.add(groupSecond);
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(chat: group),
          group,
          _reactionGuid,
        ),
        isNull,
      );
      final sms = _directChat()..isRpSms = true;
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(chat: sms),
          sms,
          _reactionGuid,
        ),
        isNull,
      );
      final stub = _directChat()..isRoutingStub = true;
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(chat: stub),
          stub,
          _reactionGuid,
        ),
        isNull,
      );
      final noHandle = _directChat()..usingHandle = '';
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(chat: noHandle),
          noHandle,
          _reactionGuid,
        ),
        isNull,
      );
      final mismatch = _directChat()..chatIdentifier = 'someone@example.com';
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(chat: mismatch),
          mismatch,
          _reactionGuid,
        ),
        isNull,
      );
    });

    test('rejects rows that are not plain outgoing reactions', () {
      final chat = _directChat();
      final mutations = <void Function(Message)>[
        (m) => m.isFromMe = false,
        (m) => m.dateCreated = null,
        (m) => m.dateScheduled = DateTime.utc(2026, 9, 8),
        (m) => m.dateDeleted = DateTime.utc(2026, 9, 8),
        (m) => m.dateEdited = DateTime.utc(2026, 9, 8),
        (m) => m.subject = 'subject',
        (m) => m.hasAttachments = true,
        (m) => m.attachments = [Attachment()],
        (m) => m.dbAttachments.add(Attachment()),
        (m) => m.messageSummaryInfo = [MessageSummaryInfo.empty()],
        (m) => m.sendingServiceId = 'service',
        (m) => m.stagingGuid = 'staging',
        (m) => m.threadOriginatorGuid = _parentGuid,
        (m) => m.threadOriginatorPart = '0',
        (m) => m.expressiveSendStyleId = 'style',
        (m) => m.balloonBundleId = 'com.apple.test',
        (m) => m.hasApplePayloadData = true,
        (m) => m.metadata = {'k': 'v'},
        (m) => m.amkSessionId = 'amk',
        (m) => m.itemType = 1,
        (m) => m.groupActionType = 2,
        (m) => m.groupTitle = 'group',
        (m) => m.ckRecordId = 'record',
        (m) => m.ckSyncState = true,
        (m) => m.temp = true,
        (m) => m.hasBeenForwarded = true,
        (m) => m.verificationFailed = true,
        (m) => m.error = 1,
        (m) => m.text = 'fallback text',
        (m) => m.attributedBody = [AttributedBody.raw('fallback text')],
      ];
      for (var i = 0; i < mutations.length; i++) {
        final row = _reactionRow(chat: chat);
        mutations[i](row);
        expect(
          CloudSyncReactionSendIdentity.capture(row, chat, _reactionGuid),
          isNull,
          reason: 'mutation $i',
        );
      }
    });

    test('rejects malformed guids, parts, and guid aliasing', () {
      final chat = _directChat();
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(chat: chat),
          chat,
          'not-a-uuid',
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(stableGuid: 'temp-12345678', chat: chat),
          chat,
          'temp-12345678',
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(parentGuid: 'has space', chat: chat),
          chat,
          _reactionGuid,
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(parentGuid: null, chat: chat),
          chat,
          _reactionGuid,
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(chat: chat),
          chat,
          _otherGuid,
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(part: -1, chat: chat),
          chat,
          _reactionGuid,
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.capture(
          _reactionRow(part: 0x100000000, chat: chat),
          chat,
          _reactionGuid,
        ),
        isNull,
      );
    });

    test('identity exposes hashes only and redacts identifiers', () {
      final chat = _directChat();
      final identity = CloudSyncReactionSendIdentity.capture(
        _reactionRow(chat: chat),
        chat,
        _reactionGuid,
      )!;
      expect(identity.toString(), 'CloudSyncReactionSendIdentity(redacted)');
      expect(identity.guidHash, isNot(contains(_reactionGuid)));
      expect(identity.sourceSha256, isNot(contains(_parentGuid)));
      expect(identity.guidHash.length, 64);
      expect(identity.sourceSha256.length, 64);
    });
  });

  group('native wire agreement', () {
    test('accepts exact add and remove matches for the standard six', () {
      for (final base in _bases) {
        for (final enable in [true, false]) {
          final chat = _directChat();
          final type = enable ? base : '-$base';
          final row = _reactionRow(type: type, chat: chat);
          final identity = CloudSyncReactionSendIdentity.captureWire(
            row,
            chat,
            _wire(base: base, enable: enable),
          );
          expect(identity, isNotNull, reason: type);
          expect(
            identity!.sourceSha256,
            CloudSyncReactionSendIdentity.capture(
              row,
              chat,
              _reactionGuid,
            )!.sourceSha256,
          );
        }
      }
    });

    test('preserves null parts exactly and never collapses them to zero', () {
      final chat = _directChat();
      final nullRow = _reactionRow(part: null, chat: chat);
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          nullRow,
          chat,
          _wire(toPart: null),
        ),
        isNotNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          nullRow,
          chat,
          _wire(toPart: 0),
        ),
        isNull,
      );
      final zeroRow = _reactionRow(part: 0, chat: chat);
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          zeroRow,
          chat,
          _wire(toPart: null),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          zeroRow,
          chat,
          _wire(toPart: 0x100000000),
        ),
        isNull,
      );
    });

    test('rejects guid, parent, kind, and flag mismatches', () {
      final chat = _directChat();
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(id: _otherGuid),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(toUuid: _otherGuid),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(toPart: 1),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(type: '-love', chat: chat),
          chat,
          _wire(base: 'love', enable: true),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(type: 'love', chat: chat),
          chat,
          _wire(base: 'love', enable: false),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(type: 'love', chat: chat),
          chat,
          _wire(base: 'like', enable: true),
        ),
        isNull,
      );
      final row = _reactionRow(chat: chat);
      final source = CloudSyncReactionSendIdentity.capture(
        row,
        chat,
        _reactionGuid,
      )!.sourceSha256;
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          row,
          chat,
          _wire(),
          expectedSourceSha256: source,
        ),
        isNotNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          row,
          chat,
          _wire(base: 'like'),
          expectedSourceSha256: source,
        ),
        isNull,
      );
    });

    test('rejects unsupported natives and transport mismatches', () {
      final chat = _directChat();
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(reaction: const api.Reaction.emoji('red-heart')),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(
            reaction: const api.Reaction.sticker(
              spec: null,
              body: api.MessageParts(field0: <api.IndexedMessagePart>[]),
            ),
          ),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(messageOverride: const api.Message.delivered()),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(sender: 'mailto:other@example.com'),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(senderGuid: 'iMessage;-;other@example.com'),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(verificationFailed: true),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(withTarget: true),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(omitConversation: true),
        ),
        isNull,
      );
    });
  });

  group('parent reference and bound chat', () {
    test('accepts non-v4 bare parent guids', () {
      final chat = _directChat();
      for (final parent in ['bad', 'prt-msg_123', _parentGuid]) {
        expect(
          CloudSyncReactionSendIdentity.capture(
            _reactionRow(parentGuid: parent, chat: chat),
            chat,
            _reactionGuid,
          ),
          isNotNull,
          reason: parent,
        );
      }
    });

    test('rejects wrapped parents and self-parent', () {
      final chat = _directChat();
      const wrapped = 'p:0/$_parentGuid';
      const bubble = 'bp:0/$_parentGuid';
      const balloon = 'bpdi:0/$_parentGuid';
      const slash = '0/$_parentGuid';
      for (final parent in [wrapped, bubble, balloon, slash, _reactionGuid]) {
        expect(
          CloudSyncReactionSendIdentity.capture(
            _reactionRow(parentGuid: parent, chat: chat),
            chat,
            _reactionGuid,
          ),
          isNull,
          reason: parent,
        );
      }
    });

    test('bound chat relation honors reload identity and route', () {
      final chat = _directChat();
      final unbound = Message(
        guid: _reactionGuid,
        isFromMe: true,
        dateCreated: DateTime.utc(2026, 9, 7),
        associatedMessageGuid: _parentGuid,
        associatedMessagePart: 0,
        associatedMessageType: 'love',
      );
      expect(
        CloudSyncReactionSendIdentity.capture(unbound, chat, _reactionGuid),
        isNull,
      );
      Chat persistedChat({
        int? id,
        String? guid,
        String? identifier,
        String? handle,
      }) {
        final recipient = Handle(address: _recipient, service: 'iMessage');
        final c = Chat(
          id: id,
          guid: guid ?? _chatGuid,
          chatIdentifier: identifier ?? _recipient,
          usingHandle: handle ?? _sender,
          style: 45,
          participants: [recipient],
        );
        c.handles.add(recipient);
        return c;
      }

      final bound = persistedChat(id: 7);
      final row = _reactionRow(chat: bound);
      final reloaded = persistedChat(id: 7);
      expect(
        CloudSyncReactionSendIdentity.capture(row, reloaded, _reactionGuid),
        isNotNull,
      );
      final others = [
        persistedChat(id: 8),
        persistedChat(id: 7, guid: 'iMessage;-;other@example.com'),
        persistedChat(id: 7, identifier: 'other@example.com'),
        persistedChat(id: 7, handle: 'mailto:other@example.com'),
        persistedChat(),
        _directChat(),
      ];
      for (var i = 0; i < others.length; i++) {
        expect(
          CloudSyncReactionSendIdentity.capture(row, others[i], _reactionGuid),
          isNull,
          reason: 'other $i',
        );
      }
    });
  });

  group('wire route agreement', () {
    test('requires non-null senderGuid and exact peer multiset', () {
      final chat = _directChat();
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(senderGuid: null),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(participants: [_sender]),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(
            participants: [
              'mailto:recipient@example.com',
              _sender,
              'mailto:extra@example.com',
            ],
          ),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(participants: ['mailto:wrong@example.com', _sender]),
        ),
        isNull,
      );
      expect(
        CloudSyncReactionSendIdentity.captureWire(
          _reactionRow(chat: chat),
          chat,
          _wire(participants: [_sender, 'mailto:recipient@example.com']),
        ),
        isNotNull,
      );
    });
  });
}
