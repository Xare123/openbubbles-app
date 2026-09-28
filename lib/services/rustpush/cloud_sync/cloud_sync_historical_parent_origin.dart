import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_chat_identity_origin.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_chat_origin.dart';
import 'cloud_sync_models.dart';

/// Ephemeral source owner for the ordinary Chat identity/admission gate. The
/// durable codec pins the committed snapshot, not a mutable Message or IDS send.
/// A missing destination Chat is valid: only confirmed reader projection may
/// create it. This object never fabricates a row to satisfy local-send checks.
final class CloudSyncHistoricalParentOrigin
    implements CloudSyncChatIdentityOrigin {
  CloudSyncHistoricalParentOrigin._({
    required Store store,
    required CloudSyncHistoricalArchiveJournal journal,
    required this.scope,
    required this.request,
    required this.durable,
  }) : // Named arguments make ownership explicit without exposing fields.
       // ignore: prefer_initializing_formals
       _store = store,
       // ignore: prefer_initializing_formals
       _journal = journal;

  factory CloudSyncHistoricalParentOrigin.capture({
    required Store store,
    required CloudSyncHistoricalArchiveJournal journal,
    required CloudSyncScope scope,
    required int generation,
    required CloudSyncHistoricalArchiveRequest request,
    required int intentId,
    required int? localChatId,
    required int parentPayloadLength,
  }) {
    final intent = journal.read(
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
    );
    if (intent == null || intent.id != intentId) {
      throw StateError('cloud_sync_historical_chat_source_changed');
    }
    final result = CloudSyncHistoricalParentOrigin._(
      store: store,
      journal: journal,
      scope: scope,
      request: request,
      durable: CloudSyncHistoricalChatOrigin(
        generation: generation,
        intentId: intentId,
        localChatId: localChatId,
        sourceChatGuidSha256: _chatDigest(request.chatGuid),
        source: intent.source,
        parentPayloadLength: parentPayloadLength,
      ),
    );
    result.requireUnchanged(store);
    return result;
  }

  /// Recreate transient checks from the originally adopted binding, never from
  /// another message's equivalent group metadata or a newly staged envelope.
  factory CloudSyncHistoricalParentOrigin.reopen({
    required Store store,
    required CloudSyncHistoricalArchiveJournal journal,
    required CloudSyncScope scope,
    required CloudSyncHistoricalArchiveRequest request,
    required CloudSyncHistoricalChatOrigin durable,
  }) {
    final result = CloudSyncHistoricalParentOrigin._(
      store: store,
      journal: journal,
      scope: scope,
      request: request,
      durable: durable,
    );
    result.requireUnchanged(store);
    return result;
  }

  final Store _store;
  final CloudSyncHistoricalArchiveJournal _journal;
  @override
  final CloudSyncScope scope;
  final CloudSyncHistoricalArchiveRequest request;
  final CloudSyncHistoricalChatOrigin durable;

  @override
  String binding(int generation) {
    if (generation != durable.generation) {
      throw StateError('cloud_sync_historical_chat_generation_changed');
    }
    return durable.encode();
  }

  @override
  void requireUnchanged(Store store) {
    if (!identical(_store, store) ||
        !_journal.isBoundToStore(store) ||
        scope.accountFingerprint != request.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'chatManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != 2 ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        request.parentState == null ||
        durable.sourceChatGuidSha256 != _chatDigest(request.chatGuid)) {
      throw StateError('cloud_sync_historical_chat_source_changed');
    }
    durable.source.requireOrigin(
      accountFingerprint: request.accountFingerprint,
      protectedStoreIdentity: request.protectedStoreIdentity,
      snapshotSha256: request.snapshotSha256,
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
    );
    final intent = _journal.read(
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
    );
    if (intent == null ||
        intent.id != durable.intentId ||
        !intent.sourceLeaseCommitted ||
        intent.readerChangeId != null ||
        intent.source.encode() != durable.source.encode()) {
      throw StateError('cloud_sync_historical_chat_source_changed');
    }
    final query =
        store
            .box<Chat>()
            .query(
              Chat_.guid
                  .equals(request.chatGuid)
                  .or(
                    Chat_.cloudGuid.equals(
                      request.groupMetadata?.cloudGuid ?? request.parentState?.cloudGuid ?? request.chatGuid,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    try {
      final matches = query.find();
      if (durable.localChatId == null) {
        if (matches.isNotEmpty) {
          throw StateError('cloud_sync_historical_chat_destination_changed');
        }
      } else if (matches.length != 1 ||
          matches.single.id != durable.localChatId ||
          matches.single.isRpSms ||
          matches.single.isRoutingStub ||
          matches.single.dateDeleted != null ||
          matches.single.ckRecordId != null) {
        throw StateError('cloud_sync_historical_chat_destination_changed');
      }
    } finally {
      query.close();
    }
  }

  static String _chatDigest(String guid) =>
      sha256.convert(utf8.encode(guid)).toString();

  @override
  String toString() => 'CloudSyncHistoricalParentOrigin(redacted)';
}

/// Retained lookup may run after the visible source row changed. Only fresh
/// admission/dispatch uses the stronger transient checks above. This lookup
/// never authorizes a retry, substitutes another source, or inspects a Message.
void requireCloudSyncHistoricalChatSource({
  required Store store,
  required CloudSyncScope scope,
  required CloudSyncHistoricalChatOrigin origin,
}) {
  final row = store.box<CloudSyncHistoricalArchiveIntentEntity>().get(
    origin.intentId,
  );
  if (scope.accountFingerprint != origin.source.accountFingerprint ||
      scope.container != 'com.apple.messages.cloud' ||
      scope.database != 'private' ||
      scope.zone != 'chatManateeZone' ||
      scope.streamKind != CloudSyncStreamKind.messages ||
      scope.schemaVersion != 2 ||
      scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
      row == null ||
      row.state < 1 ||
      validateCloudSyncHistoricalArchiveRow(row).encode() !=
          origin.source.encode()) {
    throw StateError('cloud_sync_historical_chat_source_changed');
  }
}
