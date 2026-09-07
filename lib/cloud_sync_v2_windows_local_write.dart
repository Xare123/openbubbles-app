import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

import 'services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:uuid/uuid.dart';
import 'services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'services/rustpush/cloud_sync/legacy_cloudkit_deletion_intents.dart';
import 'services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';

String cloudSyncWindowsWriteFailureCode(Object error) {
  if (error is AnyhowException) {
    final fixed = cloudSyncV2SafeFailureCodeForCandidate(error.message);
    if (fixed != 'cloud_sync_unknown_failure') return fixed;
    if (error.message.contains('Registration Error') && error.message.contains('(5052)')) {
      return 'cloud_sync_windows_sender_alias_changed';
    }
    if (error.message.contains('Registration Error') && error.message.contains('(6005)')) {
      return 'cloud_sync_windows_sender_bad_authentication';
    }
  }
  return cloudSyncV2SafeFailureCode(error);
}

/// Explicit qualification input, never read by ordinary app startup. Request
/// content stays in the private profile, not process arguments or reports.
final class CloudSyncWindowsWriteRequest {
  CloudSyncWindowsWriteRequest.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String,
        recipient = json['recipient'] as String,
        sender = json['sender'] as String,
        text = json['text'] as String {
    if (json['version'] != 1 || json['allowSend'] != true ||
        !RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(id) ||
        !RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(recipient) ||
        !RegExp(r'^[^\s:@]+@[^\s:@]+\.[^\s:@]+$').hasMatch(sender) ||
        text.trim().isEmpty || text.length > 512) {
      throw StateError('cloud_sync_windows_write_request_invalid');
    }
  }

  final String id;
  final String recipient;
  final String sender;
  final String text;
  String get binding => sha256.convert(utf8.encode(jsonEncode(
    ['windows-local-write-v1', id, recipient, sender, text],
  ))).toString();
}

/// Small Windows composition of the ordinary journal and writer, not another
/// uploader. One immutable request can send at most once. A crash before native
/// completion leaves the journal pending and requires explicit reconciliation.
final class CloudSyncWindowsLocalWrite {
  CloudSyncWindowsLocalWrite({
    required this.readClient,
    required this.prepareSender,
    required this.sendConfirmed,
    required this.reportStage,
  });

  final Object? Function() readClient;
  final Future<void> Function(String sender, String recipient) prepareSender;
  final Future<void> Function(api.MessageInst message) sendConfirmed;
  final Future<void> Function(String stage) reportStage;

  Future<Map<String, Object?>> run() async {
    if (!Platform.isWindows || !fs.cloudSyncV2WindowsDevProfileActive ||
        !CloudSyncDevGate.manualOutboundCanaryEnabled ||
        !CloudKitWriterOwnership.v2MutationsEnabled) {
      throw StateError('cloud_sync_windows_write_disabled');
    }
    final directory = Directory(path.join(fs.appDocDir.path, 'cloud-sync-v2'));
    final request = CloudSyncWindowsWriteRequest.fromJson(jsonDecode(await File(
      path.join(directory.path, 'windows-local-write-request.json'),
    ).readAsString()) as Map<String, dynamic>);
    final claim = File(path.join(directory.path, 'windows-write-${request.id}.json'));
    final client = readClient();
    if (client == null) throw StateError('cloud_sync_windows_write_client_missing');
    final objectBox = Database.store;
    bool current() => identical(client, readClient()) &&
        identical(objectBox, Database.store) && !objectBox.isClosed();
    final binding = FrbCloudSyncNativeAuthBinding();
    await binding.ensureReadAuthentication(cloudMessagesClient: client,
      privateStorageDirectory: fs.appDocDir.path);
    final authProvider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: readClient, nativeAuthBinding: binding,
      privateStorageDirectory: fs.appDocDir.path,
    );
    // Prepare IDS before capturing the stable CloudKit identity. No login reset.
    if (!claim.existsSync()) {
      await reportStage('windows-write-registering-sender');
      await prepareSender('mailto:${request.sender}', 'tel:${request.recipient}');
    }
    final auth = await authProvider.capture();
    if (auth == null || !current()) {
      throw StateError('cloud_sync_windows_write_identity_changed');
    }
    final authority = ObjectBoxCloudKitWriterAuthority(store: objectBox);
    final durable = ObjectBoxCloudSyncStore.fromDatabase(
      protector: RustCloudSyncProtector(storageDirectory: fs.appDocDir.path),
    );
    final interlock = CloudKitOperationInterlock(
      privateStorageDirectory: fs.appDocDir.path, fenceStore: durable,
    );
    final provisioner = CloudKitV2WriterProvisioner(
      authority: authority, interlock: interlock,
      readAuthSnapshot: authProvider.capture,
      quarantineLegacyDeletionQueues: () async {
        throw StateError('cloud_sync_windows_write_legacy_migration_forbidden');
      },
      readMeasurements: (scope) async {
        // This dedicated composition never initializes SettingsService, legacy
        // sync, its queues, or background sync. Reject copied preferences rather
        // than silently treating a legacy installation as a fresh writer.
        if (File(path.join(fs.appDocDir.path, 'shared_preferences.json')).existsSync()) {
          throw StateError('cloud_sync_windows_write_legacy_preferences_present');
        }
        return objectBox.runInTransaction(TxMode.read, () {
          final local = ObjectBoxCloudSyncPreflightReader.fromDatabase().read();
          final messages = objectBox.box<Message>().query(Message_.ckSyncState
              .equals(false).or(Message_.ckSyncState.isNull())).build();
          final chats = objectBox.box<Chat>().query(Chat_.ckSyncState.equals(false)).build();
          try {
            return CloudKitWriterProvisioningMeasurements(
              objectBoxReady: !objectBox.isClosed(), legacySyncEnabled: false,
              legacySyncActive: false, backgroundSyncActive: false,
              coordinatorLeaseActive: local.coordinatorLeaseActive,
              pendingLegacyDeletionIntents: LegacyCloudKitDeletionIntentStore(
                store: objectBox).pendingCountForScope(scope),
              legacyPreferenceQueueEntries: 0,
              unsyncedLegacyMessages: messages.count(), unsyncedLegacyChats: chats.count(),
              existingV2OutboxOperations: local.outboxCount,
            );
          } finally { messages.close(); chats.close(); }
        });
      },
    );
    final owner = await provisioner.ensureV2Owned(expectedAuth: auth, initialOwnerOnly: true);
    final journal = CloudSyncLocalSendJournal(store: objectBox,
      authority: authority, authoritySnapshot: owner.snapshot);
    final fence = CloudSyncLocalSendAuthFence(expected: auth,
      capture: authProvider.capture, stillCurrent: current);
    late Map<String, dynamic> savedClaim;
    if (claim.existsSync()) {
      savedClaim = jsonDecode(await claim.readAsString()) as Map<String, dynamic>;
      if (savedClaim['binding'] != request.binding || savedClaim['version'] != 1 ||
          savedClaim['account'] != auth.accountFingerprint) {
        throw StateError('cloud_sync_windows_write_request_changed');
      }
    } else {
      final wire = await api.newMsg(
        conversation: api.ConversationData(participants: [
          'tel:${request.recipient}', 'mailto:${request.sender}',
        ]),
        sender: 'mailto:${request.sender}',
        message: api.Message.message(api.NormalMessage(
          service: const api.MessageType.iMessage(), voice: false,
          parts: api.MessageParts(field0: [api.IndexedMessagePart(
            part_: api.MessagePart.text(request.text, const api.TextFormat.flags(
              api.TextFlags(bold: false, italic: false, underline: false, strikethrough: false),
            )),
          )]),
        )),
      );
      savedClaim = {'version': 1, 'binding': request.binding,
        'account': auth.accountFingerprint, 'guid': wire.id};
      // Exclusive, flushed claim precedes every canonical/journal mutation and
      // every network send. A torn claim fails closed on the next launch.
      await claim.create(exclusive: true);
      await claim.writeAsString(jsonEncode(savedClaim), flush: true);
      late CloudSyncLocalSendIdentity source;
      late Message message;
      await fence.run(() => objectBox.runInTransaction(TxMode.write, () {
        final handleQuery = objectBox.box<Handle>().query(Handle_.uniqueAddressAndService
            .equals('${request.recipient}/iMessage')).build();
        late Handle handle;
        try { handle = handleQuery.findUnique() ?? Handle(address: request.recipient,
          service: 'iMessage', uniqueAddressAndService: '${request.recipient}/iMessage');
        } finally { handleQuery.close(); }
        objectBox.box<Handle>().put(handle);
        // Admission must adopt this exact new-conversation row only.
        final chat = Chat(guid: const Uuid().v4().toUpperCase(), usingHandle: 'mailto:${request.sender}',
          style: 45, participants: [handle]);
        chat.handles.add(handle);
        objectBox.box<Chat>().put(chat);
        wire.conversation!.senderGuid = chat.guid;
        message = Message(guid: 'temp-WinWrite', text: request.text,
          isFromMe: true, dateCreated: DateTime.now().toUtc(), hasAttachments: false,
          attributedBody: [AttributedBody.raw(request.text)]);
        message.chat.target = chat;
        source = CloudSyncLocalSendIdentity.captureWire(message, chat, wire) ??
            (throw StateError('cloud_sync_windows_write_wire_invalid'));
        if (!CloudSyncLocalSendIdentity.isFreshLocalSubmission(message,
            generatedGuid: wire.id, stableGuid: wire.id)) {
          throw StateError('cloud_sync_windows_write_origin_invalid');
        }
        message.stagingGuid = wire.id;
        journal.saveSubmission(identity: source, newlyGeneratedGuid: true,
          persistMessage: () => objectBox.box<Message>().put(message),
          now: DateTime.now().toUtc());
      }), accountFingerprint: auth.accountFingerprint);
      await reportStage('windows-write-awaiting-native-send');
      await sendConfirmed(wire); // No retry and no abandoned timeout.
      journal.recordNativeSendConfirmation(stableGuid: savedClaim['guid'] as String,
        succeeded: true, capturedAuth: auth, stillCurrent: current,
        now: DateTime.now().toUtc());
    }
    final guidHash = sha256.convert(utf8.encode(jsonEncode(
      ['cloud-sync-local-send-guid-v1', savedClaim['guid']],
    ))).toString();
    final query = objectBox.box<CloudSyncLocalSendIntentEntity>().query(
      CloudSyncLocalSendIntentEntity_.accountFingerprint.equals(auth.accountFingerprint)
        .and(CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(guidHash)),
    ).build();
    late CloudSyncLocalSendIntentEntity intent;
    try { intent = query.findUnique() ??
        (throw StateError('cloud_sync_windows_write_intent_missing')); }
    finally { query.close(); }
    if (intent.state == 0) {
      throw StateError('cloud_sync_windows_write_send_unconfirmed_no_retry');
    }
    if (intent.state == 3) {
      await fence.run(() => journal.promoteIdsConfirmedDeferred(intentId: intent.id,
        currentAuth: auth, now: DateTime.now().toUtc()),
        accountFingerprint: auth.accountFingerprint);
    }
    await reportStage('windows-write-consuming-exact-intent');
    final result = await CloudSyncProductionLocalSendAdapter(
      readActiveClient: readClient, privateStorageDirectory: fs.appDocDir.path,
      stillCurrent: current,
    ).runExactIntent(intentId: intent.id, expectedRecipient: request.recipient,
      expectedSourceSha256: intent.sourceSha256);
    return {'native_send_confirmed': true, 'admitted': result.admitted,
      'deferred': result.deferred, 'outbox_blocked': result.outboxBlocked,
      'chat_readback_pending': result.chatReadbackPending,
      'deferred_reasons': result.deferredReasons};
  }
}
