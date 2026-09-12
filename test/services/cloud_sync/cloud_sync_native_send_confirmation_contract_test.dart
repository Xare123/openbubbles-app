import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// These structural checks pin the cross-language handoff. Journal transaction,
// failure, duplicate and restart behavior is exercised in the companion suite.
void main() {
  final source = File(
    'lib/services/rustpush/rustpush_service.dart',
  ).readAsStringSync();

  test('mutations release native receipt only after exact update readback', () {
    final start = source.indexOf(
      'if (source?.kind == api.CloudSyncNativeSendSourceKind.mutation)',
    );
    expect(start, greaterThan(0));
    final mutation = source.substring(
      start,
      source.indexOf('receiptSource =', start),
    );
    expect(mutation, contains('CloudSyncLocalMutationJournal('));
    expect(mutation, contains('recordNativeReceiptIntentIfTracked('));
    expect(mutation, contains('readReceiptConfirmedSource('));
    expect(mutation, contains('.reflectConfirmed('));
    expect(mutation, contains('readReflectedForUpdate('));
    expect(mutation, contains('CloudSyncMessageUpdateExecutor('));
    expect(mutation, contains('await executor.admitReflectedUpdate('));
    expect(mutation, contains('return executor.runOnce('));
    expect(mutation, contains('stillCurrent: confirmationBindingCurrent'));
    expect(mutation, contains('replayBinding: replayBinding'));
    expect(mutation, contains('return;'));
    final run = mutation.indexOf('return executor.runOnce(');
    final exact = mutation.indexOf(
      'final exactOperation = exactOperations.single;',
    );
    final confirmed = mutation.indexOf(
      'if (exactOperation.status == CloudOutboxStatus.confirmed)',
    );
    final acknowledge = mutation.indexOf(
      'cloudSyncAcknowledgeNativeSendReceipt(',
      confirmed,
    );
    expect(run, greaterThanOrEqualTo(0));
    expect(exact, greaterThan(run));
    expect(confirmed, greaterThan(exact));
    expect(acknowledge, greaterThan(confirmed));
    expect(mutation, contains('_scheduleCloudSyncV2MessageUpdateRetry(delay)'));
    expect(mutation, isNot(contains('_queueCloudSyncV2LocalSends')));
    expect(mutation, isNot(contains('resolveNativeSendReceipt')));
  });

  test('early background return cannot advance ordinary send intent', () {
    final send = source.substring(
      source.indexOf('var backgroundSendPending = false;'),
      source.indexOf('bool supportsFocusStates()'),
    );
    expect(send, contains('backgroundSendPending = await sendMsg('));
    expect(
      send,
      contains('if (localCloudIntent != null && !backgroundSendPending)'),
    );
    expect(source, contains('Future<bool> sendMsg('));
    expect(source, contains('return stillRunning;'));
  });

  test('native completion is awaited and only successful events authorize', () {
    final start = source.indexOf('if (push is api.PushMessage_SendConfirm)');
    final handler = source.substring(
      start,
      source.indexOf('var myMsg = (push as api.PushMessage_IMessage)', start),
    );
    final compact = handler.replaceAll(RegExp(r'\s+'), ' ');
    expect(handler, contains('if (push.error == null &&'));
    expect(handler, contains('push.nativeReceiptError == null &&'));
    expect(handler, contains('push.nativeReceipt != null)'));
    expect(
      compact,
      contains('await _confirmCloudSyncV2NativeSend( push.uuid,'),
    );
    expect(compact, contains('nativeReceipt: push.nativeReceipt,'));
    expect(
      handler.indexOf('await _confirmCloudSyncV2NativeSend('),
      lessThan(handler.indexOf('Message.findOne(guid: push.uuid)')),
    );
    expect(handler, contains('background send failed; intent retained'));
  });

  test('durable IDS proof precedes fresh authorization and worker wakeup', () {
    final start = source.indexOf('Future<void> _confirmCloudSyncV2NativeSend');
    final handler = source.substring(
      start,
      source.indexOf(
        'Future<void> _replayCloudSyncV2NativeSendReceipts',
        start,
      ),
    );
    expect(
      handler.indexOf('recordNativeSendConfirmation('),
      lessThan(handler.indexOf('await CloudSyncLocalSendAuthFence(')),
    );
    final promotion = handler.indexOf('promoteIdsConfirmedDeferred(');
    expect(promotion, greaterThanOrEqualTo(0));
    expect(
      promotion,
      lessThan(handler.indexOf('_queueCloudSyncV2LocalSends(', promotion)),
    );
    expect(handler, contains('}.contains(error.message)) {'));
    expect(handler, contains('rethrow;'));
    // Headless receipt must journal proof before any optional UI refresh.
    expect(
      handler.indexOf('recordNativeReceiptIntentIfTracked('),
      lessThan(handler.indexOf('ls.isUiThread')),
    );
    expect(
      handler,
      contains(
        'if (reflected != null && reflectedChat != null && ls.isUiThread)',
      ),
    );
  });
}
