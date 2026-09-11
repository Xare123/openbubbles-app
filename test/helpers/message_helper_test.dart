import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/helpers/types/helpers/message_helper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory('${Directory.current.path}/.dart_tool')
        .createTemp('retraction-preview-test-');
    Database.store = await openStore(directory: directory.path);
    Database.messages = Database.store.box<Message>();
    Database.handles = Database.store.box<Handle>();
  });
  tearDownAll(() async {
    Database.store.close();
    final root = Directory('${Directory.current.path}/.dart_tool').absolute.path;
    if (!directory.absolute.path.startsWith(
      '$root${Platform.pathSeparator}retraction-preview-test-',
    )) {
      throw StateError('unexpected synthetic test directory');
    }
    await directory.delete(recursive: true);
  });

  group('MessageHelper retracted previews', () {
    Message retracted({
      List<AttributedBody>? bodies,
      List<int> parts = const [0],
      bool hasAttachments = false,
      String? balloonBundleId,
      String? style,
    }) => Message(
      guid: 'synthetic-preview-message',
      text: 'retained original',
      subject: 'retained subject',
      attributedBody: bodies ?? [AttributedBody.raw('retained original')],
      isFromMe: false,
      hasAttachments: hasAttachments,
      balloonBundleId: balloonBundleId,
      expressiveSendStyleId: style,
      messageSummaryInfo: [
        MessageSummaryInfo(
          retractedParts: parts,
          editedContent: {},
          originalTextRange: {},
          editedParts: [],
        ),
      ],
    );

    test('hides retained text and subject without a dateEdited value', () {
      final message = retracted();
      expect(MessageHelper.getNotificationText(message), 'Unsent message');
      expect(message.text, 'retained original');
      expect(message.subject, 'retained subject');
      expect(message.attributedBody.single.string, 'retained original');
      expect(message.messageSummaryInfo.single.retractedParts, [0]);
      expect(message.dateEdited, isNull);
    });

    test('keeps a sender label without quoting an unsent body', () {
      expect(
        MessageHelper.getNotificationText(retracted(), withSender: true),
        'Someone: Unsent message',
      );
    });

    test('uses a partial label when another attributed part remains', () {
      final message = retracted(bodies: [
        AttributedBody(string: 'gonekept', runs: [
          Run(range: [0, 4], attributes: Attributes(messagePart: 0)),
          Run(range: [4, 4], attributes: Attributes(messagePart: 1)),
        ]),
      ]);
      expect(
        MessageHelper.getNotificationText(message),
        'Partially unsent message',
      );
    });

    test('all retracted multipart content has an unsent label', () {
      final message = retracted(parts: [0, 1, 0], bodies: [
        AttributedBody(string: 'gonegone', runs: [
          Run(range: [0, 4], attributes: Attributes(messagePart: 0)),
          Run(range: [4, 4], attributes: Attributes(messagePart: 1)),
        ]),
      ]);
      expect(MessageHelper.getNotificationText(message), 'Unsent message');
    });

    test('does not fetch attachments or expose a retracted app payload', () {
      final message = retracted(
        hasAttachments: true,
        balloonBundleId: 'com.example.synthetic-app',
      );
      expect(MessageHelper.getNotificationText(message), 'Unsent message');
      expect(message.attachments, isEmpty);
    });

    test('plain text fallback does not resurrect a retracted message', () {
      expect(
        MessageHelper.getNotificationText(retracted(bodies: [])),
        'Unsent message',
      );
    });

    test('retraction wins over invisible ink presentation', () {
      expect(
        MessageHelper.getNotificationText(retracted(
          style: 'com.apple.MobileSMS.expressivesend.invisibleink',
        )),
        'Unsent message',
      );
    });

    test('ordinary text and edit timestamps keep their existing preview', () {
      final message = Message(
        guid: 'synthetic-current-message',
        text: 'current text',
        isFromMe: false,
        dateEdited: DateTime.utc(2026, 9, 11),
      );
      expect(MessageHelper.getNotificationText(message), 'current text');
    });

    test('ordinary invisible ink retains its content-free preview', () {
      expect(
        MessageHelper.getNotificationText(Message(
          text: 'hidden original',
          expressiveSendStyleId:
              'com.apple.MobileSMS.expressivesend.invisibleink',
        )),
        'Message sent with Invisible Ink',
      );
    });

    test('reaction previews do not quote a retained unsent parent', () {
      final parent = retracted();
      Database.messages.put(parent);
      final reaction = Message(
        guid: 'synthetic-preview-reaction',
        isFromMe: true,
        associatedMessageGuid: parent.guid,
        associatedMessageType: 'like',
      );
      expect(
        MessageHelper.getNotificationText(reaction),
        'You liked an unsent message',
      );
      expect(Database.messages.get(parent.id!)!.text, 'retained original');
      Database.messages.remove(parent.id!);
    });

    test('a partial parent is not quoted through whole-body fallback', () {
      final parent = retracted(bodies: [
        AttributedBody(string: 'gonekept', runs: [
          Run(range: [0, 4], attributes: Attributes(messagePart: 0)),
          Run(range: [4, 4], attributes: Attributes(messagePart: 1)),
        ]),
      ]);
      Database.messages.put(parent);
      final reaction = Message(
        guid: 'synthetic-preview-partial-reaction',
        isFromMe: true,
        associatedMessageGuid: parent.guid,
        associatedMessageType: 'like',
      );
      expect(
        MessageHelper.getNotificationText(reaction),
        'You liked a partially unsent message',
      );
      Database.messages.remove(parent.id!);
    });
  });

  group('MessageHelper.getReactionFallbackText', () {
    test('uses a human-safe reaction label for missing text', () {
      expect(MessageHelper.getReactionFallbackText('Someone', null), 'Someone reacted to a message');
      expect(MessageHelper.getReactionFallbackText('Someone', '  '), 'Someone reacted to a message');
    });

    test('preserves a populated fallback reaction text', () {
      expect(MessageHelper.getReactionFallbackText('Someone', 'liked a message'), 'Someone liked a message');
    });
  });
}
