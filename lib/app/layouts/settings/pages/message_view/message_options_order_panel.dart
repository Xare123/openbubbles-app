import 'dart:ui';

import 'package:bluebubbles/app/wrappers/bb_annotated_region.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/details_menu_action.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/ui/navigator/navigator_service.dart';
import 'package:bluebubbles/services/ui/theme/themes_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/window_effect.dart';
import 'package:get/get.dart';

class MessageOptionsOrderPanel extends StatefulWidget {
  const MessageOptionsOrderPanel({super.key});

  @override
  State<StatefulWidget> createState() => _MessageOptionsOrderPanelState();
}

class _MessageOptionsOrderPanelState extends State<MessageOptionsOrderPanel> with ThemeHelpers {
  final RxList<DetailsMenuAction> actionList = RxList();

  @override
  void initState() {
    super.initState();

    actionList.value = SettingsSvc.settings.detailsMenuActions.platformSupportedActions;
  }

  @override
  Widget build(BuildContext context) {
    final Rx<Color> _backgroundColor = (kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
            ? Colors.transparent
            : context.theme.colorScheme.surface)
        .obs;

    final Color tileColor = (ThemeSvc.inDarkMode(context)
            ? context.theme.colorScheme.surfaceContainerHighest
            : context.theme.colorScheme.surface)
        .withAlpha(SettingsSvc.settings.windowEffect.value != WindowEffect.disabled ? 100 : 255);

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
                    "Message Options Order",
                    style: context.theme.textTheme.titleLarge,
                  ),
                  actions: [
                    TextButton(
                      child: Text("Reset",
                          style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                      onPressed: () {
                        actionList.value = DetailsMenuAction.values.platformSupportedActions;
                        SettingsSvc.settings.resetDetailsMenuActions();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: Container(
            color: tileColor,
            child: Obx(
              () => ReorderableListView.builder(
                shrinkWrap: true,
                onReorder: (start, end) {
                  if (start == end) return;
                  actionList.insert(end, actionList.elementAt(start));
                  actionList.removeAt(start + (end < start ? 1 : 0));
                  SettingsSvc.settings.setDetailsMenuActions(actionList.toList());
                },
                buildDefaultDragHandles: false,
                itemBuilder: (context, index) {
                  DetailsMenuAction action = actionList[index];
                  return Row(
                    key: Key(action.toString()),
                    children: [
                      Expanded(
                        child: AbsorbPointer(
                          child: DetailsMenuActionWidget(
                            action: action,
                          ),
                        ),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: ReorderableDragStartListener(
                          index: index,
                          child: Icon(
                            Icons.drag_handle,
                            color: context.theme.colorScheme.outline,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  );
                },
                itemCount: actionList.length,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
