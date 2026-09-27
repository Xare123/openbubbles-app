import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_protected_source_binding.dart';

/// Hashes in each owning journal's domain, not the historical GUID-hash domain.
/// Captured while the exact original GUID is available, then retained without
/// that GUID so dispatch after restart needs no scan of the Messages table.
/// This veto is deliberately not applied to unknown-outcome readback.
final class CloudSyncHistoricalLocalGuard {
  CloudSyncHistoricalLocalGuard._({
    required this.localSendGuidHash,
    required this.receivedGuidHash,
    required this.localMessageId,
    required this.localMessageSnapshot,
  });

  factory CloudSyncHistoricalLocalGuard.capture({
    required Store store,
    required CloudSyncHistoricalArchiveRequest request,
    required CloudSyncHistoricalProtectedSourceBinding source,
    required int localChatId,
  }) {
    source.requireOrigin(
      accountFingerprint: request.accountFingerprint,
      protectedStoreIdentity: request.protectedStoreIdentity,
      snapshotSha256: request.snapshotSha256,
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
    );
    if (_digest(['cloud-sync-historical-archive-guid-v1', request.guid]) !=
            source.messageGuidHash ||
        localChatId < 1) {
      throw StateError('cloud_sync_historical_local_source_changed');
    }
    final query =
        store.box<Message>().query(Message_.guid.equals(request.guid)).build()
          ..limit = 2;
    final List<Message> matches;
    try {
      matches = query.find();
    } finally {
      query.close();
    }
    if (matches.length > 1) {
      throw StateError('cloud_sync_historical_local_source_ambiguous');
    }
    final message = matches.isEmpty ? null : matches.single;
    if (message != null) {
      _resolveStoredSender(store, message);
      final chat = message.chat.target;
      if (chat == null ||
          message.chat.targetId != localChatId ||
          message.isFromMe != request.isFromMe ||
          message.text == null ||
          historicalTextDigest(message.text!) != request.textSha256 ||
          message.dateCreated?.millisecondsSinceEpoch !=
              request.dateCreatedMs) {
        throw StateError('cloud_sync_historical_local_source_changed');
      }
      // Compare to the qualified original without manufacturing a manifest
      // or inferring local account addresses from the remote peer.
      if (!historicalArchiveRowMatchesRequest(
        mapHistoricalRow(
          message: message,
          chat: mapHistoricalChat(chat),
          rowSnapshotSha256: source.snapshotSha256,
        ),
        request,
      )) {
        throw StateError('cloud_sync_historical_local_source_changed');
      }
    }
    final guard = CloudSyncHistoricalLocalGuard._(
      localSendGuidHash: _digest([
        'cloud-sync-local-send-guid-v1',
        request.guid,
      ]),
      receivedGuidHash: _digest([
        'cloud-sync-received-archive-guid-v1',
        request.guid,
      ]),
      localMessageId: message?.id ?? 0,
      localMessageSnapshot: message == null ? null : _messageSnapshot(message),
    );
    guard.requireUnchanged(
      store: store,
      source: source,
      localChatId: localChatId,
    );
    return guard;
  }

  final String localSendGuidHash;
  final String receivedGuidHash;
  final int localMessageId;
  final String? localMessageSnapshot;

  String encode() => jsonEncode(<Object?>[
    1,
    localSendGuidHash,
    receivedGuidHash,
    localMessageId,
    localMessageSnapshot,
  ]);

  static CloudSyncHistoricalLocalGuard decode(String encoded) {
    final dynamic value;
    try {
      if (encoded.length > 512) throw const FormatException();
      value = jsonDecode(encoded);
    } on FormatException {
      throw StateError('cloud_sync_historical_local_guard_invalid');
    }
    final hash = RegExp(r'^[a-f0-9]{64}$');
    if (value is! List ||
        value.length != 5 ||
        value[0] != 1 ||
        value[1] is! String ||
        !hash.hasMatch(value[1] as String) ||
        value[2] is! String ||
        !hash.hasMatch(value[2] as String) ||
        value[3] is! int ||
        (value[3] as int) < 0 ||
        ((value[3] == 0) != (value[4] == null)) ||
        (value[4] != null &&
            (value[4] is! String || !hash.hasMatch(value[4] as String)))) {
      throw StateError('cloud_sync_historical_local_guard_invalid');
    }
    final guard = CloudSyncHistoricalLocalGuard._(
      localSendGuidHash: value[1] as String,
      receivedGuidHash: value[2] as String,
      localMessageId: value[3] as int,
      localMessageSnapshot: value[4] as String?,
    );
    if (guard.encode() != encoded) {
      throw StateError('cloud_sync_historical_local_guard_invalid');
    }
    return guard;
  }

  void requireUnchanged({
    required Store store,
    required CloudSyncHistoricalProtectedSourceBinding source,
    required int localChatId,
  }) {
    bool exists<T>(QueryBuilder<T> builder) {
      final query = builder.build()..limit = 1;
      try {
        return query.findFirst() != null;
      } finally {
        query.close();
      }
    }

    // Account indexes bound these lookups; GUID fields in the existing journals
    // are not all individually indexed. Do not describe these as index-only.
    if (exists(
          store.box<CloudSyncLocalSendIntentEntity>().query(
            CloudSyncLocalSendIntentEntity_.accountFingerprint
                .equals(source.accountFingerprint)
                .and(
                  CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
                    localSendGuidHash,
                  ),
                ),
          ),
        ) ||
        exists(
          store.box<CloudSyncReceivedArchiveIntentEntity>().query(
            CloudSyncReceivedArchiveIntentEntity_.accountFingerprint
                .equals(source.accountFingerprint)
                .and(
                  CloudSyncReceivedArchiveIntentEntity_.messageGuidHash.equals(
                    receivedGuidHash,
                  ),
                ),
          ),
        ) ||
        exists(
          store.box<CloudSyncLocalMutationIntentEntity>().query(
            CloudSyncLocalMutationIntentEntity_.accountFingerprint
                .equals(source.accountFingerprint)
                .and(
                  CloudSyncLocalMutationIntentEntity_.targetGuidHash.equals(
                    localSendGuidHash,
                  ),
                ),
          ),
        )) {
      throw StateError('cloud_sync_historical_existing_origin_or_mutation');
    }
    if (localMessageId != 0) {
      final current = store.box<Message>().get(localMessageId);
      if (current != null) _resolveStoredSender(store, current);
      if (current == null ||
          current.chat.targetId != localChatId ||
          current.guid == null ||
          _digest(['cloud-sync-historical-archive-guid-v1', current.guid]) !=
              source.messageGuidHash ||
          _messageSnapshot(current) != localMessageSnapshot) {
        throw StateError('cloud_sync_historical_local_source_changed');
      }
    }
  }

  // Message.handle is a transient cache. Always resolve the persisted exact
  // handleId, and do not use a cached value or mutable Chat.usingHandle instead.
  static void _resolveStoredSender(Store store, Message message) {
    final handleId = message.handleId;
    if (handleId == null || handleId <= 0) {
      throw StateError('cloud_sync_historical_local_sender_missing');
    }
    final query =
        store
            .box<Handle>()
            .query(Handle_.originalROWID.equals(handleId))
            .build()
          ..limit = 2;
    try {
      final matches = query.find();
      if (matches.length != 1) {
        throw StateError('cloud_sync_historical_local_sender_ambiguous');
      }
      message.handle = matches.single;
    } finally {
      query.close();
    }
  }

  static String _messageSnapshot(Message message) => _digest([
    'historical-local-row-v1',
    message.id,
    message.guid,
    message.chat.targetId,
    message.isFromMe,
    message.text,
    message.handleId,
    message.handle?.address,
    message.dateCreated?.millisecondsSinceEpoch,
    message.dateEdited?.millisecondsSinceEpoch,
    message.dateDeleted?.millisecondsSinceEpoch,
    message.error,
    message.temp,
    message.verificationFailed,
    message.stagingGuid,
    message.sendingServiceId,
    message.hasBeenForwarded,
    message.ckRecordId,
    message.ckSyncState,
    message.itemType,
    message.groupActionType,
    message.groupTitle,
    message.dateScheduled?.millisecondsSinceEpoch,
    message.threadOriginatorGuid,
    message.threadOriginatorPart,
    message.associatedMessageGuid,
    message.associatedMessagePart,
    message.associatedMessageType,
    message.associatedMessageEmoji,
    message.hasAttachments,
    message.subject,
    message.expressiveSendStyleId,
    message.balloonBundleId,
    message.payloadData != null,
    message.hasApplePayloadData,
    message.amkSessionId,
    message.attributedBody.map((part) => part.toMap()).toList(),
    message.messageSummaryInfo.map((info) => info.toJson()).toList(),
    message.dbAttachments
        .map((attachment) => [attachment.id, attachment.guid])
        .toList(),
  ]);

  static Object? _canonical(Object? value) {
    if (value is List) return value.map(_canonical).toList();
    if (value is Map<String, dynamic>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    return value;
  }

  static String _digest(List<Object?> fields) =>
      sha256.convert(utf8.encode(jsonEncode(_canonical(fields)))).toString();

  @override
  String toString() => 'CloudSyncHistoricalLocalGuard(redacted)';
}
