import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_encoder.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final nativeLibrary = Platform.environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'];
  setUpAll(() async {
    if (nativeLibrary == null) {
      RustLib.initMock(api: _Bridge());
    } else {
      await RustLib.init(externalLibrary: ExternalLibrary.open(nativeLibrary));
    }
  });
  tearDownAll(RustLib.dispose);

  for (final text in ['plain text', 'A😀B\nhttps://example.com/a+b?x=1&y=2']) {
    test(
      'plain text roundtrip preserves content and journal binding: ${text.length}',
      () {
        final message = _message(text);
        final bodies = message.attributedBody;
        final source = CloudSyncLocalSendIdentity.capture(
          message,
          message.chat.target!,
          message.guid!,
        )!;
        final encoded = encodeCloudSyncLocalSendPlainText(message);
        final proto = api.decodeMessageproto(wrapped: encoded.msgProto);
        expect(proto.text, text);
        expect(proto.attributedBody, isNull);
        expect(proto.subject, isNull);
        expect(proto.payloadData, isNull);
        expect(proto.associatedMessageGuid, isNull);
        expect(encoded.guid, message.guid);
        expect(encoded.chatId, message.chat.target!.guid);
        expect(encoded.destinationCallerId, 'sender@example.com');
        expect(
          encoded.flags.bits(),
          IS_FINISHED | IS_FROM_ME | IS_SENT | WAS_DATA_DETECTED,
        );
        expect(identical(message.attributedBody, bodies), isTrue);
        expect(
          CloudSyncLocalSendIdentity.capture(
            message,
            message.chat.target!,
            message.guid!,
          )!.sourceSha256,
          source.sourceSha256,
        );
      },
    );
  }
  test('read and delivery state survive encoding', () {
    final message = _message('receipts')
      ..dateRead = DateTime.utc(2026, 9, 7, 1)
      ..dateDelivered = DateTime.utc(2026, 9, 7);
    final encoded = encodeCloudSyncLocalSendPlainText(message);
    final proto = api.decodeMessageproto(wrapped: encoded.msgProto);
    expect(proto.dateRead, greaterThan(proto.dateDelivered!));
    expect(
      encoded.flags.bits() & (IS_READ | IS_DELIVERED),
      IS_READ | IS_DELIVERED,
    );
  });
  final rejected = <String, void Function(Message)>{
    'styled text': (m) =>
        _attributes(m, Attributes(messagePart: 0, bold: true)),
    'attachment': (m) => m.hasAttachments = true,
    'mention': (m) => _attributes(
      m,
      Attributes(messagePart: 0, mention: 'other@example.com'),
    ),
    'different body': (m) => m.attributedBody = [AttributedBody.raw('changed')],
    'failed send': (m) => m.error = 1,
    'edit': (m) => m.dateEdited = DateTime.utc(2026, 9, 7),
    'reply': (m) => m.threadOriginatorGuid = 'reply',
    'reaction': (m) => m.associatedMessageGuid = 'parent',
    'schedule': (m) => m.dateScheduled = DateTime.utc(2026, 9, 8),
    'sms': (m) => m.chat.target!.isRpSms = true,
    'provisional chat': (m) =>
        m.chat.target!.guid = '266571D8-DA74-4C73-A681-9007C946D3AA',
  };
  for (final entry in rejected.entries) {
    test('does not flatten ${entry.key}', () {
      final message = _message('test');
      entry.value(message);
      expect(
        () => encodeCloudSyncLocalSendPlainText(message),
        throwsStateError,
      );
    });
  }
  if (nativeLibrary != null) {
    test('real legacy encoder archives plain text; V2 encoder does not', () {
      final message = _message('bridge integration fixture');
      final legacy = message.toCloud(true);
      expect(
        api.decodeMessageproto(wrapped: legacy.msgProto).attributedBody,
        isNotEmpty,
      );
      final v2 = encodeCloudSyncLocalSendPlainText(message);
      expect(
        api.decodeMessageproto(wrapped: v2.msgProto).attributedBody,
        isNull,
      );
      expect(v2.time, legacy.time);
      expect(v2.flags.bits(), legacy.flags.bits());
      expect(v2.chatId, legacy.chatId);
      expect(v2.destinationCallerId, legacy.destinationCallerId);
    });
  }
}

Message _message(String text) {
  final recipient = Handle(
    address: 'recipient@example.com',
    service: 'iMessage',
  );
  final chat = Chat(
    guid: 'iMessage;-;recipient@example.com',
    chatIdentifier: 'recipient@example.com',
    usingHandle: 'mailto:sender@example.com',
    style: 45,
    participants: [recipient],
  );
  chat.handles.add(recipient);
  return Message(
    guid: 'EA6165FC-EFF7-40A7-8F11-C0D3D397597B',
    text: text,
    dateCreated: DateTime.utc(2026, 9, 6),
    isFromMe: true,
    attributedBody: [AttributedBody.raw(text)],
  )..chat.target = chat;
}

void _attributes(Message message, Attributes attributes) {
  message.attributedBody = [
    AttributedBody(
      string: message.text!,
      runs: [
        Run(range: [0, message.text!.length], attributes: attributes),
      ],
    ),
  ];
}

// Real Dart composition, mocked only at the FFI boundary for portable CI.
// The optional signed native library runs these same cases across FRB locally.
class _Bridge implements RustLibApi {
  @override
  api.SystemTime crateApiApiUtmNow() => _Time();
  @override
  api.GZipWrapperMessageProto crateApiApiEncodeMessageproto({
    required api.MessageProto messageproto,
  }) => _Proto(messageproto);
  @override
  api.MessageProto crateApiApiDecodeMessageproto({
    required api.GZipWrapperMessageProto wrapped,
  }) => (wrapped as _Proto).value;
  @override
  api.GZipWrapperMessageProto3 crateApiApiEncodeMessageproto3({
    required api.MessageProto3 messageproto3,
  }) => _Proto3();
  @override
  api.GZipWrapperMessageProto4 crateApiApiEncodeMessageproto4({
    required api.MessageProto4 messageproto4,
  }) => _Proto4();
  @override
  api.MessageFlags crateApiApiMessageFlagsFromBitsTruncate({
    required int val,
  }) => _Flags(val);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Time implements api.SystemTime {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Proto implements api.GZipWrapperMessageProto {
  _Proto(this.value);
  final api.MessageProto value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Proto3 implements api.GZipWrapperMessageProto3 {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Proto4 implements api.GZipWrapperMessageProto4 {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Flags implements api.MessageFlags {
  _Flags(this.value);
  final int value;
  @override
  int bits() => value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
