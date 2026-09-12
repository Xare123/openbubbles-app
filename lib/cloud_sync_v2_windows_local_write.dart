import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

import 'services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'services/rustpush/cloud_sync/cloud_sync_local_mutation_identity.dart';
import 'services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'services/rustpush/cloud_sync/cloud_sync_local_mutation_source_staging.dart';
import 'services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'services/rustpush/cloud_sync/cloud_sync_models.dart'
    show
        CloudOutboxOperation,
        CloudOutboxStatus,
        CloudSyncPersistenceLane,
        CloudSyncSafeCodeFailure,
        CloudSyncScope,
        CloudSyncStreamKind;
import 'services/rustpush/imessage_reaction_payload.dart';
import 'services/rustpush/cloud_sync/cloud_sync_group_send_route.dart';
import 'cloud_sync_v2_windows_write_checkpoint.dart';
import 'cloud_sync_v2_windows_attachment_fixture.dart';
import 'services/rustpush/cloud_sync/cloud_sync_attachment_send_body.dart';
import 'services/rustpush/cloud_sync/cloud_protected_page_lease_lifecycle.dart';
import 'services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'services/rustpush/cloud_sync/cloud_sync_local_send_source_staging.dart';
import 'services/rustpush/cloud_sync/cloud_sync_message_update_executor.dart';
import 'services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart';
import 'package:uuid/uuid.dart';
import 'services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'services/rustpush/cloud_sync/cloud_sync_record_maps.dart';
import 'services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'services/rustpush/cloud_sync/cloud_sync_write_chat_identity_session.dart';
import 'services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart';
import 'services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'services/rustpush/cloud_sync/legacy_cloudkit_deletion_intents.dart';
import 'services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';

String cloudSyncWindowsWriteFailureCode(Object error) {
  if (error is AnyhowException) {
    final fixed = cloudSyncV2SafeFailureCodeForCandidate(error.message);
    if (fixed != 'cloud_sync_unknown_failure') return fixed;
    if (error.message.contains('Registration Error') &&
        error.message.contains('(5052)')) {
      return 'cloud_sync_windows_sender_alias_changed';
    }
    if (error.message.contains('Registration Error') &&
        error.message.contains('(6005)')) {
      return 'cloud_sync_windows_sender_bad_authentication';
    }
  }
  return cloudSyncV2SafeFailureCode(error);
}

/// Development-only attribution without exception bodies, handles or file paths.
/// Unknown code hashes can be compared to source literals offline, not promoted
/// to retry authority. Stack output is restricted to these reviewed source files.
Map<String, Object?> cloudSyncWindowsWriteFailureDiagnostic(
  Object error,
  StackTrace stack,
) {
  final code = cloudSyncWindowsWriteFailureCode(error);
  final candidate = switch (error) {
    CloudSyncSafeCodeFailure() => error.safeCode,
    StateError() => error.message,
    AnyhowException() => error.message,
    _ => null,
  };
  const sources = {
    'cloud_sync_v2_windows_local_write.dart',
    'cloud_sync_v2_windows_harness.dart',
    'cloud_sync_production_sampler_adapter.dart',
    'cloud_sync_local_send_consumer.dart',
    'cloud_sync_local_send_journal.dart',
    'cloud_sync_local_send_selection.dart',
    'cloud_sync_outbound_admission.dart',
    'cloud_sync_attachment_parent_coordinator.dart',
    'cloud_sync_attachment_upload_journal.dart',
    'cloud_sync_attachment_plan_coordinator.dart',
    'cloud_sync_attachment_upload_executor.dart',
    'native_protected_cloud_sync_transport.dart',
    'objectbox_cloud_sync_store.dart',
    'objectbox_cloud_sync_preflight.dart',
    'cloud_protected_page_lease_lifecycle.dart',
    'cloudkit_writer_authority.dart',
    'cloudkit_writer_mutation_guard.dart',
  };
  final frames =
      RegExp(
            r'\(package:bluebubbles/(?:services/rustpush/cloud_sync/)?([a-z0-9_]+\.dart):([0-9]{1,7}):([0-9]{1,5})\)',
          )
          .allMatches(stack.toString())
          .where((m) => sources.contains(m[1]))
          .take(6)
          .map(
            (m) => {
              'source': m[1],
              'line': int.parse(m[2]!),
              'column': int.parse(m[3]!),
            },
          )
          .toList();
  final codeShape = candidate == null
      ? null
      : RegExp(r'^cloud_sync_[a-z_]{1,100}$').firstMatch(candidate);
  return {
    'code': code,
    'kind': switch (error) {
      CloudSyncSafeCodeFailure() => 'safe_code_failure',
      StateError() => 'state_error',
      AnyhowException() => 'native_bridge',
      _ => 'other',
    },
    'unreviewed_code_sha256':
        code == 'cloud_sync_unknown_failure' &&
            candidate != null &&
            codeShape != null &&
            codeShape.end == candidate.length
        ? sha256.convert(utf8.encode(candidate)).toString()
        : null,
    'frames': frames,
  };
}

/// Explicit qualification input, never read by ordinary app startup. Request
/// content stays in the private profile, not process arguments or reports.
final class CloudSyncWindowsWriteRequest {
  CloudSyncWindowsWriteRequest.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      _recipient = json['recipient'] as String?,
      recipients = List.unmodifiable(
        json['version'] == 3
            ? (((json['recipients'] as List?)?.cast<String>().toList() ??
                    <String>[])
                ..sort())
            : [json['recipient'] as String],
      ),
      restoredGroupGuid = json['restoredGroupGuid'] as String?,
      sender = json['sender'] as String,
      text = json['text'] as String,
      reactionType = json['version'] == 5 && json['reactionType'] is String
          ? json['reactionType'] as String
          : null,
      reactionPart = json['reactionPart'] == null
          ? null
          : json['reactionPart'] is int
          ? json['reactionPart'] as int
          : -1,
      mutationType = json['version'] == 6 && json['mutationType'] is String
          ? json['mutationType'] as String
          : null,
      mutationPart = json['mutationPart'] == null
          ? null
          : json['mutationPart'] is int
          ? json['mutationPart'] as int
          : -1,
      attachmentFixture =
          json['version'] == 4 && json['attachmentFixture'] is String
          ? CloudSyncWindowsAttachmentFixture.fromId(
              json['attachmentFixture'] as String,
            )
          : null,
      refreshSenderAuthentication = json['refreshSenderAuthentication'] == true,
      existingChatFromRequestId = json['existingChatFromRequestId'] as String? {
    final validVersion = json['version'] == 3
        ? _recipient == null &&
              existingChatFromRequestId == null &&
              restoredGroupGuid != null &&
              restoredGroupGuid!.startsWith('iMessage;+;') &&
              restoredGroupGuid!.length > 'iMessage;+;'.length &&
              restoredGroupGuid!.length <= 4096 &&
              restoredGroupGuid!.trim() == restoredGroupGuid &&
              !restoredGroupGuid!.runes.any(
                (rune) => rune < 0x20 || rune == 0x7f,
              ) &&
              recipients.length >= 2 &&
              recipients.length <= 31
        : restoredGroupGuid == null &&
              !json.containsKey('recipients') &&
              (json['version'] == 5
                  ? reactionType != null &&
                        const {
                          'love',
                          'like',
                          'dislike',
                          'laugh',
                          'emphasize',
                          'question',
                          '-love',
                          '-like',
                          '-dislike',
                          '-laugh',
                          '-emphasize',
                          '-question',
                        }.contains(reactionType) &&
                        json.containsKey('reactionPart') &&
                        (reactionPart == null || reactionPart == 0) &&
                        existingChatFromRequestId != null &&
                        RegExp(
                          r'^[a-z0-9-]{1,64}$',
                        ).hasMatch(existingChatFromRequestId!) &&
                        existingChatFromRequestId != id
                  : json['version'] == 6
                  ? mutationType != null &&
                        const {'edit', 'unsend'}.contains(mutationType) &&
                        mutationPart == 0 &&
                        existingChatFromRequestId != null &&
                        RegExp(
                          r'^[a-z0-9-]{1,64}$',
                        ).hasMatch(existingChatFromRequestId!) &&
                        existingChatFromRequestId != id
                  : json['version'] == 4
                  ? attachmentFixture != null &&
                        (existingChatFromRequestId == null ||
                            (RegExp(
                                  r'^[a-z0-9-]{1,64}$',
                                ).hasMatch(existingChatFromRequestId!) &&
                                existingChatFromRequestId != id))
                  : json['version'] == 1
                  ? existingChatFromRequestId == null
                  : json['version'] == 2 &&
                        existingChatFromRequestId != null &&
                        RegExp(
                          r'^[a-z0-9-]{1,64}$',
                        ).hasMatch(existingChatFromRequestId!) &&
                        existingChatFromRequestId != id);
    if (!validVersion ||
        (json['version'] != 5 &&
            (json.containsKey('reactionType') ||
                json.containsKey('reactionPart'))) ||
        (json['version'] != 4 && json.containsKey('attachmentFixture')) ||
        (json['version'] != 6 &&
            (json.containsKey('mutationType') ||
                json.containsKey('mutationPart'))) ||
        (json.containsKey('refreshSenderAuthentication') &&
            json['refreshSenderAuthentication'] is! bool) ||
        json['allowSend'] != true ||
        !RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(id) ||
        recipients.toSet().length != recipients.length ||
        !recipients.every(RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch) ||
        !RegExp(r'^[^\s:@]+@[^\s:@]+\.[^\s:@]+$').hasMatch(sender) ||
        (mutationType != null
            ? (mutationType == 'edit' ? text.trim().isEmpty : text.isNotEmpty)
            : attachmentFixture == null && reactionType == null
            ? text.trim().isEmpty
            : text.isNotEmpty) ||
        text.length > 512) {
      throw StateError('cloud_sync_windows_write_request_invalid');
    }
  }

  final String id;
  final String? _recipient;
  final List<String> recipients;
  final String? restoredGroupGuid;
  bool get isGroup => restoredGroupGuid != null;
  String get recipient =>
      _recipient ??
      (throw StateError('cloud_sync_windows_write_group_requires_member_set'));
  final String sender;
  final String text;
  final String? reactionType;
  final int? reactionPart;
  final String? mutationType;
  final int? mutationPart;
  final CloudSyncWindowsAttachmentFixture? attachmentFixture;

  /// Explicit operator repair before any new intent or send. Never implicit
  /// retry after failure and never a reason to clear hardware or CloudKit state.
  final bool refreshSenderAuthentication;
  final String? existingChatFromRequestId;
  String get binding => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            mutationType != null
                ? [
                    'windows-local-write-v6',
                    id,
                    recipient,
                    sender,
                    existingChatFromRequestId,
                    mutationType,
                    mutationPart,
                    text,
                    if (refreshSenderAuthentication) 'refresh-sender-auth-v1',
                  ]
                : reactionType != null
                ? [
                    'windows-local-write-v5',
                    id,
                    recipient,
                    sender,
                    existingChatFromRequestId,
                    reactionType,
                    reactionPart,
                    if (refreshSenderAuthentication) 'refresh-sender-auth-v1',
                  ]
                : attachmentFixture != null
                ? [
                    'windows-local-write-v4',
                    id,
                    recipient,
                    sender,
                    text,
                    existingChatFromRequestId,
                    attachmentFixture!.id,
                    attachmentFixture!.sha256Hex,
                    attachmentFixture!.filename,
                    attachmentFixture!.mimeType,
                    attachmentFixture!.uti,
                    if (refreshSenderAuthentication) 'refresh-sender-auth-v1',
                  ]
                : isGroup
                ? [
                    'windows-local-write-v3',
                    id,
                    recipients,
                    sender,
                    text,
                    restoredGroupGuid,
                    if (refreshSenderAuthentication) 'refresh-sender-auth-v1',
                  ]
                : existingChatFromRequestId == null
                ? [
                    'windows-local-write-v1',
                    id,
                    recipient,
                    sender,
                    text,
                    if (refreshSenderAuthentication) 'refresh-sender-auth-v1',
                  ]
                : [
                    'windows-local-write-v2',
                    id,
                    recipient,
                    sender,
                    text,
                    existingChatFromRequestId,
                    if (refreshSenderAuthentication) 'refresh-sender-auth-v1',
                  ],
          ),
        ),
      )
      .toString();
}

/// The ordinary single-attachment composer shape. The exact descriptor survives
/// the ObjectBox relation round-trip and is later checked against the IDS wire.
Message cloudSyncWindowsAttachmentSubmission({
  required CloudSyncWindowsAttachmentFixture fixture,
  required api.MessageInst wire,
  required String descriptor,
}) {
  if (descriptor.isEmpty ||
      utf8.encode(descriptor).length >
          CloudSyncAttachmentSendBody.maxDescriptorBytes) {
    throw StateError('cloud_sync_windows_attachment_descriptor_invalid');
  }
  return Message(
      guid: 'temp-WinWrite',
      text: '',
      isFromMe: true,
      dateCreated: DateTime.now().toUtc(),
      hasAttachments: true,
      attributedBody: [],
    )
    ..dbAttachments.add(
      Attachment(
        guid: '${wire.id}_0',
        uti: fixture.uti,
        mimeType: fixture.mimeType,
        isOutgoing: true,
        transferName: fixture.filename,
        totalBytes: fixture.bytes.length,
        metadata: {'rustpush': descriptor},
      ),
    );
}

/// An explicit restored-group selector, not a best-match or a new group.
/// Protected semantic dependency validation still happens in the writer.
Chat cloudSyncWindowsRestoredGroupWriteChat(
  Store store,
  CloudSyncWindowsWriteRequest request,
) {
  if (!request.isGroup) {
    throw StateError('cloud_sync_windows_write_group_mismatch');
  }
  final query = store
      .box<Chat>()
      .query(Chat_.guid.equals(request.restoredGroupGuid!))
      .build();
  try {
    final matches = query.find();
    final chat = matches.length == 1 ? matches.single : null;
    final route = chat == null ? null : CloudSyncGroupSendRoute.capture(chat);
    if (route == null ||
        route.provisional ||
        route.groupId == null ||
        route.sender != request.sender ||
        jsonEncode(route.members) != jsonEncode(request.recipients)) {
      throw StateError('cloud_sync_windows_write_group_mismatch');
    }
    return chat!;
  } finally {
    query.close();
  }
}

/// Select only a previously qualified send's exact chat, never a best-match
/// conversation from restored personal history. Production admission still
/// verifies the restored Chat dependency before any CloudKit save.
Chat cloudSyncWindowsExistingWriteChat(
  Store store,
  Map<String, dynamic> claim,
  CloudSyncWindowsWriteRequest request,
  String accountFingerprint,
) {
  if (claim['version'] != 1 ||
      claim['account'] != accountFingerprint ||
      claim['guid'] is! String ||
      claim['binding'] is! String) {
    throw StateError('cloud_sync_windows_write_previous_claim_invalid');
  }
  final hash = sha256
      .convert(
        utf8.encode(
          jsonEncode(['cloud-sync-local-send-guid-v1', claim['guid']]),
        ),
      )
      .toString();
  final query = store
      .box<CloudSyncLocalSendIntentEntity>()
      .query(
        CloudSyncLocalSendIntentEntity_.accountFingerprint
            .equals(accountFingerprint)
            .and(CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(hash)),
      )
      .build();
  try {
    final intent = query.findUnique();
    final previous = intent == null
        ? null
        : store.box<Message>().get(intent.localMessageId);
    final chat = previous?.chat.target;
    if (intent?.state != 2 ||
        intent?.admittedOperationId == null ||
        previous?.guid != claim['guid'] ||
        previous?.stagingGuid != null ||
        chat == null ||
        chat.guid.isEmpty ||
        chat.style != 45 ||
        chat.usingHandle != 'mailto:${request.sender}' ||
        chat.handles.length != 1 ||
        chat.handles.single.address != request.recipient ||
        chat.handles.single.service != 'iMessage') {
      throw StateError('cloud_sync_windows_write_previous_chat_mismatch');
    }
    return chat;
  } finally {
    query.close();
  }
}

/// Select a single plaintext parent from the explicitly named test claim.
/// This is route/shape selection only; the caller must revalidate the actual
/// journal readback dependency before claiming and immediately before sending.
Message cloudSyncWindowsReactionParent(
  Store store,
  Map<String, dynamic> claim,
  CloudSyncWindowsWriteRequest request,
  String accountFingerprint,
) {
  if (request.reactionType == null) {
    throw StateError('cloud_sync_windows_reaction_request_required');
  }
  final chat = cloudSyncWindowsExistingWriteChat(
    store,
    claim,
    request,
    accountFingerprint,
  );
  final query =
      store
          .box<Message>()
          .query(Message_.guid.equals(claim['guid'] as String))
          .build()
        ..limit = 2;
  try {
    final rows = query.find();
    final parent = rows.length == 1 ? rows.single : null;
    if (parent == null ||
        parent.chat.targetId != chat.id ||
        chat.guid != 'iMessage;-;${request.recipient}' ||
        chat.chatIdentifier != request.recipient ||
        parent.isFromMe != true ||
        parent.dateDeleted != null ||
        parent.dateEdited != null ||
        parent.associatedMessageGuid != null ||
        parent.associatedMessageType != null ||
        parent.hasAttachments ||
        parent.dbAttachments.isNotEmpty ||
        parent.text?.trim().isNotEmpty != true ||
        parent.attributedBody.length != 1 ||
        parent.attributedBody.single.string != parent.text) {
      throw StateError('cloud_sync_windows_reaction_parent_invalid');
    }
    return parent;
  } finally {
    query.close();
  }
}

api.Message cloudSyncWindowsReactionPayload(
  CloudSyncWindowsWriteRequest request,
  Message parent,
) {
  final type = request.reactionType;
  if (type == null || parent.guid == null || parent.text == null) {
    throw StateError('cloud_sync_windows_reaction_parent_invalid');
  }
  final base = type.startsWith('-') ? type.substring(1) : type;
  final reaction = switch (base) {
    'love' => const api.Reaction.heart(),
    'like' => const api.Reaction.like(),
    'dislike' => const api.Reaction.dislike(),
    'laugh' => const api.Reaction.laugh(),
    'emphasize' => const api.Reaction.emphasize(),
    'question' => const api.Reaction.question(),
    _ => throw StateError('cloud_sync_windows_reaction_request_required'),
  };
  return buildIMessageReactionPayload(
    parentGuid: parent.guid!,
    parentPart: request.reactionPart,
    parentText: parent.text!,
    reaction: reaction,
    enable: !type.startsWith('-'),
  );
}

/// Small Windows composition of the ordinary journal and writer, not another
/// uploader. One immutable request can send at most once. A crash before native
/// completion leaves the journal pending and requires explicit reconciliation.
/// The first Windows mutation experiment is a direct, single-part plaintext
/// parent selected by its prior successful test claim. No arbitrary chat scan.
Message cloudSyncWindowsMutationParent(
  Store store,
  Map<String, dynamic> claim,
  CloudSyncWindowsWriteRequest request,
  String accountFingerprint,
) {
  if (request.mutationType == null) {
    throw StateError('cloud_sync_windows_mutation_request_required');
  }
  final chat = cloudSyncWindowsExistingWriteChat(
    store,
    claim,
    request,
    accountFingerprint,
  );
  final query =
      store
          .box<Message>()
          .query(Message_.guid.equals(claim['guid'] as String))
          .build()
        ..limit = 2;
  try {
    final rows = query.find();
    final parent = rows.length == 1 ? rows.single : null;
    if (parent == null ||
        parent.chat.targetId != chat.id ||
        chat.guid != 'iMessage;-;${request.recipient}' ||
        chat.chatIdentifier != request.recipient ||
        parent.isFromMe != true ||
        parent.dateDeleted != null ||
        parent.dateEdited != null ||
        parent.dateScheduled != null ||
        parent.verificationFailed ||
        parent.associatedMessageGuid != null ||
        parent.associatedMessageType != null ||
        parent.hasAttachments ||
        parent.dbAttachments.isNotEmpty ||
        parent.subject?.isNotEmpty == true ||
        parent.messageSummaryInfo.isNotEmpty ||
        parent.text?.trim().isNotEmpty != true ||
        parent.attributedBody.length != 1 ||
        parent.attributedBody.single.string != parent.text) {
      throw StateError('cloud_sync_windows_mutation_parent_invalid');
    }
    return parent;
  } finally {
    query.close();
  }
}

api.Message cloudSyncWindowsMutationPayload(
  CloudSyncWindowsWriteRequest request,
  Message parent,
) {
  if (request.mutationType == null ||
      request.mutationPart != 0 ||
      parent.guid == null) {
    throw StateError('cloud_sync_windows_mutation_parent_invalid');
  }
  return request.mutationType == 'unsend'
      ? api.Message.unsend(api.UnsendMessage(tuuid: parent.guid!, editPart: 0))
      : api.Message.edit(
          api.EditMessage(
            tuuid: parent.guid!,
            editPart: 0,
            newParts: api.MessageParts(
              field0: [
                api.IndexedMessagePart(
                  idx: 0,
                  part_: api.MessagePart.text(
                    request.text,
                    const api.TextFormat.flags(
                      api.TextFlags(
                        bold: false,
                        italic: false,
                        underline: false,
                        strikethrough: false,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
}

final class CloudSyncWindowsLocalWrite {
  CloudSyncWindowsLocalWrite({
    required this.readClient,
    required this.prepareSender,
    required this.sendConfirmed,
    required this.reportStage,
    this.uploadAttachment,
    this.sendMutationConfirmed,
  });

  final Object? Function() readClient;
  final Future<void> Function(
    String sender,
    List<String> recipients, {
    required bool refreshAuthentication,
  })
  prepareSender;
  final Future<void> Function(api.MessageInst message) sendConfirmed;
  final Future<api.CloudSyncNativeSendReceipt> Function(
    api.MessageInst message,
    api.CloudSyncNativeSendReceiptContext context,
  )?
  sendMutationConfirmed;
  final Future<void> Function(String stage) reportStage;
  final Future<api.Attachment> Function(
    File file,
    CloudSyncWindowsAttachmentFixture fixture,
  )?
  uploadAttachment;

  Future<Map<String, Object?>> run() async {
    if (!Platform.isWindows ||
        !fs.cloudSyncV2WindowsDevProfileActive ||
        !CloudSyncDevGate.manualOutboundCanaryEnabled ||
        !CloudKitWriterOwnership.v2MutationsEnabled) {
      throw StateError('cloud_sync_windows_write_disabled');
    }
    final directory = Directory(path.join(fs.appDocDir.path, 'cloud-sync-v2'));
    final request = CloudSyncWindowsWriteRequest.fromJson(
      jsonDecode(
            await File(
              path.join(directory.path, 'windows-local-write-request.json'),
            ).readAsString(),
          )
          as Map<String, dynamic>,
    );
    // v6 has a separate protected-source/receipt contract. Never let a
    // recognized mutation fall through into the initial-message writer.
    if (request.mutationType != null && sendMutationConfirmed == null) {
      throw StateError('cloud_sync_windows_mutation_runtime_unavailable');
    }
    final claim = File(
      path.join(directory.path, 'windows-write-${request.id}.json'),
    );
    final replay = claim.existsSync();
    final client = readClient();
    if (client is! rustlib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw StateError('cloud_sync_windows_write_client_missing');
    }
    final objectBox = Database.store;
    if (request.isGroup && !claim.existsSync()) {
      cloudSyncWindowsRestoredGroupWriteChat(objectBox, request);
    }
    bool current() =>
        identical(client, readClient()) &&
        identical(objectBox, Database.store) &&
        !objectBox.isClosed();
    final binding = FrbCloudSyncNativeAuthBinding();
    await binding.ensureReadAuthentication(
      cloudMessagesClient: client,
      privateStorageDirectory: fs.appDocDir.path,
    );
    final authProvider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: readClient,
      nativeAuthBinding: binding,
      privateStorageDirectory: fs.appDocDir.path,
    );
    // Prepare IDS before capturing the stable CloudKit identity. No login reset.
    if (!claim.existsSync()) {
      await reportStage('windows-write-registering-sender');
      await prepareSender(
        'mailto:${request.sender}',
        request.recipients
            .map((recipient) => 'tel:$recipient')
            .toList(growable: false),
        refreshAuthentication: request.refreshSenderAuthentication,
      );
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
      privateStorageDirectory: fs.appDocDir.path,
      fenceStore: durable,
    );
    final provisioner = CloudKitV2WriterProvisioner(
      authority: authority,
      interlock: interlock,
      readAuthSnapshot: authProvider.capture,
      quarantineLegacyDeletionQueues: () async {
        throw StateError('cloud_sync_windows_write_legacy_migration_forbidden');
      },
      readMeasurements: (scope) async {
        // This dedicated composition never initializes SettingsService, legacy
        // sync, its queues, or background sync. Reject copied preferences rather
        // than silently treating a legacy installation as a fresh writer.
        if (File(
          path.join(fs.appDocDir.path, 'shared_preferences.json'),
        ).existsSync()) {
          throw StateError(
            'cloud_sync_windows_write_legacy_preferences_present',
          );
        }
        return objectBox.runInTransaction(TxMode.read, () {
          final local = ObjectBoxCloudSyncPreflightReader.fromDatabase().read();
          final messages = objectBox
              .box<Message>()
              .query(
                Message_.ckSyncState
                    .equals(false)
                    .or(Message_.ckSyncState.isNull()),
              )
              .build();
          final chats = objectBox
              .box<Chat>()
              .query(Chat_.ckSyncState.equals(false))
              .build();
          try {
            return CloudKitWriterProvisioningMeasurements(
              objectBoxReady: !objectBox.isClosed(),
              legacySyncEnabled: false,
              legacySyncActive: false,
              backgroundSyncActive: false,
              coordinatorLeaseActive: local.coordinatorLeaseActive,
              pendingLegacyDeletionIntents: LegacyCloudKitDeletionIntentStore(
                store: objectBox,
              ).pendingCountForScope(scope),
              legacyPreferenceQueueEntries: 0,
              unsyncedLegacyMessages: messages.count(),
              unsyncedLegacyChats: chats.count(),
              existingV2OutboxOperations: local.outboxCount,
            );
          } finally {
            messages.close();
            chats.close();
          }
        });
      },
    );
    final writerScope = CloudKitWriterScope(
      accountFingerprint: auth.accountFingerprint,
    );
    final retainedOwner = request.mutationType != null && claim.existsSync()
        ? authority.read(writerScope)
        : null;
    final CloudKitWriterAuthoritySnapshot ownerSnapshot;
    if (retainedOwner != null &&
        retainedOwner.owner == CloudKitWriterOwner.v2 &&
        retainedOwner.state == CloudKitWriterAuthorityState.mutationUnknown &&
        retainedOwner.targetOwner == CloudKitWriterOwner.none &&
        retainedOwner.transitionIdHash == null) {
      // A claimed mutation may have crossed the remote edge in an earlier
      // process. Provisioning correctly refuses an unresolved writer, while
      // the exact outbox operation and persistent mutation fence below retain
      // enough evidence to run reconciliation without issuing another send.
      ownerSnapshot = retainedOwner;
    } else {
      ownerSnapshot = (await provisioner.ensureV2Owned(
        expectedAuth: auth,
        initialOwnerOnly: true,
      )).snapshot;
    }
    final journal = CloudSyncLocalSendJournal(
      store: objectBox,
      authority: authority,
      authoritySnapshot: ownerSnapshot,
    );
    final fence = CloudSyncLocalSendAuthFence(
      expected: auth,
      capture: authProvider.capture,
      stillCurrent: current,
    );
    if (request.mutationType != null) {
      final mutationJournal = CloudSyncLocalMutationJournal(
        store: objectBox,
        authority: authority,
        authoritySnapshot: ownerSnapshot,
      );
      final mutationStore = ObjectBoxCloudSyncStore(
        store: objectBox,
        protector: RustCloudSyncProtector(storageDirectory: fs.appDocDir.path),
        localMutationJournal: mutationJournal,
      );
      return _runMutation(
        request: request,
        claim: claim,
        directory: directory,
        client: client,
        store: objectBox,
        auth: auth,
        authBinding: binding,
        current: current,
        fence: fence,
        interlock: CloudKitOperationInterlock(
          privateStorageDirectory: fs.appDocDir.path,
          fenceStore: mutationStore,
        ),
        cloudStore: mutationStore,
        createJournal: journal,
        journal: mutationJournal,
      );
    }
    late Map<String, dynamic> savedClaim;
    if (claim.existsSync()) {
      savedClaim =
          jsonDecode(await claim.readAsString()) as Map<String, dynamic>;
      if (savedClaim['binding'] != request.binding ||
          savedClaim['version'] != 1 ||
          savedClaim['account'] != auth.accountFingerprint) {
        throw StateError('cloud_sync_windows_write_request_changed');
      }
    } else {
      Chat? existingChat;
      Map<String, dynamic>? previousClaim;
      if (request.existingChatFromRequestId != null) {
        previousClaim =
            jsonDecode(
                  await File(
                    path.join(
                      directory.path,
                      'windows-write-${request.existingChatFromRequestId}.json',
                    ),
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        existingChat = cloudSyncWindowsExistingWriteChat(
          objectBox,
          previousClaim,
          request,
          auth.accountFingerprint,
        );
      }
      if (request.isGroup) {
        existingChat = cloudSyncWindowsRestoredGroupWriteChat(
          objectBox,
          request,
        );
      }
      Message requireReactionParent() {
        final parent = cloudSyncWindowsReactionParent(
          objectBox,
          previousClaim!,
          request,
          auth.accountFingerprint,
        );
        final scope = CloudSyncScope(
          accountFingerprint: auth.accountFingerprint,
          container: 'com.apple.messages.cloud',
          database: 'private',
          zone: 'messageManateeZone',
          persistenceLane: CloudSyncPersistenceLane.semantic,
        );
        if (journal.readConfirmedParentDependency(objectBox, scope, parent) ==
            null) {
          throw StateError(
            'cloud_sync_windows_reaction_parent_readback_required',
          );
        }
        return parent;
      }

      final reactionParent = request.reactionType == null
          ? null
          : await fence.run(
              requireReactionParent,
              accountFingerprint: auth.accountFingerprint,
            );
      // Preserve both layers of the pre-send checkpoint. An ObjectBox backup
      // alone becomes unreplayable when normal GC retires its native reference.
      await fence.run(
        () => cloudSyncWindowsPreserveWriteCheckpoint(
          store: objectBox,
          profile: fs.appDocDir,
          requestId: request.id,
          requestBinding: request.binding,
          accountFingerprint: auth.accountFingerprint,
        ),
        accountFingerprint: auth.accountFingerprint,
      );
      final fixture = request.attachmentFixture;
      api.Attachment? uploaded;
      String? descriptor;
      if (fixture != null) {
        final upload = uploadAttachment;
        if (upload == null) {
          throw StateError('cloud_sync_windows_attachment_upload_unavailable');
        }
        final file = await fixture.materialize(fs.appDocDir, request.id);
        await reportStage('windows-write-uploading-ids-attachment');
        await fence.run<void>(() {});
        uploaded = await upload(file, fixture);
        await fence.run<void>(() {});
        if (uploaded.aType is! api.AttachmentType_MMCS ||
            uploaded.iris ||
            uploaded.mime != fixture.mimeType ||
            uploaded.utiType != fixture.uti ||
            uploaded.name != fixture.filename ||
            (uploaded.aType as api.AttachmentType_MMCS).field0.size !=
                fixture.bytes.length) {
          throw StateError('cloud_sync_windows_attachment_descriptor_invalid');
        }
        descriptor = await api.saveAttachment(att: uploaded);
        await fence.run<void>(() {});
      }
      final wire = await api.newMsg(
        conversation: api.ConversationData(
          participants: [
            ...request.recipients.map((recipient) => 'tel:$recipient'),
            'mailto:${request.sender}',
          ],
          senderGuid: existingChat?.guid,
          cvName: existingChat?.apnTitle,
          afterGuid: previousClaim?['guid'] as String?,
        ),
        sender: 'mailto:${request.sender}',
        message: reactionParent != null
            ? cloudSyncWindowsReactionPayload(request, reactionParent)
            : api.Message.message(
                api.NormalMessage(
                  service: const api.MessageType.iMessage(),
                  voice: false,
                  parts: api.MessageParts(
                    field0: [
                      api.IndexedMessagePart(
                        part_: uploaded != null
                            ? api.MessagePart.attachment(uploaded)
                            : api.MessagePart.text(
                                request.text,
                                const api.TextFormat.flags(
                                  api.TextFlags(
                                    bold: false,
                                    italic: false,
                                    underline: false,
                                    strikethrough: false,
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
      );
      savedClaim = {
        'version': 1,
        'binding': request.binding,
        'account': auth.accountFingerprint,
        'guid': wire.id,
      };
      // Exclusive, flushed claim precedes every canonical/journal mutation and
      // every network send. A torn claim fails closed on the next launch.
      await claim.create(exclusive: true);
      await claim.writeAsString(jsonEncode(savedClaim), flush: true);
      // The ordinary executor reads the canonical attachment cache path.
      // Only our deterministic fixture is written, never a user-selected file.
      final attachmentGuid = '${wire.id}_0';
      if (fixture != null) {
        await fixture.materializeForAttachment(fs.appDocDir, attachmentGuid);
      }
      late CloudSyncLocalSendIdentity source;
      late Message message;
      await fence.run(
        () => objectBox.runInTransaction(TxMode.write, () {
          late Chat chat;
          if (request.isGroup) {
            chat = cloudSyncWindowsRestoredGroupWriteChat(objectBox, request);
          } else if (existingChat != null) {
            chat = cloudSyncWindowsExistingWriteChat(
              objectBox,
              previousClaim!,
              request,
              auth.accountFingerprint,
            );
          } else {
            final handleQuery = objectBox
                .box<Handle>()
                .query(
                  Handle_.uniqueAddressAndService.equals(
                    '${request.recipient}/iMessage',
                  ),
                )
                .build();
            late Handle handle;
            try {
              handle =
                  handleQuery.findUnique() ??
                  Handle(
                    address: request.recipient,
                    service: 'iMessage',
                    uniqueAddressAndService: '${request.recipient}/iMessage',
                  );
            } finally {
              handleQuery.close();
            }
            objectBox.box<Handle>().put(handle);
            chat = Chat(
              guid: const Uuid().v4().toUpperCase(),
              usingHandle: 'mailto:${request.sender}',
              style: 45,
              participants: [handle],
            );
            // Admission must adopt this exact new-conversation row only.
            chat.handles.add(handle);
            objectBox.box<Chat>().put(chat);
          }
          wire.conversation!.senderGuid = chat.guid;
          if (reactionParent != null) {
            final fresh = requireReactionParent();
            if (fresh.guid != reactionParent.guid ||
                fresh.text != reactionParent.text) {
              throw StateError('cloud_sync_windows_reaction_parent_changed');
            }
          }
          message = reactionParent != null
              ? Message(
                  guid: 'temp-WinWrite',
                  text: '',
                  isFromMe: true,
                  dateCreated: DateTime.now().toUtc(),
                  hasAttachments: false,
                  attributedBody: [],
                  associatedMessageGuid: reactionParent.guid,
                  associatedMessagePart: request.reactionPart,
                  associatedMessageType: request.reactionType,
                )
              : fixture != null
              ? cloudSyncWindowsAttachmentSubmission(
                  fixture: fixture,
                  wire: wire,
                  descriptor: descriptor!,
                )
              : Message(
                  guid: 'temp-WinWrite',
                  text: request.text,
                  isFromMe: true,
                  dateCreated: DateTime.now().toUtc(),
                  hasAttachments: false,
                  attributedBody: [AttributedBody.raw(request.text)],
                );
          message.chat.target = chat;
          source =
              (reactionParent != null
                  ? CloudSyncLocalSendIdentity.captureReactionWire(
                      message,
                      chat,
                      wire,
                    )
                  : fixture == null
                  ? CloudSyncLocalSendIdentity.captureWire(message, chat, wire)
                  : CloudSyncLocalSendIdentity.captureAttachment(
                      message,
                      chat,
                      wire.id,
                    )) ??
              (throw StateError('cloud_sync_windows_write_wire_invalid'));
          if (!CloudSyncLocalSendIdentity.isFreshLocalSubmission(
            message,
            generatedGuid: wire.id,
            stableGuid: wire.id,
          )) {
            throw StateError('cloud_sync_windows_write_origin_invalid');
          }
          message.stagingGuid = wire.id;
          journal.saveSubmission(
            identity: source,
            newlyGeneratedGuid: true,
            persistMessage: () => objectBox.box<Message>().put(message),
            now: DateTime.now().toUtc(),
          );
        }),
        accountFingerprint: auth.accountFingerprint,
      );
      CloudSyncLocalSendSourceBinding? protectedSource;
      if (fixture != null) {
        final receipt = api.CloudSyncNativeSendReceiptContext(
          storageDirectory: fs.appDocDir.path,
          guidHash: source.guidHash,
          accountFingerprint: auth.accountFingerprint,
          protectedStoreIdentity: auth.protectedStoreIdentity,
          nativeSessionId: auth.nativeSessionId,
        );
        // Same local lease/adoption sequence as the ordinary composer. This
        // helper cannot upload or save a CloudKit record.
        final transport = NativeProtectedCloudSyncTransport(
          cloudMessagesClient: client,
          storageDirectory: fs.appDocDir.path,
          protectedStoreIdentity: auth.protectedStoreIdentity,
        );
        protectedSource =
            await CloudSyncLocalSendSourceStaging(
              journal: journal,
              authFence: fence,
              capturedAuth: auth,
              stillCurrent: current,
              exclusion: interlock,
              transport: transport,
            ).prepare(
              identity: source,
              validateWire: () async =>
                  (await CloudSyncLocalSendIdentity.captureAttachmentWire(
                    message,
                    message.chat.target!,
                    wire,
                    expectedSourceSha256: source.sourceSha256,
                    serializeAttachment: (value) =>
                        api.saveAttachment(att: value),
                  ))?.sourceSha256 ==
                  source.sourceSha256,
              stage: () async {
                final native = await api.cloudSyncStageIdsAttachmentSource(
                  cloudMessagesClient: client,
                  context: receipt,
                  localSourceSha256: source.sourceSha256,
                  message: wire,
                  attachmentGuids: CloudSyncAttachmentSendBody.capture(
                    message,
                  )!.attachmentGuids,
                );
                return CloudSyncLocalSendSourceBinding(
                  accountFingerprint: auth.accountFingerprint,
                  protectedStoreIdentity: auth.protectedStoreIdentity,
                  messageGuidHash: source.guidHash,
                  sourceSha256: native.sourceSha256,
                  protectedReference: native.protectedReference,
                  leaseReference: native.leaseReference,
                  payloadSha256: native.payloadSha256,
                  payloadLength: native.payloadLength.toInt(),
                );
              },
            );
      }
      await reportStage('windows-write-awaiting-native-send');
      await fence.run<void>(() {});
      if (reactionParent != null) {
        await fence.run(() {
          final fresh = requireReactionParent();
          if (fresh.guid != reactionParent.guid ||
              fresh.text != reactionParent.text) {
            throw StateError('cloud_sync_windows_reaction_parent_changed');
          }
        }, accountFingerprint: auth.accountFingerprint);
      }
      await sendConfirmed(wire); // No retry or abandoned timeout.
      await fence.run(
        () => journal.recordNativeSendConfirmation(
          stableGuid: savedClaim['guid'] as String,
          succeeded: true,
          capturedAuth: auth,
          stillCurrent: current,
          now: DateTime.now().toUtc(),
          protectedSource: protectedSource,
        ),
        accountFingerprint: auth.accountFingerprint,
      );
    }
    final guidHash = sha256
        .convert(
          utf8.encode(
            jsonEncode(['cloud-sync-local-send-guid-v1', savedClaim['guid']]),
          ),
        )
        .toString();
    final query = objectBox
        .box<CloudSyncLocalSendIntentEntity>()
        .query(
          CloudSyncLocalSendIntentEntity_.accountFingerprint
              .equals(auth.accountFingerprint)
              .and(
                CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
                  guidHash,
                ),
              ),
        )
        .build();
    late CloudSyncLocalSendIntentEntity intent;
    try {
      intent =
          query.findUnique() ??
          (throw StateError('cloud_sync_windows_write_intent_missing'));
    } finally {
      query.close();
    }
    if (intent.state == 0) {
      throw StateError('cloud_sync_windows_write_send_unconfirmed_no_retry');
    }
    if (intent.state == 3) {
      await fence.run(
        () => journal.promoteIdsConfirmedDeferred(
          intentId: intent.id,
          currentAuth: auth,
          now: DateTime.now().toUtc(),
        ),
        accountFingerprint: auth.accountFingerprint,
      );
    }
    await reportStage('windows-write-consuming-exact-intent');
    final adapter = CloudSyncProductionLocalSendAdapter(
      readActiveClient: readClient,
      privateStorageDirectory: fs.appDocDir.path,
      stillCurrent: current,
    );
    final result = request.isGroup
        ? await adapter.runExactGroupIntent(
            intentId: intent.id,
            expectedChatGuid: request.restoredGroupGuid!,
            expectedMembers: request.recipients,
            expectedSender: request.sender,
            expectedSourceSha256: intent.sourceSha256,
          )
        : await adapter.runExactIntent(
            intentId: intent.id,
            expectedRecipient: request.recipient,
            expectedSourceSha256: intent.sourceSha256,
          );
    final settledIntent = objectBox.box<CloudSyncLocalSendIntentEntity>().get(
      intent.id,
    );
    CloudOutboxOperationEntity? settledOperation;
    final settledOperationId = settledIntent?.admittedOperationId;
    if (settledOperationId != null) {
      final settledQuery = objectBox
          .box<CloudOutboxOperationEntity>()
          .query(
            CloudOutboxOperationEntity_.operationId.equals(settledOperationId),
          )
          .build();
      try {
        settledOperation = settledQuery.findUnique();
      } finally {
        settledQuery.close();
      }
    }
    final exactReadbackCommitted =
        settledIntent?.confirmedReadbackBindingSha256 != null &&
        settledOperation?.state == CloudOutboxStatus.confirmed.index &&
        settledOperation?.protectedLeaseReference == null;
    return {
      'native_send_confirmed': true,
      'native_send_attempted_this_run': !replay,
      'restart_reconciliation_only': replay,
      'exact_readback_committed': exactReadbackCommitted,
      'protected_outbox_lease_finalized': exactReadbackCommitted,
      'admitted': result.admitted,
      'deferred': result.deferred,
      'outbox_blocked': result.outboxBlocked,
      'chat_readback_pending': result.chatReadbackPending,
      'deferred_reasons': result.deferredReasons,
      'existing_history_diagnostics': result.existingHistoryDiagnostics,
    };
  }

  /// Bounded receipt-bound mutation qualification. It never enters the initial
  /// create lane; after local reflection it conditionally updates the exact
  /// existing Message record and acknowledges IDS evidence only after exact
  /// CloudKit readback has committed.
  Future<Map<String, Object?>> _runMutation({
    required CloudSyncWindowsWriteRequest request,
    required File claim,
    required Directory directory,
    required rustlib.ArcCloudMessagesClientDefaultAnisetteProvider client,
    required Store store,
    required CloudSyncNativeAuthSnapshot auth,
    required CloudSyncNativeAuthBinding authBinding,
    required bool Function() current,
    required CloudSyncLocalSendAuthFence fence,
    required CloudKitOperationInterlock interlock,
    required ObjectBoxCloudSyncStore cloudStore,
    required CloudSyncLocalSendJournal createJournal,
    required CloudSyncLocalMutationJournal journal,
  }) async {
    final replay = claim.existsSync();
    api.CloudSyncNativeSendReceipt? acceptedReceipt;
    final bindings = FrbNativeProtectedCloudSyncBindings();
    final mutationGuard = CloudKitWriterMutationGuard(
      store: store,
      readActiveClient: readClient,
      privateStorageDirectory: fs.appDocDir.path,
      reconciliationBinding: bindings,
    );
    final transport = NativeProtectedCloudSyncTransport(
      cloudMessagesClient: client,
      storageDirectory: fs.appDocDir.path,
      protectedStoreIdentity: auth.protectedStoreIdentity,
      bindings: bindings,
      writerMutationGuard: mutationGuard,
      readCheckpointGeneration: (scope) async =>
          (await cloudStore.readCheckpoint(scope)).generation,
      retainConfirmedReceiptsForReplay: true,
    );
    Future<void> validateMutationIdentity() => fence.run<void>(() {
      if (!current()) {
        throw StateError('cloud_sync_windows_write_identity_changed');
      }
    }, accountFingerprint: auth.accountFingerprint);
    final identitySession = CloudSyncWriteChatIdentitySession(
      exclusion: interlock,
      nativePause: FrbCloudSyncNativeWriterPause(),
      validate: validateMutationIdentity,
      ensureReadAuthentication: () => authBinding.ensureReadAuthentication(
        cloudMessagesClient: client,
        privateStorageDirectory: fs.appDocDir.path,
      ),
      warmReadAuthentication: (token) =>
          authBinding.warmReadAuthenticationUnderWriterPause(
            cloudMessagesClient: client,
            pauseToken: token,
          ),
    );
    try {
      final staging = CloudSyncLocalMutationSourceStaging(
        journal: journal,
        authFence: fence,
        capturedAuth: auth,
        stillCurrent: current,
        exclusion: interlock,
        transport: transport,
      );
      await CloudProtectedPageLeaseLifecycle(
        store: cloudStore,
        transport: transport,
      ).ensureRecoveredBeforeWrite();
      late Map<String, dynamic> saved;
      if (replay) {
        saved = jsonDecode(await claim.readAsString()) as Map<String, dynamic>;
        if (saved['version'] != 2 ||
            saved['purpose'] != 'mutation' ||
            saved['binding'] != request.binding ||
            saved['account'] != auth.accountFingerprint ||
            saved['guid'] is! String) {
          throw StateError('cloud_sync_windows_write_request_changed');
        }
      } else {
        final previous =
            jsonDecode(
                  await File(
                    path.join(
                      directory.path,
                      'windows-write-${request.existingChatFromRequestId}.json',
                    ),
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        Message selectParent() {
          final parent = cloudSyncWindowsMutationParent(
            store,
            previous,
            request,
            auth.accountFingerprint,
          );
          // Deliberately narrow qualification window, not a claim about Apple's
          // full product limits. Five minutes covers isolated harness startup
          // while still requiring a freshly sent approved test message.
          final created = parent.dateCreated?.toUtc();
          final age = created == null
              ? null
              : DateTime.now().toUtc().difference(created);
          if (age == null ||
              age.isNegative ||
              age > const Duration(minutes: 5)) {
            throw StateError(
              'cloud_sync_windows_mutation_fresh_test_parent_required',
            );
          }
          final scope = CloudSyncScope(
            accountFingerprint: auth.accountFingerprint,
            container: 'com.apple.messages.cloud',
            database: 'private',
            zone: 'messageManateeZone',
            persistenceLane: CloudSyncPersistenceLane.semantic,
          );
          if (createJournal.readConfirmedParentDependency(
                store,
                scope,
                parent,
              ) ==
              null) {
            throw StateError(
              'cloud_sync_windows_mutation_parent_readback_required',
            );
          }
          return parent;
        }

        final parent = await fence.run(selectParent);
        await fence.run(
          () => cloudSyncWindowsPreserveWriteCheckpoint(
            store: store,
            profile: fs.appDocDir,
            requestId: request.id,
            requestBinding: request.binding,
            accountFingerprint: auth.accountFingerprint,
          ),
        );
        final wire = await api.newMsg(
          conversation: api.ConversationData(
            participants: [
              'tel:${request.recipient}',
              'mailto:${request.sender}',
            ],
            senderGuid: parent.chat.target!.guid,
            cvName: parent.chat.target!.apnTitle,
            afterGuid: parent.guid,
          ),
          sender: 'mailto:${request.sender}',
          message: cloudSyncWindowsMutationPayload(request, parent),
        );
        final identity =
            CloudSyncLocalMutationIdentity.captureWire(wire) ??
            (throw StateError('cloud_sync_windows_mutation_wire_invalid'));
        await fence.run(() {
          if (selectParent().id != parent.id) {
            throw StateError('cloud_sync_windows_mutation_parent_changed');
          }
        });
        saved = {
          'version': 2,
          'purpose': 'mutation',
          'binding': request.binding,
          'account': auth.accountFingerprint,
          'guid': wire.id,
          'local_message_id': parent.id,
          'target_guid_hash': identity.targetGuidHash,
          'source_sha256': identity.sourceSha256,
        };
        await claim.create(exclusive: true);
        await claim.writeAsString(jsonEncode(saved), flush: true);
        api.CloudSyncNativeSendReceiptContext context([
          CloudSyncLocalMutationSourceBinding? source,
        ]) => api.CloudSyncNativeSendReceiptContext(
          storageDirectory: fs.appDocDir.path,
          guidHash: identity.guidHash,
          accountFingerprint: auth.accountFingerprint,
          protectedStoreIdentity: auth.protectedStoreIdentity,
          nativeSessionId: auth.nativeSessionId,
          sourceBinding: source == null
              ? null
              : api.CloudSyncNativeSendSourceBinding(
                  kind: api.CloudSyncNativeSendSourceKind.mutation,
                  sourceSha256: source.sourceSha256,
                  protectedReference: source.protectedReference,
                  leaseReference: source.leaseReference,
                  payloadSha256: source.payloadSha256,
                  payloadLength: BigInt.from(source.payloadLength),
                ),
        );
        await reportStage('windows-mutation-preparing-protected-source');
        await staging.submitConfirmed(
          localMessageId: parent.id!,
          identity: identity,
          stage: () async {
            final native = await api.cloudSyncStageIdsMutationSource(
              cloudMessagesClient: client,
              context: context(),
              localSourceSha256: identity.sourceSha256,
              message: wire,
            );
            if (native.kind != api.CloudSyncNativeSendSourceKind.mutation) {
              throw StateError('cloud_sync_windows_mutation_source_invalid');
            }
            return CloudSyncLocalMutationSourceBinding(
              accountFingerprint: auth.accountFingerprint,
              protectedStoreIdentity: auth.protectedStoreIdentity,
              mutationGuidHash: identity.guidHash,
              targetGuidHash: identity.targetGuidHash,
              targetPart: identity.targetPart,
              sourceSha256: native.sourceSha256,
              protectedReference: native.protectedReference,
              leaseReference: native.leaseReference,
              payloadSha256: native.payloadSha256,
              payloadLength: native.payloadLength.toInt(),
            );
          },
          restore: (source) => api.cloudSyncRestoreIdsMutationSource(
            cloudMessagesClient: client,
            context: context(source),
          ),
          validateBeforeSend: selectParent,
          send: (wire, source) async {
            final receipt = await sendMutationConfirmed!(wire, context(source));
            acceptedReceipt = receipt;
            return receipt;
          },
        );
      }
      final guidHash = sha256
          .convert(
            utf8.encode(
              jsonEncode(['cloud-sync-local-send-guid-v1', saved['guid']]),
            ),
          )
          .toString();
      CloudSyncLocalMutationIntentEntity readIntent() {
        final query = store
            .box<CloudSyncLocalMutationIntentEntity>()
            .query(
              CloudSyncLocalMutationIntentEntity_.accountFingerprint
                  .equals(auth.accountFingerprint)
                  .and(
                    CloudSyncLocalMutationIntentEntity_.mutationGuidHash.equals(
                      guidHash,
                    ),
                  ),
            )
            .build();
        try {
          final row = query.findUnique();
          if (row == null) {
            throw StateError('cloud_sync_windows_mutation_intent_missing');
          }
          validateCloudSyncMutationRow(row);
          if (row.localMessageId != saved['local_message_id'] ||
              row.targetGuidHash != saved['target_guid_hash'] ||
              row.sourceSha256 != saved['source_sha256'] ||
              row.targetPart != request.mutationPart ||
              row.kind !=
                  CloudSyncLocalMutationKind.values
                      .byName(request.mutationType!)
                      .index) {
            throw StateError('cloud_sync_windows_write_request_changed');
          }
          return row;
        } finally {
          query.close();
        }
      }

      var intent = await fence.run(readIntent);
      CloudSyncNativeReceiptReplayBinding? replayBinding;
      if (replay && intent.state >= 1) {
        final binding = CloudSyncNativeReceiptReplayBinding(
          expectedAuth: auth,
          expectedState: this,
          expectedStore: store,
          expectedClient: client,
          expectedStoragePath: fs.appDocDir.path,
          readState: () => this,
          readStore: () => Database.store,
          readClient: readClient,
          readStoragePath: () => fs.appDocDir.path,
          runtimeCurrent: current,
        );
        replayBinding = binding;
        String? after;
        final cursors = <String>{};
        do {
          await fence.run<void>(binding.requireCurrent);
          final page = await api.cloudSyncReplayNativeSendReceipts(
            storageDirectory: fs.appDocDir.path,
            expectedAccountFingerprint: auth.accountFingerprint,
            expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
            afterReceiptId: after,
          );
          for (final receipt in page.receipts.where(
            (r) => r.guidHash == guidHash,
          )) {
            await fence.run(
              () => journal.recordNativeReceipt(
                intentId: intent.id,
                receipt: receipt,
                capturedAuth: auth,
                stillCurrent: current,
                now: DateTime.now().toUtc(),
                replayBinding: binding,
              ),
            );
            if (acceptedReceipt != null && acceptedReceipt != receipt) {
              throw StateError('cloud_sync_windows_mutation_receipt_changed');
            }
            acceptedReceipt = receipt;
          }
          after = page.nextCursor;
          if (after != null && !cursors.add(after)) {
            throw StateError(
              'cloud_sync_windows_mutation_receipt_cursor_repeated',
            );
          }
        } while (after != null);
        intent = await fence.run(readIntent);
      }
      if (intent.state < 2) {
        throw StateError(
          'cloud_sync_windows_mutation_send_unconfirmed_no_retry',
        );
      }
      final receipt = acceptedReceipt;
      if (intent.state == 5) {
        final terminalSource = journal.readTerminalSourceForCleanup(
          intentId: intent.id,
          currentAuth: auth,
          stillCurrent: current,
        );
        if (terminalSource == null) {
          throw StateError('cloud_sync_windows_mutation_terminal_changed');
        }
        await transport.acknowledgeCommittedPageLease(
          terminalSource.leaseReference,
        );
        if (receipt != null) {
          api.cloudSyncAcknowledgeNativeSendReceipt(
            storageDirectory: fs.appDocDir.path,
            expectedAccountFingerprint: auth.accountFingerprint,
            expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
            receipt: receipt,
          );
        }
        return {
          'native_send_confirmed': true,
          'mutation_receipt_present': receipt != null,
          'mutation_receipt_acknowledged': receipt != null,
          'restart_reconciliation_only': true,
          'cloudkit_update_enabled': true,
          'cloudkit_operation_status': CloudOutboxStatus.confirmed.name,
          'cloudkit_recovered_readbacks': 0,
          'cloudkit_reconciled_unknown': 0,
          'cloudkit_submitted': 0,
          'cloudkit_confirmed': 0,
          'cloudkit_not_applied': 0,
          'cloudkit_diverged': 0,
          'cloudkit_unresolved': 0,
          'local_reflection_complete': true,
        };
      }
      if (intent.state < 3) {
        if (receipt == null) {
          throw StateError(
            'cloud_sync_windows_mutation_retained_receipt_missing',
          );
        }
        final source = validateCloudSyncMutationRow(intent);
        await reportStage('windows-mutation-reflecting-confirmed-source');
        await staging.reflectConfirmed(
          intentId: intent.id,
          source: source,
          receipt: receipt,
          replayBinding: replayBinding,
          restore: (originalSource) => api.cloudSyncRestoreIdsMutationSource(
            cloudMessagesClient: client,
            context: api.CloudSyncNativeSendReceiptContext(
              storageDirectory: fs.appDocDir.path,
              guidHash: originalSource.mutationGuidHash,
              accountFingerprint: auth.accountFingerprint,
              protectedStoreIdentity: auth.protectedStoreIdentity,
              nativeSessionId: auth.nativeSessionId,
              sourceBinding: api.CloudSyncNativeSendSourceBinding(
                kind: api.CloudSyncNativeSendSourceKind.mutation,
                sourceSha256: originalSource.sourceSha256,
                protectedReference: originalSource.protectedReference,
                leaseReference: originalSource.leaseReference,
                payloadSha256: originalSource.payloadSha256,
                payloadLength: BigInt.from(originalSource.payloadLength),
              ),
            ),
          ),
        );
        intent = await fence.run(readIntent);
      }
      if (intent.state < 3) {
        throw StateError('cloud_sync_windows_mutation_reflection_incomplete');
      }

      final scope = CloudSyncScope(
        accountFingerprint: auth.accountFingerprint,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'messageManateeZone',
        streamKind: CloudSyncStreamKind.messages,
        schemaVersion: 2,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final admission = journal.readReflectedForUpdate(
        intentId: intent.id,
        currentAuth: auth,
        stillCurrent: current,
        replayBinding: replayBinding,
      );
      final pendingCreateReadbacks = await cloudStore
          .readPendingMessageCreateReadbacks(scope, maximumCount: 16);
      for (final snapshot in pendingCreateReadbacks) {
        await transport.finalizePendingMessageCreateReadback(
          snapshot,
          finalizeDurableReadback: (expected) =>
              cloudStore.finalizeMessageCreateReadbackLeases(
                expectedSnapshot: expected,
                createSourceLeaseCommitted: true,
                readbackLeaseCommitted: true,
              ),
        );
      }
      final predecessor = admission.requirePredecessor(
        store: store,
        messageScope: scope,
        readConfirmedLocalParent: (parent) =>
            createJournal.readConfirmedParentDependency(
              store,
              scope,
              parent,
              reflectedMutationValidated: admission.matchesReflectedParent(
                parent,
              ),
            ),
      );
      final executor = CloudSyncMessageUpdateExecutor(
        objectBoxStore: store,
        cloudStore: cloudStore,
        journal: journal,
        transport: transport,
        preparedSubmissionReleaser: transport,
        leaseTransport: transport,
        replayBinding: replayBinding,
        readConfirmedLocalParent: (parent) =>
            createJournal.readConfirmedParentDependency(
              store,
              scope,
              parent,
              reflectedMutationValidated: admission.matchesReflectedParent(
                parent,
              ),
            ),
      );
      late final CloudOutboxOperation admittedOperation;
      await reportStage('windows-mutation-running-cloudkit-update');
      final result = await interlock.runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: () async {
          // Restored read credentials do not imply warm read-only Messages,
          // Cuttlefish, or Securityd containers. Writer PCS preparation reads
          // those existing dependencies, so warm them under the native pause
          // before staging or reconciling. This performs no IDS mutation and
          // the pause is released before the writer crosses its remote edge.
          await identitySession.run<void>((_) async {});
          final adoptedOperationId = admission.adoptedOperationId;
          if (adoptedOperationId == null) {
            if (receipt == null) {
              throw StateError(
                'cloud_sync_windows_mutation_retained_receipt_missing',
              );
            }
            admittedOperation = await executor.admitReflectedUpdate(
              scope,
              source: admission,
              predecessor: predecessor,
              currentAuth: auth,
              stillCurrent: current,
              receipt: receipt,
            );
          } else {
            final exact = (await cloudStore.readOutboxEntries(scope))
                .where(
                  (operation) => operation.operationId == adoptedOperationId,
                )
                .toList(growable: false);
            if (exact.length != 1) {
              throw StateError('cloud_sync_message_update_adoption_missing');
            }
            admittedOperation = exact.single;
            final mapping = cloudSyncFindRecordMap(
              store: store,
              scope: scope,
              generation: predecessor.generation,
              logicalEntityKeyHash: admittedOperation.logicalEntityKeyHash,
              serverRecordIdHash: admittedOperation.serverRecordIdHash,
            );
            if (mapping == null) {
              throw StateError('cloud_sync_message_update_predecessor_missing');
            }
            journal.validateAdoptedOperation(store, admittedOperation, mapping);
          }
          return executor.runOnce(
            scope,
            currentAuth: auth,
            stillCurrent: current,
          );
        },
      );
      final exactOperations = (await cloudStore.readOutboxEntries(scope))
          .where(
            (operation) =>
                operation.operationId == admittedOperation.operationId,
          )
          .toList(growable: false);
      if (exactOperations.length != 1) {
        throw StateError('cloud_sync_message_update_adoption_missing');
      }
      final exactOperation = exactOperations.single;
      var receiptAcknowledged = false;
      if (exactOperation.status == CloudOutboxStatus.confirmed) {
        final confirmedSource = journal.markExactReadbackConfirmed(
          intentId: intent.id,
          operation: exactOperation,
          currentAuth: auth,
          stillCurrent: current,
          now: DateTime.now().toUtc(),
        );
        await transport.acknowledgeCommittedPageLease(
          confirmedSource.leaseReference,
        );
        if (receipt != null) {
          api.cloudSyncAcknowledgeNativeSendReceipt(
            storageDirectory: fs.appDocDir.path,
            expectedAccountFingerprint: auth.accountFingerprint,
            expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
            receipt: receipt,
          );
          receiptAcknowledged = true;
        }
      }
      return {
        'native_send_confirmed': true,
        'mutation_receipt_present': receipt != null,
        'mutation_receipt_acknowledged': receiptAcknowledged,
        'restart_reconciliation_only': replay,
        'cloudkit_update_enabled': true,
        'cloudkit_operation_status': exactOperation.status.name,
        'cloudkit_recovered_readbacks': result.recoveredReadbacks,
        'cloudkit_reconciled_unknown': result.reconciledUnknown,
        'cloudkit_submitted': result.submitted,
        'cloudkit_confirmed': result.confirmed,
        'cloudkit_not_applied': result.notApplied,
        'cloudkit_diverged': result.diverged,
        'cloudkit_unresolved': result.unresolved,
        'local_reflection_complete': intent.state >= 3,
      };
    } finally {
      await transport.quiesceNativeOperations();
    }
  }
}
