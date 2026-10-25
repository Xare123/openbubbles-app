import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_models.dart';

/// Transient origin for the shared retained-Chat comparison. Implementations
/// retain their own provenance: a historical source never becomes an IDS proof.
abstract interface class CloudSyncChatIdentityOrigin {
  CloudSyncScope get scope;
  String binding(int generation);
  void requireUnchanged(Store store);
}

/// Local Chat creates share queue and readback mechanics while keeping their
/// direct/group capture rules and durable proof formats distinct.
abstract interface class CloudSyncLocalChatCreateOrigin
    implements CloudSyncChatIdentityOrigin {
  int get chatId;
  String get originalGuid;
  String get canonicalGuid;
  String get chatIdentifier;
  String get usingHandle;
  @override
  String binding(int generation, {String? localSendProof});
}
