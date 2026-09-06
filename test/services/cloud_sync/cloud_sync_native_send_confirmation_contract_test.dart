import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// These structural checks pin the cross-language handoff. Journal transaction,
// failure, duplicate and restart behavior is exercised in the companion suite.
void main() {
  final source = File(
    'lib/services/rustpush/rustpush_service.dart',
  ).readAsStringSync();

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
    final handler = source.substring(start, source.indexOf('return;',
        source.indexOf('await _confirmCloudSyncV2NativeSend', start)));
    expect(handler, contains('if (push.error == null)'));
    expect(handler, contains('await _confirmCloudSyncV2NativeSend(push.uuid)'));
    expect(handler, contains('background send failed; intent retained'));
  });

  test('durable IDS proof precedes fresh authorization and worker wakeup', () {
    final start = source.indexOf('Future<void> _confirmCloudSyncV2NativeSend');
    final handler = source.substring(
      start, source.indexOf('Future<void> _saveCloudSyncV2LocalSend', start),
    );
    expect(handler.indexOf('recordNativeSendConfirmation('),
        lessThan(handler.indexOf('await CloudSyncLocalSendAuthFence(')));
    expect(handler.indexOf('promoteIdsConfirmedDeferred('),
        lessThan(handler.indexOf('_queueCloudSyncV2LocalSends(')));
    expect(handler, contains('}.contains(error.message)) {'));
    expect(handler, contains('rethrow;'));
    // Headless receipt must be able to journal proof; only dispatch is UI-bound.
    expect(handler, isNot(contains('ls.isUiThread')));
  });
}
