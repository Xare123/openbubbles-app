import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// These structural checks pin the cross-language handoff. Journal transaction,
// failure, duplicate and restart behavior is exercised in the companion suite.
void main() {
  final source = File(
    'lib/services/rustpush/rustpush_service.dart',
  ).readAsStringSync();

  test('live and replayed mutations use their own journal without create acknowledgement', () {
    final start = source.indexOf('if (source?.kind == api.CloudSyncNativeSendSourceKind.mutation)');
    expect(start, greaterThan(0));
    final mutation = source.substring(start, source.indexOf('receiptSource =', start));
    expect(mutation, contains('CloudSyncLocalMutationJournal('));
    expect(mutation, contains('recordNativeReceiptIfTracked('));
    expect(mutation, contains('stillCurrent: confirmationBindingCurrent'));
    expect(mutation, contains('replayBinding: replayBinding'));
    expect(mutation, contains('return;'));
    expect(mutation, isNot(contains('cloudSyncAcknowledgeNativeSendReceipt')));
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
    final handler = source.substring(start, source.indexOf('return;',
        source.indexOf('await _confirmCloudSyncV2NativeSend', start)));
    final compact = handler.replaceAll(RegExp(r'\s+'), ' ');
    expect(handler, contains('if (push.error == null)'));
    expect(compact, contains('await _confirmCloudSyncV2NativeSend( push.uuid,'));
    expect(compact, contains('nativeReceipt: push.nativeReceipt,'));
    expect(handler, contains('background send failed; intent retained'));
  });

  test('durable IDS proof precedes fresh authorization and worker wakeup', () {
    final start = source.indexOf('Future<void> _confirmCloudSyncV2NativeSend');
    final handler = source.substring(
      start,
      source.indexOf('Future<void> _replayCloudSyncV2NativeSendReceipts', start),
    );
    expect(handler.indexOf('recordNativeSendConfirmation('),
        lessThan(handler.indexOf('await CloudSyncLocalSendAuthFence(')));
    final promotion = handler.indexOf('promoteIdsConfirmedDeferred(');
    expect(promotion, greaterThanOrEqualTo(0));
    expect(promotion,
        lessThan(handler.indexOf('_queueCloudSyncV2LocalSends(', promotion)));
    expect(handler, contains('}.contains(error.message)) {'));
    expect(handler, contains('rethrow;'));
    // Headless receipt must be able to journal proof; only dispatch is UI-bound.
    expect(handler, isNot(contains('ls.isUiThread')));
  });
}
