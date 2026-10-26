import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_group_send_route.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_group_binding.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

import 'backend_harness_protocol.dart';

Never _refuse([String code = 'backend_not_ready']) =>
    throw BackendHarnessFailure(code, effectNotEntered: true);
String _bare(String value) => value.startsWith('tel:')
    ? value.substring(4)
    : value.startsWith('mailto:')
    ? value.substring(7)
    : value;

/// Existing, exact, already-projected routes only. New-conversation creation is
/// a separate backend gate; never manufacture a duplicate local conversation.
Chat selectBackendHarnessFixtureChat({
  required Store store,
  required List<String> recipients,
  required Set<String> senderHandles,
  required void Function(Chat chat, bool group) requireDependency,
  String? expectedChatGuidSha256,
}) => store.runInTransaction(TxMode.read, () {
  if (recipients.isEmpty ||
      recipients.length > 2 ||
      recipients.toSet().length != recipients.length ||
      !recipients.every(const {'+16177106179', '+19079786948'}.contains)) {
    _refuse();
  }
  final group = recipients.length == 2;
  if (expectedChatGuidSha256 != null &&
      (!group || !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedChatGuidSha256))) {
    _refuse();
  }
  final query =
      store
          .box<Chat>()
          .query(
            group
                ? Chat_.style.equals(43)
                : Chat_.guid.equals('iMessage;-;${recipients.single}'),
          )
          .build()
        ..limit = group ? 4097 : 2;
  late final List<Chat> candidates;
  try {
    candidates = query.find();
  } finally {
    query.close();
  }
  if (candidates.length >= (group ? 4097 : 2)) {
    _refuse();
  }
  final members = [...recipients]..sort();
  final senders = senderHandles.map(_bare).toSet();
  final qualified = <Chat>[];
  var parentMatched = false;
  var senderMatched = false;
  var routeMatched = false;
  for (final chat in candidates) {
    if (expectedChatGuidSha256 != null &&
        sha256.convert(utf8.encode(chat.guid)).toString() != expectedChatGuidSha256) {
      continue;
    }
    parentMatched = true;
    if (chat.usingHandle == null ||
        !senders.contains(_bare(chat.usingHandle!))) {
      continue;
    }
    senderMatched = true;
    if (chat.isRpSms || chat.isRoutingStub) continue;
    if (group) {
      final route = CloudSyncGroupSendRoute.capture(chat);
      if (route == null ||
          route.provisional ||
          route.groupId == null ||
          jsonEncode(route.members) != jsonEncode(members)) {
        continue;
      }
    } else {
      final handles = chat.handles.toList();
      if (chat.style != 45 ||
          chat.chatIdentifier != recipients.single ||
          handles.length != 1 ||
          handles.single.service != 'iMessage' ||
          handles.single.address != recipients.single) {
        continue;
      }
    }
    routeMatched = true;
    try {
      requireDependency(chat, group);
    } catch (_) {
      continue;
    }
    qualified.add(chat);
  }
  if (qualified.length != 1) {
    if (expectedChatGuidSha256 != null) {
      if (!parentMatched) _refuse('backend_group_parent_not_ready');
      if (!senderMatched) _refuse('backend_group_sender_not_ready');
      if (!routeMatched) _refuse('backend_group_route_not_ready');
      if (qualified.isEmpty) _refuse('backend_group_dependency_not_ready');
      _refuse('backend_group_route_ambiguous');
    }
    _refuse();
  }
  return qualified.single;
});

Future<Chat> resolveBackendHarnessFixtureChat({
  required Store store,
  required CloudSyncNativeAuthSnapshot auth,
  required List<String> recipients,
  required String fixtureId,
  String? expectedChatGuidSha256,
}) async {
  final contextFailure = expectedChatGuidSha256 == null
      ? 'backend_not_ready' : 'backend_group_context_not_ready';
  if (backend is! RustPushBackend) _refuse(contextFailure);
  final state = pushService.state;
  final client = state?.icloudServices?.cloudMessagesClient;
  if (state == null ||
      client == null ||
      !identical(client, auth.cloudMessagesClient) ||
      store.isClosed() ||
      !identical(store, Database.store)) {
    _refuse(contextFailure);
  }
  final handles = await api.getHandles(state: state.client);
  if (!identical(state, pushService.state) ||
      !identical(
        client,
        pushService.state?.icloudServices?.cloudMessagesClient,
      ) ||
      store.isClosed() ||
      !identical(store, Database.store)) {
    _refuse(contextFailure);
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
  return selectBackendHarnessFixtureChat(
    store: store,
    recipients: recipients,
    senderHandles: handles.toSet(),
    expectedChatGuidSha256: expectedChatGuidSha256,
    requireDependency: (chat, group) {
      final target = Message(isFromMe: true)..chat.target = chat;
      if (group) {
        requireCloudSyncRestoredGroupChatProof(
          store: store,
          messageScope: scope,
          message: target,
        );
      } else {
        requireCloudSyncRestoredDirectChatProofForId(
          store: store,
          messageScope: scope,
          chatId: chat.id!,
        );
      }
    },
  );
}
