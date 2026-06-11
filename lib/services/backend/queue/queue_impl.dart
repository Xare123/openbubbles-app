import 'dart:async';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/queue/outgoing_queue.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:get/get.dart';

abstract class Queue extends GetxService {
  RxBool isProcessing = false.obs;
  List<QueueItem> items = [];

  Future<void> queue(QueueItem item, {bool prep = true}) async {
    if (prep) {
      final returned = await prepItem(item);
      // we may get a link split into 2 messages
      if (item is OutgoingItem && returned is List) {
        items.addAll(returned.map((e) => OutgoingItem(
              type: item.type,
              chat: item.chat,
              message: e,
              completer: item.completer,
              selected: item.selected,
              reaction: item.reaction,
            )));
      } else {
        items.add(item);
      }
    } else {
      items.add(item);
    }
    if (!isProcessing.value || (items.isEmpty && item is IncomingItem)) processNextItem();
  }

  Future<dynamic> prepItem(QueueItem _);

  Future<void> processNextItem() async {
    if (items.isEmpty) {
      isProcessing.value = false;
      if (LifecycleSvc.isDead && !outq.isProcessing.value) {
        Logger.info("Done! waiting a bit for any stragglers");
        LifecycleSvc.closeTimer = Timer(const Duration(seconds: 5), () {
          MethodChannelSvc.invokeMethod("engine-done");
        });
      }
      return;
    }

    LifecycleSvc.closeTimer?.cancel();
    LifecycleSvc.closeTimer = null;

    isProcessing.value = true;
    QueueItem queued = items.removeAt(0);

    try {
      await handleQueueItem(queued).catchError((err, trace) async {
        Logger.error("Failed to handle queued item!", error: err, trace: trace);
        if (queued is OutgoingItem && SettingsSvc.settings.cancelQueuedMessages.value) {
          final toCancel =
              List<OutgoingItem>.from(items.whereType<OutgoingItem>().where((e) => e.chat.guid == queued.chat.guid));
          for (OutgoingItem i in toCancel) {
            items.remove(i);
            final m = i.message;
            final tempGuid = m.guid;
            m.guid = m.guid!.replaceAll("temp", "error-Canceled due to previous failure");
            m.error = MessageError.BAD_REQUEST.code;
            Message.replaceMessage(tempGuid, m);
          }
        }
      });
      queued.completer?.complete();
    } catch (ex, stacktrace) {
      Logger.error("Failed to handle queued item!", error: ex, trace: stacktrace);
      queued.completer?.completeError(ex);
    }

    await processNextItem();
  }

  Future<void> handleQueueItem(QueueItem _);
}
