import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';

class SyncActions {
  /// Performs an incremental sync of chats
  static Future<List<int>> performIncrementalSync(dynamic data) async {
    try {
      int syncStart = SettingsSvc.settings.lastIncrementalSync.value;
      int startRowId = SettingsSvc.settings.lastIncrementalSyncRowId.value;

      final incrementalSyncManager =
          IncrementalSyncManager(startTimestamp: syncStart, startRowId: startRowId, saveMarker: true);

      await incrementalSyncManager.start();
      return incrementalSyncManager.latestMessageIdPerChat.values.toList();
    } catch (ex, s) {
      Logger.error('Incremental sync failed!', error: ex, trace: s);
    }

    return [];
  }
}
