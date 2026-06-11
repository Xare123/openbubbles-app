import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/helpers/backend/settings_helpers.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/extension_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

// ignore: non_constant_identifier_names
MethodChannelService get MethodChannelSvc => GetIt.I<MethodChannelService>();

class MethodChannelService {
  late final MethodChannel channel;
  bool headless = false;
  bool isBubble = false;
  final RxList<Map<String, dynamic>> simInfo = <Map<String, dynamic>>[].obs;

  // music theme
  bool isRunning = false;
  Uint8List? previousArt;

  bool get shouldIgnoreMessage => !headless && !LifecycleSvc.isAlive && SettingsSvc.settings.keepAppAlive.value;

  Future<void> init({bool headless = false, bool isBubble = false, BinaryMessenger? binaryMessenger}) async {
    if (kIsWeb || kIsDesktop) return;
    Logger.debug("Initializing MethodChannelService${headless ? " in headless mode" : ""}");

    this.headless = headless;
    this.isBubble = isBubble;
    channel = MethodChannel('com.bluebubbles.messaging', const StandardMethodCodec(), binaryMessenger);

    // Only send the ready signal if we are in the BackgroundIsolate/UI (not the GlobalIsolate)
    if (binaryMessenger == null) {
      channel.setMethodCallHandler(_callHandler);
      channel.invokeMethod("ready");
    }

    if (!kIsWeb && !kIsDesktop && !headless) {
      try {
        if (SettingsSvc.settings.colorsFromMedia.value) {
          await invokeMethod("start-notification-listener");
        }
        if (!this.isBubble) {
          BackgroundIsolate.initialize();
          SyncIsolate.initialize();
        }
        // chromeOS = await mcs().invokeMethod("check-chromeos") ?? false;
      } catch (_) {}
    }

    // Don't await this
    createAllNotificationChannels();

    Logger.debug("MethodChannelService initialized");
  }

  Future<bool> _callHandler(MethodCall call) async {
    final Map<String, dynamic>? arguments =
        call.arguments is String ? jsonDecode(call.arguments) : call.arguments?.cast<String, Object>();

    // ONLY RETURN Future.value or Future.error
    // Future.value(false) will have the engine retry the call
    // Future.value(true) will have the engine stop trying to call the method

    switch (call.method) {
      case "SMSMsg":
        try {
          if (!SettingsSvc.settings.isSmsRouter.value) return true;
          final List<Object?> addresses = call.arguments["recipients"];
          String sender = call.arguments["sender"];
          final List<Object?> body = call.arguments["body"];
          final int threadId = call.arguments["thread_id"];
          final List<Map<String, dynamic>> mapped =
              body.map((e) => (e as Map<Object?, Object?>).cast<String, dynamic>()).toList();
          final Chat chat = await Chat.getChatForTel(
            threadId,
            addresses.map((e) {
              final map = (e as Map<Object?, Object?>).cast<String, dynamic>();
              return map["address"] as String;
            }).toList(),
          );
          final bool fromMe = sender == "me";
          if (fromMe && PushSvc.disableOutgoingSms) return true;
          if (fromMe) sender = (await chat.ensureHandle()).replaceFirst("tel:", "");

          await chat.deliverSMS(sender, fromMe, mapped);
        } catch (e, s) {
          Logger.error("SMS deliver error", error: e, trace: s);
          rethrow;
        }
        return true;
      case "APNMsg":
        try {
          final String pointer = call.arguments["pointer"];
          final String retry = call.arguments["retry"];
          Logger.info("got message $pointer $retry");
          await PushSvc.recievedMsgPointer(pointer, retry);
          Logger.info("finish message $pointer $retry");
        } catch (e, s) {
          Logger.error("APN MSG error", error: e, trace: s);
          rethrow;
        }
        return true;
      case "extension-add-message":
        try {
          ExtensionSvc.addMessage(arguments!);
          return true;
        } catch (e, s) {
          Logger.error("Add extension error", error: e, trace: s);
          return Future.error(PlatformException(code: "500", message: e.toString()), s);
        }
      case "extension-update-message":
        try {
          await ExtensionSvc.updateMessage(arguments!);
          return true;
        } catch (e, s) {
          Logger.error("Extension update error", error: e, trace: s);
          return Future.error(PlatformException(code: "500", message: e.toString()), s);
        }
      case "extension-set-suppress":
        try {
          await ExtensionSvc.setSuppress(arguments!);
          return true;
        } catch (e, s) {
          Logger.error("Set suppress error", error: e, trace: s);
          return Future.error(PlatformException(code: "500", message: e.toString()), s);
        }
      case "NewServerUrl":
        if (arguments == null) return Future.value(false);
        await Database.waitForInit();

        String address = arguments["server_url"];
        bool updated = await saveNewServerUrl(address, restartSocket: false);
        if (updated && !headless) {
          SocketSvc.restartSocket();
        }
        return Future.value(true);
      case "new-message": // FCM message
        await Database.waitForInit();
        Logger.info("Received new message from MethodChannel");
        try {
          // The socket will handle this event if the app is alive and unifiedpush is not enabled
          if (!headless &&
              LifecycleSvc.isAlive &&
              (SocketSvc.socket?.connected ?? false) &&
              SettingsSvc.settings.endpointUnifiedPush.value == "") {
            Logger.debug("App is alive, ignoring new message...");
            return Future.value(true);
          } else if (!headless && !LifecycleSvc.isAlive && SettingsSvc.settings.keepAppAlive.value) {
            Logger.debug("Ignoring FCM message while app is not alive, but keepAppAlive is enabled");
            return Future.value(true);
          }

          Map<String, dynamic>? data = arguments;
          if (!isNullOrEmpty(data)) {
            final payload = ServerPayload.fromJson(data!);
            await IncomingMsgHandler.handle(IncomingPayload(
              type: MessageEventType.newMessage,
              source: MessageSource.methodChannel,
              chat: Chat.fromMap(payload.data['chats'].first.cast<String, Object>()),
              message: Message.fromMap(payload.data),
              tempGuid: payload.data['tempGuid'],
            ));
          }
        } catch (e, s) {
          debugPrint("Error processing new message: $e");
          debugPrint(s.toString());
          Logger.error("Error processing new message: $e", trace: s);
          return Future.error(e, s);
        }

        return Future.value(true);
      case "updated-message":
        await Database.waitForInit();
        Logger.info("Received updated message from MethodChannel");

        // Don't ignore message updates when app is alive - they contain important info like delivery status
        // The socket might not always send these events, or there could be timing issues
        if (!headless && !LifecycleSvc.isAlive && SettingsSvc.settings.keepAppAlive.value) {
          Logger.debug("Ignoring FCM message while app is not alive, but keepAppAlive is enabled");
          return Future.value(true);
        }

        try {
          Map<String, dynamic>? data = arguments;
          if (!isNullOrEmpty(data)) {
            final payload = ServerPayload.fromJson(data!);

            // Since this is an updated-message event, the message should exist in the DB.
            // So if there is no chat, we can find it from the message guid
            if (payload.data["chats"] == null || payload.data["chats"].isEmpty) {
              Logger.warn("No chat data found, attempting to find chat from message guid...");
              final existingMsg = Message.findOne(guid: payload.data["guid"]);
              if (existingMsg != null && existingMsg.chat.target != null) {
                Logger.debug("Found chat from message guid, adding to payload");
                payload.data['chats'] = [existingMsg.chat.target!.toMap()];
              } else {
                Logger.warn("No chat data found, and unable to find chat from message guid");
                return Future.value(false);
              }
            }

            await IncomingMsgHandler.handle(IncomingPayload(
              type: MessageEventType.updatedMessage,
              source: MessageSource.methodChannel,
              chat: Chat.fromMap(payload.data['chats'].first.cast<String, Object>()),
              message: Message.fromMap(payload.data),
              tempGuid: payload.data['tempGuid'],
            ));
          }
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(true);
      case "group-name-change":
      case "participant-removed":
      case "participant-added":
      case "participant-left":
        await Database.waitForInit();
        Logger.info("Received ${call.method} from MethodChannel");

        // Don't ignore chat updates when app is alive - they need to be processed
        if (shouldIgnoreMessage) {
          Logger.debug("Ignoring FCM message while app is not alive, but keepAppAlive is enabled");
          return Future.value(true);
        }

        try {
          Map<String, dynamic>? data = arguments;
          if (!isNullOrEmpty(data)) {
            final payload = ServerPayload.fromJson(data!);
            await MessageHandlerSvc.handleNewOrUpdatedChat(
                Chat.fromMap(payload.data['chats'].first.cast<String, Object>()));
          }
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(true);
      case "group-icon-changed":
        await Database.waitForInit();
        Logger.info("Received group icon change from MethodChannel");

        // Don't ignore icon changes when app is alive - they need to be processed
        if (shouldIgnoreMessage) {
          Logger.debug("Ignoring FCM message while app is not alive, but keepAppAlive is enabled");
          return Future.value(true);
        }

        try {
          Map<String, dynamic>? data = arguments;
          if (!isNullOrEmpty(data)) {
            final payload = ServerPayload.fromJson(data!);
            final guid = payload.data["chats"].first["guid"];
            final chat = Chat.findOne(guid: guid);
            if (chat != null) {
              await Chat.getIcon(chat);
            }
          }
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(true);
      case "scheduled-message-error":
        Logger.info("Received scheduled message error from FCM");
        try {
          Map<String, dynamic>? data = arguments;
          if (data == null) return Future.value(true);
          final payload = ServerPayload.fromJson(data);
          Chat? chat = Chat.findOne(guid: payload.data["payload"]["chatGuid"]);
          if (chat != null) {
            await NotificationsSvc.createFailedToSend(chat, scheduled: true);
          }
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(true);
      case "ReplyChat":
        await Database.waitForInit();
        await PushSvc.initFuture;
        Logger.info("Received reply to message from Kotlin");
        final Map<String, dynamic>? data = arguments;
        if (data == null) return Future.value(true);

        // check and make sure that we aren't sending a duplicate reply
        final recentReplyGuid = PrefsSvc.i.getString("recent-reply")?.split("/").first;
        final recentReplyText = PrefsSvc.i.getString("recent-reply")?.split("/").last;
        if (recentReplyGuid == data["messageGuid"] && recentReplyText == data["text"]) return Future.value(false);
        await PrefsSvc.i.setString("recent-reply", "${data["messageGuid"]}/${data["text"]}");
        Logger.info("Updated recent reply cache to ${PrefsSvc.i.getString("recent-reply")}");
        Chat? chat = Chat.findOne(guid: data["chatGuid"]);
        if (chat == null) {
          return Future.value(false);
        } else {
          final Completer<void> completer = Completer();
          OutgoingMsgHandler.queue(OutgoingItem(
              type: QueueType.sendMessage,
              completer: completer,
              chat: chat,
              message: Message(
                text: data['text'],
                dateCreated: DateTime.now(),
                hasAttachments: false,
                isFromMe: true,
                handleId: 0,
              ),
              customArgs: {'notifReply': true}));
          await completer.future;
          return Future.value(true);
        }
      case "MarkChatRead":
        if (!headless && LifecycleSvc.isAlive) return Future.value(true);
        await Database.waitForInit();
        Logger.info("Received markAsRead from Kotlin");

        try {
          final Map<String, dynamic>? data = arguments;
          if (data != null) {
            Chat? chat = Chat.findOne(guid: data["chatGuid"]);
            if (chat != null) {
              // Don't clear local notifications because tapping Mark as Read should clear the notification automatically
              await chat.toggleHasUnreadAsync(false, clearLocalNotifications: false);
              // The save goes through the GlobalIsolate, so ChatsService is never notified.
              // Explicitly update the ChatState so the UI reflects the change immediately.
              ChatsSvc.getChatState(chat.guid)?.updateHasUnreadInternal(false);
              return Future.value(true);
            }
          }
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(false);
      case "chat-read-status-changed":
        if (!headless && LifecycleSvc.isAlive) return Future.value(true);
        await Database.waitForInit();
        Logger.info("Received chat status change from FCM");

        try {
          Map<String, dynamic>? data = arguments;
          if (!isNullOrEmpty(data)) {
            final payload = ServerPayload.fromJson(data!);
            Chat? chat = Chat.findOne(guid: payload.data["chatGuid"]);
            if (chat == null || (payload.data["read"] != true && payload.data["read"] != false)) {
              return Future.value(false);
            } else {
              chat.toggleHasUnreadAsync(!payload.data["read"]!, privateMark: false);
              return Future.value(true);
            }
          } else {
            return Future.value(false);
          }
        } catch (e, s) {
          return Future.error(e, s);
        }
      case "MediaColors":
        await Database.waitForInit();
        if (!SettingsSvc.settings.colorsFromMedia.value) return Future.value(true);

        final Uint8List art = call.arguments["albumArt"];
        if (Get.context != null && (!isRunning || art != previousArt)) {
          ThemeSvc.updateMusicTheme(Get.context!, art);
          isRunning = false;
        }

        return Future.value(true);
      case "sim-info":
        final info = (arguments?["info"] as List<dynamic>? ?? <dynamic>[])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        simInfo.assignAll(info);
        return Future.value(true);
      case "incoming-facetime":
        await Database.waitForInit();
        Logger.info("Received legacy incoming facetime from FCM");
        try {
          Map<String, dynamic>? data = arguments;
          if (!isNullOrEmpty(data)) {
            final payload = ServerPayload.fromJson(data!);
            await ActionHandler().handleIncomingFaceTimeCallLegacy(payload.data);
          }
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(true);
      case "ft-call-status-changed":
        if (!headless && LifecycleSvc.isAlive) return Future.value(true);
        await Database.waitForInit();
        Logger.info("Received facetime call status change from FCM");

        try {
          Map<String, dynamic>? data = arguments;
          if (!isNullOrEmpty(data)) {
            final payload = ServerPayload.fromJson(data!);
            await ActionHandler().handleFaceTimeStatusChange(payload.data);
          }
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(true);
      case "answer-facetime":
        Logger.info("Answering FaceTime call");
        final Map<String, dynamic>? data = arguments;
        if (data == null) return Future.value(true);
        await IntentsSvc.answerFaceTime(data["callUuid"]);
        return Future.value(true);
      case "imessage-aliases-removed":
        Map<String, dynamic>? data = arguments;
        try {
          if (!isNullOrEmpty(data)) {
            final payload = ServerPayload.fromJson(data!);
            Logger.info("Alias(es) removed ${payload.data["aliases"]}");
            await NotificationsSvc.createAliasesRemovedNotification((payload.data["aliases"] as List).cast<String>());
          } else {
            Logger.warn("Aliases removed data empty or null");
          }
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(true);
      case "socket-event":
        Map<String, dynamic>? data = arguments;
        if (data == null) return Future.value(true);

        try {
          final Map<String, dynamic> jsonData = jsonDecode(data['data']);
          await MessageHandlerSvc.handleEvent(data['event'], jsonData, 'MethodChannel', useQueue: false);
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(true);
      case "unifiedpush-settings":
        Map<String, dynamic>? data = arguments;
        if (data == null) return false;

        try {
          final String endpoint = data['endpoint'].toString();
          upr.update(endpoint);
        } catch (e, s) {
          return Future.error(e, s);
        }

        return Future.value(true);
      default:
        return Future.value(true);
    }
  }

  Future<dynamic> invokeMethod(String method, [dynamic arguments]) async {
    if (kIsWeb || kIsDesktop) return;
    Logger.info("Sending method $method to Kotlin");
    return await channel.invokeMethod(method, arguments);
  }

  /// Not in the NotificationService to avoid circular dependency.
  /// The method channel service handles kotlin messages, which may
  /// invoke actions that use notifications (i.e. new-message events).
  Future<void> createAllNotificationChannels() async {
    await createNotificationChannel(
      NotificationsService.NEW_MESSAGE_CHANNEL,
      "New Messages",
      "Displays all received new messages",
    );
    await createNotificationChannel(
      NotificationsService.ERROR_CHANNEL,
      "Errors",
      "Displays message send failures, connection failures, and more",
    );
    await createNotificationChannel(NotificationsService.SHARED_STREAMS_CHANNEL, "Shared Albums",
        "Displays invitations and updates for shared albums.");
    await createNotificationChannel(
      NotificationsService.REMINDER_CHANNEL,
      "Message Reminders",
      "Displays message reminders set through the app",
    );
    await createNotificationChannel(
      NotificationsService.FACETIME_CHANNEL,
      "Incoming FaceTimes",
      "Displays incoming FaceTimes detected by the server",
    );
    await createNotificationChannel(
      NotificationsService.FOREGROUND_SERVICE_CHANNEL,
      "Foreground Service",
      "Allows BlueBubbles to stay open in the background for notifications if FCM is not being used",
    );
    await createNotificationChannel(
        NotificationsService.AUTH_CODES_CHANNEL, "Apple Account login requests", "Shows Apple Account login requests");
    await createNotificationChannel(
        NotificationsService.SYNC_STATUS_CHANNEL, "Sync Status", "View the status of iCloud syncing.");
    await createNotificationChannel(NotificationsService.SHARED_BEACONS_CHANNEL, "Shared Items",
        "Displays invitations and updates for shared items.");
  }

  Future<void> createNotificationChannel(String channelID, String channelName, String channelDescription) async {
    await invokeMethod("create-notification-channel", {
      "channel_name": channelName,
      "channel_description": channelDescription,
      "channel_id": channelID,
    });
  }
}
