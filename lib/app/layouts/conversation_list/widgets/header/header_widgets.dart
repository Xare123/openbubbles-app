import 'package:auto_size_text/auto_size_text.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:bluebubbles/app/layouts/facetime/facetime.dart';
import 'package:bluebubbles/app/layouts/settings/pages/misc/shared_streams_panel.dart';
import 'package:bluebubbles/app/layouts/settings/pages/passwords/passwords_panel.dart';
import 'package:bluebubbles/app/layouts/settings/pages/profile/profile_panel.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/settings/settings_page.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:get/get.dart';
import 'package:pull_down_button/pull_down_button.dart';

class HeaderText extends StatelessWidget {
  const HeaderText({super.key, required this.controller, this.fontSize});

  final ConversationListController controller;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10.0),
      child: AutoSizeText(
        controller.showArchivedChats
            ? "Archive"
            : controller.showUnknownSenders
                ? "Unknown Senders"
                : controller.showDeletedMessages
                    ? "Recently Deleted"
                    : "Messages",
        style: context.textTheme.headlineLarge!.copyWith(
          color: context.theme.colorScheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: fontSize,
        ),
        maxLines: 1,
      ),
    );
  }
}

class SyncIndicator extends StatelessWidget {
  final double size;

  const SyncIndicator({super.key, this.size = 12});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!SettingsSvc.settings.showSyncIndicator.value || !SyncSvc.isIncrementalSyncing.value) {
        return const SizedBox.shrink();
      }
      return buildProgressIndicator(context, size: size);
    });
  }
}

class OverflowMenu extends StatelessWidget {
  final bool extraItems;
  final ConversationListController? controller;
  const OverflowMenu({super.key, this.extraItems = false, this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (SettingsSvc.settings.skin.value == Skins.iOS) {
        return CupertinoOverflowMenu(extraItems: extraItems, controller: controller);
      }

      return MaterialAvatarMenu(controller: controller, extraItems: extraItems);
    });
  }
}

class MaterialAvatarMenu extends StatefulWidget {
  const MaterialAvatarMenu({
    super.key,
    required this.controller,
    required this.extraItems,
  });

  final ConversationListController? controller;
  final bool extraItems;

  @override
  State<MaterialAvatarMenu> createState() => _MaterialAvatarMenuState();
}

class _MaterialAvatarMenuState extends State<MaterialAvatarMenu> with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 250),
    );
    _scaleAnimation = CurvedAnimation(parent: _animationController, curve: Curves.easeOutBack);
    _fadeAnimation = CurvedAnimation(parent: _animationController, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _animationController.dispose();
    super.dispose();
  }

  void _showMenu() {
    if (_overlayEntry != null) {
      _hideMenu();
      return;
    }
    final navContext = context;
    _overlayEntry = _buildOverlayEntry(navContext);
    Overlay.of(navContext).insert(_overlayEntry!);
    _animationController.forward();
  }

  Future<void> _hideMenu() async {
    await _animationController.reverse();
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  OverlayEntry _buildOverlayEntry(BuildContext navContext) {
    return OverlayEntry(
      builder: (overlayContext) {
        final windowEffect = SettingsSvc.settings.windowEffect.value;
        final cardColor = overlayContext.theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: windowEffect != WindowEffect.disabled ? 0.95 : 1.0);
        final filterUnknownSenders = SettingsSvc.settings.filterUnknownSenders.value;
        final moveChatCreatorToHeader = SettingsSvc.settings.moveChatCreatorToHeader.value;
        final userName = SettingsSvc.settings.userName.value;
        final iCloudAccount = SettingsSvc.settings.iCloudAccount.value;

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _hideMenu,
                child: const SizedBox.expand(),
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 8),
              child: ScaleTransition(
                scale: _scaleAnimation,
                alignment: Alignment.topRight,
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(16),
                    color: cardColor,
                    child: SizedBox(
                      width: 240,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Profile header
                            InkWell(
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(16),
                                topRight: Radius.circular(16),
                              ),
                              onTap: () => _hideMenu().then((_) => goToProfile(navContext)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                child: Row(
                                  children: [
                                    const ContactAvatarWidget(
                                      size: 50,
                                      preferHighResAvatar: true,
                                      borderThickness: 0.1,
                                      editable: false,
                                      fontSize: 16,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            userName.isNotEmpty ? userName : 'My Account',
                                            style: overlayContext.theme.textTheme.titleSmall?.copyWith(
                                              color: overlayContext.theme.colorScheme.onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            iCloudAccount.isNotEmpty ? iCloudAccount : 'Tap to open profile',
                                            style: overlayContext.theme.textTheme.bodySmall?.copyWith(
                                              color: overlayContext.theme.colorScheme.onSurfaceVariant
                                                  .withValues(alpha: 0.6),
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.chevron_right,
                                      color: overlayContext.theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                                      size: 20,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Divider(
                              height: 1,
                              thickness: 1,
                              indent: 16,
                              endIndent: 16,
                              color: overlayContext.theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.1),
                            ),
                            // Menu items
                            _MenuItemRow(
                              icon: Icons.done_all_outlined,
                              label: 'Mark All As Read',
                              onTap: () => _hideMenu().then((_) => ChatsSvc.markAllAsRead()),
                            ),
                            _MenuItemRow(
                              icon: Icons.archive_outlined,
                              label: 'Archived',
                              onTap: () => _hideMenu().then((_) => goToArchived(navContext)),
                            ),
                            if (filterUnknownSenders)
                              _MenuItemRow(
                                icon: Icons.person_off_outlined,
                                label: 'Unknown Senders',
                                onTap: () => _hideMenu().then((_) => goToUnknownSenders(navContext)),
                              ),
                            _MenuItemRow(
                              icon: Icons.delete_outline,
                              label: 'Recently Deleted',
                              onTap: () => _hideMenu().then((_) => goToRecentlyDeleted(navContext)),
                            ),
                            if (BackendSvc.supportsFindMy())
                              _MenuItemRow(
                                icon: Icons.location_on_outlined,
                                label: 'Map',
                                onTap: () => _hideMenu().then((_) => goToFindMy(navContext)),
                              ),
                            if (PushSvc.state?.icloudServices?.sharedstreams != null)
                              _MenuItemRow(
                                icon: Icons.photo_outlined,
                                label: 'Shared Albums',
                                onTap: () => _hideMenu().then((_) => goToSharedStreams(navContext)),
                              ),
                            _MenuItemRow(
                              icon: Icons.video_call_outlined,
                              label: 'Video Calls',
                              onTap: () => _hideMenu().then((_) => goToFaceTime(navContext)),
                            ),
                            if (PushSvc.state?.icloudServices?.keychain != null)
                              _MenuItemRow(
                                icon: Icons.key_outlined,
                                label: 'Passwords',
                                onTap: () => _hideMenu().then((_) => goToPasswords(navContext)),
                              ),
                            if (widget.extraItems)
                              _MenuItemRow(
                                icon: Icons.search,
                                label: 'Search',
                                onTap: () => _hideMenu().then((_) => goToSearch(navContext)),
                              ),
                            if (widget.extraItems && moveChatCreatorToHeader)
                              _MenuItemRow(
                                icon: Icons.edit_outlined,
                                label: 'New Chat',
                                onTap: () => _hideMenu().then((_) => widget.controller?.openNewChatCreator(navContext)),
                              ),
                            _MenuItemRow(
                              icon: Icons.settings_outlined,
                              label: 'Settings',
                              onTap: () => _hideMenu().then((_) => goToSettings(navContext)),
                            ),
                            if (kIsWeb)
                              _MenuItemRow(
                                icon: Icons.logout,
                                label: 'Logout',
                                onTap: () => _hideMenu().then((_) => logout(navContext)),
                              ),
                            const SizedBox(height: 4),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        onTap: _showMenu,
        child: Container(
          padding: const EdgeInsets.all(2),
          child: const ContactAvatarWidget(
            size: 32,
            preferHighResAvatar: true,
            borderThickness: 0.1,
            editable: false,
            fontSize: 12,
            scaleSize: false,
          ),
        ),
      ),
    );
  }
}

class _MenuItemRow extends StatelessWidget {
  const _MenuItemRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: context.theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 16),
              Text(
                label,
                style: context.theme.textTheme.bodyLarge?.copyWith(
                  color: context.theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CupertinoOverflowMenu extends StatelessWidget {
  const CupertinoOverflowMenu({
    super.key,
    required this.extraItems,
    required this.controller,
  });

  final bool extraItems;
  final ConversationListController? controller;

  @override
  Widget build(BuildContext context) {
    final userName = SettingsSvc.settings.userName.value;
    final filterUnknownSenders = SettingsSvc.settings.filterUnknownSenders.value;
    final moveChatCreatorToHeader = SettingsSvc.settings.moveChatCreatorToHeader.value;

    final itemTheme = PullDownMenuItemTheme(
      textStyle: TextStyle(
        color: context.theme.colorScheme.onSurface,
      ),
      onHoverTextColor: context.theme.colorScheme.onSurface,
      onHoverBackgroundColor: context.theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      subtitleStyle: TextStyle(
        color: context.theme.colorScheme.onSurface.withValues(alpha: 0.7),
      ),
    );

    return PullDownButton(
      animationAlignmentOverride: Alignment.topRight,
      routeTheme: PullDownMenuRouteTheme(
          backgroundColor: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.9)),
      itemBuilder: (context) => [
        PullDownMenuHeader(
          itemTheme: itemTheme,
          title: SettingsSvc.settings.redactedMode.value ? "User Name" : userName,
          icon: CupertinoIcons.chevron_right,
          leadingBuilder: (context, constraints) {
            return Container(
                constraints: constraints,
                child: const ContactAvatarWidget(
                    size: 50, preferHighResAvatar: true, borderThickness: 0.1, editable: false, fontSize: 16));
          },
          subtitle: "Tap to open profile",
          onTap: () => goToProfile(context),
        ),
        PullDownMenuItem(
          itemTheme: itemTheme,
          title: 'Mark All As Read',
          icon: CupertinoIcons.check_mark_circled,
          onTap: ChatsSvc.markAllAsRead,
        ),
        PullDownMenuItem(
          itemTheme: itemTheme,
          title: 'Recently Deleted',
          icon: CupertinoIcons.delete,
          onTap: () => goToRecentlyDeleted(context),
        ),
        if (filterUnknownSenders)
          PullDownMenuItem(
            itemTheme: itemTheme,
            title: 'Unknown Senders',
            icon: CupertinoIcons.person_crop_circle_badge_xmark,
            onTap: () => goToUnknownSenders(context),
          ),
        if (BackendSvc.supportsFindMy())
          PullDownMenuItem(
            itemTheme: itemTheme,
            title: 'Map',
            icon: CupertinoIcons.location,
            onTap: () => goToFindMy(context),
          ),
        if (PushSvc.state?.icloudServices?.sharedstreams != null)
          PullDownMenuItem(
            itemTheme: itemTheme,
            title: 'Shared Albums',
            icon: CupertinoIcons.photo,
            onTap: () => goToSharedStreams(context),
          ),
        PullDownMenuItem(
          itemTheme: itemTheme,
          title: 'Video Calls',
          icon: CupertinoIcons.video_camera,
          onTap: () => goToFaceTime(context),
        ),
        if (PushSvc.state?.icloudServices?.keychain != null)
          PullDownMenuItem(
            itemTheme: itemTheme,
            title: 'Passwords',
            icon: Icons.key,
            onTap: () => goToPasswords(context),
          ),
        if (extraItems)
          PullDownMenuItem(
            itemTheme: itemTheme,
            title: 'Search',
            icon: CupertinoIcons.search,
            onTap: () => goToSearch(context),
          ),
        if (extraItems && moveChatCreatorToHeader)
          PullDownMenuItem(
              itemTheme: itemTheme,
              title: 'New Chat',
              icon: CupertinoIcons.plus,
              onTap: () => controller?.openNewChatCreator(context)),
        PullDownMenuItem(
          itemTheme: itemTheme,
          title: 'Archived',
          icon: CupertinoIcons.archivebox,
          onTap: () => goToArchived(context),
        ),
        PullDownMenuItem(
          itemTheme: itemTheme,
          title: 'Settings',
          icon: CupertinoIcons.gear,
          onTap: () => goToSettings(context),
        ),
        if (kIsWeb)
          PullDownMenuItem(
            itemTheme: itemTheme,
            title: 'Logout',
            icon: CupertinoIcons.power,
            onTap: () => logout(context),
          ),
      ],
      buttonBuilder: (context, showMenu) => ThemeSwitcher(
          iOSSkin: ClipOval(
            child: Material(
              color: context.theme.colorScheme.surfaceContainerHighest,
              child: SizedBox(
                width: 30,
                height: 30,
                child: InkWell(
                  onTap: showMenu,
                  child: Icon(
                    Icons.more_horiz,
                    color: context.theme.colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
          materialSkin: const SizedBox.shrink(),
          samsungSkin: const SizedBox.shrink()),
    );
  }
}

Future<void> goToSearch(BuildContext context) async {
  final current = NavigationSvc.ratio(context);
  EventDispatcherSvc.emit("override-split", 0.3);
  await NavigationSvc.pushLeft(context, const SearchView());
  EventDispatcherSvc.emit("override-split", current);
}

Future<void> goToRecentlyDeleted(BuildContext context) async {
  NavigationSvc.pushLeft(
      context,
      ConversationList(
        showArchivedChats: false,
        showUnknownSenders: false,
        showDeletedMessages: true,
      ));
}

Future<void> goToFindMy(BuildContext context) async {
  final currentChat = ChatsSvc.activeChat?.chat;
  NavigationSvc.closeAllConversationView(context);
  await ChatsSvc.setAllInactive();
  await Navigator.of(Get.context!).push(
    ThemeSwitcher.buildPageRoute(
      builder: (BuildContext context) {
        return FindMyPage();
      },
    ),
  );
  if (currentChat != null) {
    await ChatsSvc.setActiveChat(currentChat);
    if (SettingsSvc.settings.tabletMode.value) {
      NavigationSvc.pushAndRemoveUntil(
        context,
        ConversationView(
          chat: currentChat,
        ),
        (route) => route.isFirst,
      );
    } else {
      cvc(currentChat).close();
    }
  }
}

Future<void> goToFaceTime(BuildContext context) async {
  final currentChat = ChatsSvc.activeChat?.chat;
  NavigationSvc.closeAllConversationView(context);
  await ChatsSvc.setAllInactive();
  await Navigator.of(Get.context!).push(
    ThemeSwitcher.buildPageRoute(
      builder: (BuildContext context) {
        return FaceTimePanel();
      },
    ),
  );
  if (currentChat != null) {
    await ChatsSvc.setActiveChat(currentChat);
    if (SettingsSvc.settings.tabletMode.value) {
      NavigationSvc.pushAndRemoveUntil(
        context,
        ConversationView(
          chat: currentChat,
        ),
        (route) => route.isFirst,
      );
    } else {
      cvc(currentChat).close();
    }
  }
}

Future<void> goToPasswords(BuildContext context) async {
  final currentChat = ChatsSvc.activeChat?.chat;
  NavigationSvc.closeAllConversationView(context);
  await ChatsSvc.setAllInactive();
  await Navigator.of(Get.context!).push(
    ThemeSwitcher.buildPageRoute(
      builder: (BuildContext context) {
        return const PasswordsPanel();
      },
    ),
  );
  if (currentChat != null) {
    await ChatsSvc.setActiveChat(currentChat);
    if (SettingsSvc.settings.tabletMode.value) {
      NavigationSvc.pushAndRemoveUntil(
        context,
        ConversationView(
          chat: currentChat,
        ),
        (route) => route.isFirst,
      );
    } else {
      cvc(currentChat).close();
    }
  }
}

Future<void> goToSharedStreams(BuildContext context) async {
  final currentChat = ChatsSvc.activeChat?.chat;
  NavigationSvc.closeAllConversationView(context);
  await ChatsSvc.setAllInactive();
  await Navigator.of(Get.context!).push(
    ThemeSwitcher.buildPageRoute(
      builder: (BuildContext context) {
        return SharedStreamsPanel();
      },
    ),
  );
  if (currentChat != null) {
    await ChatsSvc.setActiveChat(currentChat);
    if (SettingsSvc.settings.tabletMode.value) {
      NavigationSvc.pushAndRemoveUntil(
        context,
        ConversationView(
          chat: currentChat,
        ),
        (route) => route.isFirst,
      );
    } else {
      cvc(currentChat).close();
    }
  }
}

void logout(BuildContext context) {
  showDialog(
    barrierDismissible: false,
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(
          "Are you sure?",
          style: context.theme.textTheme.titleLarge,
        ),
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        actions: <Widget>[
          TextButton(
            child: Text("No",
                style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
          TextButton(
            child: Text("Yes",
                style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
            onPressed: () async {
              FilesystemSvc.deleteDB();
              SocketSvc.forgetConnection();
              SettingsSvc.settings = Settings();
              SettingsSvc.fcmData = FCMData();
              await PrefsSvc.admin.clearAll();
              await PrefsSvc.theme.setSelectedThemes(
                darkTheme: "OLED Dark",
                lightTheme: "Bright White",
              );
              Get.offAll(
                  () => const PopScope(
                        canPop: false,
                        child: TitleBarWrapper(child: SetupView()),
                      ),
                  duration: Duration.zero,
                  transition: Transition.noTransition);
            },
          ),
        ],
      );
    },
  );
}

void goToUnknownSenders(BuildContext context) {
  NavigationSvc.pushLeft(
      context,
      ConversationList(
        showArchivedChats: false,
        showUnknownSenders: true,
      ));
}

Future<void> goToSettings(BuildContext context) async {
  final currentChat = ChatsSvc.activeChat?.chat;
  NavigationSvc.closeAllConversationView(context);
  await ChatsSvc.setAllInactive();
  await Navigator.of(Get.context!).push(
    ThemeSwitcher.buildPageRoute(
      builder: (BuildContext context) {
        return const SettingsPage();
      },
    ),
  );
  if (currentChat != null) {
    await ChatsSvc.setActiveChat(currentChat);
    if (SettingsSvc.settings.tabletMode.value) {
      NavigationSvc.pushAndRemoveUntil(
        context,
        ConversationView(
          chat: currentChat,
        ),
        (route) => route.isFirst,
      ).onError((error, stackTrace) => ChatsSvc.setAllInactiveSync());
    } else {
      cvc(currentChat).close();
    }
  }
}

void goToArchived(BuildContext context) {
  NavigationSvc.pushLeft(
      context,
      ConversationList(
        showArchivedChats: true,
        showUnknownSenders: false,
      ));
}

void goToProfile(BuildContext context) {
  NavigationSvc.pushLeft(context, const ProfilePanel());
}
