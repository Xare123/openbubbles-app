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
import 'backend_harness_fixture_archive.dart';

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

  static bool hasRetainedFixture(Store store, String fixtureId) {
    final query = store.box<Chat>().query(
      Chat_.guid.equals(fixtureId).or(Chat_.cloudGuid.equals(fixtureId)),
    ).build()..limit = 1;
    try { return query.count() != 0; } finally { query.close(); }
  }

  static bool ownsMessage(Message message, String fixtureId, {
    bool retainedChat = false,
  }) =>
      message.isFromMe == true &&
      (message.chat.target?.guid == fixtureId ||
          (retainedChat && message.chat.target?.cloudGuid == fixtureId)) &&
      message.dateScheduled == null &&
      message.dateDeleted == null &&
      (message.text == marker(fixtureId) ||
          message.text == marker(fixtureId, edited: true) ||
          message.subject == marker(fixtureId) ||
          _ownsAttachmentBody(message, fixtureId));

  static bool _ownsAttachmentBody(Message message, String id) {
    if (!message.hasAttachments || message.attributedBody.length != 1 ||
        message.subject?.isNotEmpty == true) {
      return false;
    }
    final body = message.attributedBody.single;
    final text = marker(id);
    if (message.text != body.string || body.runs.length != 2 ||
        (body.string != '$text\uFFFC' && body.string != '$text ')) {
      return false;
    }
    final first = body.runs.first;
    final last = body.runs.last;
    return first.range.length == 2 && first.range[0] == 0 &&
        first.range[1] == text.length &&
        first.attributes?.messagePart == 0 &&
        first.attributes?.attachmentGuid == null &&
        last.range.length == 2 && last.range[0] == text.length &&
        last.range[1] == 1 && last.attributes?.messagePart == 1 &&
        last.attributes?.attachmentGuid?.isNotEmpty == true;
  }

  /// Same supported text/attachment body used for capture and local reflection.
  /// The backend must preserve these ordered parts in its IDS wire payload.
  static Message prepareAttachment(String id, Attachment attachment) {
    final text = marker(id);
    return Message(
      text: '$text\uFFFC',
      attributedBody: [AttributedBody(
        string: '$text\uFFFC',
        runs: [
          Run(range: [0, text.length], attributes: Attributes(messagePart: 0)),
          Run(range: [text.length, 1], attributes: Attributes(
            messagePart: 1, attachmentGuid: attachment.guid,
          )),
        ],
      )],
      isFromMe: true,
      handleId: 0,
      dateCreated: DateTime.now(),
      hasAttachments: true,
      attachments: [attachment],
    )..generateTempGuid();
  }

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
        !auth.sameIdentity(await _identity()) ||
        !pushService.cloudSyncV2BackendArchiveScopeCurrent(preference)) {
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
    // Canonical adoption can move the UUID to cloudGuid. Either exact retained
    // identity consumes this fixture, including after a crash before reflection.
    if (hasRetainedFixture(store, id)) {
      throw BackendHarnessFailure('backend_request_reused');
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
      final pending = prepareAttachment(id, attachment);
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
    return _status(auth, id, completedAction: 'create');
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
    if (found.length != 1 ||
        !ownsMessage(found.single, id, retainedChat: true)) {
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
    if (!hasSettledMutationPredecessor(store, auth, id, message.guid!)) {
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
    return _status(auth, id, completedAction: undo ? 'undo' : 'edit');
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

  BackendHarnessPayload _status(CloudSyncNativeAuthSnapshot auth, String id, {
    String? completedAction,
  }) => readStatus(Database.store, auth, id, completedAction: completedAction);

  /// A retained canonical Chat is selectable only through the same exact
  /// account/source/readback observation as status, never cloudGuid alone.
  static bool hasSettledMutationPredecessor(
    Store store, CloudSyncNativeAuthSnapshot auth, String id, String messageGuid,
  ) {
    final observed = readStatus(store, auth, id);
    final flags = observed.flags;
    return observed.fixture?.messageGuid == messageGuid &&
        flags['ids_evidence_present'] == true &&
        flags['fixture_create_settled'] == true &&
        flags['outcome_uncertain'] == false &&
        (flags['fixture_edit_present'] != true || flags['fixture_edit_settled'] == true) &&
        flags['fixture_undo_present'] != true;
  }

  /// Synchronous local observation; the command entrypoint fences native
  /// identity and the Store around this call. Also usable with disposable stores.
  static BackendHarnessPayload readStatus(
    Store store, CloudSyncNativeAuthSnapshot auth, String id, {
    String? completedAction,
  }) => store.runInTransaction(TxMode.read, () {
        final chats =
            store.box<Chat>().query(Chat_.guid.equals(id).or(Chat_.cloudGuid.equals(id))).build()
              ..limit = 2;
        late final List<Chat> matching;
        try {
          matching = chats.find();
        } finally {
          chats.close();
        }
        if (matching.length != 1) {
          return BackendHarnessPayload(
            flags: backendFixtureArchiveAbsentFlags(
              uncertain: matching.length > 1 || completedAction != null,
            ),
            counts: const {'messages': 0},
          );
        }
        final query =
            store
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
        if (messages.length != 1 ||
            !ownsMessage(messages.single, id, retainedChat: true)) {
          return BackendHarnessPayload(
            phase: BackendHarnessPhase.blocked,
            flags: backendFixtureArchiveAbsentFlags(uncertain: true),
            counts: {'messages': messages.length},
          );
        }
        final message = messages.single;
        final guid =
            BackendHarnessFixtureReceipt.uuid.hasMatch(message.guid ?? '')
            ? message.guid
            : message.stagingGuid;
        if (guid == null || !BackendHarnessFixtureReceipt.uuid.hasMatch(guid)) {
          return BackendHarnessPayload(
            phase: BackendHarnessPhase.blocked,
            flags: backendFixtureArchiveAbsentFlags(uncertain: true),
            counts: const {'messages': 1},
          );
        }
        final archive = backendFixtureArchiveFlags(
          store: store, auth: auth, message: message, messageGuid: guid,
          completedAction: completedAction,
        );
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
          phase: archive['outcome_uncertain'] == true
              ? BackendHarnessPhase.blocked : BackendHarnessPhase.idle,
          flags: archive,
          counts: {'messages': 1},
          fixture: BackendHarnessFixtureReceipt(
            fixtureId: id,
            messageGuid: guid,
            visibleTextSha256: sha256.convert(utf8.encode(visible)).toString(),
            participantsSha256: backendFixtureParticipantsSha256(matching.single),
            editHistorySha256: backendFixtureEditHistorySha256(message),
            chatGuidSha256: sha256.convert(utf8.encode(matching.single.guid)).toString(),
          ),
        );
      });
}
