import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_origin.dart';
import 'cloud_sync_attachment_upload_journal.dart';
import 'cloud_sync_persistent_keys.dart';
import 'objectbox_cloud_sync_store.dart';
import 'objectbox_cloud_sync_preflight.dart';

/// One adapter-lifetime diagnostic selection. This grants no writer authority.
/// Message adoption requires durable intent linkage. A shared Chat create may
/// be recovered after restart only through its exact durable local origin and
/// the existing generation/map/envelope checks, never recipient matching alone.
final class CloudSyncLocalSendExactSelection {
  CloudSyncLocalSendExactSelection({
    required this.intentId,
    required this.expectedRecipient,
    required this.expectedSourceSha256,
  }) : expectedChatGuid = null, expectedMembers = null, expectedSender = null;

  CloudSyncLocalSendExactSelection.group({
    required this.intentId,
    required String this.expectedChatGuid,
    required List<String> expectedMembers,
    required String this.expectedSender,
    required this.expectedSourceSha256,
  }) : expectedRecipient = '',
       expectedMembers = List.unmodifiable(expectedMembers.toList()..sort());

  final int intentId;
  final String expectedRecipient;
  final String expectedSourceSha256;
  final String? expectedChatGuid;
  final List<String>? expectedMembers;
  final String? expectedSender;
  bool get isGroup => expectedChatGuid != null;
  String? _sourceBinding;
  int? _state;
  Store? _boundStore;
  String? _chatOperationId;
  String? _chatOperationBinding;
  String? _messageOperationBinding;
  final Map<String, String> _attachmentOperationBindings = {};
  final Map<String, String> _inertAuditRows = {};

  /// Only initial settled history or journal-proven held creates may be
  /// excluded from the diagnostic drain. Each row remains byte-for-byte pinned
  /// and is never acknowledged, reconciled or submitted by this selection.
  bool isInertAuditOperation(String operationId) =>
      _inertAuditRows.containsKey(operationId);

  bool matches({
    required int intentId,
    required String expectedRecipient,
    required String expectedSourceSha256,
  }) =>
      !isGroup && this.intentId == intentId &&
      this.expectedRecipient == expectedRecipient &&
      this.expectedSourceSha256 == expectedSourceSha256;

  bool matchesGroup({
    required int intentId,
    required String expectedChatGuid,
    required List<String> expectedMembers,
    required String expectedSender,
    required String expectedSourceSha256,
  }) => isGroup && this.intentId == intentId &&
      this.expectedChatGuid == expectedChatGuid &&
      this.expectedSender == expectedSender &&
      jsonEncode(this.expectedMembers) == jsonEncode(expectedMembers.toList()..sort()) &&
      this.expectedSourceSha256 == expectedSourceSha256;

  CloudSyncLocalSendAdmissionSource validate({
    required Store store,
    required CloudSyncLocalSendJournal journal,
    required ObjectBoxCloudSyncStore durable,
    required CloudSyncScope scope,
    // Optional per-pass upload journal proving attachment-zone ownership.
    // The selection is created before any per-pass journal exists and is
    // retained across passes, so the journal arrives here with current
    // per-pass authority instead of being captured at construction. Absent
    // means every attachment row is rejected; the Attachment zone is never
    // broadly admitted. Pinned attachment bindings live on the selection and
    // therefore persist across passes.
    CloudSyncAttachmentUploadJournal? uploadJournal,
  }) => store.runInTransaction(TxMode.read, () {
    if ((_boundStore != null && !identical(_boundStore, store)) ||
        !journal.isBoundToStore(store)) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    final source = isGroup ? journal.readExactGroupIntent(
      intentId: intentId,
      expectedChatGuid: expectedChatGuid!,
      expectedMembers: expectedMembers!,
      expectedSender: expectedSender!,
      expectedSourceSha256: expectedSourceSha256,
    ) : journal.readExactIntent(
      intentId: intentId,
      expectedRecipient: expectedRecipient,
      expectedSourceSha256: expectedSourceSha256,
    );
    final chat = source.message!.chat.target!;
    final binding = _digest([
      scope.storageKey,
      source.intentId,
      source.intentKey,
      source.accountFingerprint,
      source.writerEpoch,
      source.localMessageId,
      source.sourceSha256,
      source.messageGuidHash,
      source.createdAtUtc.millisecondsSinceEpoch,
      chat.id,
    ]);
    if (scope.accountFingerprint != source.accountFingerprint ||
        (_sourceBinding != null && _sourceBinding != binding) ||
        (_state == 2 && source.state != 2) ||
        (_state == 1 && source.state == 3)) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    // Inspect the whole store, not just the selected account's two queues.
    // Unrelated active work blocks. Initial settled history and pristine
    // pre-proof creates are pinned and excluded from every drain callback.
    String? inertFingerprint(CloudOutboxOperationEntity row) =>
        ObjectBoxCloudSyncPreflightReader.settledAuditFingerprint([row]) ??
        ObjectBoxCloudSyncPreflightReader.retainedPreproofAuditFingerprint(
          row,
          journal: journal,
        );
    final rows = store.box<CloudOutboxOperationEntity>().getAll();
    CloudOutboxOperationEntity? selectedChat;
    for (final row in rows) {
      final inert = _inertAuditRows[row.operationId];
      if (inert != null) {
        if (inertFingerprint(row) != inert) {
          throw StateError('cloud_sync_local_send_selection_changed');
        }
        continue;
      }
      if (_sourceBinding == null &&
          row.operationId != source.admittedOperationId) {
        final settled = inertFingerprint(row);
        if (settled != null) {
          _inertAuditRows[row.operationId] = settled;
          continue;
        }
      }
      if (row.operationId == source.admittedOperationId) {
        final operation = durable.readAdoptedLocalSendOperation(
          scope,
          journal: journal,
          source: source,
        );
        if (operation.operationId != row.operationId ||
            (_messageOperationBinding != null &&
                _messageOperationBinding != _outboxBinding(row))) {
          throw StateError('cloud_sync_local_send_selection_changed');
        }
      } else if (row.zone == 'chatManateeZone') {
        // Restored-group qualification may reuse a proven existing Chat, but
        // cannot authorize creating a different/provisional group or draining
        // an unrelated active direct-chat create.
        if (isGroup) {
          throw StateError('cloud_sync_local_send_unrelated_outbox');
        }
        final chatScope = CloudSyncScope(
          accountFingerprint: scope.accountFingerprint,
          container: scope.container,
          database: scope.database,
          zone: 'chatManateeZone',
          streamKind: scope.streamKind,
          schemaVersion: scope.schemaVersion,
          persistenceLane: scope.persistenceLane,
        );
        // Canonical projection preserves the original provisional GUID in
        // cloudGuid. Build only a transient identity view, never mutate Chat.
        final originalGuid = chat.guid.startsWith('iMessage;')
            ? chat.cloudGuid
            : chat.guid;
        if (originalGuid == null) {
          throw StateError('cloud_sync_local_send_unrelated_outbox');
        }
        final originView = Chat(
          id: chat.id,
          guid: originalGuid,
          chatIdentifier: expectedRecipient,
          usingHandle: chat.usingHandle,
          style: 45,
        )..handles.addAll(chat.handles);
        final origin = CloudSyncOutboundChatOrigin.capture(
          scope: chatScope,
          chat: originView,
        );
        if (selectedChat != null ||
            row.accountFingerprint != scope.accountFingerprint ||
            row.localChatOrigin == null ||
            cloudSyncOutboundChatOriginIdentity(row.localChatOrigin!) !=
                origin.binding(row.checkpointGeneration) ||
            (_chatOperationId != null && _chatOperationId != row.operationId) ||
            (_chatOperationBinding != null &&
                _chatOperationBinding != _outboxBinding(row))) {
          throw StateError('cloud_sync_local_send_selection_changed');
        }
        final operation = durable.readOutboundChatCreateForLocalRow(
          chatScope,
          chat.id!,
        );
        if (operation?.operationId != row.operationId) {
          throw StateError('cloud_sync_local_send_selection_changed');
        }
        selectedChat = row;
      } else if (row.zone == 'attachmentManateeZone') {
        // Attachment rows are never broadly admitted. Only an attachment
        // operation adopted from this exact selected original source passes,
        // proven through the per-pass upload journal below. Without a
        // journal every attachment row is unrelated work.
        final uploads = uploadJournal;
        if (uploads == null) {
          throw StateError('cloud_sync_local_send_unrelated_outbox');
        }
        _validateSelectedAttachmentRow(
          store,
          row,
          scope: scope,
          source: source,
          uploads: uploads,
        );
      } else {
        throw StateError('cloud_sync_local_send_unrelated_outbox');
      }
    }
    if (_inertAuditRows.keys.any(
          (id) => !rows.any((row) => row.operationId == id),
        ) ||
        (source.admittedOperationId != null &&
            !rows.any(
              (row) => row.operationId == source.admittedOperationId,
            )) ||
        (_chatOperationId != null &&
            !rows.any((row) => row.operationId == _chatOperationId)) ||
        _attachmentOperationBindings.keys.any(
          (id) => !rows.any((row) => row.operationId == id),
        )) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    _boundStore ??= store;
    _sourceBinding ??= binding;
    _state = source.state;
    if (selectedChat != null) {
      _chatOperationId ??= selectedChat.operationId;
      _chatOperationBinding ??= _outboxBinding(selectedChat);
    }
    if (source.admittedOperationId != null) {
      _messageOperationBinding ??= _outboxBinding(
        rows.singleWhere(
          (row) => row.operationId == source.admittedOperationId,
        ),
      );
    }
    return source;
  });

  // Admits one attachment-zone row only when the upload journal proves it
  // is the adopted final-save operation of an upload owned by this exact
  // selected intent. Ownership is the upload owner-intent linkage
  // (upload localSendIntentId equal to the selected intent id); integrity
  // is requireAdoptedOperation over the exact result bindings. No GUID
  // or body inference is consulted: a row without an adopted upload, an
  // upload owned by another intent, or a tampered child binding fails.
  void _validateSelectedAttachmentRow(
    Store store,
    CloudOutboxOperationEntity row, {
    required CloudSyncScope scope,
    required CloudSyncLocalSendAdmissionSource source,
    required CloudSyncAttachmentUploadJournal uploads,
  }) {
    // The expected attachment scope is derived from the validated message
    // scope, never trusted from the row or the journal. The persistent key
    // covers account, container, database, zone, stream, schema, and lane,
    // with explicit zone and account checks for a precise failure code.
    final attachmentScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'attachmentManateeZone',
      streamKind: scope.streamKind,
      schemaVersion: scope.schemaVersion,
      persistenceLane: scope.persistenceLane,
    );
    if (!uploads.isBoundTo(store, attachmentScope)) {
      throw StateError('cloud_sync_local_send_unrelated_outbox');
    }
    if (row.accountFingerprint != source.accountFingerprint ||
        row.accountFingerprint != attachmentScope.accountFingerprint ||
        row.zone != 'attachmentManateeZone' ||
        row.scopeKey != cloudSyncPersistentScopeKey(attachmentScope)) {
      throw StateError('cloud_sync_local_send_unrelated_outbox');
    }
    final query = store
        .box<CloudAttachmentUploadEntity>()
        .query(
          CloudAttachmentUploadEntity_.admittedOperationId.equals(
            row.operationId,
          ),
        )
        .build();
    final CloudAttachmentUploadEntity? upload;
    try {
      upload = query.findUnique();
    } finally {
      query.close();
    }
    if (upload == null || upload.localSendIntentId != source.intentId) {
      throw StateError('cloud_sync_local_send_unrelated_outbox');
    }
    uploads.requireAdoptedOperation(
      _attachmentDomainOperation(row, attachmentScope),
    );
    final binding = _outboxBinding(row);
    final pinned = _attachmentOperationBindings[row.operationId];
    if (pinned != null && pinned != binding) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    _attachmentOperationBindings[row.operationId] = binding;
  }

  static CloudOutboxOperation _attachmentDomainOperation(
    CloudOutboxOperationEntity row,
    CloudSyncScope scope,
  ) => CloudOutboxOperation(
    scope: scope,
    operationId: row.operationId,
    logicalEntityKeyHash: row.logicalEntityKeyHash,
    action: CloudOutboxAction.values[row.action],
    payloadVersion: row.payloadVersion,
    mutationRevision: row.mutationRevision,
    checkpointGeneration: row.checkpointGeneration,
    dependencyOperationIds:
        (jsonDecode(row.dependencyOperationIdsJson) as List)
            .whereType<String>(),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row.createdAtMs,
      isUtc: true,
    ),
    encryptedPayloadReference: row.encryptedPayloadRef,
    payloadSha256: row.payloadSha256,
    serverRecordIdHash: row.serverRecordIdHash,
    protectedLeaseReference: row.protectedLeaseReference,
    appleRequestUuid: row.appleRequestUuid,
    appleOperationUuid: row.appleOperationUuid,
    status: CloudOutboxStatus.values[row.state],
    attemptCount: row.attemptCount,
  );

  static String _outboxBinding(CloudOutboxOperationEntity row) => _digest([
    row.operationId, row.scopeKey, row.accountFingerprint, row.zone,
    row.logicalEntityKeyHash, row.action, row.payloadVersion,
    row.mutationRevision, row.checkpointGeneration, row.encryptedPayloadRef,
    row.payloadSha256, row.serverRecordIdHash, row.dependencyOperationIdsJson,
    row.createdAtMs, row.localChatOrigin == null ? null :
        cloudSyncActiveChatOriginBinding(row.localChatOrigin!),
    // Status, lease and receipt fields legitimately evolve under native guards.
  ]);

  static String _digest(List<Object?> values) =>
      sha256.convert(utf8.encode(jsonEncode(values))).toString();

  @override
  String toString() => 'CloudSyncLocalSendExactSelection(redacted)';
}
