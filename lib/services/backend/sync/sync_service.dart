import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/main.dart';
import 'package:bluebubbles/services/backend/interfaces/contact_v2_interface.dart';
import 'package:bluebubbles/services/backend/interfaces/sync_interface.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';

// ignore: non_constant_identifier_names
SyncService get SyncSvc => GetIt.I<SyncService>();

class SyncService {
  int numberOfMessagesPerPage = 25;
  bool skipEmptyChats = true;
  bool saveToDownloads = false;
  bool syncGroupChatIcons = false;
  int? syncTimeFilter;
  final RxBool isIncrementalSyncing = false.obs;

  FullSyncManager? _manager;
  FullSyncManager? get fullSyncManager => _manager;

  void initFullSync() {
    _manager = FullSyncManager(
        messageCount: numberOfMessagesPerPage.toInt(),
        skipEmptyChats: skipEmptyChats,
        saveLogs: saveToDownloads,
        syncGroupChatIcons: syncGroupChatIcons,
        syncTimeFilter: syncTimeFilter);
  }

  Future<void> startFullSync() async {
    if (_manager == null) {
      initFullSync();
    }

    if (BackendSvc.getRemoteService() == null) {
      await ContactsSvcV2.syncContactsToHandles();
      return;
    }

    // Set the last sync date (for incremental, even though this isn't incremental)
    // We won't try an incremental sync until the last (full) sync date is set
    SettingsSvc.settings.lastIncrementalSync.value = DateTime.now().millisecondsSinceEpoch;
    await SettingsSvc.settings.saveOneAsync('lastIncrementalSync');
    await _manager!.start();
  }

  Future<void> startIncrementalSync() async {
    if (BackendSvc.getRemoteService() == null && kIsDesktop) {
      await ChatsSvc.init();
    }
    isIncrementalSyncing.value = true;
    int errors = 0;

    try {
      if (usingRustPush) {
        final refreshedHandleIds = await ContactsSvcV2.syncContactsToHandles();
        Logger.info('Finished contact refresh, refreshed ${refreshedHandleIds.length} handles',
            tag: 'Incremental Contact Sync');
        if (refreshedHandleIds.isNotEmpty) {
          ContactsSvcV2.notifyHandlesUpdated(refreshedHandleIds);
        }
      } else {
        Logger.info('Starting incremental chat sync...', tag: 'Incremental Chat Sync');
        final chatStopwatch = Stopwatch()..start();
        final syncedMessages = await SyncInterface.performIncrementalSync();
        if (syncedMessages.isNotEmpty) {
          final Map<String, Message> latestPerChat = {};
          for (final message in syncedMessages) {
            final chatGuid = message.chat.target?.guid;
            if (chatGuid == null) continue;
            final existing = latestPerChat[chatGuid];
            if (existing == null ||
                (message.dateCreated != null &&
                    (existing.dateCreated == null || message.dateCreated!.isAfter(existing.dateCreated!)))) {
              latestPerChat[chatGuid] = message;
            }
          }

          for (final entry in latestPerChat.entries) {
            ChatsSvc.updateChatLatestMessage(entry.key, entry.value);
          }

          for (final message in syncedMessages) {
            final chatGuid = message.chat.target?.guid;
            if (chatGuid == null || message.guid == null) continue;
            if (Get.isRegistered<MessagesService>(tag: chatGuid)) {
              unawaited(Get.find<MessagesService>(tag: chatGuid).addNewMessage(message));
            }
          }
        }
        chatStopwatch.stop();
        Logger.info(
            'Incremental chat sync completed! Synced ${syncedMessages.length} messages across '
            '${syncedMessages.map((m) => m.chat.target?.guid).toSet().length} chats '
            'in ${chatStopwatch.elapsedMilliseconds}ms',
            tag: 'Incremental Chat Sync');
      }
    } catch (e, stack) {
      Logger.error('Incremental chat sync failed!', error: e, trace: stack, tag: 'Incremental Chat Sync');
      errors += 1;
    }

    try {
      Logger.info('Starting contact refresh', tag: 'Incremental Contact Sync');
      final contactStopwatch = Stopwatch()..start();
      final refreshedHandleIds = await ContactsSvcV2.syncContactsToHandles();
      contactStopwatch.stop();
      Logger.info(
          'Finished contact refresh, refreshed ${refreshedHandleIds.length} handles in ${contactStopwatch.elapsedMilliseconds}ms',
          tag: 'Incremental Contact Sync');

      if (refreshedHandleIds.isNotEmpty) {
        ContactsSvcV2.notifyHandlesUpdated(refreshedHandleIds);
      }
    } catch (ex, stack) {
      Logger.error('Contacts refresh failed!', error: ex, trace: stack, tag: 'Incremental Contact Sync');
      errors += 1;
    }

    try {
      // Auto upload contacts if requested
      if (SettingsSvc.settings.syncContactsAutomatically.value && BackendSvc.getRemoteService() != null) {
        Logger.debug("Starting contact upload to server...", tag: "Contact Upload");
        final contactUploadStopwatch = Stopwatch()..start();
        // Get all contacts from ContactServiceV2
        final contactsV2 = await ContactsSvcV2.getAllContacts();
        final _contacts = <Map<String, dynamic>>[];
        for (final c in contactsV2) {
          _contacts.add(c.toMap());
        }

        await ContactV2Interface.uploadContacts(_contacts);
        contactUploadStopwatch.stop();
        Logger.debug("Contact upload complete in ${contactUploadStopwatch.elapsedMilliseconds}ms",
            tag: "Contact Upload");
      }
    } catch (e, stack) {
      Logger.error("Failed to upload contacts!", error: e, trace: stack, tag: "Contact Upload");
      errors += 1;
    }

    if (SettingsSvc.settings.showIncrementalSync.value) {
      if (errors > 0) {
        showSnackbar('Error', '⚠️ Incremental sync completed with $errors errors ⚠️');
      } else {
        showSnackbar('Success', '🔄 Incremental sync complete 🔄');
      }
    }

    isIncrementalSyncing.value = false;
  }
}
