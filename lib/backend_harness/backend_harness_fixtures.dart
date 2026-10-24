import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'backend_harness_protocol.dart';
import 'backend_harness_fixture_assets.dart';
import 'backend_harness_fixture_proof.dart';

/// Fixed synthetic fixtures through the ordinary backend. This adds no queue,
/// resend, reset or receipt authority. The host must retain its durable dispatch
/// record and admit a recoverable device before invoking any writer command.
final class BackendHarnessFixtures {
  static const recipients = {'+16177106179', '+19079786948'};
  static final _uuid = BackendHarnessFixtureReceipt.uuid;
  static String marker(String id, {bool edited = false}) =>
      backendFixtureMarker(id, edited: edited);

  static bool _admission(Map<String, Object?> args) =>
      args['fixtureId'] is String &&
      _uuid.hasMatch(args['fixtureId'] as String) &&
      args['acknowledgeSend'] == true &&
      args['retainedRecoveryOwner'] is String &&
      _uuid.hasMatch(args['retainedRecoveryOwner'] as String);
  static bool validSend(Map<String, Object?> args) =>
      _admission(args) &&
      args.length == 5 &&
      args.keys.every(
        const {
          'fixtureId',
          'acknowledgeSend',
          'retainedRecoveryOwner',
          'recipients',
          'kind',
        }.contains,
      ) &&
      const {'text', 'image', 'document'}.contains(args['kind']) &&
      args['recipients'] is List &&
      (args['recipients'] as List).isNotEmpty &&
      (args['recipients'] as List).length <= 2 &&
      (args['recipients'] as List).toSet().length ==
          (args['recipients'] as List).length &&
      (args['recipients'] as List).every(recipients.contains);
  static bool validMutation(Map<String, Object?> args) =>
      _admission(args) &&
      args.length == 4 &&
      args.keys.every(
        const {
          'fixtureId',
          'acknowledgeSend',
          'retainedRecoveryOwner',
          'messageGuid',
        }.contains,
      ) &&
      args['messageGuid'] is String &&
      _uuid.hasMatch(args['messageGuid'] as String);
  static bool validStatus(Map<String, Object?> args) =>
      args.length == 1 &&
      args['fixtureId'] is String &&
      _uuid.hasMatch(args['fixtureId'] as String);

  static bool ownsMessage(Message message, String fixtureId) =>
      message.isFromMe == true &&
      message.chat.target?.guid == fixtureId &&
      message.dateScheduled == null &&
      message.dateDeleted == null &&
      (message.text == marker(fixtureId) ||
          message.text == marker(fixtureId, edited: true) ||
          message.subject == marker(fixtureId));

  Future<CloudSyncNativeAuthSnapshot> _identity() async {
    await pushService.initFuture;
    final auth = await CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: () =>
          pushService.state?.icloudServices?.cloudMessagesClient,
      nativeAuthBinding: FrbCloudSyncNativeAuthBinding(),
      privateStorageDirectory: pushService.statePath,
    ).capture();
    if (auth == null || Database.store.isClosed()) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    return auth;
  }

  Future<CloudSyncNativeAuthSnapshot> _admit() async {
    if (!CloudSyncDevGate.agentBackendEnabled ||
        !CloudKitWriterOwnership.v2MutationsEnabled ||
        !CloudSyncDevGate.manualOutboundCanaryEnabled ||
        !CloudSyncDevGate.localSendRuntimeEnabled) {
      throw BackendHarnessFailure('backend_disabled');
    }
    if (!CloudSyncDevGate.isAgentBackendRuntime(
      isAndroid: Platform.isAndroid,
      isWindows: Platform.isWindows,
      packageName: fs.packageInfo.packageName,
      isolatedWindowsProfile: fs.cloudSyncV2WindowsDevProfileActive,
    )) {
      throw BackendHarnessFailure('backend_disabled');
    }
    final auth = await _identity();
    if (backend is! RustPushBackend ||
        !ss.settings.finishedSetup.value ||
        pushService.cloudSyncV2HistoryReadActive ||
        pushService.cloudSyncV2Progress.active) {
      throw BackendHarnessFailure('backend_busy');
    }
    final preference = await pushService
        .readCloudSyncV2AutomaticArchivePreference();
    if (!preference.enabled ||
        preference.identity.accountFingerprint != auth.accountFingerprint ||
        preference.identity.protectedStoreIdentity !=
            auth.protectedStoreIdentity ||
        !auth.sameIdentity(await _identity())) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    return auth;
  }

  Future<BackendHarnessPayload> send(Map<String, Object?> args) async {
    if (!validSend(args)) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final auth = await _admit();
    final id = args['fixtureId'] as String;
    final store = Database.store;
    final existing = store.box<Chat>().query(Chat_.guid.equals(id)).build()
      ..limit = 1;
    try {
      // A retained chat is a consumed fixture, even if its send outcome is
      // unknown or the crash preceded message reflection. Never recreate it.
      if (existing.count() != 0) {
        throw BackendHarnessFailure('backend_request_reused');
      }
    } finally {
      existing.close();
    }
    final unfinished =
        store
            .box<CloudOutboxOperationEntity>()
            .query(
              CloudOutboxOperationEntity_.accountFingerprint
                  .equals(auth.accountFingerprint)
                  .and(CloudOutboxOperationEntity_.state.notEquals(2)),
            )
            .build()
          ..limit = 1;
    try {
      if (unfinished.count() != 0) throw BackendHarnessFailure('backend_busy');
    } finally {
      unfinished.close();
    }
    final addresses = (args['recipients'] as List)
        .cast<String>()
        .map((value) => 'tel:$value')
        .toList();
    final kind = args['kind'] as String;
    final body = marker(id);
    final chat = await backend.createChat(
      addresses,
      kind == 'text' ? AttributedBody.raw(body) : null,
      'iMessage',
      existingGuid: id,
    );
    if (kind != 'text') {
      // Small fixed fixtures avoid arbitrary host-file paths or personal media.
      final bytes = backendFixtureBytes(id, kind);
      final attachment = Attachment(
        guid: const Uuid().v4(),
        isOutgoing: true,
        transferName: 'ob-lab-$id.${kind == 'image' ? 'png' : 'txt'}',
        mimeType: kind == 'image' ? 'image/png' : 'text/plain',
        uti: kind == 'image' ? 'public.png' : 'public.plain-text',
        totalBytes: bytes.length,
        bytes: bytes,
      );
      final pending = Message(
        subject: body,
        isFromMe: true,
        handleId: 0,
        dateCreated: DateTime.now(),
        hasAttachments: true,
        attachments: [attachment],
      )..generateTempGuid();
      await ah.prepAttachment(chat, pending);
      if (!auth.sameIdentity(await _identity()) ||
          !identical(store, Database.store)) {
        throw BackendHarnessFailure('backend_identity_changed');
      }
      final reflected = await backend.sendAttachment(
        chat,
        pending,
        false,
        attachment,
      );
      await ah.matchMessageWithExisting(
        chat,
        pending.guid!,
        reflected,
        existing: pending,
      );
    }
    if (!auth.sameIdentity(await _identity()) ||
        !identical(store, Database.store)) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    return _status(auth, id);
  }

  Future<BackendHarnessPayload> edit(Map<String, Object?> args) =>
      _mutate(args, false);
  Future<BackendHarnessPayload> unsend(Map<String, Object?> args) =>
      _mutate(args, true);
  Future<BackendHarnessPayload> _mutate(
    Map<String, Object?> args,
    bool undo,
  ) async {
    if (!validMutation(args)) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final auth = await _admit();
    final id = args['fixtureId'] as String;
    final store = Database.store;
    final query =
        store
            .box<Message>()
            .query(Message_.guid.equals(args['messageGuid'] as String))
            .build()
          ..limit = 2;
    late final List<Message> found;
    try {
      found = query.find();
    } finally {
      query.close();
    }
    if (found.length != 1 || !ownsMessage(found.single, id)) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    final message = found.single;
    final previous =
        store
            .box<CloudSyncLocalMutationIntentEntity>()
            .query(
              CloudSyncLocalMutationIntentEntity_.accountFingerprint
                  .equals(auth.accountFingerprint)
                  .and(
                    CloudSyncLocalMutationIntentEntity_.localMessageId.equals(
                      message.id!,
                    ),
                  )
                  .and(
                    CloudSyncLocalMutationIntentEntity_.kind.equals(
                      undo ? 1 : 0,
                    ),
                  ),
            )
            .build()
          ..limit = 1;
    try {
      if (previous.count() != 0) {
        throw BackendHarnessFailure('backend_request_reused');
      }
    } finally {
      previous.close();
    }
    final created = message.dateCreated;
    final age = created == null ? null : DateTime.now().difference(created);
    if (age == null ||
        age.isNegative ||
        age >
            (undo
                ? const Duration(seconds: 110)
                : const Duration(minutes: 14))) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    // A received/restored row or Delivered flag cannot stand in for this
    // fixture's exact positive IDS origin and completed create readback.
    final origins =
        store
            .box<CloudSyncLocalSendIntentEntity>()
            .query(
              CloudSyncLocalSendIntentEntity_.accountFingerprint
                  .equals(auth.accountFingerprint)
                  .and(
                    CloudSyncLocalSendIntentEntity_.localMessageId.equals(
                      message.id!,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    late final List<CloudSyncLocalSendIntentEntity> intent;
    try {
      intent = origins.find();
    } finally {
      origins.close();
    }
    if (intent.length != 1 ||
        intent.single.state != 2 ||
        intent.single.idsConfirmationVersion != 2 ||
        intent.single.confirmedReadbackBindingSha256 == null ||
        intent.single.admittedOperationId == null) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    if (undo) {
      final parts = message
          .buildMessageParts()
          .where((part) => part.part == 0 && !part.isUnsent)
          .toList();
      if (parts.length != 1) throw BackendHarnessFailure('backend_not_ready');
      await backend.unsend(message, parts.single);
    } else {
      await backend.edit(
        message,
        AttributedBody.raw(marker(id, edited: true)),
        0,
      );
    }
    if (!auth.sameIdentity(await _identity()) ||
        !identical(store, Database.store)) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    return _status(auth, id);
  }

  Future<BackendHarnessPayload> status(Map<String, Object?> args) async {
    if (!validStatus(args)) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final auth = await _identity();
    final store = Database.store;
    final result = _status(auth, args['fixtureId'] as String);
    if (!auth.sameIdentity(await _identity()) ||
        !identical(store, Database.store)) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    return result;
  }

  BackendHarnessPayload _status(CloudSyncNativeAuthSnapshot auth, String id) =>
      Database.store.runInTransaction(TxMode.read, () {
        final chats =
            Database.store.box<Chat>().query(Chat_.guid.equals(id)).build()
              ..limit = 2;
        late final List<Chat> matching;
        try {
          matching = chats.find();
        } finally {
          chats.close();
        }
        if (matching.length != 1) {
          return const BackendHarnessPayload(counts: {'messages': 0});
        }
        final query =
            Database.store
                .box<Message>()
                .query(Message_.chat.equals(matching.single.id!))
                .build()
              ..limit = 2;
        late final List<Message> messages;
        try {
          messages = query.find();
        } finally {
          query.close();
        }
        if (messages.length != 1 || !ownsMessage(messages.single, id)) {
          return BackendHarnessPayload(
            phase: BackendHarnessPhase.blocked,
            flags: const {'outcome_uncertain': true},
            counts: {'messages': messages.length},
          );
        }
        final message = messages.single;
        final guid =
            BackendHarnessFixtureReceipt.uuid.hasMatch(message.guid ?? '')
            ? message.guid
            : message.stagingGuid;
        if (guid == null || !BackendHarnessFixtureReceipt.uuid.hasMatch(guid)) {
          return const BackendHarnessPayload(
            phase: BackendHarnessPhase.blocked,
            flags: {'outcome_uncertain': true},
            counts: {'messages': 1},
          );
        }
        final origins =
            Database.store
                .box<CloudSyncLocalSendIntentEntity>()
                .query(
                  CloudSyncLocalSendIntentEntity_.accountFingerprint
                      .equals(auth.accountFingerprint)
                      .and(
                        CloudSyncLocalSendIntentEntity_.localMessageId.equals(
                          message.id!,
                        ),
                      ),
                )
                .build()
              ..limit = 2;
        late final List<CloudSyncLocalSendIntentEntity> intents;
        try {
          intents = origins.find();
        } finally {
          origins.close();
        }
        final ids =
            intents.length == 1 && intents.single.idsConfirmationVersion == 2;
        final visible = message
            .buildMessageParts()
            .where((part) => !part.isUnsent)
            .map(
              (part) => [part.subject, part.text]
                  .whereType<String>()
                  .where((value) => value.isNotEmpty)
                  .join('\n'),
            )
            .where((value) => value.isNotEmpty)
            .join('\n');
        return BackendHarnessPayload(
          flags: {'ids_evidence_present': ids, 'outcome_uncertain': !ids},
          counts: {'messages': 1},
          fixture: BackendHarnessFixtureReceipt(
            fixtureId: id,
            messageGuid: guid,
            visibleTextSha256: sha256.convert(utf8.encode(visible)).toString(),
            participantsSha256: backendFixtureParticipantsSha256(matching.single),
            editHistorySha256: backendFixtureEditHistorySha256(message),
          ),
        );
      });
}
