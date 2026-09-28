import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/cloud_sync_chat_identity.dart';

import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_binding.dart';
import 'cloud_sync_outbound_group_binding.dart';

/// Common inputs to the existing native historical parent proof. Selection
/// reuses the ordinary direct/group proof, including latest applied record,
/// account, generation, aliases and group routing checks. No new parent is
/// created and current members are not asserted to be historical members.
typedef CloudSyncHistoricalParentProof = ({
  String binding,
  int generation,
  String logicalEntityKeyHash,
  CloudSyncChatIdentitySourceInput source,
});

CloudSyncHistoricalParentProof requireCloudSyncHistoricalParentProof({
  required Store store,
  required CloudSyncScope messageScope,
  required int chatId,
  String? expectedBinding,
}) => store.runInTransaction(TxMode.read, () {
  final chat = chatId > 0 ? store.box<Chat>().get(chatId) : null;
  if (chat?.style == 43) {
    final group = expectedBinding == null
        ? requireCloudSyncRestoredGroupChatProofForId(
            store: store,
            messageScope: messageScope,
            chatId: chatId,
          )
        : requireCloudSyncAdoptedGroupChatProof(
            store: store,
            messageScope: messageScope,
            binding: expectedBinding,
            expectedChatId: chatId,
          );
    return (
      binding: group.binding,
      generation: group.generation,
      logicalEntityKeyHash: group.logicalEntityKeyHash,
      source: group.source,
    );
  }
  final direct = requireCloudSyncRestoredDirectChatProofForId(
    store: store,
    messageScope: messageScope,
    chatId: chatId,
  );
  return (
    binding: direct.binding,
    generation: direct.generation,
    logicalEntityKeyHash: direct.logicalEntityKeyHash,
    source: direct.source,
  );
});

void requireCloudSyncHistoricalParentUnchanged({
  required Store store,
  required CloudSyncScope messageScope,
  required int chatId,
  required String binding,
}) {
  // Preserve the existing direct adopted-record check. A canonical duplicate
  // selected later must not silently replace an already-pinned parent.
  final chat = chatId > 0 ? store.box<Chat>().get(chatId) : null;
  if (chat?.style != 43) {
    requireCloudSyncAdoptedChatDependency(
      store: store,
      messageScope: messageScope,
      binding: binding,
      expectedChatId: chatId,
    );
    return;
  }
  if (requireCloudSyncHistoricalParentProof(
        store: store,
        messageScope: messageScope,
        chatId: chatId,
        expectedBinding: binding,
      ).binding !=
      binding) {
    throw StateError('cloud_sync_historical_create_parent_changed');
  }
}
