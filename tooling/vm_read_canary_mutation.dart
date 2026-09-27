import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';

import 'vm_trigger_cloudkit_write.dart' as connection;

/// VM evaluate returns only a short String preview. Expand that same object,
/// without repeating the expression, and bound the diagnostic response size.
Future<String> readBoundedVmString(
  VmService service,
  String isolateId,
  Response result,
) async {
  const limit = 8192;
  if (result is! InstanceRef || result.kind != InstanceKind.kString) {
    throw StateError('mutation_observation_unavailable');
  }
  InstanceRef value = result;
  if (value.valueAsStringIsTruncated == true) {
    final id = value.id;
    if (id == null) throw StateError('mutation_observation_unavailable');
    final expanded = await service.getObject(
      isolateId,
      id,
      offset: 0,
      count: limit + 1,
    );
    if (expanded is! Instance || expanded.kind != InstanceKind.kString) {
      throw StateError('mutation_observation_unavailable');
    }
    value = expanded;
  }
  final text = value.valueAsString;
  if (text == null ||
      text.length > limit ||
      value.valueAsStringIsTruncated == true) {
    throw StateError('mutation_observation_unavailable');
  }
  return text;
}

/// Read the exact retained mutation in one read-only transaction on the running
/// Canary. No account/network calls, retries, sends, writes or source reloads.
/// Only counters and proof markers leave the device, not messages or routes.
/// Persisted readback markers are not a new independent Apple observation.
Future<void> main(List<String> args) async {
  if (args.length != 3 ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(args[1]) ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(args[2])) {
    throw ArgumentError(
      'usage: vm_read_canary_mutation.dart '
      '<ws-uri> <target-guid-hash> <recipient-sha256>',
    );
  }
  final recipient = Platform.environment['OPENBUBBLES_CANARY_RECIPIENT'] ?? '';
  if (connection.normalizedRecipientSha256(recipient) != args[2]) {
    throw StateError('mutation_recipient_mismatch');
  }
  final targetHash = jsonEncode(args[1]);
  final peer = jsonEncode(recipient);
  final target = await connection.findWriteTarget(args[0]);
  try {
    final result = await target.service.evaluate(
      target.isolateId,
      target.libraryId,
      '''
      jsonEncode(Database.store.runInTransaction(TxMode.read, () {
        final store = Database.store;
        final matches = store.box<CloudSyncLocalMutationIntentEntity>()
            .getAll().where((row) => row.targetGuidHash == $targetHash).toList();
        if (matches.length != 1) throw StateError('mutation_target_ambiguous');
        final row = matches.single;
        validateCloudSyncMutationRow(row);
        final message = store.box<Message>().get(row.localMessageId);
        final chat = message?.chat.target;
        if (message == null || message.isFromMe != true ||
            message.chat.targetId != row.localChatId ||
            chat?.guid != 'iMessage;-;' + $peer ||
            chat?.chatIdentifier != $peer) {
          throw StateError('mutation_recipient_mismatch');
        }
        final sends = store.box<CloudSyncLocalSendIntentEntity>().getAll()
            .where((entry) => entry.accountFingerprint == row.accountFingerprint &&
                entry.localMessageId == row.localMessageId &&
                entry.messageGuidHash == row.targetGuidHash).toList();
        if (sends.length != 1) throw StateError('mutation_original_ambiguous');
        final original = sends.single;
        final operations = store.box<CloudOutboxOperationEntity>().getAll();
        final updates = operations.where((entry) =>
            entry.accountFingerprint == row.accountFingerprint &&
            entry.operationId == row.admittedOperationId).toList();
        final creates = operations.where((entry) =>
            entry.accountFingerprint == row.accountFingerprint &&
            entry.operationId == original.admittedOperationId).toList();
        if (updates.length > 1 || creates.length > 1) {
          throw StateError('mutation_operation_ambiguous');
        }
        final update = updates.isEmpty ? null : updates.single;
        final summaries = message.messageSummaryInfo;
        return <String, Object?>{
          'scope': 'persisted_exact_mutation_not_fresh_remote_observation',
          'targetGuidHash': $targetHash,
          'exactRecipientMatched': true,
          'kind': row.kind,
          'state': row.state,
          'positiveIdsReceiptMarkerPresent': row.idsReceiptBindingSha256 != null,
          'reflectionMarkerPresent': row.reflectedSnapshotSha256 != null,
          'storedUnsent': summaries.length == 1 &&
              summaries.single.retractedParts.where((part) => part == 0).length == 1,
          'messagePreserved': message.dateDeleted == null,
          'originalState': original.state,
          'originalIdsConfirmed': original.idsConfirmationVersion ==
              cloudSyncIdsConfirmationVersion,
          'originalOperationCount': creates.length,
          'originalOperationState': creates.isEmpty ? null : creates.single.state,
          'originalExactReadbackMarker': original.state == 2 &&
              original.confirmedReadbackBindingSha256 != null &&
              original.confirmedReadbackBindingSha256 == original.admittedBindingSha256,
          'conditionalOperationCount': updates.length,
          'conditionalOperationState': update?.state,
          'conditionalOperationAttempts': update?.attemptCount,
          'terminalReadbackMarkerPresent': row.state == 5,
          'conditionalOperationSettled': update != null && update.state == 2 &&
              update.confirmedAtMs > 0 && update.serverRecordIdHash != null &&
              update.protectedLeaseReference == null && update.leaseIdHash == null &&
              update.leaseExpiresAtMs == 0,
        };
      }))
      '''
          .replaceAll(RegExp(r'[\r\n]'), ' '),
      disableBreakpoints: true,
    );
    final decoded = jsonDecode(
      await readBoundedVmString(target.service, target.isolateId, result),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded['targetGuidHash'] != args[1]) {
      throw StateError('mutation_observation_invalid');
    }
    final runtime = await target.service.evaluate(
      target.isolateId,
      target.targetId,
      '''jsonEncode(<String, bool>{
        'receiptReplayActive': _cloudSyncV2NativeReceiptReplayInFlight != null,
        'mutationActive': _cloudSyncV2MessageUpdateInFlight != null,
        'retryScheduled': _cloudSyncV2MessageUpdateRetryTimer?.isActive == true,
        'replayContinuationScheduled': _cloudSyncV2NativeReceiptReplayContinuationScheduled,
        'outboundActive': _cloudSyncV2OutboundInFlight != null,
        'semanticReadActive': _cloudSyncV2SemanticPullInFlight != null,
        'quiescing': _cloudSyncV2OutboundQuiescing,
        'loggingOut': loggingOut,
        'developerRuntimeAllowed': _cloudSyncV2DeveloperRuntimeAllowed,
      })'''
          .replaceAll(RegExp(r'[\r\n]'), ' '),
      disableBreakpoints: true,
    );
    decoded['runtime'] = jsonDecode(
      await readBoundedVmString(target.service, target.isolateId, runtime),
    );
    print(jsonEncode(decoded));
  } finally {
    await target.service.dispose();
  }
}
