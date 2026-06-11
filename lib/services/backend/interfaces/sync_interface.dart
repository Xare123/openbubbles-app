import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/services/backend/actions/sync_actions.dart';
import 'package:bluebubbles/services/isolates/incremental_sync_isolate.dart';
import 'package:get_it/get_it.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';

class SyncInterface {
  /// Performs an incremental sync in the isolate.
  /// Returns the latest [Message] object per synced chat, hydrated from the local DB.
  /// Callers use these messages to update [ChatState] subtitles via [ChatsService].
  static Future<List<Message>> performIncrementalSync() async {
    late List<int> messageIds = [];
    if (isIsolate) {
      messageIds = await SyncActions.performIncrementalSync({});
    } else {
      messageIds =
          await GetIt.I<IncrementalSyncIsolate>().send<List<int>>(IsolateRequestType.performIncrementalSync, input: {});
    }

    return Database.messages.getMany(messageIds).whereType<Message>().toList();
  }
}
