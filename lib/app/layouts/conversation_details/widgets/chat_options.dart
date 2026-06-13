import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/chat_sync_dialog.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/timeframe_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/app/layouts/settings/pages/profile/poster_edit.dart';
import 'package:bluebubbles/app/layouts/settings/pages/profile/posterkit.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/avatar/avatar_crop.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/background/background_crop.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/main.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:universal_io/io.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'dart:math' as math;

class ChatOptions extends StatefulWidget {
  const ChatOptions({super.key, required this.chat});

  final Chat chat;

  @override
  State<StatefulWidget> createState() => _ChatOptionsState();
}

class _ChatOptionsState extends State<ChatOptions> with ThemeHelpers {
  Chat get chat => widget.chat;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AdaptiveTheme.of(context).theme,
      child: SliverToBoxAdapter(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 15.0, bottom: 5.0),
              child: Text("OPTIONS & ACTIONS",
                  style: context.theme.textTheme.bodyMedium!.copyWith(color: context.theme.colorScheme.outline)),
            ),
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                if (!kIsWeb && !kIsDesktop && (FilesystemSvc.androidInfo?.version.sdkInt ?? 0) >= 30)
                  SettingsTile(
                    title: "Notification Settings",
                    subtitle: "Customize notification sounds, importance, and more for this specific chat",
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 15.0),
                      child: Icon(
                        iOS ? CupertinoIcons.bell : Icons.notifications_on,
                      ),
                    ),
                    isThreeLine: true,
                    onTap: () async {
                      await MethodChannelSvc.actions.openConversationNotificationSettings(
                        channelId: chat.guid,
                        displayName: chat.getTitle(),
                      );
                    },
                  ),
                if (!kIsWeb)
                  SettingsTile(
                    title: "Change Chat Avatar",
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 15.0),
                      child: Icon(
                        SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.person : Icons.person_outlined,
                      ),
                    ),
                    onTap: () async {
                      if (chat.customAvatarPath != null) {
                        showDialog(
                          context: context,
                          builder: (BuildContext context) {
                            return AlertDialog(
                                backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                                title: Text("Custom Avatar", style: context.theme.textTheme.titleLarge),
                                content: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("You already have a custom avatar for this chat. What would you like to do?",
                                        style: context.theme.textTheme.bodyLarge),
                                  ],
                                ),
                                actions: <Widget>[
                                  TextButton(
                                    child: Text("Cancel",
                                        style: context.theme.textTheme.bodyLarge!
                                            .copyWith(color: context.theme.colorScheme.primary)),
                                    onPressed: () {
                                      Navigator.of(context, rootNavigator: true).pop();
                                    },
                                  ),
                                  TextButton(
                                    child: Text("Reset",
                                        style: context.theme.textTheme.bodyLarge!
                                            .copyWith(color: context.theme.colorScheme.primary)),
                                    onPressed: () async {
                                      await ChatsSvc.setChatCustomAvatarPath(chat, null);
                                      Navigator.of(context, rootNavigator: true).pop();
                                    },
                                  ),
                                  TextButton(
                                    child: Text("Set New",
                                        style: context.theme.textTheme.bodyLarge!
                                            .copyWith(color: context.theme.colorScheme.primary)),
                                    onPressed: () async {
                                      Navigator.of(context, rootNavigator: true).pop();
                                      final result = await Get.to<String?>(() => AvatarCrop(chat: chat));
                                      if (result != null) {
                                        await ChatsSvc.setChatCustomAvatarPath(chat, result);
                                      }
                                    },
                                  ),
                                ]);
                          },
                        );
                      } else {
                        final result = await Get.to<String?>(() => AvatarCrop(chat: chat));
                        if (result == null) return;
                        await ChatsSvc.setChatCustomAvatarPath(chat, result);
                      }
                    },
                  ),
                if (!kIsWeb && !usingRustPush)
                  SettingsTile(
                    title: "Custom Background",
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 15.0),
                      child: Icon(
                        iOS ? CupertinoIcons.photo : Icons.wallpaper,
                      ),
                    ),
                    onTap: () {
                      if (chat.customBackgroundPath != null) {
                        showDialog(
                          context: context,
                          builder: (BuildContext context) {
                            return AlertDialog(
                              backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                              title: Text("Custom Background", style: context.theme.textTheme.titleLarge),
                              content: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "You already have a custom background for this chat. What would you like to do?",
                                    style: context.theme.textTheme.bodyLarge,
                                  ),
                                ],
                              ),
                              actions: <Widget>[
                                TextButton(
                                  child: Text("Cancel",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () {
                                    Navigator.of(context, rootNavigator: true).pop();
                                  },
                                ),
                                TextButton(
                                  child: Text("Remove",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.error)),
                                  onPressed: () async {
                                    final File bgFile = File(chat.customBackgroundPath!);
                                    if (await bgFile.exists()) bgFile.delete();
                                    await ChatsSvc.setChatCustomBackgroundPath(chat, null);
                                    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                                  },
                                ),
                                TextButton(
                                  child: Text("Set New",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () {
                                    Navigator.of(context, rootNavigator: true).pop();
                                    Get.to(() => BackgroundCrop(chat: chat));
                                  },
                                ),
                              ],
                            );
                          },
                        );
                      } else {
                        Get.to(() => BackgroundCrop(chat: chat));
                      }
                    },
                  ),
                SettingsTile(
                  title: chat.transcriptPosterPath != null ? "Change Chat Background" : "Set Chat Background",
                  trailing: Padding(
                    padding: const EdgeInsets.only(right: 15.0),
                    child: Icon(
                      SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.photo : Icons.photo,
                    ),
                  ),
                  onTap: () {
                    var randomColor = Color((math.Random().nextDouble() * 0xFFFFFF).toInt()).withOpacity(1.0);
                    Navigator.of(context).push(
                      ThemeSwitcher.buildPageRoute(
                        builder: (context) => PosterEdit(
                          transcriptPoster: cvc(chat).backgroundPoster.value ??
                              api.SimplifiedTranscriptPoster(
                                  poster: createNewPoster(
                                      const api.PosterType.transcriptDynamic(
                                          data: api.TranscriptDynamicUserData(identifier: "")),
                                      randomColor,
                                      api.PosterRole.prPosterRoleBackdrop),
                                  watch: api.WatchBackground(
                                      isHighKey: false,
                                      luminance: 0,
                                      backgroundImageData: Uint8List(0),
                                      extensionIdentifier: "com.apple.ContactsUI.MonogramPosterExtension")),
                          activePath: chat.transcriptPosterPath,
                          posterEdited: (newPath) async {
                            if (chat.transcriptPosterPath != newPath && chat.transcriptPosterPath != null) {
                              await PushSvc.deletePoster(chat.transcriptPosterPath!);
                            }

                            chat.transcriptPosterPath = newPath;
                            chat.save(updateTranscriptPosterPath: true);
                            cvc(chat).updatePoster();
                            setState(() {});
                            await PushSvc.updateChatPoster(chat);
                          },
                        ),
                      ),
                    );
                  },
                ),
                if (chat.transcriptPosterPath != null)
                  SettingsTile(
                    title: "Remove Chat Background",
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 15.0),
                      child: Icon(
                        SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.clear : Icons.clear,
                      ),
                    ),
                    onTap: () async {
                      if (chat.transcriptPosterPath != null) {
                        await PushSvc.deletePoster(chat.transcriptPosterPath!);
                      }

                      chat.transcriptPosterPath = null;
                      chat.save(updateTranscriptPosterPath: true);
                      cvc(chat).updatePoster();
                      setState(() {});
                      await PushSvc.updateChatPoster(chat);
                    },
                  ),
                if (iOS)
                  SettingsTile(
                      title: "View Bookmarks",
                      subtitle: "See your bookmarked messages",
                      backgroundColor: tileColor,
                      trailing: Padding(
                        padding: const EdgeInsets.only(right: 15.0),
                        child: Icon(iOS ? CupertinoIcons.bookmark : Icons.bookmark),
                      ),
                      onTap: () async {
                        showBookmarksThread(cvc(widget.chat), context);
                      }),
                if (BackendSvc.getRemoteService() != null)
                  SettingsTile(
                      title: "Fetch Chat Details",
                      subtitle: "Get the latest chat title and participants from the server",
                      backgroundColor: tileColor,
                      trailing: Padding(
                        padding: const EdgeInsets.only(right: 15.0),
                        child: Icon(iOS ? CupertinoIcons.chat_bubble : Icons.sms),
                      ),
                      onTap: () async {
                        await ChatsSvc.fetchChat(chat.guid);
                        showSnackbar("Notice", "Fetched details!");
                      }),
                if (BackendSvc.getRemoteService() != null)
                  SettingsTile(
                    title: "Fetch More Messages",
                    subtitle: "Fetches up to 100 messages after the last message stored locally",
                    isThreeLine: true,
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 15.0),
                      child: Icon(iOS ? CupertinoIcons.cloud_download : Icons.file_download),
                    ),
                    onTap: () async {
                      await showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (context) => ChatSyncDialog(
                          chat: chat,
                          withOffset: true,
                          initialMessage: "Fetching more messages...",
                          limit: 100,
                        ),
                      );
                    },
                  ),
                if (BackendSvc.getRemoteService() != null)
                  SettingsTile(
                    title: "Sync Last 25 Messages",
                    subtitle: "Resyncs the 25 most recent messages from the server",
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 15.0),
                      child: Icon(iOS ? CupertinoIcons.arrow_counterclockwise : Icons.replay),
                    ),
                    onTap: () {
                      showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (context) =>
                            ChatSyncDialog(chat: chat, initialMessage: "Resyncing messages...", limit: 25),
                      );
                    },
                  ),
                if (!kIsWeb && SettingsSvc.settings.enablePrivateAPI.value) const SettingsDivider(),
                if (!kIsWeb && SettingsSvc.settings.enablePrivateAPI.value)
                  Obx(() {
                    final chatState = ChatsSvc.getChatState(chat.guid);
                    return SettingsSwitch(
                      title: "Send Typing Indicators",
                      initialVal: chatState?.autoSendTypingIndicators.value ??
                          SettingsSvc.settings.privateSendTypingIndicators.value,
                      onChanged: (value) {
                        if (chatState != null) {
                          ChatsSvc.setChatAutoSendTypingIndicators(chatState.chat, value);
                        } else {
                          chat.toggleAutoTypeAsync(value);
                        }
                      },
                      backgroundColor: tileColor,
                    );
                  }),
                if (!kIsWeb && SettingsSvc.settings.enablePrivateAPI.value)
                  Obx(() {
                    final chatState = ChatsSvc.getChatState(chat.guid);
                    return SettingsSwitch(
                      title: "Follow Global Setting",
                      subtitle:
                          "Typing Indicators ${SettingsSvc.settings.privateSendTypingIndicators.value ? "Enabled" : "Disabled"}",
                      initialVal: chatState?.autoSendTypingIndicators.value == null,
                      onChanged: (value) {
                        if (chatState != null) {
                          ChatsSvc.setChatAutoSendTypingIndicators(
                            chatState.chat,
                            value ? null : SettingsSvc.settings.privateSendTypingIndicators.value,
                          );
                        } else {
                          chat.toggleAutoTypeAsync(
                              value ? null : SettingsSvc.settings.privateSendTypingIndicators.value);
                        }
                      },
                    );
                  }),
                if (!kIsWeb && SettingsSvc.settings.enablePrivateAPI.value) const SettingsDivider(),
                if (!kIsWeb && SettingsSvc.settings.enablePrivateAPI.value)
                  Obx(() {
                    final chatState = ChatsSvc.getChatState(chat.guid);
                    return SettingsSwitch(
                      title:
                          "${SettingsSvc.settings.privateManualMarkAsRead.value ? "Automatically " : ""}Send Read Receipts",
                      initialVal:
                          chatState?.autoSendReadReceipts.value ?? SettingsSvc.settings.privateMarkChatAsRead.value,
                      onChanged: (value) {
                        if (chatState != null) {
                          ChatsSvc.setChatAutoSendReadReceipts(chatState.chat, value);
                        } else {
                          chat.toggleAutoReadAsync(value);
                        }
                      },
                      backgroundColor: tileColor,
                    );
                  }),
                if (!kIsWeb && SettingsSvc.settings.enablePrivateAPI.value)
                  Obx(() {
                    final chatState = ChatsSvc.getChatState(chat.guid);
                    return SettingsSwitch(
                      title: "Follow Global Setting",
                      subtitle:
                          "${SettingsSvc.settings.privateManualMarkAsRead.value ? "Automatic " : ""}Read Receipts ${SettingsSvc.settings.privateMarkChatAsRead.value ? "Enabled" : "Disabled"}",
                      initialVal: chatState?.autoSendReadReceipts.value == null,
                      onChanged: (value) {
                        if (chatState != null) {
                          ChatsSvc.setChatAutoSendReadReceipts(
                            chatState.chat,
                            value ? null : SettingsSvc.settings.privateMarkChatAsRead.value,
                          );
                        } else {
                          chat.toggleAutoReadAsync(value ? null : SettingsSvc.settings.privateMarkChatAsRead.value);
                        }
                      },
                    );
                  }),
                if ((!kIsWeb && !chat.isGroup && SettingsSvc.settings.enablePrivateAPI.value) || chat.isGroup)
                  const SettingsDivider(),
                if (!kIsWeb &&
                    !chat.isGroup &&
                    SettingsSvc.settings.enablePrivateAPI.value &&
                    (() {
                      final contact = ContactV2.findOne(address: chat.handles.firstOrNull?.address);
                      return contact != null && !contact.isSharedSuggestion;
                    })())
                  SettingsSwitch(
                    title: "Share Status",
                    initialVal: chat.shareZenMode ?? SettingsSvc.settings.enableShareZen.value,
                    onChanged: (value) async {
                      if (!SettingsSvc.settings.enableShareZen.value) {
                        if (!await PushSvc.setupZenMode(true)) return;
                      }
                      chat.shareZenMode = value;
                      await chat.saveAsync(updateShareZenMode: true);
                      setState(() {});
                      chat.fixZenModeShared();
                    },
                    backgroundColor: tileColor,
                  ),
                if (chat.isGroup)
                  Obx(() {
                    final chatState = ChatsSvc.getChatState(chat.guid);
                    return SettingsSwitch(
                      title: "Lock Chat Name",
                      subtitle:
                          "Keep the current chat name on this device, even if someone else in the chat changes it",
                      initialVal: chatState?.lockChatName.value ?? chat.lockChatName,
                      onChanged: (value) {
                        if (chatState != null) {
                          ChatsSvc.setChatLockName(chatState.chat, value);
                        } else {
                          chat.lockChatName = value;
                          chat.saveAsync(updateLockChatName: true);
                        }
                      },
                    );
                  }),
                if (chat.isGroup)
                  Obx(() {
                    final chatState = ChatsSvc.getChatState(chat.guid);
                    return SettingsSwitch(
                      title: "Lock Chat Icon",
                      subtitle:
                          "Keep the current chat icon on this device, even if someone else in the chat changes it",
                      initialVal: chatState?.lockChatIcon.value ?? chat.lockChatIcon,
                      onChanged: (value) {
                        if (chatState != null) {
                          ChatsSvc.setChatLockIcon(chatState.chat, value);
                        } else {
                          chat.lockChatIcon = value;
                          chat.saveAsync(updateLockChatIcon: true);
                        }
                      },
                    );
                  }),
                if (chat.isGroup) const SettingsDivider(),
                if (!kIsWeb)
                  Obx(() {
                    final chatState = ChatsSvc.getChatState(chat.guid);
                    return SettingsSwitch(
                      title: "Pin Conversation",
                      initialVal: chatState?.isPinned.value ?? chat.isPinned!,
                      onChanged: (value) {
                        if (chatState != null) {
                          ChatsSvc.setChatPinned(chatState.chat, !chatState.isPinned.value);
                        } else {
                          ChatsSvc.toggleChatPin(chat, !chat.isPinned!);
                        }
                      },
                      backgroundColor: tileColor,
                    );
                  }),
                if (!kIsWeb)
                  Obx(() {
                    final chatState = ChatsSvc.getChatState(chat.guid);
                    return SettingsSwitch(
                      title: "Mute Conversation",
                      initialVal: (chatState?.muteType.value ?? chat.muteType) == "mute",
                      onChanged: (value) {
                        if (chatState != null) {
                          ChatsSvc.setChatMuted(chatState.chat, value);
                        } else {
                          chat.toggleMuteAsync(value);
                        }
                      },
                      backgroundColor: tileColor,
                    );
                  }),
                if (!kIsWeb)
                  Obx(() {
                    final chatState = ChatsSvc.getChatState(chat.guid);
                    return SettingsSwitch(
                      title: "Archive Conversation",
                      initialVal: chatState?.isArchived.value ?? chat.isArchived!,
                      onChanged: (value) {
                        if (chatState != null) {
                          ChatsSvc.setChatArchived(chatState.chat, value);
                        } else {
                          ChatsSvc.toggleChatArchive(chat, value);
                        }
                      },
                      backgroundColor: tileColor,
                    );
                  }),
                if (!kIsWeb && !chat.isGroup && chat.handles.length == 1)
                  SettingsSwitch(
                    title: "Block Sender",
                    initialVal: chat.handles.first.isBlocked(),
                    onChanged: (value) {
                      if (value) {
                        showDialog(
                          context: context,
                          builder: (BuildContext context) {
                            return AlertDialog(
                                backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                                title:
                                    Text("Are you sure you want to block?", style: context.theme.textTheme.titleLarge),
                                content: Text(
                                  'You will not receive notifications or calls from this user, and their messages will not be marked as delivered.',
                                  style: context.theme.textTheme.bodyLarge,
                                ),
                                actions: <Widget>[
                                  TextButton(
                                    child: Text("Cancel",
                                        style: context.theme.textTheme.bodyLarge!
                                            .copyWith(color: context.theme.colorScheme.primary)),
                                    onPressed: () {
                                      Navigator.of(context, rootNavigator: true).pop();
                                    },
                                  ),
                                  TextButton(
                                    child: Text("Block",
                                        style: context.theme.textTheme.bodyLarge!
                                            .copyWith(color: context.theme.colorScheme.primary)),
                                    onPressed: () async {
                                      Navigator.of(context, rootNavigator: true).pop();
                                      chat.handles.first.setBlocked(true);
                                      setState(() {});
                                    },
                                  ),
                                  TextButton(
                                    child: Text("Block and archive",
                                        style: context.theme.textTheme.bodyLarge!
                                            .copyWith(color: context.theme.colorScheme.primary)),
                                    onPressed: () async {
                                      Navigator.of(context, rootNavigator: true).pop();
                                      chat.handles.first.setBlocked(true);
                                      await ChatsSvc.toggleChatArchive(chat, true);
                                      setState(() {});
                                    },
                                  ),
                                ]);
                          },
                        );
                      } else {
                        chat.handles.first.setBlocked(false);
                        ChatsSvc.toggleChatArchive(chat, false);
                        setState(() {});
                      }
                    },
                    backgroundColor: tileColor,
                  ),
                if (!kIsWeb)
                  SettingsTile(
                    title: "Clear Transcript",
                    subtitle: "Delete all messages for this chat on this device",
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 15.0),
                      child: Icon(iOS ? CupertinoIcons.trash : Icons.delete_outlined),
                    ),
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                              backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                              title: Text("Are You Sure?", style: context.theme.textTheme.titleLarge),
                              content: Text(
                                'Clearing the transcript will permanently delete all messages in this chat. It will also prevent any previous messages from being loaded by the app, until you perform a full reset.',
                                style: context.theme.textTheme.bodyLarge,
                              ),
                              actions: <Widget>[
                                TextButton(
                                  child: Text("Cancel",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () {
                                    Navigator.of(context, rootNavigator: true).pop();
                                  },
                                ),
                                TextButton(
                                  child: Text("Yes",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () async {
                                    Navigator.of(context, rootNavigator: true).pop();
                                    chat.clearTranscript();
                                    EventDispatcherSvc.emit("refresh-messagebloc", {"chatGuid": chat.guid});
                                  },
                                ),
                              ]);
                        },
                      );
                    },
                  ),
                if (!kIsWeb)
                  SettingsTile(
                    title: "Download Chat Transcript",
                    subtitle: kIsDesktop
                        ? "Left click for a plaintext transcript\nRight click for a PDF transcript"
                        : "Tap for a plaintext transcript\nTap and hold for a PDF transcript",
                    isThreeLine: true,
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 15.0),
                      child: Icon(iOS ? CupertinoIcons.doc_text : Icons.note_outlined),
                    ),
                    onTap: () async {
                      final date =
                          await showTimeframePicker("Select Timeframe", context, additionalTimeframes: {"6 Hours": 6});
                      if (date == null) return;
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text("Generating document...", style: context.theme.textTheme.titleLarge),
                          content: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const SizedBox(
                                height: 15.0,
                              ),
                              buildProgressIndicator(context),
                            ],
                          ),
                          backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                        ),
                        barrierDismissible: false,
                      );
                      final messages = (await Chat.getMessagesAsync(chat, limit: 0, includeDeleted: true))
                          .reversed
                          .where((e) => e.dateCreated!.isAfter(date));
                      if (messages.isEmpty) {
                        Navigator.of(context, rootNavigator: true).pop();
                        showSnackbar("Error", "No messages found!");
                        return;
                      }
                      final List<String> lines = [];
                      for (Message m in messages) {
                        final readStr = m.dateRead != null ? "Read: ${buildFullDate(m.dateRead!)}, " : "";
                        final deliveredStr =
                            m.dateDelivered != null ? "Delivered: ${buildFullDate(m.dateDelivered!)}, " : "";
                        final sentStr = "Sent: ${buildFullDate(m.dateCreated!)}";
                        final text = m.getNotificationText(withSender: true);
                        final line = "($readStr$deliveredStr$sentStr) $text";
                        lines.add(line);
                      }
                      final now = DateTime.now().toLocal();
                      final filePath = p.join(await FilesystemSvc.downloadsDirectory,
                          "${chat.getTitle().replaceAll(RegExp(r'[<>:"/\\|?*]'), "")}-transcript-${now.year}${now.month}${now.day}_${now.hour}${now.minute}${now.second}.txt");
                      File file = File(filePath);
                      await file.create(recursive: true);
                      await file.writeAsString(lines.join('\n'));
                      Navigator.of(context, rootNavigator: true).pop();
                      showSnackbar("Success", "Saved transcript to the downloads folder");
                    },
                    onLongPress: () async {
                      final date =
                          await showTimeframePicker("Select Timeframe", context, additionalTimeframes: {"6 Hours": 6});
                      if (date == null) return;
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text("Generating PDF...", style: context.theme.textTheme.titleLarge),
                          content: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const SizedBox(
                                  height: 15.0,
                                ),
                                buildProgressIndicator(context),
                              ]),
                          backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                        ),
                        barrierDismissible: false,
                      );
                      final messages = (await Chat.getMessagesAsync(chat, limit: 0, includeDeleted: true))
                          .reversed
                          .where((e) => e.dateCreated!.isAfter(date));
                      if (messages.isEmpty) {
                        Navigator.of(context, rootNavigator: true).pop();
                        showSnackbar("Error", "No messages found!");
                        return;
                      }
                      final doc = pw.Document();
                      final List<String> timestamps = [];
                      final List<dynamic> content = [];
                      final List<Size?> dimensions = [];
                      for (Message m in messages) {
                        final readStr = m.dateRead != null ? "Read: ${buildFullDate(m.dateRead!)}, " : "";
                        final deliveredStr =
                            m.dateDelivered != null ? "Delivered: ${buildFullDate(m.dateDelivered!)}, " : "";
                        final sentStr = "Sent: ${buildFullDate(m.dateCreated!)}";
                        if (m.hasAttachments) {
                          final attachments = m.dbAttachments.where(
                              (e) => e.guid != null && ["image/png", "image/jpg", "image/jpeg"].contains(e.mimeType));
                          final files = attachments
                              .map((e) => AttachmentsSvc.getContent(e, autoDownload: false))
                              .whereType<PlatformFile>();
                          if (files.isNotEmpty) {
                            for (PlatformFile f in files) {
                              final a = attachments.firstWhere((e) => e.transferName == f.name);
                              timestamps.add(readStr + deliveredStr + sentStr);
                              content.add(pw.MemoryImage(await File(f.path!).readAsBytes()));
                              final aspectRatio = (a.width ?? 150.0) / (a.height ?? 150.0);
                              dimensions.add(Size(400, aspectRatio * 400));
                            }
                          }
                          timestamps.add(readStr + deliveredStr + sentStr);
                          content.add(m.getNotificationText(withSender: true));
                          dimensions.add(null);
                        } else {
                          timestamps.add(readStr + deliveredStr + sentStr);
                          content.add(m.getNotificationText(withSender: true));
                          dimensions.add(null);
                        }
                      }
                      final font = await PdfGoogleFonts.openSansRegular();
                      doc.addPage(pw.MultiPage(
                          maxPages: 1000,
                          header: (pw.Context context) => pw.Padding(
                              padding: const pw.EdgeInsets.only(bottom: 10),
                              child: pw.Text(chat.getTitle(),
                                  textScaleFactor: 2,
                                  style: pw.Theme.of(context)
                                      .defaultTextStyle
                                      .copyWith(fontWeight: pw.FontWeight.bold, font: font))),
                          build: (pw.Context context) => [
                                pw.Partitions(children: [
                                  pw.Partition(
                                      child: pw.Table(
                                          children: List.generate(
                                              timestamps.length,
                                              (index) => pw.TableRow(children: [
                                                    pw.Padding(
                                                      padding:
                                                          const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 10),
                                                      child: pw.Text(timestamps[index],
                                                          style: pw.Theme.of(context)
                                                              .defaultTextStyle
                                                              .copyWith(font: font)),
                                                    ),
                                                    pw.Container(
                                                        child: pw.Padding(
                                                            padding: const pw.EdgeInsets.symmetric(
                                                                horizontal: 3, vertical: 10),
                                                            child: content[index] is pw.MemoryImage
                                                                ? pw.Image(content[index],
                                                                    width: dimensions[index]!.width,
                                                                    height: dimensions[index]!.height)
                                                                : pw.Text(content[index].toString(),
                                                                    style: pw.TextStyle(font: font))))
                                                  ])))),
                                ]),
                              ]));
                      final now = DateTime.now().toLocal();
                      final filePath = p.join(await FilesystemSvc.downloadsDirectory,
                          "${chat.getTitle().replaceAll(RegExp(r'[<>:"/\\|?*]'), "")}-transcript-${now.year}${now.month}${now.day}_${now.hour}${now.minute}${now.second}.pdf");
                      File file = File(filePath);
                      await file.create(recursive: true);
                      await file.writeAsBytes(await doc.save());
                      Navigator.of(context, rootNavigator: true).pop();
                      showSnackbar("Success", "Saved transcript to the downloads folder");
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
