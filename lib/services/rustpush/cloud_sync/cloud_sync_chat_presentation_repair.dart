import 'dart:async';

import 'package:async_task/async_task.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';

const _cloudSyncChatPresentationRepairPageSize = 512;

/// Maintains the denormalized date used by the conversation-list query.
///
/// The value is monotonic because a partial CloudKit history must never move a
/// conversation behind a newer locally delivered message.
bool updateCloudSyncChatLatestMessageDate(Chat chat, DateTime messageDate) {
  final current = chat.dbOnlyLatestMessageDate;
  if (current != null && !current.isBefore(messageDate)) return false;
  chat.dbOnlyLatestMessageDate = messageDate;
  return true;
}

/// Backfills profiles projected before message writes maintained the chat-list
/// ordering cache. It derives only from existing local rows and performs no
/// CloudKit operation.
int repairCloudSyncChatLatestMessageDatesInStore(Store store) {
  return store.runInTransaction(TxMode.write, () {
    final latestDateByChatId = <int, DateTime>{};
    final messageQuery = (store.box<Message>().query(
      Message_.dateDeleted.isNull().and(Message_.dateCreated.notNull()),
    )..order(Message_.id)).build();
    try {
      var offset = 0;
      while (true) {
        messageQuery
          ..offset = offset
          ..limit = _cloudSyncChatPresentationRepairPageSize;
        final page = messageQuery.find();
        for (final message in page) {
          final chatId = message.chat.targetId;
          final createdAt = message.dateCreated;
          if (chatId == 0 || createdAt == null) continue;
          final current = latestDateByChatId[chatId];
          if (current == null || current.isBefore(createdAt)) {
            latestDateByChatId[chatId] = createdAt;
          }
        }
        if (page.length < _cloudSyncChatPresentationRepairPageSize) break;
        offset += page.length;
      }
    } finally {
      messageQuery.close();
    }

    if (latestDateByChatId.isEmpty) return 0;
    final updates = <Chat>[];
    final chatQuery = (store.box<Chat>().query()..order(Chat_.id)).build();
    try {
      var offset = 0;
      while (true) {
        chatQuery
          ..offset = offset
          ..limit = _cloudSyncChatPresentationRepairPageSize;
        final page = chatQuery.find();
        for (final chat in page) {
          final latestDate = latestDateByChatId[chat.id];
          if (latestDate != null &&
              updateCloudSyncChatLatestMessageDate(chat, latestDate)) {
            updates.add(chat);
          }
        }
        if (page.length < _cloudSyncChatPresentationRepairPageSize) break;
        offset += page.length;
      }
    } finally {
      chatQuery.close();
    }
    if (updates.isNotEmpty) {
      store.box<Chat>().putMany(updates, mode: PutMode.update);
    }
    return updates.length;
  });
}

final class CloudSyncChatPresentationRepairTask
    extends AsyncTask<List<dynamic>, int> {
  CloudSyncChatPresentationRepairTask(this._parameters);

  final List<dynamic> _parameters;

  @override
  AsyncTask<List<dynamic>, int> instantiate(
    List<dynamic> parameters, [
    Map<String, SharedData>? sharedData,
  ]) => CloudSyncChatPresentationRepairTask(parameters);

  @override
  List<dynamic> parameters() => _parameters;

  @override
  FutureOr<int> run() =>
      repairCloudSyncChatLatestMessageDatesInStore(Database.store);
}

Future<int> repairCloudSyncChatLatestMessageDates() async {
  return await createAsyncTask<int>(CloudSyncChatPresentationRepairTask([])) ??
      0;
}
