import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

// Synthetic fixtures only. No Apple account, network, database, or native
// library is touched: the wire objects below are plain Dart constructions
// and capture itself is pure. Every row carries positive ids because capture
// requires persisted input.
const _remote = 'remote@example.com';
const _owner = 'mailto:owner@example.com';
const _chatGuid = 'iMessage;-;remote@example.com';
const _incomingGuid = 'recv-guid-incoming-0001';
const _mirroredGuid = 'recv-guid-mirrored-0001';
const _text = 'plain hello';
final _sentAt = DateTime.utc(2026, 9, 15, 12).millisecondsSinceEpoch;

const _liveContext = CloudSyncReceivedArchiveLiveContext(
  observedViaLiveReceive: true,
  observedLocalHandles: [_owner],
  receivedOnHandle: _owner,
);

Handle _remoteHandle() => Handle(address: _remote, service: 'iMessage');

Handle _storedHandle(String address) =>
    Handle(address: address, service: 'iMessage');

Chat _directChat({int id = 70, String? cloudGuid}) {
  final remote = _remoteHandle();
  final chat = Chat(
    id: id,
    guid: _chatGuid,
    chatIdentifier: _remote,
    usingHandle: _owner,
    style: 45,
    participants: [remote],
  );
  chat.handles.add(remote);
  if (cloudGuid != null) chat.cloudGuid = cloudGuid;
  return chat;
}

Chat _provisionalChat({int id = 71}) {
  final remote = _remoteHandle();
  final chat = Chat(
    id: id,
    guid: 'AA6165FC-EFF7-4CA7-8F11-C0D3D397597B',
    usingHandle: _owner,
    participants: [remote],
  );
  chat.handles.add(remote);
  return chat;
}

Message _row({
  required Chat chat,
  int? id = 90,
  String guid = _incomingGuid,
  String text = _text,
  required bool? isFromMe,
  int? sentAt,
  String? handleAddress,
}) {
  final row = Message(
    id: id,
    guid: guid,
    text: text,
    dateCreated: DateTime.fromMillisecondsSinceEpoch(
      sentAt ?? _sentAt,
      isUtc: true,
    ),
    isFromMe: isFromMe ?? false,
    attributedBody: [AttributedBody.raw(text)],
    handle: handleAddress == null ? null : _storedHandle(handleAddress),
  );
  if (isFromMe == null) row.isFromMe = null;
  row.chat.target = chat;
  return row;
}

api.NormalMessage _plainNormal(String text) {
  return api.NormalMessage(
    parts: api.MessageParts(
      field0: [
        api.IndexedMessagePart(
          part_: api.MessagePart.text(
            text,
            const api.TextFormat.flags(
              api.TextFlags(
                bold: false,
                italic: false,
                underline: false,
                strikethrough: false,
              ),
            ),
          ),
        ),
      ],
    ),
    service: const api.MessageType_IMessage(),
    voice: false,
  );
}

api.MessageInst _wire({
  String id = _incomingGuid,
  String? sender = 'mailto:remote@example.com',
  api.NormalMessage? normal,
  api.Message? messageOverride,
  String? senderGuid = _chatGuid,
  String? afterGuid,
  List<String>? participants,
  int? sentAt,
  bool verificationFailed = false,
  List<api.MessageTarget>? target,
}) {
  return api.MessageInst(
    id: id,
    sender: sender,
    conversation: api.ConversationData(
      participants: participants ?? [_owner, 'mailto:remote@example.com'],
      senderGuid: senderGuid,
      afterGuid: afterGuid,
    ),
    message:
        messageOverride ?? api.Message.message(normal ?? _plainNormal(_text)),
    sentTimestamp: sentAt ?? _sentAt,
    // IDSRecvMessage.to_message preserves the sender's reply-device token.
    // This is not the addressed local handle (IDS tP).
    target: target ?? [api.MessageTarget.token(Uint8List(32))],
    sendDelivered: false,
    verificationFailed: verificationFailed,
  );
}

String _reason(CloudSyncReceivedArchiveCapture capture) {
  expect(capture, isA<CloudSyncReceivedArchiveIneligible>());
  return (capture as CloudSyncReceivedArchiveIneligible).reason;
}

CloudSyncReceivedArchiveIdentity _eligible(
  CloudSyncReceivedArchiveCapture capture,
) {
  expect(capture, isA<CloudSyncReceivedArchiveEligible>());
  return (capture as CloudSyncReceivedArchiveEligible).identity;
}

void main() {
  group('eligible received origins', () {
    test('reply-device token is optional routing, not message content', () {
      final chat = _directChat();
      final row = _row(chat: chat, isFromMe: false, handleAddress: _remote);
      final wire = _wire();
      final first = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: row,
          chat: chat,
          wire: wire,
          liveContext: _liveContext,
        ),
      );
      for (final target in <List<api.MessageTarget>?>[
        null,
        [],
        [api.MessageTarget.token(Uint8List.fromList(List.filled(32, 9)))],
      ]) {
        wire.target = target;
        final next = _eligible(
          CloudSyncReceivedArchiveIdentity.capture(
            message: row,
            chat: chat,
            wire: wire,
            liveContext: _liveContext,
            expectedSourceSha256: first.sourceSha256,
          ),
        );
        expect(next.sourceSha256, first.sourceSha256);
      }
    });

    test('incoming plain text binds GUID, sender, body, and time', () {
      final chat = _directChat();
      final identity = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(chat: chat, isFromMe: false, handleAddress: _remote),
          chat: chat,
          wire: _wire(),
          liveContext: _liveContext,
        ),
      );
      expect(identity.origin, CloudSyncReceivedArchiveOrigin.incoming);
      expect(identity.guidHash, isNotEmpty);
      expect(identity.sourceSha256, isNotEmpty);
      expect(identity.guidHash, isNot(identity.sourceSha256));
    });

    test('mirrored own-device send is distinct from incoming', () {
      final chat = _directChat();
      final mirrored = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(
            chat: chat,
            guid: _mirroredGuid,
            isFromMe: true,
            handleAddress: 'owner@example.com',
          ),
          chat: chat,
          wire: _wire(id: _mirroredGuid, sender: _owner),
          liveContext: _liveContext,
        ),
      );
      expect(mirrored.origin, CloudSyncReceivedArchiveOrigin.mirrored);
      final incomingChat = _directChat();
      final incoming = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(
            chat: incomingChat,
            isFromMe: false,
            handleAddress: _remote,
          ),
          chat: incomingChat,
          wire: _wire(),
          liveContext: _liveContext,
        ),
      );
      expect(mirrored.sourceSha256, isNot(incoming.sourceSha256));
    });

    test('mirrored stays eligible when participants omit self', () {
      final chat = _directChat();
      final identity = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(
            chat: chat,
            guid: _mirroredGuid,
            isFromMe: true,
            handleAddress: 'owner@example.com',
          ),
          chat: chat,
          wire: _wire(
            id: _mirroredGuid,
            sender: _owner,
            participants: ['mailto:remote@example.com'],
          ),
          liveContext: _liveContext,
        ),
      );
      expect(identity.origin, CloudSyncReceivedArchiveOrigin.mirrored);
    });

    test('provisional direct rows are covered for both origins', () {
      final incomingChat = _provisionalChat();
      final incoming = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(
            chat: incomingChat,
            isFromMe: false,
            handleAddress: _remote,
          ),
          chat: incomingChat,
          wire: _wire(senderGuid: null),
          liveContext: _liveContext,
        ),
      );
      expect(incoming.origin, CloudSyncReceivedArchiveOrigin.incoming);
      final mirroredChat = _provisionalChat(id: 72);
      final mirrored = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(
            chat: mirroredChat,
            guid: _mirroredGuid,
            isFromMe: true,
            handleAddress: 'owner@example.com',
          ),
          chat: mirroredChat,
          wire: _wire(id: _mirroredGuid, sender: _owner, senderGuid: null),
          liveContext: _liveContext,
        ),
      );
      expect(mirrored.origin, CloudSyncReceivedArchiveOrigin.mirrored);
    });

    test('capture is deterministic and revalidates a known source', () {
      final firstChat = _directChat();
      final first = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(
            chat: firstChat,
            isFromMe: false,
            handleAddress: _remote,
          ),
          chat: firstChat,
          wire: _wire(),
          liveContext: _liveContext,
        ),
      );
      final secondChat = _directChat();
      final second = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(
            chat: secondChat,
            isFromMe: false,
            handleAddress: _remote,
          ),
          chat: secondChat,
          wire: _wire(),
          liveContext: _liveContext,
          expectedSourceSha256: first.sourceSha256,
        ),
      );
      expect(second.sourceSha256, first.sourceSha256);
      expect(second.guidHash, first.guidHash);
    });

    test(
      'received source does not depend on the outgoing sender preference',
      () {
        final chat = _directChat();
        final row = _row(chat: chat, isFromMe: false, handleAddress: _remote);
        final wire = _wire();
        final first = _eligible(
          CloudSyncReceivedArchiveIdentity.capture(
            message: row,
            chat: chat,
            wire: wire,
            liveContext: _liveContext,
          ),
        );
        for (final senderPreference in <String?>[
          null,
          '',
          'tel:+15550000003',
        ]) {
          chat.usingHandle = senderPreference;
          final next = _eligible(
            CloudSyncReceivedArchiveIdentity.capture(
              message: row,
              chat: chat,
              wire: wire,
              liveContext: _liveContext,
              expectedSourceSha256: first.sourceSha256,
            ),
          );
          expect(next.sourceSha256, first.sourceSha256);
        }
      },
    );

    test('same-row canonical adoption preserves the received source', () {
      final chat = _provisionalChat();
      final wire = _wire(senderGuid: chat.guid);
      final row = _row(chat: chat, isFromMe: false, handleAddress: _remote);
      final first = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: row,
          chat: chat,
          wire: wire,
          liveContext: _liveContext,
        ),
      );
      chat.cloudGuid = chat.guid;
      chat.guid = _chatGuid;
      chat.chatIdentifier = _remote;
      chat.style = 45;
      final next = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: row,
          chat: chat,
          wire: wire,
          liveContext: _liveContext,
          expectedSourceSha256: first.sourceSha256,
        ),
      );
      expect(next.guidHash, first.guidHash);
      expect(next.sourceSha256, first.sourceSha256);
    });

    test('participant ordering is not new content but a changed wire is', () {
      final chat = _directChat();
      final row = _row(chat: chat, isFromMe: false, handleAddress: _remote);
      final first = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: row,
          chat: chat,
          wire: _wire(),
          liveContext: _liveContext,
        ),
      );
      _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: row,
          chat: chat,
          wire: _wire(participants: ['mailto:remote@example.com', _owner]),
          liveContext: _liveContext,
          expectedSourceSha256: first.sourceSha256,
        ),
      );
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: row,
            chat: chat,
            wire: _wire(afterGuid: 'prior-message'),
            liveContext: _liveContext,
            expectedSourceSha256: first.sourceSha256,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonSourceChanged,
      );
    });

    test('changed body or timestamp cannot pass old source revalidation', () {
      final chat = _directChat();
      final row = _row(chat: chat, isFromMe: false, handleAddress: _remote);
      final first = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: row,
          chat: chat,
          wire: _wire(),
          liveContext: _liveContext,
        ),
      );
      for (final changedTime in [false, true]) {
        final text = changedTime ? _text : 'changed hello';
        final timestamp = _sentAt + (changedTime ? 1 : 0);
        expect(
          _reason(
            CloudSyncReceivedArchiveIdentity.capture(
              message: _row(
                chat: chat,
                text: text,
                sentAt: timestamp,
                isFromMe: false,
                handleAddress: _remote,
              ),
              chat: chat,
              wire: _wire(normal: _plainNormal(text), sentAt: timestamp),
              liveContext: _liveContext,
              expectedSourceSha256: first.sourceSha256,
            ),
          ),
          CloudSyncReceivedArchiveIdentity.reasonSourceChanged,
        );
      }
    });

    test('conversation identity feeds the digest', () {
      final plainChat = _directChat();
      final plain = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(
            chat: plainChat,
            isFromMe: false,
            handleAddress: _remote,
          ),
          chat: plainChat,
          wire: _wire(),
          liveContext: _liveContext,
        ),
      );
      final aliasedChat = _directChat(cloudGuid: 'canon-cloud-id');
      final aliased = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(
            chat: aliasedChat,
            isFromMe: false,
            handleAddress: _remote,
          ),
          chat: aliasedChat,
          wire: _wire(senderGuid: 'canon-cloud-id'),
          liveContext: _liveContext,
        ),
      );
      expect(aliased.sourceSha256, isNot(plain.sourceSha256));
    });

    test('wrong expected source hash is rejected without detail', () {
      final chat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(chat: chat, isFromMe: false, handleAddress: _remote),
            chat: chat,
            wire: _wire(),
            liveContext: _liveContext,
            expectedSourceSha256: 'wrong',
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonSourceChanged,
      );
    });

    test('inputs are not mutated and isFromMe is preserved', () {
      final chat = _directChat();
      final row = _row(chat: chat, isFromMe: false, handleAddress: _remote);
      final bodies = row.attributedBody;
      _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: row,
          chat: chat,
          wire: _wire(),
          liveContext: _liveContext,
        ),
      );
      expect(row.isFromMe, isFalse);
      expect(row.guid, _incomingGuid);
      expect(identical(row.attributedBody, bodies), isTrue);
    });
  });

  group('persistence and live context binding', () {
    test('same peer does not authorize a different persisted parent', () {
      final bound = _directChat();
      final other = _directChat(id: 81);
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(chat: bound, isFromMe: false, handleAddress: _remote),
            chat: other,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonRoute,
      );
    });

    test('deleted or routing-only chats cannot become archive candidates', () {
      for (final mutate in <void Function(Chat)>[
        (chat) => chat.dateDeleted = DateTime.utc(2026, 9, 16),
        (chat) => chat.isRoutingStub = true,
      ]) {
        final chat = _directChat();
        mutate(chat);
        expect(
          _reason(
            CloudSyncReceivedArchiveIdentity.capture(
              message: _row(
                chat: chat,
                isFromMe: false,
                handleAddress: _remote,
              ),
              chat: chat,
              wire: _wire(),
              liveContext: _liveContext,
            ),
          ),
          CloudSyncReceivedArchiveIdentity.reasonRoute,
        );
      }
    });

    test('unpersisted rows are rejected even when identical', () {
      final chat = _directChat(id: 0);
      final row = _row(chat: chat, isFromMe: false, handleAddress: _remote);
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: row,
            chat: chat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonUnpersisted,
      );
      final unpersistedChat = _directChat();
      unpersistedChat.id = null;
      final unpersistedRow = _row(
        chat: unpersistedChat,
        id: null,
        isFromMe: false,
        handleAddress: _remote,
      );
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: unpersistedRow,
            chat: unpersistedChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonUnpersisted,
      );
    });

    test('non-live observation is rejected', () {
      final chat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(chat: chat, isFromMe: false, handleAddress: _remote),
            chat: chat,
            wire: _wire(),
            liveContext: const CloudSyncReceivedArchiveLiveContext(
              observedViaLiveReceive: false,
              observedLocalHandles: [_owner],
              receivedOnHandle: _owner,
            ),
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonNotLiveReceive,
      );
    });

    test('GUID mismatch is rejected', () {
      final chat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(chat: chat, isFromMe: false, handleAddress: _remote),
            chat: chat,
            wire: _wire(id: 'recv-guid-other-0009'),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonGuidMismatch,
      );
    });

    test('temporary and error GUIDs are rejected', () {
      for (final guid in ['temp-abcdefgh', 'error-protocol: x']) {
        final chat = _directChat();
        expect(
          _reason(
            CloudSyncReceivedArchiveIdentity.capture(
              message: _row(
                chat: chat,
                guid: guid,
                isFromMe: false,
                handleAddress: _remote,
              ),
              chat: chat,
              wire: _wire(id: guid),
              liveContext: _liveContext,
            ),
          ),
          CloudSyncReceivedArchiveIdentity.reasonTempGuid,
        );
      }
    });

    test('verification failures are rejected on either side', () {
      final failingWireChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: failingWireChat,
              isFromMe: false,
              handleAddress: _remote,
            ),
            chat: failingWireChat,
            wire: _wire(verificationFailed: true),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonVerificationFailed,
      );
      final failingRowChat = _directChat();
      final badRow = _row(
        chat: failingRowChat,
        isFromMe: false,
        handleAddress: _remote,
      )..verificationFailed = true;
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: badRow,
            chat: failingRowChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonVerificationFailed,
      );
    });

    test('legacy-mapped rows stay in the read lane', () {
      final mappedChat = _directChat();
      final mapped = _row(
        chat: mappedChat,
        isFromMe: false,
        handleAddress: _remote,
      )..ckRecordId = 'record';
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: mapped,
            chat: mappedChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonLegacyMapped,
      );
    });
  });

  group('direction and send-state separation', () {
    test('sender and direction must agree', () {
      final fromMeRemoteChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: fromMeRemoteChat,
              isFromMe: true,
              handleAddress: 'owner@example.com',
            ),
            chat: fromMeRemoteChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonDirectionMismatch,
      );
      final nullDirectionChat = _directChat();
      final nullDirection = _row(
        chat: nullDirectionChat,
        isFromMe: null,
        handleAddress: _remote,
      );
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: nullDirection,
            chat: nullDirectionChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonDirectionMismatch,
      );
    });

    test('composer send-state markers are rejected', () {
      final markers = <String, void Function(Message)>{
        'staging': (m) => m.stagingGuid = 'staged',
        'temp': (m) => m.temp = true,
        'service': (m) => m.sendingServiceId = 'iMessage',
        'error': (m) => m.error = 1,
        'forwarded': (m) => m.hasBeenForwarded = true,
      };
      for (final entry in markers.entries) {
        final chat = _directChat();
        final row = _row(
          chat: chat,
          guid: _mirroredGuid,
          isFromMe: true,
          handleAddress: 'owner@example.com',
        );
        entry.value(row);
        expect(
          _reason(
            CloudSyncReceivedArchiveIdentity.capture(
              message: row,
              chat: chat,
              wire: _wire(id: _mirroredGuid, sender: _owner),
              liveContext: _liveContext,
            ),
          ),
          CloudSyncReceivedArchiveIdentity.reasonSendState,
          reason: entry.key,
        );
      }
    });
  });

  group('stored sender and counterpart binding', () {
    test('recipient must be the captured local endpoint, never guessed', () {
      for (final endpoint in [
        '',
        'mailto:foreign@example.com',
        'owner@example.com',
      ]) {
        final chat = _directChat();
        expect(
          _reason(
            CloudSyncReceivedArchiveIdentity.capture(
              message: _row(
                chat: chat,
                isFromMe: false,
                handleAddress: _remote,
              ),
              chat: chat,
              wire: _wire(),
              liveContext: CloudSyncReceivedArchiveLiveContext(
                observedViaLiveReceive: true,
                observedLocalHandles: const [_owner],
                receivedOnHandle: endpoint,
              ),
            ),
          ),
          CloudSyncReceivedArchiveIdentity.reasonRecipient,
        );
      }
    });

    test(
      'original local endpoint is bound even when both aliases are ours',
      () {
        const alternate = 'tel:+15550000003';
        const observedHandles = [_owner, alternate];
        final chat = _directChat();
        final row = _row(chat: chat, isFromMe: false, handleAddress: _remote);
        final wire = _wire();
        final first = _eligible(
          CloudSyncReceivedArchiveIdentity.capture(
            message: row,
            chat: chat,
            wire: wire,
            liveContext: const CloudSyncReceivedArchiveLiveContext(
              observedViaLiveReceive: true,
              observedLocalHandles: observedHandles,
              receivedOnHandle: _owner,
            ),
          ),
        );
        expect(
          _reason(
            CloudSyncReceivedArchiveIdentity.capture(
              message: row,
              chat: chat,
              wire: wire,
              liveContext: const CloudSyncReceivedArchiveLiveContext(
                observedViaLiveReceive: true,
                observedLocalHandles: observedHandles,
                receivedOnHandle: alternate,
              ),
              expectedSourceSha256: first.sourceSha256,
            ),
          ),
          CloudSyncReceivedArchiveIdentity.reasonSourceChanged,
        );
      },
    );

    test(
      'certified envelope endpoints must agree with the received source',
      () {
        for (final mismatch in [false, true]) {
          final chat = _directChat();
          final wire = _wire();
          wire.certifiedContext = api.CertifiedContext(
            version: 1,
            receipt: Uint8List.fromList([1]),
            sender: mismatch ? 'mailto:foreign@example.com' : wire.sender!,
            target: mismatch ? _owner : 'mailto:foreign@example.com',
            uuid: Uint8List(16),
            token: Uint8List(32),
          );
          expect(
            _reason(
              CloudSyncReceivedArchiveIdentity.capture(
                message: _row(
                  chat: chat,
                  isFromMe: false,
                  handleAddress: _remote,
                ),
                chat: chat,
                wire: wire,
                liveContext: _liveContext,
              ),
            ),
            CloudSyncReceivedArchiveIdentity.reasonRecipient,
          );
        }
      },
    );

    test('mismatched stored senders are rejected', () {
      final foreignChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: foreignChat,
              isFromMe: false,
              handleAddress: 'stranger@example.com',
            ),
            chat: foreignChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonSender,
      );
      final nullHandleChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(chat: nullHandleChat, isFromMe: false),
            chat: nullHandleChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonSender,
      );
      final mirroredRemoteChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: mirroredRemoteChat,
              guid: _mirroredGuid,
              isFromMe: true,
              handleAddress: _remote,
            ),
            chat: mirroredRemoteChat,
            wire: _wire(id: _mirroredGuid, sender: _owner),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonSender,
      );
    });

    test('missing conversation evidence is rejected', () {
      final chat = _directChat();
      final nullConversation = _wire();
      nullConversation.conversation = null;
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(chat: chat, isFromMe: false, handleAddress: _remote),
            chat: chat,
            wire: nullConversation,
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonCounterparts,
      );
    });

    test('wrong remote counterpart sets are rejected', () {
      final extraPeerChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: extraPeerChat,
              isFromMe: false,
              handleAddress: _remote,
            ),
            chat: extraPeerChat,
            wire: _wire(
              participants: [
                _owner,
                'mailto:remote@example.com',
                'mailto:third@example.com',
              ],
            ),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonCounterparts,
      );
      final missingRemoteChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: missingRemoteChat,
              isFromMe: false,
              handleAddress: _remote,
            ),
            chat: missingRemoteChat,
            wire: _wire(participants: [_owner]),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonCounterparts,
      );
      final unresolvableGuidChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: unresolvableGuidChat,
              isFromMe: false,
              handleAddress: _remote,
            ),
            chat: unresolvableGuidChat,
            wire: _wire(senderGuid: 'unknown-chat-id'),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonCounterparts,
      );
    });

    test('group chats stay explicitly unsupported', () {
      final first = Handle(address: 'first@example.com', service: 'iMessage');
      final second = Handle(address: '+15550000002', service: 'iMessage');
      final chat = Chat(
        id: 73,
        guid: 'iMessage;+;restored-group',
        chatIdentifier: 'restored-group',
        usingHandle: _owner,
        style: 43,
        participants: [first, second],
      );
      chat.handles.addAll([first, second]);
      final row = Message(
        id: 91,
        guid: _incomingGuid,
        text: _text,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(_sentAt, isUtc: true),
        isFromMe: false,
        attributedBody: [AttributedBody.raw(_text)],
        handle: _storedHandle(_remote),
      );
      row.chat.target = chat;
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: row,
            chat: chat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonGroup,
      );
    });
  });

  group('unsupported shapes stay explicit', () {
    test('non-message wire is rejected', () {
      final reactChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: reactChat,
              isFromMe: false,
              handleAddress: _remote,
            ),
            chat: reactChat,
            wire: _wire(
              messageOverride: const api.Message.react(
                api.ReactMessage(
                  toUuid: 'recv-guid-parent-0001',
                  toPart: 0,
                  reaction: api.ReactMessageType.react(
                    reaction: api.Reaction.like(),
                    enable: true,
                  ),
                  toText: 'parent snapshot',
                ),
              ),
            ),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonNotIMessage,
      );
    });

    test('system and scheduled rows are rejected', () {
      final systemChat = _directChat();
      final system = _row(
        chat: systemChat,
        isFromMe: false,
        handleAddress: _remote,
      )..itemType = 1;
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: system,
            chat: systemChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonSystemMessage,
      );
      final scheduledChat = _directChat();
      final scheduled = _row(
        chat: scheduledChat,
        isFromMe: false,
        handleAddress: _remote,
      )..dateScheduled = DateTime.utc(2026, 9, 16);
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: scheduled,
            chat: scheduledChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonScheduled,
      );
    });

    test('media, replies, and reactions are rejected', () {
      final mediaChat = _directChat();
      final media = _row(
        chat: mediaChat,
        isFromMe: false,
        handleAddress: _remote,
      )..hasAttachments = true;
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: media,
            chat: mediaChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonMedia,
      );
      final replyChat = _directChat();
      final reply = _row(
        chat: replyChat,
        isFromMe: false,
        handleAddress: _remote,
      )..threadOriginatorGuid = 'recv-guid-parent-0001';
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: reply,
            chat: replyChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonReply,
      );
      final reactionChat = _directChat();
      final reaction =
          _row(chat: reactionChat, isFromMe: false, handleAddress: _remote)
            ..associatedMessageGuid = 'recv-guid-parent-0001'
            ..associatedMessageType = 'like';
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: reaction,
            chat: reactionChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonReaction,
      );
    });

    test('rich payloads and non-plain bodies are rejected', () {
      final styledChat = _directChat();
      final styled =
          _row(chat: styledChat, isFromMe: false, handleAddress: _remote)
            ..attributedBody = [
              AttributedBody(
                string: _text,
                runs: [
                  Run(
                    range: [0, _text.length],
                    attributes: Attributes(messagePart: 0, bold: true),
                  ),
                ],
              ),
            ];
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: styled,
            chat: styledChat,
            wire: _wire(),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonBody,
      );
    });

    test('wire mismatches and targets are rejected', () {
      final driftedChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: driftedChat,
              isFromMe: false,
              handleAddress: _remote,
            ),
            chat: driftedChat,
            wire: _wire(normal: _plainNormal('different')),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonWireBodyMismatch,
      );
      final targetedChat = _directChat();
      expect(
        _reason(
          CloudSyncReceivedArchiveIdentity.capture(
            message: _row(
              chat: targetedChat,
              isFromMe: false,
              handleAddress: _remote,
            ),
            chat: targetedChat,
            wire: _wire(target: [const api.MessageTarget.uuid('target-guid')]),
            liveContext: _liveContext,
          ),
        ),
        CloudSyncReceivedArchiveIdentity.reasonTarget,
      );
    });

    test('diagnostics stay redacted', () {
      final chat = _directChat();
      final identity = _eligible(
        CloudSyncReceivedArchiveIdentity.capture(
          message: _row(chat: chat, isFromMe: false, handleAddress: _remote),
          chat: chat,
          wire: _wire(),
          liveContext: _liveContext,
        ),
      );
      final shown = identity.toString();
      expect(shown.contains(_text), isFalse);
      expect(shown.contains(_incomingGuid), isFalse);
      expect(shown.contains(_remote), isFalse);
      expect(shown, contains('incoming'));
    });
  });
}
