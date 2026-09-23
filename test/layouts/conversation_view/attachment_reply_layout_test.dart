import 'dart:convert';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/attachment_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_bubble.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

class _FixedAttachmentsService extends AttachmentsService {
  _FixedAttachmentsService(this.content);

  final dynamic content;

  @override
  dynamic getContent(
    Attachment attachment, {
    String? path,
    bool? autoDownload,
    Function(PlatformFile)? onComplete,
    bool forExtension = false,
  }) => content;

  @override
  Future<bool> canAutoDownload() async => false;
}

void main() {
  late AttachmentsService previousAttachments;

  setUp(() {
    Get.testMode = true;
    ss.settings = Settings();
    ss.settings.skin.value = Skins.iOS;
    previousAttachments = as;
  });

  tearDown(() {
    as = previousAttachments;
    Get.reset();
  });

  for (final scale in [1.0, 2.0]) {
    for (final reply in [false, true]) {
      testWidgets(
        'failed photo fits ${reply ? 'reply' : 'message'} at scale $scale',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(360, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final attachment = Attachment(
            id: 1,
            guid: 'layout-photo',
            mimeType: 'image/jpeg',
            transferName: 'photo.jpg',
            totalBytes: 1024,
          );
          // Do not register the controller: this is a deterministic failure
          // state, with no live queue, network or account access.
          final download = AttachmentDownloadController(attachment: attachment)
            ..progress.value = 0.25
            ..error.value = true;
          as = _FixedAttachmentsService(download);
          final chat = Chat(guid: 'layout-chat');
          final conversation = ConversationViewController(chat);
          final part = MessagePart(part: 0, attachments: [attachment]);
          final message = Message(
            guid: 'layout-message',
            isFromMe: false,
            hasAttachments: true,
            attachments: [attachment],
            dateCreated: DateTime.utc(2026, 9, 15),
          );
          final controller = MessageWidgetController(message)
            ..cvController = conversation
            ..parts = [part];
          await tester.pumpWidget(
            GetMaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(360, 800),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: reply
                        ? ReplyBubble(
                            parentController: controller,
                            part: 0,
                            showAvatar: false,
                            cvController: conversation,
                          )
                        : AttachmentHolder(
                            parentController: controller,
                            message: part,
                          ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Failed to download!'), findsOneWidget);
          expect(tester.takeException(), isNull);
          final holder = tester.getRect(find.byType(AttachmentHolder));
          final label = tester.getRect(find.text('Failed to download!'));
          expect(label.bottom, lessThanOrEqualTo(holder.bottom));
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('downloaded reply photo keeps its compact height', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP4z8DwHwAFAAH/VscvDQAAAABJRU5ErkJggg==',
    );
    final attachment = Attachment(
      id: 2,
      guid: 'downloaded-photo',
      mimeType: 'image/png',
      transferName: 'photo.png',
      totalBytes: bytes.length,
      width: 200,
      height: 400,
    );
    as = _FixedAttachmentsService(
      PlatformFile(name: 'photo.png', size: bytes.length, bytes: bytes),
    );
    final conversation = ConversationViewController(Chat(guid: 'photo-chat'))
      ..imageData[attachment.guid!] = bytes;
    final part = MessagePart(part: 0, attachments: [attachment]);
    final controller =
        MessageWidgetController(
            Message(
              guid: 'photo-message',
              isFromMe: false,
              hasAttachments: true,
              attachments: [attachment],
              dateCreated: DateTime.utc(2026, 9, 15),
            ),
          )
          ..cvController = conversation
          ..parts = [part];
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: ReplyScope(
            child: Align(
              alignment: Alignment.topLeft,
              child: AttachmentHolder(
                parentController: controller,
                message: part,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsOneWidget);
    expect(
      tester.getSize(find.byType(AttachmentHolder)).height,
      lessThanOrEqualTo(100),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
}
