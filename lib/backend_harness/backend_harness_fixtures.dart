import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_group_send_route.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/imessage_initial_submission.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'backend_harness_protocol.dart';
import 'backend_harness_fixture_assets.dart';
import 'backend_harness_fixture_proof.dart';
import 'backend_harness_fixture_archive.dart';
import 'backend_harness_fixture_claims.dart';
import 'backend_harness_fixture_routing.dart';

/// Fixed synthetic fixtures through the ordinary backend. This adds no queue,
/// resend, reset or receipt authority. The host must retain its durable dispatch
/// record and admit a recoverable device before invoking any writer command.
final class BackendHarnessFixtures {
  static const recipients = {'+16177106179', '+19079786948'};
  static final _uuid = BackendHarnessFixtureReceipt.uuid;
  static final _chatDigest = RegExp(r'^[a-f0-9]{64}$');
  static String marker(String id, {bool edited = false}) =>
      backendFixtureMarker(id, edited: edited);

  static bool _admission(Map<String, Object?> args) =>
      args['fixtureId'] is String &&
      _uuid.hasMatch(args['fixtureId'] as String) &&
      args['acknowledgeSend'] == true &&
      args['retainedRecoveryOwner'] is String &&
      _uuid.hasMatch(args['retainedRecoveryOwner'] as String);
  static bool _pinnedExistingGroup(Map<String, Object?> args) =>
      !args.containsKey('createGroup') &&
      args['recipients'] is List &&
      (args['recipients'] as List).length == 2 &&
      args['chatGuidSha256'] is String &&
      _chatDigest.hasMatch(args['chatGuidSha256'] as String);
  static bool validSend(Map<String, Object?> args) =>
      _admission(args) &&
      (args.length == 5 ||
          (args.length == 6 &&
              (_pinnedExistingGroup(args) ||
                  (args['createGroup'] == true && args['kind'] == 'text' &&
                      args['recipients'] is List &&
                      (args['recipients'] as List).length == 2)))) &&
      args.keys.every(
        const {
          'fixtureId',
          'acknowledgeSend',
          'retainedRecoveryOwner',
          'recipients',
          'kind',
          'createGroup',
          'chatGuidSha256',
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

  static bool validRoute(Map<String, Object?> args) =>
      (args.length == 1 ||
          (args.length == 2 &&
              (_pinnedExistingGroup(args) ||
                  (args['createGroup'] == true && args['recipients'] is List &&
                      (args['recipients'] as List).length == 2)))) &&
      args.keys.every(const {'recipients', 'createGroup', 'chatGuidSha256'}.contains) &&
      args['recipients'] is List &&
      (args['recipients'] as List).isNotEmpty &&
      (args['recipients'] as List).length <= 2 &&
      (args['recipients'] as List).toSet().length ==
          (args['recipients'] as List).length &&
      (args['recipients'] as List).every(recipients.contains);

  Future<BackendHarnessPayload> route(Map<String, Object?> args) async {
    if (!validRoute(args)) {
      throw BackendHarnessFailure(
        'backend_invalid_arguments',
        effectNotEntered: true,
      );
    }
    late final CloudSyncNativeAuthSnapshot auth;
    try {
      auth = await _identity();
    } on BackendHarnessFailure catch (failure) {
      if (args.containsKey('chatGuidSha256') && failure.code == 'backend_not_ready') {
        throw BackendHarnessFailure('backend_group_context_not_ready', effectNotEntered: true);
      }
      rethrow;
    }
    final store = Database.store;
    final storage = pushService.statePath;
    final requested = (args['recipients'] as List).cast<String>();
    final current = pushService.state;
    late final String sender;
    if (args['createGroup'] == true) {
      sender = await _preflightFreshGroupSender(requested);
    } else {
      final chat = await resolveBackendHarnessFixtureChat(
        store: store, auth: auth, recipients: requested,
        // Read-only selection has no fixture claim or message identity.
        fixtureId: '00000000-0000-4000-8000-000000000000',
        expectedChatGuidSha256: args['chatGuidSha256'] as String?,
      );
      sender = chat.usingHandle ?? '';
    }
    if (current == null || !identical(current, pushService.state)) {
      throw BackendHarnessFailure('backend_identity_changed', effectNotEntered: true);
    }
    // The ordinary directory lookup exercises the same registration resource
    // and target-key cache as send, including own-device reflection, without a
    // Message, claim or IDS packet. This does not validate key signatures.
    try {
      await preflightTargets(
        requested: requested,
        sender: sender,
        lookup: (targets, handle) => api.validateTargets(
          state: current.client, targets: targets, sender: handle),
      );
    } on BackendHarnessFailure catch (failure) {
      if (args.containsKey('chatGuidSha256') && failure.code == 'backend_not_ready') {
        throw BackendHarnessFailure('backend_group_targets_not_ready', effectNotEntered: true);
      }
      rethrow;
    }
    if (!auth.sameIdentity(await _identity()) ||
        !identical(current, pushService.state) ||
        !identical(store, Database.store) ||
        storage != pushService.statePath) {
      throw BackendHarnessFailure(
        'backend_identity_changed',
        effectNotEntered: true,
      );
    }
    return const BackendHarnessPayload(
      flags: {'fixture_route_available': true, 'send_resources_ready': true},
    );
  }

  static Future<void> preflightTargets({
    required List<String> requested,
    required String sender,
    required Future<List<String>> Function(List<String>, String) lookup,
  }) async {
    final bareSender = sender.startsWith('tel:') ? sender.substring(4)
        : sender.startsWith('mailto:') ? sender.substring(7) : '';
    if (requested.isEmpty || requested.length > 2 ||
        requested.toSet().length != requested.length ||
        !requested.every(recipients.contains) || bareSender.isEmpty ||
        requested.contains(bareSender)) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
    final targets = [for(final value in requested) 'tel:$value', sender];
    final valid = await lookup(List.unmodifiable(targets), sender);
    if (valid.length != targets.length ||
        valid.toSet().length != targets.length || !valid.every(targets.contains)) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
  }

  static bool hasRetainedFixture(Store store, String fixtureId) {
    final query = store.box<Chat>().query(
      Chat_.guid.equals(fixtureId).or(Chat_.cloudGuid.equals(fixtureId)),
    ).build()..limit = 1;
    try { return query.count() != 0; } finally { query.close(); }
  }

  static bool ownsMessage(
    Message message,
    String fixtureId, {
    bool retainedChat = false,
    String? exactMessageGuid,
  }) =>
      message.isFromMe == true &&
      (exactMessageGuid != null
          ? _uuid.hasMatch(exactMessageGuid) &&
                message.guid == exactMessageGuid &&
                message.chat.target != null
          : message.chat.target?.guid == fixtureId ||
                (retainedChat &&
                    message.chat.target?.cloudGuid == fixtureId)) &&
      message.dateScheduled == null &&
      message.dateDeleted == null &&
      (message.text == marker(fixtureId) ||
          message.text == marker(fixtureId, edited: true) ||
          message.subject == marker(fixtureId) ||
          _ownsAttachmentBody(message, fixtureId));

  static bool _ownsAttachmentBody(Message message, String id) {
    if (!message.hasAttachments ||
        message.attributedBody.length != 1 ||
        message.subject?.isNotEmpty == true) {
      return false;
    }
    final body = message.attributedBody.single;
    final text =
        body.string == '${marker(id, edited: true)}\uFFFC' ||
            body.string == '${marker(id, edited: true)} '
        ? marker(id, edited: true)
        : marker(id);
    if (message.text != body.string ||
        body.runs.length != 2 ||
        (body.string != '$text\uFFFC' && body.string != '$text ')) {
      return false;
    }
    final first = body.runs.first;
    final last = body.runs.last;
    return first.range.length == 2 &&
        first.range[0] == 0 &&
        first.range[1] == text.length &&
        first.attributes?.messagePart == 0 &&
        first.attributes?.attachmentGuid == null &&
        last.range.length == 2 &&
        last.range[0] == text.length &&
        last.range[1] == 1 &&
        last.attributes?.messagePart == 1 &&
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
      throw BackendHarnessFailure('backend_disabled', effectNotEntered: true);
    }
    if (!CloudSyncDevGate.isAgentBackendRuntime(
      isAndroid: Platform.isAndroid,
      isWindows: Platform.isWindows,
      packageName: fs.packageInfo.packageName,
      isolatedWindowsProfile: fs.cloudSyncV2WindowsDevProfileActive,
    )) {
      throw BackendHarnessFailure('backend_disabled', effectNotEntered: true);
    }
    final auth = await _identity();
    if (backend is! RustPushBackend ||
        !ss.settings.finishedSetup.value ||
        pushService.cloudSyncV2HistoryReadActive ||
        pushService.cloudSyncV2Progress.active) {
      throw BackendHarnessFailure('backend_busy', effectNotEntered: true);
    }
    final preference = await pushService
        .readCloudSyncV2AutomaticArchivePreference();
    if (!preference.enabled ||
        preference.identity.accountFingerprint != auth.accountFingerprint ||
        preference.identity.protectedStoreIdentity !=
            auth.protectedStoreIdentity ||
        !auth.sameIdentity(await _identity()) ||
        !pushService.cloudSyncV2BackendArchiveScopeCurrent(preference)) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
    return auth;
  }

  Future<BackendHarnessPayload> send(Map<String, Object?> args) async {
    if (!validSend(args)) {
      throw BackendHarnessFailure(
        'backend_invalid_arguments',
        effectNotEntered: true,
      );
    }
    final auth = await _admit();
    final id = (args['fixtureId'] as String).toUpperCase();
    final store = Database.store;
    final storage = pushService.statePath;
    // Preserve consumed fixtures from the older chat-correlated harness too.
    // New sends use the independent one-use claim below.
    if (hasRetainedFixture(store, id)) {
      throw BackendHarnessFailure(
        'backend_request_reused',
        effectNotEntered: true,
      );
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
      if (unfinished.count() != 0) {
        throw BackendHarnessFailure('backend_busy', effectNotEntered: true);
      }
    } finally {
      unfinished.close();
    }
    final claims = _claims(auth);
    late final BackendHarnessFixtureClaim claim;
    try {
      claim = claims.consume(
        id,
        owner: args['retainedRecoveryOwner'] as String,
      );
    } on BackendHarnessFailure catch (failure) {
      throw BackendHarnessFailure(failure.code, effectNotEntered: true);
    }
    final kind = args['kind'] as String;
    final body = marker(id);
    final requested = (args['recipients'] as List).cast<String>();
    final createGroup = args['createGroup'] == true;
    if (createGroup) {
      await _preflightFreshGroupSender(requested);
      if (!auth.sameIdentity(await _identity()) ||
          !identical(store, Database.store) || storage != pushService.statePath) {
        throw BackendHarnessFailure('backend_identity_changed', effectNotEntered: true);
      }
    }
    // The one-use claim above precedes even local Chat creation. Let the normal
    // backend choose its fresh group identity; fixture UUID is correlation only.
    // This path exercises provisional Chat admission/readback in the ordinary
    // archive worker, then subsequent media fixtures may use that restored Chat.
    final chat = createGroup
        ? await backend.createChat(requested, null, 'iMessage')
        : await resolveBackendHarnessFixtureChat(
            store: store, auth: auth, recipients: requested, fixtureId: id,
            expectedChatGuidSha256: args['chatGuidSha256'] as String?,
          );
    if (!auth.sameIdentity(await _identity()) ||
        !identical(store, Database.store) ||
        storage != pushService.statePath) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    if (createGroup) {
      requireFreshGroup(chat, requested);
    }
    late final Message reflected;
    if (kind == 'text') {
      final pending = createPendingInitialIMessage(
        AttributedBody.raw(body),
        createdAt: DateTime.now(),
        sender: RustPushBBUtils.rustHandleToBB(await chat.ensureHandle()),
      );
      if (!auth.sameIdentity(await _identity()) ||
          !identical(store, Database.store) ||
          storage != pushService.statePath) {
        throw BackendHarnessFailure('backend_identity_changed');
      }
      final prepared = await ah.prepMessage(chat, pending, null, null);
      if (prepared.length != 1 || !identical(prepared.single, pending)) {
        throw BackendHarnessFailure('backend_not_ready');
      }
      if (!auth.sameIdentity(await _identity()) ||
          !identical(store, Database.store) ||
          storage != pushService.statePath) {
        throw BackendHarnessFailure('backend_identity_changed');
      }
      reflected = await backend.sendMessage(chat, pending);
      await ah.matchMessageWithExisting(
        chat,
        pending.guid!,
        reflected,
        existing: pending,
      );
    } else {
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
          !identical(store, Database.store) ||
          storage != pushService.statePath) {
        throw BackendHarnessFailure('backend_identity_changed');
      }
      reflected = await backend.sendAttachment(
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
        !identical(store, Database.store) ||
        storage != pushService.statePath) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    final canonical = requireMergedMessage(
      store: store, chat: chat, fixtureId: id, messageGuid: reflected.guid,
    );
    claims.commit(claim, canonical.guid!);
    return _status(auth, id, completedAction: 'create');
  }

  /// The normal merger persists an existing row without attaching the returned
  /// reflection to its Chat. Validate that exact persisted result, not the
  /// detached response, and never fall back to a pending/staging GUID.
  static Message requireMergedMessage({
    required Store store,
    required Chat chat,
    required String fixtureId,
    required String? messageGuid,
  }) {
    if (store.isClosed() || chat.id == null || chat.id! <= 0 ||
        messageGuid == null || !_uuid.hasMatch(messageGuid)) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    return store.runInTransaction(TxMode.read, () {
      final query = store.box<Message>().query(
        Message_.guid.equals(messageGuid),
      ).build()..limit = 2;
      late final List<Message> found;
      try { found = query.find(); } finally { query.close(); }
      if (found.length != 1 ||
          found.single.chat.targetId != chat.id ||
          found.single.chat.target?.guid != chat.guid ||
          !ownsMessage(found.single, fixtureId, exactMessageGuid: messageGuid)) {
        throw BackendHarnessFailure('backend_not_ready');
      }
      return found.single;
    });
  }

  Future<BackendHarnessPayload> edit(Map<String, Object?> args) =>
      _mutate(args, false);

  /// Validate the normal backend's newly generated local route before IDS.
  /// This is not a CloudKit dependency or an already-archived group claim.
  static void requireFreshGroup(Chat chat, List<String> requested) {
    final route = CloudSyncGroupSendRoute.capture(chat);
    final expected = [...requested]..sort();
    if (requested.length != 2 || requested.toSet().length != 2 ||
        !requested.every(recipients.contains) || route == null ||
        !route.provisional || route.groupId != null ||
        jsonEncode(route.members) != jsonEncode(expected)) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
  }

  Future<String> _preflightFreshGroupSender(List<String> requested) async {
    final activeBackend = backend;
    if (activeBackend is! RustPushBackend) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
    // This ordinary backend method chooses from fresh native owned handles.
    // Merely checking a route must not create a Handle or change a preference.
    final sender = await activeBackend.getDefaultHandle();
    final bare = sender.startsWith('tel:') ? sender.substring(4)
        : sender.startsWith('mailto:') ? sender.substring(7) : sender;
    if (bare.isEmpty || requested.contains(bare)) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
    return sender;
  }
  Future<BackendHarnessPayload> unsend(Map<String, Object?> args) =>
      _mutate(args, true);
  Future<BackendHarnessPayload> _mutate(
    Map<String, Object?> args,
    bool undo,
  ) async {
    if (!validMutation(args)) {
      throw BackendHarnessFailure('backend_invalid_arguments', effectNotEntered: true);
    }
    final auth = await _admit();
    final id = (args['fixtureId'] as String).toUpperCase();
    final store = Database.store;
    late final BackendHarnessPayload claimed;
    try {
      claimed = _status(auth, id, owner: args['retainedRecoveryOwner'] as String);
    } on BackendHarnessFailure catch (failure) {
      throw BackendHarnessFailure(failure.code, effectNotEntered: true);
    }
    if (claimed.fixture?.messageGuid != args['messageGuid']) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
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
        !ownsMessage(found.single, id, exactMessageGuid: claimed.fixture!.messageGuid)) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
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
        throw BackendHarnessFailure('backend_request_reused', effectNotEntered: true);
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
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
    // A received/restored row or Delivered flag cannot stand in for this
    // fixture's exact positive IDS origin and completed create readback.
    if (!hasSettledMutationPredecessor(store, auth, id, message.guid!,
        exactMessageGuid: claimed.fixture!.messageGuid)) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
    if (undo) {
      final parts = message
          .buildMessageParts()
          .where((part) => part.part == 0 && !part.isUnsent)
          .toList();
      if (parts.length != 1) throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
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
    final result = _status(auth, (args['fixtureId'] as String).toUpperCase());
    if (!auth.sameIdentity(await _identity()) ||
        !identical(store, Database.store)) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    return result;
  }

  /// Read-only completion observation after the command engine has drained.
  /// The original job/claim stays immutable. This uses the original action's
  /// native receipt, not archive settlement or a new dispatch.
  Future<BackendHarnessPayload> observeNativeCompletionForShutdown(
    Map<String, Object?> job,
  ) async {
    final expected = _shutdownFixture(job);
    final auth = await _identity();
    final store = Database.store;
    final observed = _status(
      auth, expected.fixtureId,
      owner: expected.owner, completedAction: expected.completedAction,
    );
    if (!auth.sameIdentity(await _identity()) ||
        !identical(store, Database.store) ||
        !nativeCompletionMatches(job, observed)) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    return observed;
  }

  static ({
    String fixtureId, String messageGuid, String owner, String completedAction,
  }) _shutdownFixture(Map<String, Object?> job) {
    final action = switch (job['action']) {
      'fixture.send' => 'create',
      'fixture.edit' => 'edit',
      'fixture.unsend' => 'undo',
      _ => throw BackendHarnessFailure('backend_invalid_arguments'),
    };
    final receipt = job['fixture'];
    final correlation = job['correlation'];
    if (!BackendHarnessFixtureReceipt.validJson(receipt) ||
        receipt is! Map || correlation is! Map ||
        correlation['retainedRecoveryOwner'] is! String ||
        !_uuid.hasMatch(correlation['retainedRecoveryOwner'] as String) ||
        correlation['fixtureId'] is! String ||
        (correlation['fixtureId'] as String).toUpperCase() !=
            (receipt['fixtureId'] as String).toUpperCase() ||
        (correlation['messageGuid'] != null &&
          (correlation['messageGuid'] as String).toUpperCase() !=
            (receipt['messageGuid'] as String).toUpperCase())) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    return (
      fixtureId: (receipt['fixtureId'] as String).toUpperCase(),
      messageGuid: (receipt['messageGuid'] as String).toUpperCase(),
      owner: correlation['retainedRecoveryOwner'] as String,
      completedAction: action,
    );
  }

  /// Exact fixture identity plus the requested action's positive native proof.
  /// Creation proof alone cannot settle an uncertain edit/undo command.
  static bool nativeCompletionMatches(
    Map<String, Object?> job, BackendHarnessPayload observed,
  ) {
    final expected = _shutdownFixture(job);
    final actual = observed.fixture;
    return observed.flags['ids_evidence_present'] == true &&
        observed.flags['outcome_uncertain'] == false &&
        observed.counts['messages'] == 1 && actual != null &&
        actual.fixtureId.toUpperCase() == expected.fixtureId &&
        actual.messageGuid.toUpperCase() == expected.messageGuid &&
        observed.flags['fixture_${expected.completedAction}_present'] == true;
  }

  BackendHarnessPayload _status(
    CloudSyncNativeAuthSnapshot auth,
    String id, {
    String? completedAction,
    String? owner,
  }) {
    final claim = _claims(auth).read(id, owner: owner);
    if (claim == null) {
      return BackendHarnessPayload(
        flags: backendFixtureArchiveAbsentFlags(),
        counts: const {'messages': 0},
      );
    }
    return readClaimStatus(
      Database.store,
      auth,
      id,
      claim,
      completedAction: completedAction,
    );
  }

  BackendHarnessFixtureClaims _claims(CloudSyncNativeAuthSnapshot auth) =>
      BackendHarnessFixtureClaims(
        storageDirectory: pushService.statePath,
        source: BackendHarnessGate.source,
        auth: auth,
      );

  static BackendHarnessPayload readClaimStatus(
    Store store,
    CloudSyncNativeAuthSnapshot auth,
    String id,
    BackendHarnessFixtureClaim claim, {
    String? completedAction,
  }) {
    if (claim.fixtureId != id.toUpperCase() ||
        claim.accountFingerprint != auth.accountFingerprint ||
        claim.protectedStoreIdentity != auth.protectedStoreIdentity) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    final guid =
        claim.messageGuid ?? _recoverClaimedMessageGuid(store, auth, id);
    if (guid == null) {
      return BackendHarnessPayload(
        phase: BackendHarnessPhase.blocked,
        flags: backendFixtureArchiveAbsentFlags(uncertain: true),
        counts: const {'messages': 0},
      );
    }
    return readStatus(
      store,
      auth,
      id,
      exactMessageGuid: guid,
      completedAction: completedAction,
    );
  }

  static String? _recoverClaimedMessageGuid(
    Store store,
    CloudSyncNativeAuthSnapshot auth,
    String id,
  ) => store.runInTransaction(TxMode.read, () {
    final candidates =
        store
            .box<Message>()
            .query(
              Message_.text
                  .oneOf([
                    marker(id),
                    marker(id, edited: true),
                    '${marker(id)}\uFFFC',
                    '${marker(id)} ',
                    '${marker(id, edited: true)}\uFFFC',
                    '${marker(id, edited: true)} ',
                  ])
                  .or(Message_.subject.equals(marker(id))),
            )
            .build()
          ..limit = 2;
    late final List<Message> rows;
    try {
      rows = candidates.find();
    } finally {
      candidates.close();
    }
    if (rows.length != 1) return null;
    final row = rows.single;
    final guid = row.guid;
    if (guid == null ||
        !_uuid.hasMatch(guid) ||
        !ownsMessage(row, id, exactMessageGuid: guid)) {
      return null;
    }
    final hash = sha256
        .convert(
          utf8.encode(jsonEncode(['cloud-sync-local-send-guid-v1', guid])),
        )
        .toString();
    final origins =
        store
            .box<CloudSyncLocalSendIntentEntity>()
            .query(
              CloudSyncLocalSendIntentEntity_.accountFingerprint
                  .equals(auth.accountFingerprint)
                  .and(
                    CloudSyncLocalSendIntentEntity_.localMessageId.equals(
                      row.id!,
                    ),
                  )
                  .and(
                    CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
                      hash,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    try {
      return origins.find().length == 1 ? guid : null;
    } finally {
      origins.close();
    }
  });

  /// A retained canonical Chat is selectable only through the same exact
  /// account/source/readback observation as status, never cloudGuid alone.
  static bool hasSettledMutationPredecessor(
    Store store,
    CloudSyncNativeAuthSnapshot auth,
    String id,
    String messageGuid, {
    String? exactMessageGuid,
  }) {
    final observed = readStatus(
      store,
      auth,
      id,
      exactMessageGuid: exactMessageGuid,
    );
    final flags = observed.flags;
    return observed.fixture?.messageGuid == messageGuid &&
        flags['ids_evidence_present'] == true &&
        flags['fixture_create_settled'] == true &&
        flags['outcome_uncertain'] == false &&
        (flags['fixture_edit_present'] != true ||
            flags['fixture_edit_settled'] == true) &&
        flags['fixture_undo_present'] != true;
  }

  /// Synchronous local observation; the command entrypoint fences native
  /// identity and the Store around this call. Also usable with disposable stores.
  static BackendHarnessPayload readStatus(
    Store store,
    CloudSyncNativeAuthSnapshot auth,
    String id, {
    String? completedAction,
    String? exactMessageGuid,
  }) => store.runInTransaction(TxMode.read, () {
    late final List<Message> messages;
    Chat? chat;
    if (exactMessageGuid != null) {
      if (!_uuid.hasMatch(exactMessageGuid)) {
        throw BackendHarnessFailure('backend_not_ready');
      }
      final exact =
          store
              .box<Message>()
              .query(Message_.guid.equals(exactMessageGuid))
              .build()
            ..limit = 2;
      try {
        messages = exact.find();
      } finally {
        exact.close();
      }
      if (messages.length == 1) chat = messages.single.chat.target;
    } else {
      final chats =
          store
              .box<Chat>()
              .query(Chat_.guid.equals(id).or(Chat_.cloudGuid.equals(id)))
              .build()
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
      try {
        messages = query.find();
      } finally {
        query.close();
      }
      chat = matching.single;
    }
    if (messages.length != 1 ||
        chat == null ||
        !ownsMessage(
          messages.single,
          id,
          retainedChat: true,
          exactMessageGuid: exactMessageGuid,
        )) {
      return BackendHarnessPayload(
        phase: BackendHarnessPhase.blocked,
        flags: backendFixtureArchiveAbsentFlags(uncertain: true),
        counts: {'messages': messages.length},
      );
    }
    final message = messages.single;
    final guid = message.guid;
    if (guid == null || !BackendHarnessFixtureReceipt.uuid.hasMatch(guid)) {
      return BackendHarnessPayload(
        phase: BackendHarnessPhase.blocked,
        flags: backendFixtureArchiveAbsentFlags(uncertain: true),
        counts: const {'messages': 1},
      );
    }
    final archive = backendFixtureArchiveFlags(
      store: store,
      auth: auth,
      message: message,
      messageGuid: guid,
      completedAction: completedAction,
    );
    final visible = message
        .buildMessageParts()
        .where((part) => !part.isUnsent)
        .map(
          (part) => [
            part.subject,
            part.text,
          ].whereType<String>().where((value) => value.isNotEmpty).join('\n'),
        )
        .where((value) => value.isNotEmpty)
        .join('\n');
    return BackendHarnessPayload(
      phase: archive['outcome_uncertain'] == true
          ? BackendHarnessPhase.blocked
          : BackendHarnessPhase.idle,
      flags: archive,
      counts: {'messages': 1},
      fixture: BackendHarnessFixtureReceipt(
        fixtureId: id,
        messageGuid: guid,
        visibleTextSha256: sha256.convert(utf8.encode(visible)).toString(),
        participantsSha256: backendFixtureParticipantsSha256(chat),
        editHistorySha256: backendFixtureEditHistorySha256(message),
        chatGuidSha256: sha256.convert(utf8.encode(chat.guid)).toString(),
      ),
    );
  });
}
