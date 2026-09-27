import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/delivered_indicator.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

Future<void> showIndicator(
  WidgetTester tester, {
  bool forceShow = true,
  bool unsent = false,
  bool delivered = false,
  bool keptAudio = false,
  int error = 0,
  String guid = 'test-delivery-message',
}) async {
  final time = DateTime.utc(2026, 9, 27, 16, 36);
  final message = Message(
    guid: guid,
    text: 'Synthetic delivery fixture',
    isFromMe: true,
    dateCreated: time,
    dateDelivered: delivered ? time : null,
    error: error,
  );
  final controller = MessageWidgetController(message)
    ..cvController = ConversationViewController(Chat(guid: 'test-direct-chat'))
    ..parts = [MessagePart(part: 0, isUnsent: unsent)];
  if (keptAudio) controller.audioWasKept.value = time;
  await tester.pumpWidget(GetMaterialApp(
    home: Scaffold(
      body: DeliveredIndicator(
        parentController: controller,
        forceShow: forceShow,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() {
    Get.testMode = true;
    ss.settings = Settings();
    ss.settings.skin.value = Skins.iOS;
  });
  tearDown(Get.reset);

  for (final expanded in [false, true]) {
    testWidgets('unsent message hides old delivery label, expanded=$expanded',
        (tester) async {
      await showIndicator(tester,
          forceShow: expanded, unsent: true, delivered: true);
      expect(find.textContaining('Delivered', findRichText: true), findsNothing);
      expect(find.textContaining('Sent', findRichText: true), findsNothing);
    });
  }

  testWidgets('unsent audio does not revive a kept status', (tester) async {
    await showIndicator(tester, unsent: true, keptAudio: true);
    expect(find.textContaining('Kept', findRichText: true), findsNothing);
  });

  for (final failure in [
    (error: 22, guid: 'test-delivery-message'),
    (error: 0, guid: 'error-test-delivery-message'),
  ]) {
    testWidgets('expanded failed send does not claim Sent: ${failure.error}',
        (tester) async {
      await showIndicator(tester, error: failure.error, guid: failure.guid);
      expect(find.textContaining('Send not confirmed', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('Sent ', findRichText: true), findsNothing);
    });
  }

  testWidgets('positive delivery evidence keeps its normal label', (tester) async {
    await showIndicator(tester, delivered: true, error: 22);
    expect(find.textContaining('Delivered', findRichText: true), findsOneWidget);
    expect(find.textContaining('Send not confirmed', findRichText: true),
        findsNothing);
  });

  testWidgets('ordinary expanded send keeps its normal label', (tester) async {
    await showIndicator(tester);
    expect(find.textContaining('Sent ', findRichText: true), findsOneWidget);
  });
}
