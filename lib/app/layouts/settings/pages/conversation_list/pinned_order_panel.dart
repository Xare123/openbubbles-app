import 'dart:ui';

import 'package:bluebubbles/app/wrappers/bb_annotated_region.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/conversation_tile.dart';
import 'package:bluebubbles/app/wrappers/scrollbar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:get/get.dart';

class PinnedOrderPanel extends StatelessWidget {
  const PinnedOrderPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final Rx<Color> _backgroundColor = (kIsDesktop && SettingsSvc.settings.windowEffect.value == WindowEffect.disabled
            ? Colors.transparent
            : context.theme.colorScheme.surface)
        .obs;
    final ScrollController scrollController = ScrollController();

    if (kIsDesktop) {
      SettingsSvc.settings.windowEffect.listen((WindowEffect effect) => _backgroundColor.value =
          effect != WindowEffect.disabled ? Colors.transparent : context.theme.colorScheme.surface);
    }
    return BBAnnotatedRegion(
      child: Obx(
        () => Scaffold(
          backgroundColor: _backgroundColor.value,
          appBar: PreferredSize(
            preferredSize: Size(NavigationSvc.width(context), 80),
            child: ClipRRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: AppBar(
                  systemOverlayStyle:
                      ThemeData.estimateBrightnessForColor(context.theme.colorScheme.surface) == Brightness.dark
                          ? SystemUiOverlayStyle.light
                          : SystemUiOverlayStyle.dark,
                  toolbarHeight: kIsDesktop ? 80 : 50,
                  elevation: 0,
                  scrolledUnderElevation: 3,
                  surfaceTintColor: context.theme.colorScheme.primary,
                  leading: buildBackButton(context),
                  backgroundColor: _backgroundColor.value,
                  centerTitle: SettingsSvc.settings.skin.value == Skins.iOS,
                  title: Text(
                    "Pinned Chat Order",
                    style: context.theme.textTheme.titleLarge,
                  ),
                  actions: [
                    TextButton(
                        child: Text("Reset",
                            style:
                                context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                        onPressed: () {
                          ChatsSvc.removePinIndices();
                        }),
                  ],
                ),
              ),
            ),
          ),
          body: ScrollbarWrapper(
            showScrollbar: true,
            controller: scrollController,
            child: SingleChildScrollView(
              controller: scrollController,
              physics: ThemeSwitcher.getScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                children: <Widget>[
                  Obx(() {
                    if (!ChatsSvc.loadedFirstChatBatch.value) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 50.0),
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Text(
                                  "Loading chats...",
                                  style: context.theme.textTheme.labelLarge,
                                ),
                              ),
                              buildProgressIndicator(context, size: 15),
                            ],
                          ),
                        ),
                      );
                    }
                    final pinnedChats = ChatsSvc.getFilteredChats(pinnedOnly: true);
                    if (ChatsSvc.hasChats.value && pinnedChats.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 50.0),
                          child: Text(
                            "You have no pinned chats :(",
                            style: context.theme.textTheme.labelLarge,
                          ),
                        ),
                      );
                    }

                    return ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      onReorder: ChatsSvc.updateChatPinIndex,
                      header: Padding(
                        padding: const EdgeInsets.all(13.0),
                        child: Text("Set the order of pinned chats by dragging the chat tile to the desired location.",
                            style: context.theme.textTheme.bodyLarge),
                      ),
                      itemBuilder: (context, index) {
                        final chat = pinnedChats[index];
                        return ReorderableDragStartListener(
                          key: Key(chat.guid.toString()),
                          index: index,
                          child: AbsorbPointer(
                            absorbing: true,
                            child: ConversationTile(
                              chat: chat,
                              controller: Get.put(
                                  ConversationListController(showUnknownSenders: true, showArchivedChats: true),
                                  tag: "pinned-order-panel"),
                              inSelectMode: true,
                              onSelect: (_) {},
                            ),
                          ),
                        );
                      },
                      itemCount: pinnedChats.length,
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
