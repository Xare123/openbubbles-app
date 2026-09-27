import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';

import 'vm_trigger_cloudkit_write.dart' as connection;

/// Explicit single-target recovery using the installed app's native receipt
/// consumer. Never sends IDS, enables automatic uploads, or replays other peers.
/// Requires one already-reflected mutation and its confirmed original archive.
/// An observation timeout is NOT cancellation or permission to run again.
Future<void> main(List<String> args) async {
  if (args.length != 4 ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(args[1]) ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(args[2]) ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(args[3])) {
    throw ArgumentError(
      'usage: vm_resume_canary_mutation.dart '
      '<ws-uri> <installed-source> <target-guid-hash> <recipient-sha256>',
    );
  }
  final recipient = Platform.environment['OPENBUBBLES_CANARY_RECIPIENT'] ?? '';
  if (recipient.isEmpty ||
      connection.normalizedRecipientSha256(recipient) != args[3]) {
    throw StateError('mutation_recipient_mismatch');
  }
  final target = await connection.findWriteTarget(args[0]);
  try {
    final observer = await target.service.evaluate(
      target.isolateId,
      target.libraryId,
      '''(() {
        final observation = <List<String>>[<String>['pending', '']];
        Future<void> run() async {
          try {
            final expectedState = mutationTarget.state;
            final client = expectedState?.icloudServices?.cloudMessagesClient;
            final path = mutationTarget.statePath;
            final store = Database.store;
            bool current() => !mutationTarget.loggingOut &&
                !mutationTarget._serviceClosing &&
                !mutationTarget._cloudSyncV2OutboundQuiescing &&
                identical(mutationTarget.state, expectedState) &&
                identical(mutationTarget.state?.icloudServices?.cloudMessagesClient, client) &&
                mutationTarget.statePath == path &&
                identical(Database.store, store) && !store.isClosed();
            void ready() {
              if (!current() || client == null || path.isEmpty ||
                  mutationTarget._cloudSyncV2BuildIdentifier() != ${jsonEncode(args[1])} ||
                  !mutationTarget.cloudSyncV2ManualOutboundAvailable ||
                  mutationTarget._cloudSyncV2LocalSendRuntime != null ||
                  mutationTarget._cloudSyncV2NativeReceiptReplayInFlight != null ||
                  mutationTarget._cloudSyncV2MessageUpdateInFlight != null ||
                  mutationTarget._cloudSyncV2MessageUpdateRetryTimer?.isActive == true ||
                  mutationTarget._cloudSyncV2SemanticPullInFlight != null ||
                  ss.settings.cloudSyncingEnabled.value ||
                  mutationTarget.isSyncing.value != null) {
                throw StateError('cloud_sync_exact_mutation_not_idle');
              }
            }
            ready();
            final metadata = await FrbCloudSyncNativeAuthBinding().capture(
              cloudMessagesClient: client!, privateStorageDirectory: path,
            );
            ready();
            final auth = CloudSyncNativeAuthSnapshot.fromNative(
              nativeSessionId: metadata.nativeSessionId,
              accountFingerprint: metadata.accountFingerprint,
              protectedStoreIdentity: metadata.protectedStoreIdentity,
              cloudMessagesClient: client,
            );
            final rows = store.box<CloudSyncLocalMutationIntentEntity>().getAll()
                .where((row) => row.targetGuidHash == ${jsonEncode(args[2])} &&
                    row.accountFingerprint == auth.accountFingerprint).toList();
            if (rows.length != 1) throw StateError('cloud_sync_exact_mutation_ambiguous');
            final row = rows.single;
            final source = validateCloudSyncMutationRow(row);
            final message = store.box<Message>().get(row.localMessageId);
            final chat = message?.chat.target;
            if (row.state != 3 || row.admittedOperationId != null ||
                row.idsReceiptBindingSha256 == null || row.reflectedSnapshotSha256 == null ||
                message == null || message.isFromMe != true ||
                message.chat.targetId != row.localChatId ||
                chat?.guid != 'iMessage;-;' + ${jsonEncode(recipient)} ||
                chat?.chatIdentifier != ${jsonEncode(recipient)}) {
              throw StateError('cloud_sync_exact_mutation_changed');
            }
            final original = store.box<CloudSyncLocalSendIntentEntity>().getAll()
                .where((entry) => entry.accountFingerprint == auth.accountFingerprint &&
                    entry.localMessageId == row.localMessageId &&
                    entry.messageGuidHash == row.targetGuidHash).toList();
            if (original.length != 1 || original.single.state != 2 ||
                original.single.confirmedReadbackBindingSha256 == null ||
                original.single.confirmedReadbackBindingSha256 != original.single.admittedBindingSha256) {
              throw StateError('cloud_sync_exact_mutation_original_not_confirmed');
            }
            final receipts = <api.CloudSyncNativeSendReceipt>[];
            String? cursor;
            var drained = false;
            for (var pageIndex = 0; pageIndex < 64; pageIndex++) {
              ready();
              final page = await api.cloudSyncReplayNativeSendReceipts(
                storageDirectory: path,
                expectedAccountFingerprint: auth.accountFingerprint,
                expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
                afterReceiptId: cursor,
              );
              receipts.addAll(page.receipts.where((receipt) =>
                  receipt.guidHash == row.mutationGuidHash &&
                  receipt.sourceBinding?.kind == api.CloudSyncNativeSendSourceKind.mutation &&
                  receipt.sourceBinding?.sourceSha256 == source.sourceSha256));
              final next = page.nextCursor;
              if (next == null) { drained = true; break; }
              if (next == cursor) throw StateError('cloud_sync_exact_mutation_cursor_stalled');
              cursor = next;
            }
            if (!drained || receipts.length != 1) {
              throw StateError('cloud_sync_exact_mutation_receipt_unavailable');
            }
            ready();
            final replayBinding = CloudSyncNativeReceiptReplayBinding(
              expectedAuth: auth, expectedState: expectedState!, expectedStore: store,
              expectedClient: client, expectedStoragePath: path,
              readState: () => mutationTarget.state,
              readStore: () => Database.store,
              readClient: () => mutationTarget.state?.icloudServices?.cloudMessagesClient,
              readStoragePath: () => mutationTarget.statePath,
              runtimeCurrent: current,
            );
            await mutationTarget._confirmCloudSyncV2NativeSend('',
              nativeReceipt: receipts.single, replayBinding: replayBinding,
            );
            observation[0] = <String>['completed', ''];
          } catch (error) {
            final code = error is StateError ? error.message.toString() : '';
            observation[0] = <String>['failed',
              RegExp(r'^cloud_sync_[a-z0-9_]+\$').hasMatch(code)
                  ? code : 'cloud_sync_exact_mutation_failed'];
          }
        }
        Future<void>(run);
        return observation;
      })()'''
          .replaceAll(RegExp(r'[\r\n]'), ' '),
      scope: {'mutationTarget': target.targetId},
      disableBreakpoints: true,
    );
    if (observer is! InstanceRef || observer.id == null) {
      throw StateError('mutation_observer_unavailable_outcome_unknown');
    }
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(minutes: 3)) {
      final box = await target.service.getObject(
        target.isolateId,
        observer.id!,
      );
      if (box is! Instance || box.elements?.length != 1) {
        throw StateError('mutation_observer_unavailable_outcome_unknown');
      }
      final item = box.elements!.single;
      if (item is! InstanceRef || item.id == null) {
        throw StateError('mutation_observer_unavailable_outcome_unknown');
      }
      final result = await target.service.getObject(target.isolateId, item.id!);
      if (result is! Instance || result.elements?.length != 2) {
        throw StateError('mutation_observer_unavailable_outcome_unknown');
      }
      final status = result.elements![0] as InstanceRef;
      final code = result.elements![1] as InstanceRef;
      if (status.valueAsString == 'completed' && code.valueAsString == '') {
        print(
          jsonEncode({
            'scope': 'exact_installed_mutation_consumer_returned',
            'targetGuidHash': args[2],
            'recipientSha256': args[3],
            'verifySavedReadbackSeparately': true,
          }),
        );
        return;
      }
      if (status.valueAsString == 'failed') {
        throw StateError(code.valueAsString!);
      }
      if (status.valueAsString != 'pending' || code.valueAsString != '') {
        throw StateError('mutation_observer_unavailable_outcome_unknown');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('mutation_still_running_do_not_retry');
  } finally {
    await target.service.dispose();
  }
}
