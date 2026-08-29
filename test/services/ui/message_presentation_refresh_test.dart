import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  tearDown(() {
    Get.reset();
  });

  Message message({
    String? text = 'before',
    String? subject,
    List<AttributedBody>? attributedBody,
    List<MessageSummaryInfo>? messageSummaryInfo,
    bool hasAttachments = false,
    List<Attachment?> attachments = const [],
    DateTime? dateEdited,
    DateTime? dateDelivered,
  }) {
    return Message(
      guid: 'presentation-refresh-message',
      text: text,
      subject: subject,
      attributedBody: attributedBody ?? const [],
      messageSummaryInfo: messageSummaryInfo ?? const [],
      hasAttachments: hasAttachments,
      attachments: attachments,
      isFromMe: true,
      dateCreated: DateTime.utc(2026, 8, 29),
      dateEdited: dateEdited,
      dateDelivered: dateDelivered,
    );
  }

  test('presentation signature changes for every rendered-content input', () {
    final initial = message();
    final signatures = <String>{messagePresentationSignature(initial)};

    final textChanged = message(text: 'after');
    final subjectChanged = message(subject: 'subject');
    final attributedBodyChanged = message(
      attributedBody: [AttributedBody.raw('attributed')],
    );
    final summaryChanged = message(
      messageSummaryInfo: [
        MessageSummaryInfo(
          retractedParts: const [],
          editedContent: const {},
          originalTextRange: const {},
          editedParts: const [0],
        ),
      ],
    );
    final attachmentFlagChanged = message(hasAttachments: true);
    final backlinkChanged = message(
      attachments: [Attachment(guid: 'attachment-1')],
    );
    final attachmentMetadataChanged = message(
      attachments: [
        Attachment(
          guid: 'attachment-1',
          mimeType: 'application/pdf',
          transferName: 'document.pdf',
          totalBytes: 42,
        ),
      ],
    );

    for (final changed in [
      textChanged,
      subjectChanged,
      attributedBodyChanged,
      summaryChanged,
      attachmentFlagChanged,
      backlinkChanged,
      attachmentMetadataChanged,
    ]) {
      expect(signatures.add(messagePresentationSignature(changed)), isTrue);
    }
  });

  test('presentation signature ignores lifecycle-only changes', () {
    final initial = message();
    final lifecycleOnly = message(
      dateEdited: DateTime.utc(2026, 8, 29, 0, 1),
      dateDelivered: DateTime.utc(2026, 8, 29, 0, 2),
    );

    expect(
      messagePresentationSignature(lifecycleOnly),
      messagePresentationSignature(initial),
    );
  });

  test('fresh attachment metadata is not masked by a stale backlink', () {
    final stale = message(
      hasAttachments: true,
      attachments: [Attachment(guid: 'attachment-1')],
    );
    stale.dbAttachments.add(Attachment(guid: 'attachment-1'));

    final hydrated = message(
      hasAttachments: true,
      attachments: [
        Attachment(
          guid: 'attachment-1',
          mimeType: 'application/pdf',
          transferName: 'document.pdf',
          totalBytes: 42,
        ),
      ],
    );
    hydrated.dbAttachments.add(Attachment(guid: 'attachment-1'));

    expect(
      messagePresentationSignature(hydrated),
      isNot(messagePresentationSignature(stale)),
    );
  });

  test(
    'mounted message parts refresh when content changes without dateEdited',
    () {
      const chatGuid = 'presentation-refresh-chat';
      final original = message();
      original.chat.target = Chat(guid: chatGuid);
      final service = MessagesService(chatGuid);
      service.struct.addMessages([original]);
      service.updateFunc = (_, {oldGuid}) {};
      Get.put<MessagesService>(service, tag: chatGuid);

      final controller = MessageWidgetController(original);
      controller.buildMessageParts();
      final originalParts = controller.parts;

      controller.updateMessage(message(text: 'after'));

      expect(controller.message.text, 'after');
      expect(identical(controller.parts, originalParts), isFalse);
      expect(controller.parts.single.text, 'after');
    },
  );

  test(
    'mounted attachment parts refresh when metadata arrives for the same guid',
    () {
      const chatGuid = 'presentation-refresh-attachment-chat';
      final original = message(
        text: null,
        hasAttachments: true,
        attachments: [Attachment(guid: 'attachment-1')],
      );
      original.chat.target = Chat(guid: chatGuid);
      final service = MessagesService(chatGuid);
      service.struct.addMessages([original]);
      service.updateFunc = (_, {oldGuid}) {};
      Get.put<MessagesService>(service, tag: chatGuid);

      final controller = MessageWidgetController(original);
      controller.buildMessageParts();
      final originalParts = controller.parts;

      controller.updateMessage(
        message(
          text: null,
          hasAttachments: true,
          attachments: [
            Attachment(
              guid: 'attachment-1',
              mimeType: 'application/pdf',
              transferName: 'document.pdf',
              totalBytes: 42,
            ),
          ],
        ),
      );

      expect(identical(controller.parts, originalParts), isFalse);
      expect(
        controller.message.attachments.single!.mimeType,
        'application/pdf',
      );
    },
  );

  test(
    'dateEdited-only updates preserve mounted parts and lifecycle refresh',
    () {
      const chatGuid = 'presentation-refresh-date-chat';
      final original = message();
      original.chat.target = Chat(guid: chatGuid);
      final service = MessagesService(chatGuid);
      service.struct.addMessages([original]);
      service.updateFunc = (_, {oldGuid}) {};
      Get.put<MessagesService>(service, tag: chatGuid);

      final controller = MessageWidgetController(original);
      controller.buildMessageParts();
      final originalParts = controller.parts;
      var holderUpdates = 0;
      controller.updateWidgetFunctions[MessageHolder] = [
        (_) => holderUpdates++,
      ];

      controller.updateMessage(
        message(dateEdited: DateTime.utc(2026, 8, 29, 0, 1)),
      );

      expect(identical(controller.parts, originalParts), isTrue);
      expect(holderUpdates, 1);
    },
  );
}
