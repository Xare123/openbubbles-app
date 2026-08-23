import 'dart:io';

import 'package:bluebubbles/database/global/payload_data.dart' as payload_data;
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/constants.dart' as constants;
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_canary_candidate.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 8, 22, 12);
const _opaqueCloudMessage = _FakeCloudMessage();

void main() {
  test('selects the newest eligible one-to-one text', () {
    final older = _ordinaryMessage(
      guid: 'older-message',
      text: 'older text',
      createdAt: _now.subtract(const Duration(minutes: 2)),
    );
    final newest = _ordinaryMessage(
      guid: 'newest-message',
      text: 'newest text',
      createdAt: _now.subtract(const Duration(minutes: 1)),
    );
    final encoded = <Message>[];

    final candidate = CloudSyncOutboundCanaryCandidateSelector(
      reader: _Reader([older, newest]),
      encoder: (message) {
        encoded.add(message);
        return _opaqueCloudMessage;
      },
      clock: () => _now,
    ).selectNewest();

    expect(candidate, isNotNull);
    expect(encoded, [newest]);
    expect(candidate!.cloudMessage, same(_opaqueCloudMessage));
    expect(candidate.characterCount, 'newest text'.runes.length);
    expect(candidate.createdAtUtc, newest.dateCreated!.toUtc());
    expect(candidate.guidHash, 'f094c2d57a312a52');
  });

  test('returns only redacted diagnostics', () {
    final candidate = CloudSyncOutboundCanaryCandidateSelector(
      reader: _Reader([
        _ordinaryMessage(
          guid: 'redaction-guid',
          text: 'THIS MUST NEVER APPEAR IN DIAGNOSTICS',
        ),
      ]),
      encoder: (_) => _opaqueCloudMessage,
      clock: () => _now,
    ).selectNewest()!;

    final diagnostic = '${candidate.toString()} ${candidate.toJson()}';
    expect(diagnostic, contains('guidHash'));
    expect(diagnostic, contains('characterCount'));
    expect(diagnostic, isNot(contains('THIS MUST NEVER APPEAR')));
    expect(diagnostic, isNot(contains('person@example.com')));
    expect(diagnostic, isNot(contains('redaction-guid')));
  });

  test('never falls back when the newest outgoing row is unsafe', () {
    final older = _ordinaryMessage(
      guid: 'older-safe-message',
      createdAt: _now.subtract(const Duration(minutes: 2)),
    );
    final newest = _ordinaryMessage(
      guid: 'newest-unsafe-message',
      createdAt: _now.subtract(const Duration(minutes: 1)),
      hasAttachments: true,
    );
    var conversions = 0;

    final candidate = CloudSyncOutboundCanaryCandidateSelector(
      reader: _Reader([older, newest]),
      encoder: (_) {
        conversions++;
        return _opaqueCloudMessage;
      },
      clock: () => _now,
    ).selectNewest();

    expect(candidate, isNull);
    expect(conversions, 0);
  });

  test('never falls back after newest-row conversion failure', () {
    final older = _ordinaryMessage(
      guid: 'older-safe-message',
      createdAt: _now.subtract(const Duration(minutes: 2)),
    );
    final newest = _ordinaryMessage(
      guid: 'newest-conversion-failure',
      createdAt: _now.subtract(const Duration(minutes: 1)),
    );
    final encoded = <Message>[];

    final candidate = CloudSyncOutboundCanaryCandidateSelector(
      reader: _Reader([older, newest]),
      encoder: (message) {
        encoded.add(message);
        throw StateError('conversion_failed');
      },
      clock: () => _now,
    ).selectNewest();

    expect(candidate, isNull);
    expect(encoded, [newest]);
  });

  test('rejects a candidate older than the short operator-intent window', () {
    final candidate = CloudSyncOutboundCanaryCandidateSelector(
      reader: _Reader([
        _ordinaryMessage(
          createdAt: _now.subtract(
            CloudSyncOutboundCanaryCandidateSelector.maximumCandidateAge +
                const Duration(seconds: 1),
          ),
        ),
      ]),
      encoder: (_) => _opaqueCloudMessage,
      clock: () => _now,
    ).selectNewest();

    expect(candidate, isNull);
  });

  for (final entry in <String, Message Function()>{
    'incoming': () => _ordinaryMessage(isFromMe: false),
    'missing guid': () => _ordinaryMessage(guid: null),
    'empty text': () => _ordinaryMessage(text: '   '),
    'missing date': () => _ordinaryMessage(missingDate: true),
    'attachments flag': () => _ordinaryMessage(hasAttachments: true),
    'attachment list': () =>
        _ordinaryMessage(attachments: [Attachment(guid: 'attachment-guid')]),
    'attachment run': () => _ordinaryMessage(
      runAttributes: Attributes(
        messagePart: 0,
        attachmentGuid: 'attachment-guid',
      ),
    ),
    'reaction association': () =>
        _ordinaryMessage(associatedMessageGuid: 'parent-guid'),
    'sticker association': () =>
        _ordinaryMessage(associatedMessageType: 'sticker'),
    'reply association': () =>
        _ordinaryMessage(threadOriginatorGuid: 'parent-guid'),
    'scheduled': () => _ordinaryMessage(dateScheduled: _now),
    'deleted': () => _ordinaryMessage(dateDeleted: _now),
    'staging': () => _ordinaryMessage(stagingGuid: 'staging-guid'),
    'sending error': () => _ordinaryMessage(error: 1),
    'sending service': () => _ordinaryMessage(sendingServiceId: 'iMessage'),
    'effect': () => _ordinaryMessage(expressiveSendStyleId: 'com.apple.effect'),
    'balloon': () => _ordinaryMessage(balloonBundleId: 'bundle'),
    'payload': () => _ordinaryMessage(
      payloadData: payload_data.PayloadData(type: constants.PayloadType.url),
    ),
    'apple payload marker': () => _ordinaryMessage(hasApplePayloadData: true),
    'edit metadata': () =>
        _ordinaryMessage(messageSummaryInfo: [MessageSummaryInfo.empty()]),
    'generic metadata': () => _ordinaryMessage(metadata: <String, dynamic>{}),
    'scheduled record already has CloudKit id': () =>
        _ordinaryMessage(ckRecordId: 'record-id'),
    'already crawled': () => _ordinaryMessage(ckSyncState: true),
    'subject': () => _ordinaryMessage(subject: 'subject'),
    'multiple attributed bodies': () => _ordinaryMessage(
      attributedBody: [
        AttributedBody.raw('message'),
        AttributedBody.raw('second'),
      ],
    ),
    'malformed attributed range': () => _ordinaryMessage(runRange: [1, 7]),
    'mention': () => _ordinaryMessage(
      runAttributes: Attributes(messagePart: 0, mention: 'person@example.com'),
    ),
    'audio transcript': () => _ordinaryMessage(
      runAttributes: Attributes(messagePart: 0, audioTranscript: 'audio'),
    ),
    'styled text': () =>
        _ordinaryMessage(runAttributes: Attributes(messagePart: 0, bold: true)),
  }.entries) {
    test('skips ${entry.key}', () {
      var conversions = 0;
      final candidate = CloudSyncOutboundCanaryCandidateSelector(
        reader: _Reader([entry.value()]),
        encoder: (_) {
          conversions++;
          return _opaqueCloudMessage;
        },
        clock: () => _now,
      ).selectNewest();

      expect(candidate, isNull, reason: entry.key);
      expect(conversions, 0, reason: 'conversion must happen after validation');
    });
  }

  test('skips SMS, RCS, and group conversations', () {
    final sms = _ordinaryMessage(chat: _chat(isRpSms: true));
    final rcs = _ordinaryMessage(chat: _chat(participantService: 'RCS'));
    final group = _ordinaryMessage(
      chat: _chat(
        participants: [
          _handle('person@example.com'),
          _handle('second@example.com'),
        ],
      ),
    );
    final styleGroup = _ordinaryMessage(chat: _chat(style: 43));

    for (final message in [sms, rcs, group, styleGroup]) {
      var conversions = 0;
      final candidate = CloudSyncOutboundCanaryCandidateSelector(
        reader: _Reader([message]),
        encoder: (_) {
          conversions++;
          return _opaqueCloudMessage;
        },
        clock: () => _now,
      ).selectNewest();
      expect(candidate, isNull);
      expect(conversions, 0);
    }
  });

  test('does not mutate a valid message while converting it', () {
    final message = _ordinaryMessage(text: 'unchanged text');
    final body = message.attributedBody.single;
    final originalGuid = message.guid;
    final originalText = message.text;
    final originalBody = message.attributedBody;

    final candidate = CloudSyncOutboundCanaryCandidateSelector(
      reader: _Reader([message]),
      encoder: (value) {
        expect(value, same(message));
        return _opaqueCloudMessage;
      },
      clock: () => _now,
    ).selectNewest();

    expect(candidate, isNotNull);
    expect(message.guid, originalGuid);
    expect(message.text, originalText);
    expect(identical(message.attributedBody, originalBody), isTrue);
    expect(body.string, 'unchanged text');
    expect(body.runs.single.range, [0, 'unchanged text'.length]);
    expect(body.runs.single.attributes!.messagePart, 0);
    expect(body.runs.single.attributes!.attachmentGuid, isNull);
    expect(body.runs.single.attributes!.mention, isNull);
  });

  test(
    'ObjectBox reader is query-only and returns the newest eligible row',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openbubbles-cloud-sync-canary-candidate-',
      );
      final objectBox = await openStore(directory: directory.path);
      try {
        final handles = objectBox.box<Handle>();
        final chats = objectBox.box<Chat>();
        final messages = objectBox.box<Message>();
        final handle = _handle('person@example.com');
        handles.put(handle);
        final chat = _chat();
        chat.handles.add(handle);
        chats.put(chat);
        final message = _ordinaryMessage(
          guid: 'objectbox-message',
          text: 'objectbox text',
          createdAt: _now.subtract(const Duration(minutes: 1)),
          chat: chat,
        );
        final id = messages.put(message);
        final countBefore = messages.count();

        final candidate = CloudSyncOutboundCanaryCandidateSelector(
          reader: ObjectBoxCloudSyncOutboundCanaryMessageReader(
            messages: messages,
          ),
          encoder: (_) => _opaqueCloudMessage,
          clock: () => _now,
        ).selectNewest();

        expect(candidate, isNotNull);
        expect(messages.count(), countBefore);
        expect(messages.get(id)!.guid, 'objectbox-message');
        expect(messages.get(id)!.text, 'objectbox text');
      } finally {
        objectBox.close();
        if (directory.existsSync()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );
}

final class _Reader implements CloudSyncOutboundCanaryMessageReader {
  _Reader(this.messages);

  final List<Message> messages;

  @override
  List<Message> readMessages() => List<Message>.of(messages);
}

Message _ordinaryMessage({
  String? guid = 'message-guid',
  String? text = 'ordinary text',
  DateTime? createdAt,
  bool missingDate = false,
  bool isFromMe = true,
  Chat? chat,
  bool hasAttachments = false,
  List<Attachment?> attachments = const [],
  List<AttributedBody>? attributedBody,
  Attributes? runAttributes,
  List<int>? runRange,
  String? associatedMessageGuid,
  String? associatedMessageType,
  String? threadOriginatorGuid,
  DateTime? dateScheduled,
  DateTime? dateDeleted,
  String? stagingGuid,
  String? sendingServiceId,
  int error = 0,
  String? expressiveSendStyleId,
  String? balloonBundleId,
  PayloadData? payloadData,
  bool hasApplePayloadData = false,
  List<MessageSummaryInfo> messageSummaryInfo = const [],
  Map<String, dynamic>? metadata,
  String? ckRecordId,
  bool ckSyncState = false,
  String? subject,
}) {
  final actualText = text ?? 'ordinary text';
  final body = AttributedBody(
    string: actualText,
    runs: [
      Run(
        range: runRange ?? [0, actualText.length],
        attributes: runAttributes ?? Attributes(messagePart: 0),
      ),
    ],
  );
  final message = Message(
    guid: guid,
    text: text,
    dateCreated: missingDate ? null : (createdAt ?? _now),
    isFromMe: isFromMe,
    hasAttachments: hasAttachments,
    attachments: attachments,
    attributedBody: attributedBody ?? [body],
    associatedMessageGuid: associatedMessageGuid,
    associatedMessageType: associatedMessageType,
    threadOriginatorGuid: threadOriginatorGuid,
    dateScheduled: dateScheduled,
    dateDeleted: dateDeleted,
    stagingGuid: stagingGuid,
    sendingServiceId: sendingServiceId,
    error: error,
    expressiveSendStyleId: expressiveSendStyleId,
    balloonBundleId: balloonBundleId,
    payloadData: payloadData,
    hasApplePayloadData: hasApplePayloadData,
    messageSummaryInfo: messageSummaryInfo,
    metadata: metadata,
    ckRecordId: ckRecordId,
    subject: subject,
  )..ckSyncState = ckSyncState;
  message.chat.target = chat ?? _chat();
  return message;
}

Chat _chat({
  bool isRpSms = false,
  int? style = 45,
  String participantService = 'iMessage',
  List<Handle>? participants,
}) {
  return Chat(
    guid: 'iMessage;-;person@example.com',
    chatIdentifier: 'person@example.com',
    usingHandle: 'me@example.com',
    isRpSms: isRpSms,
    style: style,
    participants:
        participants ?? [_handle('person@example.com', participantService)],
  );
}

Handle _handle(String address, [String service = 'iMessage']) => Handle(
  address: address,
  service: service,
  uniqueAddressAndService: '$address/$service',
);

final class _FakeCloudMessage implements api.CloudMessage {
  const _FakeCloudMessage();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
