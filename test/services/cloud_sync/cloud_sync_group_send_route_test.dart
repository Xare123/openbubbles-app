import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_group_send_route.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

const _guid = '11111111-1111-4111-8111-111111111111';
Handle _member(String value) => Handle(address: value, service: 'iMessage');
Chat _group() => Chat(
  id: 12,
  guid: 'iMessage;+;chat-group',
  chatIdentifier: 'chat-group',
  style: 43,
  usingHandle: 'mailto:self@example.com',
)..handles.addAll([_member('first@example.com'), _member('+15550000002')]);

Message _message(Chat chat) => Message(
  guid: _guid,
  text: 'hello',
  attributedBody: [AttributedBody.raw('hello')],
  dateCreated: DateTime.utc(2026, 9, 7),
  isFromMe: true,
)..chat.target = chat;

api.MessageInst _wire(Chat chat) => api.MessageInst(
  id: _guid,
  sender: chat.usingHandle,
  conversation: api.ConversationData(
    participants: [
      'mailto:first@example.com',
      'tel:+15550000002',
      chat.usingHandle!,
    ],
    senderGuid: chat.guid,
  ),
  message: api.Message.message(
    api.NormalMessage(
      parts: const api.MessageParts(
        field0: [
          api.IndexedMessagePart(
            part_: api.MessagePart.text(
              'hello',
              api.TextFormat.flags(
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
      service: const api.MessageType.iMessage(),
      voice: false,
    ),
  ),
  sentTimestamp: 0,
  sendDelivered: true,
  verificationFailed: false,
);

void main() {
  test('group routing digest matches the native framed SHA-256 vector', () {
    final group = _group()
      ..cloudGuid = 'raw-apple-group'
      ..groupVersion = 9;
    final route = CloudSyncGroupSendRoute.capture(group)!;
    expect(route.groupId, 'raw-apple-group');
    expect(
      route.routingMetadataDigest(groupVersion: group.groupVersion),
      '5ce8101f42beb2e5112a07339417c778b442f7efd9c92c5ebc817335a1c616c2',
    );
    group.handles.first.address = 'mailto:first@example.com';
    expect(
      CloudSyncGroupSendRoute.capture(
        group,
      )!.routingMetadataDigest(groupVersion: group.groupVersion),
      '5ce8101f42beb2e5112a07339417c778b442f7efd9c92c5ebc817335a1c616c2',
    );
    group.groupVersion = 10;
    expect(
      CloudSyncGroupSendRoute.capture(
        group,
      )!.routingMetadataDigest(groupVersion: group.groupVersion),
      isNot('5ce8101f42beb2e5112a07339417c778b442f7efd9c92c5ebc817335a1c616c2'),
    );
  });

  test('group route preserves an exact business participant identity', () {
    const business = 'urn:biz:123e4567-e89b-12d3-a456-426614174000';
    final group = _group();
    group.handles.first.address = business;
    final route = CloudSyncGroupSendRoute.capture(group);
    expect(route, isNotNull);
    expect(route!.members, contains(business));
    final wire = _wire(group);
    wire.conversation!.participants[0] = business;
    expect(
      CloudSyncLocalSendIdentity.captureWire(_message(group), group, wire),
      isNotNull,
    );
  });

  test('non-BMP group members use the native UTF-8 ordering', () {
    final group = _group()
      ..cloudGuid = 'raw-apple-group'
      ..groupVersion = 9;
    group.handles
      ..clear()
      ..addAll([_member('\u{10000}'), _member('\uE000')]);
    expect(
      CloudSyncGroupSendRoute.capture(
        group,
      )!.routingMetadataDigest(groupVersion: group.groupVersion),
      '745cda1e196792998ef8b585fec5b2d6e6d96cf5960af0a261740a769c44dd4b',
    );
  });

  test('restoring raw CloudKit group ID preserves captured IDS origin', () {
    final group = _group();
    final message = _message(group);
    final wire = _wire(group);
    final before = CloudSyncLocalSendIdentity.captureWire(
      message,
      group,
      wire,
    )!;
    for (final rawGroupId in ['raw-apple-group', _guid]) {
      group.cloudGuid = rawGroupId;
      final after = CloudSyncLocalSendIdentity.captureWire(
        message,
        group,
        wire,
        expectedSourceSha256: before.sourceSha256,
      );
      expect(after, isNotNull);
      expect(after!.sourceSha256, before.sourceSha256);
      expect(after.guidHash, before.guidHash);
    }
  });

  test('an identified group remains a group with one other member', () {
    final group = _group();
    group.handles.removeLast();
    final wire = _wire(group);
    wire.conversation!.participants.remove('tel:+15550000002');
    expect(
      CloudSyncLocalSendIdentity.captureWire(_message(group), group, wire),
      isNotNull,
    );
    group
      ..guid = _guid
      ..chatIdentifier = null;
    // A one-member provisional conversation is a direct send, not a newly
    // invented group. Restored canonical group identity distinguishes them.
    expect(CloudSyncGroupSendRoute.capture(group), isNull);
  });

  test(
    'member ordering and matching explicit prefixes do not change source',
    () {
      final group = _group();
      final message = _message(group);
      final original = CloudSyncLocalSendIdentity.captureWire(
        message,
        group,
        _wire(group),
      )!;
      final members = group.handles.toList().reversed.toList();
      group.handles
        ..clear()
        ..addAll(members);
      group.usingHandle = 'self@example.com';
      group.handles.singleWhere((h) => h.address.contains('@')).address =
          'mailto:first@example.com';
      final wire = _wire(group)..sender = 'self@example.com';
      wire.conversation!.participants = wire.conversation!.participants.reversed
          .toList();
      final reordered = CloudSyncLocalSendIdentity.captureWire(
        message,
        group,
        wire,
        expectedSourceSha256: original.sourceSha256,
      );
      expect(reordered!.sourceSha256, original.sourceSha256);
      expect(
        CloudSyncGroupSendRoute.capture(group).toString(),
        'CloudSyncGroupSendRoute(redacted)',
      );
    },
  );

  for (final change in <String, void Function(Chat)>{
    'missing row': (c) => c.id = null,
    'direct style with two members': (c) => c.style = 45,
    'wrong canonical identifier': (c) => c.chatIdentifier = 'elsewhere',
    'duplicate member': (c) =>
        c.handles.add(_member('mailto:first@example.com')),
    'sender as other member': (c) => c.handles.add(_member('self@example.com')),
    'scheme mismatch': (c) => c.usingHandle = 'tel:self@example.com',
    'control character': (c) => c.handles.first.address = 'bad\naddress',
    'other service': (c) => c.handles.first.service = 'SMS',
    'sms chat': (c) => c.isRpSms = true,
    'missing members': (c) => c.handles.clear(),
  }.entries) {
    test('rejects ${change.key}', () {
      final group = _group();
      change.value(group);
      expect(
        CloudSyncLocalSendIdentity.capture(_message(group), group, _guid),
        isNull,
      );
    });
  }

  for (final change in <String, void Function(api.MessageInst)>{
    'sender': (w) => w.sender = 'mailto:other@example.com',
    'omitted participant': (w) => w.conversation!.participants.removeLast(),
    'added participant': (w) =>
        w.conversation!.participants.add('tel:+15550000003'),
    'duplicate participant': (w) => w.conversation!.participants.add(w.sender!),
    'different chat': (w) => w.conversation!.senderGuid = 'iMessage;+;other',
    'wrong scheme': (w) =>
        w.conversation!.participants[0] = 'tel:first@example.com',
    'text': (w) => (w.message as api.Message_Message).field0.parts =
        const api.MessageParts(field0: []),
    'verification failure': (w) => w.verificationFailed = true,
  }.entries) {
    test('wire rejects changed ${change.key}', () {
      final group = _group();
      final wire = _wire(group);
      change.value(wire);
      expect(
        CloudSyncLocalSendIdentity.captureWire(_message(group), group, wire),
        isNull,
      );
    });
  }

  test(
    'old source cannot follow a different persisted row or changed member set',
    () {
      final group = _group();
      final message = _message(group);
      final source = CloudSyncLocalSendIdentity.capture(message, group, _guid)!;
      group.id = 13;
      expect(
        CloudSyncLocalSendIdentity.capture(
          message,
          group,
          _guid,
          expectedSourceSha256: source.sourceSha256,
        ),
        isNull,
      );
      group.id = 12;
      group.handles.first.address = 'replacement@example.com';
      expect(
        CloudSyncLocalSendIdentity.capture(
          message,
          group,
          _guid,
          expectedSourceSha256: source.sourceSha256,
        ),
        isNull,
      );
    },
  );
}
