import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_models.dart';

/// Transient origin for the shared retained-Chat comparison. Implementations
/// retain their own provenance: a historical source never becomes an IDS proof.
abstract interface class CloudSyncChatIdentityOrigin {
  CloudSyncScope get scope;
  String binding(int generation);
  void requireUnchanged(Store store);
}
