// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

import 'cloud_operation_identity.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

/// Immutable local send identity. Raw routing/content never leaves this
/// capture; the raw GUID is retained in memory only for exact revalidation.
final class CloudSyncLocalSendIdentity {
  const CloudSyncLocalSendIdentity._(
    this._guid,
    this.guidHash,
    this.sourceSha256,
  );

  final String _guid;
  final String guidHash;
  final String sourceSha256;

  static CloudSyncLocalSendIdentity? capture(
    Message message,
    Chat chat,
    String stableGuid,
  ) {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(stableGuid)) {
      return null;
    }
    if (message.isFromMe != true ||
        message.ckRecordId != null ||
        message.ckSyncState == true ||
        message.temp ||
        message.hasBeenForwarded ||
        message.verificationFailed ||
        message.dateCreated == null ||
        message.dateScheduled != null ||
        message.dateDeleted != null ||
        message.dateEdited != null ||
        message.subject?.isNotEmpty == true ||
        message.hasAttachments ||
        message.attachments.isNotEmpty ||
        message.dbAttachments.isNotEmpty ||
        message.messageSummaryInfo.isNotEmpty ||
        message.associatedMessageGuid != null ||
        message.associatedMessagePart != null ||
        message.associatedMessageType != null ||
        message.associatedMessageEmoji != null ||
        message.sendingServiceId != null ||
        message.threadOriginatorGuid != null ||
        message.threadOriginatorPart != null ||
        message.expressiveSendStyleId != null ||
        message.balloonBundleId != null ||
        message.payloadData != null ||
        message.hasApplePayloadData ||
        message.metadata != null ||
        message.amkSessionId != null ||
        (message.itemType ?? 0) != 0 ||
        (message.groupActionType ?? 0) != 0 ||
        message.groupTitle != null) {
      return null;
    }
    final text = message.text;
    if (text == null ||
        text.trim().isEmpty ||
        message.attributedBody.length != 1) {
      return null;
    }
    final body = message.attributedBody.single;
    if (body.string != text || body.runs.isEmpty) return null;
    var end = 0;
    for (final run in body.runs) {
      final attributes = run.attributes;
      if (run.range.length != 2 ||
          run.range.first != end ||
          run.range.last <= 0 ||
          attributes == null ||
          attributes.messagePart != 0 ||
          attributes.attachmentGuid != null ||
          attributes.mention != null ||
          attributes.audioTranscript != null ||
          attributes.stickerData != null ||
          attributes.textEffect != null ||
          attributes.bold == true ||
          attributes.italic == true ||
          attributes.strikethrough == true ||
          attributes.underline == true) {
        return null;
      }
      end += run.range.last;
      if (end > text.length) return null;
    }
    if (end != text.length ||
        chat.style != 45 ||
        chat.isRpSms ||
        chat.isRoutingStub ||
        chat.usingHandle?.isNotEmpty != true ||
        chat.chatIdentifier?.isNotEmpty != true) {
      return null;
    }
    final participants = chat.handles.toList(growable: false);
    if (participants.length != 1 ||
        participants.single.service != 'iMessage' ||
        participants.single.address != chat.chatIdentifier ||
        chat.guid != 'iMessage;-;${chat.chatIdentifier}') {
      return null;
    }

    // Read/delivery receipts, a reaction to this message and server timestamp
    // normalization do not change the text that this device submitted.
    return CloudSyncLocalSendIdentity._(
      stableGuid,
      _digest(['cloud-sync-local-send-guid-v1', stableGuid]),
      _digest([
        'cloud-sync-local-send-source-v1',
        stableGuid,
        text,
        chat.guid,
        chat.chatIdentifier,
        chat.usingHandle,
      ]),
    );
  }

  static String _digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  /// Validate the actual IDS payload, not only the mutable local model. Wire
  /// construction and retries can await network work while that model changes.
  /// This is entirely local inspection of Dart fields, with no native calls.
  static CloudSyncLocalSendIdentity? captureWire(
    Message message,
    Chat chat,
    api.MessageInst wire,
  ) {
    final identity = capture(message, chat, wire.id);
    if (identity == null ||
        wire.verificationFailed ||
        wire.target != null ||
        wire.sender != chat.usingHandle ||
        wire.message is! api.Message_Message) {
      return null;
    }
    final normal = (wire.message as api.Message_Message).field0;
    if (normal.service is! api.MessageType_IMessage ||
        normal.effect != null ||
        normal.replyGuid != null ||
        normal.replyPart != null ||
        normal.subject?.isNotEmpty == true ||
        normal.app != null ||
        normal.linkMeta != null ||
        normal.voice ||
        normal.scheduled != null ||
        normal.parts.field0.isEmpty) {
      return null;
    }
    final text = StringBuffer();
    for (final indexed in normal.parts.field0) {
      final part = indexed.part_;
      if (indexed.ext != null ||
          (indexed.idx != null && indexed.idx != 0) ||
          part is! api.MessagePart_Text ||
          part.field1 is! api.TextFormat_Flags) {
        return null;
      }
      final flags = (part.field1 as api.TextFormat_Flags).field0;
      if (flags.bold ||
          flags.italic ||
          flags.underline ||
          flags.strikethrough) {
        return null;
      }
      text.write(part.field0);
    }
    final recipient = chat.chatIdentifier!;
    final expectedParticipants = [
      '${recipient.contains('@') ? 'mailto' : 'tel'}:$recipient',
      chat.usingHandle!,
    ]..sort();
    final conversation = wire.conversation;
    final actualParticipants = conversation?.participants.toList()?..sort();
    if (text.toString() != message.text ||
        conversation?.senderGuid != chat.guid ||
        jsonEncode(actualParticipants) != jsonEncode(expectedParticipants)) {
      return null;
    }
    return identity;
  }

  /// A UUID from this invocation is necessary but not sufficient: a restored
  /// row can also be re-sent. Only the unsent local temporary-GUID path creates
  /// new origin; stable-GUID retries must already have a durable intent.
  static bool isFreshLocalSubmission(
    Message message, {
    required String generatedGuid,
    required String stableGuid,
  }) =>
      generatedGuid == stableGuid &&
      message.stagingGuid == null &&
      message.dateScheduled == null &&
      message.ckRecordId == null &&
      message.ckSyncState != true &&
      RegExp(r'^temp-[A-Za-z0-9]{8}$').hasMatch(message.guid ?? '');

  @override
  String toString() => 'CloudSyncLocalSendIdentity(redacted)';
}

/// Revalidates native account, client generation and keystore identity before
/// synchronous local persistence. Dart object identity alone is insufficient.
/// This grants no remote mutation capability and performs no network warmup.
final class CloudSyncLocalSendAuthFence {
  const CloudSyncLocalSendAuthFence({
    required CloudSyncNativeAuthSnapshot expected,
    required CloudSyncNativeAuthSnapshotReader capture,
    required bool Function() stillCurrent,
  }) : _expected = expected,
       _capture = capture,
       _stillCurrent = stillCurrent;

  final CloudSyncNativeAuthSnapshot _expected;
  final CloudSyncNativeAuthSnapshotReader _capture;
  final bool Function() _stillCurrent;

  Future<T> run<T>(T Function() persist, {String? accountFingerprint}) async {
    if (!_stillCurrent() ||
        (accountFingerprint != null &&
            accountFingerprint != _expected.accountFingerprint)) {
      throw StateError('cloud_sync_local_send_identity_changed');
    }
    final current = await _capture();
    if (!_expected.sameIdentity(current) || !_stillCurrent()) {
      throw StateError('cloud_sync_local_send_identity_changed');
    }
    return persist();
  }
}

/// Local-only journal. It cannot create an outbox row or contact CloudKit.
/// The caller's synchronous persistence callback and this journal share one
/// ObjectBox transaction. The persisted message is re-read before acceptance.
final class CloudSyncLocalSendJournal {
  CloudSyncLocalSendJournal({
    required Store store,
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitWriterAuthoritySnapshot authoritySnapshot,
  }) : _store = store,
       _authority = authority,
       _binding = authoritySnapshot,
       _intents = store.box<CloudSyncLocalSendIntentEntity>(),
       _messages = store.box<Message>() {
    if (!authority.isBoundToStore(store)) {
      throw StateError('cloud_sync_local_send_authority_store_mismatch');
    }
  }

  final Store _store;
  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitWriterAuthoritySnapshot _binding;
  final Box<CloudSyncLocalSendIntentEntity> _intents;
  final Box<Message> _messages;

  bool isBoundToStore(Store store) => identical(store, _store);

  /// A retry may re-use an existing intent, but cannot invent local origin for
  /// a GUID that predated this journal. Only the fresh IDS GUID path may create.
  void saveSubmission({
    required CloudSyncLocalSendIdentity identity,
    required bool newlyGeneratedGuid,
    required int Function() persistMessage,
    required DateTime now,
  }) => _save(
    identity,
    persistMessage,
    now,
    newlyGeneratedGuid: newlyGeneratedGuid,
    confirmed: false,
  );

  /// Call only after the matching IDS send future succeeds. A failed or
  /// interrupted send never advances the durable intent to ready.
  void saveConfirmedSubmission({
    required CloudSyncLocalSendIdentity identity,
    required int Function() persistMessage,
    required DateTime now,
  }) => _save(
    identity,
    persistMessage,
    now,
    newlyGeneratedGuid: false,
    confirmed: true,
  );

  void _save(
    CloudSyncLocalSendIdentity identity,
    int Function() persistMessage,
    DateTime now, {
    required bool newlyGeneratedGuid,
    required bool confirmed,
  }) {
    _store.runInTransaction(TxMode.write, () {
      _verifyLocalOwnership();
      if (!now.isUtc || now.millisecondsSinceEpoch <= 0) {
        throw StateError('cloud_sync_local_send_time_invalid');
      }
      final key = CloudSyncLocalSendIdentity._digest([
        'cloud-sync-local-send-intent-v1',
        _binding.scope.accountFingerprint,
        identity.guidHash,
      ]);
      final query = _intents
          .query(CloudSyncLocalSendIntentEntity_.intentKey.equals(key))
          .build();
      final CloudSyncLocalSendIntentEntity? previous;
      try {
        previous = query.findUnique();
      } finally {
        query.close();
      }
      if (previous == null && (!newlyGeneratedGuid || confirmed)) {
        throw StateError('cloud_sync_local_send_origin_missing');
      }
      if (previous != null &&
          (previous.accountFingerprint != _binding.scope.accountFingerprint ||
              previous.writerEpoch != _binding.epoch ||
              previous.messageGuidHash != identity.guidHash ||
              previous.sourceSha256 != identity.sourceSha256 ||
              previous.state < 0 ||
              previous.state > 2 ||
              !_hasConsistentAdoption(previous))) {
        throw StateError('cloud_sync_local_send_intent_changed');
      }
      final messageId = persistMessage();
      final saved = messageId > 0 ? _messages.get(messageId) : null;
      final chat = saved?.chat.target;
      final actual = saved == null || chat == null
          ? null
          : CloudSyncLocalSendIdentity.capture(saved, chat, identity._guid);
      if (actual == null ||
          actual.sourceSha256 != identity.sourceSha256 ||
          (confirmed
              ? saved!.guid != identity._guid || saved.stagingGuid != null
              : saved!.stagingGuid != identity._guid)) {
        throw StateError('cloud_sync_local_send_source_changed');
      }
      final intent =
          previous ??
          CloudSyncLocalSendIntentEntity(
            intentKey: key,
            accountFingerprint: _binding.scope.accountFingerprint,
            writerEpoch: _binding.epoch,
            localMessageId: messageId,
            messageGuidHash: identity.guidHash,
            sourceSha256: identity.sourceSha256,
            createdAtMs: now.millisecondsSinceEpoch,
            updatedAtMs: now.millisecondsSinceEpoch,
          );
      intent.localMessageId = messageId;
      if (confirmed && intent.state == 0) intent.state = 1;
      intent.updatedAtMs = now.millisecondsSinceEpoch;
      _intents.put(intent);
    });
  }

  List<CloudSyncLocalSendIntentEntity> readReady({int limit = 50}) {
    if (limit < 1 || limit > 50) {
      throw ArgumentError('cloud_sync_local_send_limit_invalid');
    }
    return _store.runInTransaction(TxMode.read, () {
      _verifyLocalOwnership();
      final query =
          _intents
              .query(
                CloudSyncLocalSendIntentEntity_.accountFingerprint
                    .equals(_binding.scope.accountFingerprint)
                    .and(
                      CloudSyncLocalSendIntentEntity_.writerEpoch.equals(
                        _binding.epoch,
                      ),
                    )
                    .and(CloudSyncLocalSendIntentEntity_.state.equals(1)),
              )
              .order(CloudSyncLocalSendIntentEntity_.id)
              .build()
            ..limit = limit;
      try {
        return query.find();
      } finally {
        query.close();
      }
    });
  }

  /// Reconstruct only from an existing journaled origin, never by scanning
  /// Message.isFromMe. An adopted intent does not need its mutable message
  /// anymore: the outbox's original protected envelope is authoritative.
  CloudSyncLocalSendAdmissionSource readForAdmission(int intentId) =>
      _store.runInTransaction(TxMode.read, () {
        _verifyLocalOwnership();
        final intent = _readBoundIntent(intentId);
        if (intent.state != 1 && intent.state != 2) {
          throw StateError('cloud_sync_local_send_not_ready');
        }
        final message = intent.state == 1 ? _validatedMessage(intent) : null;
        return CloudSyncLocalSendAdmissionSource._(intent, message);
      });

  /// A fresh-create scheduling exception needs both durable origin and a
  /// currently stable V2 owner. Journaling itself intentionally needs less:
  /// an earlier unknown write must not prevent recording a new IDS send.
  void validateReadyForCreate(
    Store transactionStore,
    CloudSyncScope scope,
    CloudSyncLocalSendAdmissionSource expected,
  ) => _store.runInTransaction(TxMode.read, () {
    _requireCreateAuthority(transactionStore, scope);
    final intent = _readBoundIntent(expected.intentId);
    if (intent.state != 1 || !expected._matches(intent)) {
      throw StateError('cloud_sync_local_send_not_ready');
    }
    _validatedMessage(intent);
  });

  /// Resolve explicit adoption, never origin inferred from an outgoing row.
  /// The immutable envelope binding survives restart and receipt transitions.
  /// No match means the ordinary, fully-projected writer gate still applies.
  CloudSyncLocalSendAdmissionSource? readAdoptedCreateSource(
    Store transactionStore,
    CloudOutboxOperation operation,
  ) => _store.runInTransaction(TxMode.read, () {
    if (!identical(transactionStore, _store)) {
      throw StateError('cloud_sync_local_send_adoption_store_mismatch');
    }
    final query = _intents
        .query(CloudSyncLocalSendIntentEntity_.admittedOperationId
            .equals(operation.operationId))
        .build();
    final CloudSyncLocalSendIntentEntity? intent;
    try {
      intent = query.findUnique();
    } finally {
      query.close();
    }
    if (intent == null) return null;
    _requireCreateAuthority(transactionStore, operation.scope);
    final source = CloudSyncLocalSendAdmissionSource._(intent, null);
    validateAdoptedOperation(transactionStore, source, operation);
    if (operation.operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: operation.scope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              payloadVersion: operation.payloadVersion,
            ) ||
        operation.dependencyOperationIds.isNotEmpty) {
      throw StateError('cloud_sync_local_send_adopted_operation_missing');
    }
    return source;
  });

  void _requireCreateAuthority(Store transactionStore, CloudSyncScope scope) {
    if (!identical(transactionStore, _store)) {
      throw StateError('cloud_sync_local_send_adoption_store_mismatch');
    }
    if (scope.accountFingerprint != _binding.scope.accountFingerprint ||
        scope.container != _binding.scope.container ||
        scope.database != _binding.scope.database ||
        scope.zone != 'messageManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != cloudSyncSchemaVersion ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw StateError('cloud_sync_local_send_scope_invalid');
    }
    _verifyLocalOwnership();
    final permit = _authority.issuePermit(
      _binding.scope,
      expectedOwner: CloudKitWriterOwner.v2,
    );
    if (permit.epoch != _binding.epoch) {
      throw StateError('cloud_sync_local_send_owner_changed');
    }
  }

  /// Called synchronously inside this exact Store's outbox write transaction.
  /// Throwing rejects both adoption and the journal transition together.
  void adoptInOutboxTransaction(
    Store transactionStore,
    CloudSyncLocalSendAdmissionSource expected,
    CloudOutboxOperation operation,
  ) {
    if (!identical(transactionStore, _store)) {
      throw StateError('cloud_sync_local_send_adoption_store_mismatch');
    }
    _verifyLocalOwnership();
    final intent = _readBoundIntent(expected.intentId);
    if (!expected._matches(intent) ||
        intent.state != 1 ||
        operation.scope.accountFingerprint != intent.accountFingerprint ||
        operation.scope.container != _binding.scope.container ||
        operation.scope.database != _binding.scope.database ||
        operation.scope.zone != 'messageManateeZone' ||
        operation.scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncOutboundPayloadVersion ||
        operation.status != CloudOutboxStatus.pending ||
        operation.attemptCount != 0 ||
        operation.operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: operation.scope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              payloadVersion: operation.payloadVersion,
            ) ||
        operation.createdAt.millisecondsSinceEpoch != intent.createdAtMs) {
      throw StateError('cloud_sync_local_send_adoption_changed');
    }
    _validatedMessage(intent);
    intent
      ..state = 2
      ..admittedOperationId = operation.operationId
      ..admittedBindingSha256 = _operationBinding(operation);
    _intents.put(intent);
  }

  void validateAdoptedOperation(
    Store transactionStore,
    CloudSyncLocalSendAdmissionSource expected,
    CloudOutboxOperation? operation,
  ) => _store.runInTransaction(TxMode.read, () {
    if (!identical(transactionStore, _store)) {
      throw StateError('cloud_sync_local_send_adoption_store_mismatch');
    }
    _verifyLocalOwnership();
    final intent = _readBoundIntent(expected.intentId);
    if (!expected._matches(intent) ||
        intent.state != 2 ||
        operation == null ||
        operation.operationId != intent.admittedOperationId ||
        operation.scope.accountFingerprint != intent.accountFingerprint ||
        operation.scope.container != _binding.scope.container ||
        operation.scope.database != _binding.scope.database ||
        operation.scope.zone != 'messageManateeZone' ||
        operation.scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncOutboundPayloadVersion ||
        intent.admittedBindingSha256 != _operationBinding(operation) ||
        operation.createdAt.millisecondsSinceEpoch != intent.createdAtMs) {
      throw StateError('cloud_sync_local_send_adopted_operation_missing');
    }
  });

  CloudSyncLocalSendIntentEntity _readBoundIntent(int intentId) {
    final intent = intentId > 0 ? _intents.get(intentId) : null;
    if (intent == null ||
        intent.accountFingerprint != _binding.scope.accountFingerprint ||
        intent.writerEpoch != _binding.epoch ||
        intent.state < 0 ||
        intent.state > 2 ||
        !_hasConsistentAdoption(intent) ||
        intent.intentKey !=
            CloudSyncLocalSendIdentity._digest([
              'cloud-sync-local-send-intent-v1',
              intent.accountFingerprint,
              intent.messageGuidHash,
            ])) {
      throw StateError('cloud_sync_local_send_intent_changed');
    }
    return intent;
  }

  static bool _hasConsistentAdoption(CloudSyncLocalSendIntentEntity intent) =>
      intent.state == 2
      ? intent.admittedOperationId != null &&
            RegExp(
              r'^[0-9a-f]{64}$',
            ).hasMatch(intent.admittedBindingSha256 ?? '')
      : intent.admittedOperationId == null &&
            intent.admittedBindingSha256 == null;

  static String _operationBinding(CloudOutboxOperation operation) =>
      CloudSyncLocalSendIdentity._digest([
        'cloud-sync-local-send-adoption-v1',
        operation.scope.storageKey, operation.operationId,
        operation.logicalEntityKeyHash, operation.action.name,
        operation.payloadVersion, operation.mutationRevision,
        operation.checkpointGeneration, operation.encryptedPayloadReference,
        operation.payloadSha256, operation.serverRecordIdHash,
        operation.dependencyOperationIds.toList()..sort(),
        operation.createdAt.millisecondsSinceEpoch,
        // Lease/receipt/status fields legitimately change on confirmation.
        // Native recovery and submission still validate the live lease itself.
      ]);

  Message _validatedMessage(CloudSyncLocalSendIntentEntity intent) {
    final message = _messages.get(intent.localMessageId);
    final chat = message?.chat.target;
    final guid = message?.guid;
    final identity =
        message == null ||
            chat == null ||
            guid == null ||
            message.stagingGuid != null
        ? null
        : CloudSyncLocalSendIdentity.capture(message, chat, guid);
    if (identity == null ||
        identity.guidHash != intent.messageGuidHash ||
        identity.sourceSha256 != intent.sourceSha256) {
      throw StateError('cloud_sync_local_send_source_changed');
    }
    return message!;
  }

  void _verifyLocalOwnership() {
    if (_binding.owner != CloudKitWriterOwner.v2 ||
        _binding.epoch <= 0 ||
        _binding.scope.container != 'com.apple.messages.cloud' ||
        _binding.scope.database != 'private') {
      throw StateError('cloud_sync_local_send_owner_invalid');
    }
    final current = _authority.read(_binding.scope);
    if (current == null ||
        current.owner != _binding.owner ||
        current.epoch != _binding.epoch) {
      throw StateError('cloud_sync_local_send_owner_changed');
    }
    // An unresolved earlier remote mutation may fence uploads, but it must
    // not prevent journaling a new local send. This grants no writer permit.
  }
}

/// Immutable admission binding. Only the journal can construct one. The
/// mutable Message is used for first encoding only and re-read at adoption.
final class CloudSyncLocalSendAdmissionSource {
  CloudSyncLocalSendAdmissionSource._(
    CloudSyncLocalSendIntentEntity intent,
    this.message,
  ) : intentId = intent.id,
      intentKey = intent.intentKey,
      localMessageId = intent.localMessageId,
      accountFingerprint = intent.accountFingerprint,
      writerEpoch = intent.writerEpoch,
      sourceSha256 = intent.sourceSha256,
      messageGuidHash = intent.messageGuidHash,
      admittedOperationId = intent.admittedOperationId,
      admittedBindingSha256 = intent.admittedBindingSha256,
      state = intent.state,
      createdAtUtc = DateTime.fromMillisecondsSinceEpoch(
        intent.createdAtMs,
        isUtc: true,
      );

  final int intentId;
  final String intentKey;
  final int localMessageId;
  final String accountFingerprint;
  final int writerEpoch;
  final String sourceSha256;
  final String messageGuidHash;
  final String? admittedOperationId;
  final String? admittedBindingSha256;
  final int state;
  final DateTime createdAtUtc;
  final Message? message;

  bool _matches(CloudSyncLocalSendIntentEntity intent) =>
      intentId == intent.id &&
      intentKey == intent.intentKey &&
      localMessageId == intent.localMessageId &&
      accountFingerprint == intent.accountFingerprint &&
      writerEpoch == intent.writerEpoch &&
      sourceSha256 == intent.sourceSha256 &&
      messageGuidHash == intent.messageGuidHash &&
      state == intent.state &&
      admittedOperationId == intent.admittedOperationId &&
      admittedBindingSha256 == intent.admittedBindingSha256 &&
      createdAtUtc.millisecondsSinceEpoch == intent.createdAtMs;

  @override
  String toString() => 'CloudSyncLocalSendAdmissionSource(redacted)';
}
