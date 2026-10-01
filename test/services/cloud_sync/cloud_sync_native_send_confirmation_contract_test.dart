import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// These structural checks pin the cross-language handoff. Journal transaction,
// failure, duplicate and restart behavior is exercised in the companion suite.
void main() {
  final source = File(
    'lib/services/rustpush/rustpush_service.dart',
  ).readAsStringSync();

  test(
    'ordinary app routes validated mutations through acknowledgment transport',
    () {
      final native = File(
        'rust/src/api/api.rs',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final start = native.indexOf('pub async fn send(\n');
      expect(start, greaterThanOrEqualTo(0));
      final send = native.substring(
        start,
        native.indexOf('\n#[frb(ignore)]', start),
      );
      final validated = send.indexOf('cloud_sync_send_source(');
      final dispatch = send.indexOf('match source.as_ref()');
      expect(validated, greaterThanOrEqualTo(0));
      expect(dispatch, greaterThan(validated));
      final compact = send.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        compact,
        contains(
          'Some(CloudSyncBoundSendSource::Mutation(_)) => { '
          'state.send_mutation_requesting_acknowledgment(&mut msg).await',
        ),
      );
      expect(compact, contains('_ => state.send(&mut msg).await,'));
      expect(send, contains('cloud_sync_send_start_error('));
      expect(send, contains('confirmation.require_confirmed()'));
      expect(send, contains('cloud_sync_validate_prepared_send_source('));
    },
  );

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
    final reflected = mutation.indexOf('readReflectedForUpdate(');
    final receiptSource = mutation.indexOf('readReceiptConfirmedSource(');
    final reflect = mutation.indexOf('.reflectConfirmed(');
    expect(reflected, greaterThanOrEqualTo(0));
    expect(receiptSource, greaterThan(reflected));
    expect(reflect, greaterThan(receiptSource));
    expect(mutation, contains("'cloud_sync_local_mutation_update_not_ready'"));
    expect(mutation, contains('CloudSyncMessageUpdateExecutor('));
    expect(mutation, contains('CloudSyncWriteChatIdentitySession('));
    expect(
      mutation,
      contains('await identitySession.run<void>((_) async {});'),
    );
    expect(
      mutation.indexOf('await identitySession.run<void>((_) async {});'),
      lessThan(mutation.indexOf('await executor.admitReflectedUpdate(')),
    );
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
    final waiting = mutation.substring(
      mutation.indexOf(
        "if (error.message != 'cloud_sync_local_mutation_predecessor_not_ready')",
      ),
      mutation.indexOf('await transport.quiesceNativeOperations();'),
    );
    expect(waiting, contains('rethrow;'));
    expect(waiting, contains('stage=predecessor_wait'));
    expect(
      waiting,
      contains(
        '_scheduleCloudSyncV2MessageUpdateRetry(const Duration(seconds: 5))',
      ),
    );
    expect(waiting, isNot(contains('cloudSyncAcknowledgeNativeSendReceipt')));
    expect(waiting, isNot(contains('markExactReadbackConfirmed')));
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

  test('active archival defers only after durable mutation acceptance', () {
    final start = source.indexOf(
      'if (source?.kind == api.CloudSyncNativeSendSourceKind.mutation)',
    );
    final mutation = source.substring(
      start,
      source.indexOf('receiptSource =', start),
    );
    final journaled = mutation.indexOf('recordNativeReceiptIntentIfTracked(');
    final defer = mutation.indexOf('if (replayBinding == null &&');
    expect(journaled, greaterThanOrEqualTo(0));
    expect(defer, greaterThan(journaled));
    final handoff = mutation.substring(
      defer,
      mutation.indexOf('final cloudStore'),
    );
    expect(handoff, contains('_cloudSyncV2DeveloperRuntimeAllowed'));
    expect(handoff, contains('_cloudSyncV2AutomaticArchiveActive'));
    expect(handoff, contains('_scheduleCloudSyncV2MessageUpdateRetry('));
    expect(handoff, contains('const Duration(milliseconds: 100)'));
    expect(handoff, contains('return;'));
    expect(handoff, isNot(contains('cloudSyncAcknowledgeNativeSendReceipt')));
    expect(handoff, isNot(contains('markExactReadbackConfirmed')));
    expect(handoff, isNot(contains('sendMsg(')));
  });

  test(
    'accepted mutation recovery shares the gate and drains before handback',
    () {
      final start = source.indexOf('Future<void> processMutationReceipt()');
      expect(start, greaterThanOrEqualTo(0));
      final process = source.substring(
        start,
        source.indexOf('await _cloudSyncV2AttachmentGate.run<void>(', start),
      );
      expect(
        process,
        contains('await lifecycle.ensureRecoveredBeforeWrite();'),
      );
      expect(process, contains('await transport.quiesceNativeOperations();'));
      expect(process, contains('finally {'));
      final gateStart = source.indexOf(
        'await _cloudSyncV2AttachmentGate.run<void>(',
        start,
      );
      final gate = source.substring(
        gateStart,
        source.indexOf('return; // Never route mutation evidence', gateStart),
      );
      expect(gate, contains('waitTimeout: const Duration(seconds: 30)'));
      expect(gate, contains('if (!confirmationBindingCurrent())'));
      expect(
        gate.indexOf('await validateMutationIdentity();'),
        lessThan(gate.indexOf('await processMutationReceipt();')),
      );
      expect(gate, isNot(contains('.timeout(')));
      expect(
        gate,
        contains('on CloudKitOperationInterlockException catch (error)'),
      );
      expect(
        gate,
        contains("if (error.safeCode != 'cloudkit_interlock_busy') rethrow;"),
      );
      expect(gate, contains('stage=scheduler_wait'));
      expect(
        gate,
        contains(
          '_scheduleCloudSyncV2MessageUpdateRetry(const Duration(seconds: 5))',
        ),
      );
      expect(gate, isNot(contains('cloudSyncAcknowledgeNativeSendReceipt')));
      expect(gate, isNot(contains('sendMsg(')));
      expect(gate, contains('_cloudSyncV2MessageUpdateInFlight = null'));
    },
  );

  test('queued receipt retries retain the engine without forcing release', () {
    final start = source.indexOf(
      'void _scheduleCloudSyncV2MessageUpdateRetry(',
    );
    final timer = source.substring(
      start,
      source.indexOf(
        'Future<void> _replayCloudSyncV2NativeSendReceipts()',
        start,
      ),
    );
    expect(
      timer,
      contains(
        'await ls.retainEngineUntil(_replayCloudSyncV2NativeSendReceipts)',
      ),
    );
    expect(timer, contains('catch (error)'));
    expect(timer, contains('cloudSyncV2SafeFailureCode(error)'));
    expect(timer, isNot(contains('cloudSyncAcknowledgeNativeSendReceipt')));
    expect(timer, isNot(contains('markExactReadbackConfirmed')));
    expect(timer, isNot(contains('releaseEngine')));
    expect(timer, isNot(contains('sendMsg(')));
  });

  test(
    'replay retries only recognized lock contention, not arbitrary failures',
    () {
      final start = source.indexOf(
        'Future<void> _runCloudSyncV2NativeSendReceiptReplay()',
      );
      final replay = source.substring(
        start,
        source.indexOf('Future<void> _saveCloudSyncV2LocalSend(', start),
      );
      final failure = replay.substring(replay.lastIndexOf('} catch (error) {'));
      expect(
        failure,
        contains('error is CloudKitOperationInterlockException &&'),
      );
      expect(failure, contains("error.safeCode == 'cloudkit_interlock_busy'"));
      expect(
        failure,
        contains(
          '_scheduleCloudSyncV2MessageUpdateRetry(const Duration(seconds: 5))',
        ),
      );
      expect(
        failure,
        contains('_cloudSyncV2NativeReceiptReplayNeedsContinuation = false'),
      );
      expect(failure, isNot(contains('cloudSyncAcknowledgeNativeSendReceipt')));
      expect(failure, isNot(contains('sendMsg(')));
    },
  );

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
    final noMessage = handler.substring(
      handler.indexOf('if (message == null)'),
      handler.indexOf('message.sendingServiceId = null;'),
    );
    expect(
      noMessage,
      contains('if (push.error != null || push.nativeReceiptError != null)'),
    );
    expect(noMessage, isNot(contains('push.nativeReceipt?.sourceBinding')));
    expect(
      noMessage,
      contains('Send confirmation unresolved for an operation'),
    );
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
