import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RustPush confirmation failures are not treated as successful sends',
      () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();

    expect(source, contains('shouldMarkSendConfirmationFailed('));
    expect(
      source,
      contains('await markFailed(message, "Send confirmation failed:'),
    );
    final handlerStart =
        source.indexOf('if (push is api.PushMessage_SendConfirm)');
    final confirmationHandler = source.substring(
      handlerStart,
      source.indexOf('var myMsg =', handlerStart),
    );
    expect(
      confirmationHandler
          .indexOf('message.save(updateSendingServiceId: true);'),
      lessThan(confirmationHandler
          .indexOf('await markFailed(message, "Send confirmation failed:')),
    );
    expect(source, contains('isDelivered: message.isDelivered'));
    expect(
      source,
      contains('Late send confirmation error ignored after delivery'),
    );
    expect(source, contains('shouldFailInterruptedSend('));
    expect(source, contains('shouldClearCompletedSendOwner('));
    expect(
      source,
      contains(
        'updateSendingServiceId: myMsg.message is api.Message_Delivered',
      ),
    );
  });

  test('overdue retries require a duplicate-send warning', () {
    final source = File(
      'lib/app/layouts/conversation_view/widgets/message/timestamp/timestamp_separator.dart',
    ).readAsStringSync();

    expect(source, contains('Delivery not confirmed'));
    expect(source, contains('may have sent without a confirmation'));
    expect(source, contains('message.stagingGuid ??= message.guid'));
    expect(source, contains('return hasPendingSchedule(message) ?'));
  });

  test('notification replies are not copied into plaintext logs', () {
    final source = File(
      'lib/services/backend/java_dart_interop/method_channel_service.dart',
    ).readAsStringSync();

    expect(source, contains('Logger.info("Updated recent reply cache")'));
    expect(source, isNot(contains('Updated recent reply cache to')));
  });
}
