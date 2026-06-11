import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/app/layouts/conversation_details/dialogs/timeframe_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/interactive/polls.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/attachment_picker_file.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/database/global/payload_data.dart';
import 'package:bluebubbles/database/global/platform_file.dart';
import 'package:bluebubbles/helpers/types/constants.dart' as constants;
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/extension_service.dart';
import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart' hide PlatformFile;
import 'package:file_picker/file_picker.dart' as pf;
import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hand_signature/signature.dart';
import 'package:bluebubbles/app/layouts/camera/camera_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:universal_io/io.dart';

/// Optimized attachment picker that avoids loading bytes until absolutely necessary
/// This significantly improves performance and reduces memory usage
class AttachmentPicker extends StatefulWidget {
  const AttachmentPicker({
    super.key,
    required this.controller,
  });

  final ConversationViewController controller;

  @override
  State<AttachmentPicker> createState() => AttachmentPickerState();
}

class AttachmentPickerState extends State<AttachmentPicker> with ThemeHelpers {
  List<AssetEntity> _images = <AssetEntity>[];
  bool _isLoadingImages = false;
  bool _permissionDenied = false;
  List<Map<String, dynamic>> iconsList = [];
  App? currentApp;

  ConversationViewController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    generateIcons();
    getAttachments();
  }

  void generateIcons() {
    iconsList = [
      if (controller.chat.isIMessage)
        {
          "icon": Icons.how_to_vote,
          "text": "Polls",
          "handle": () async {
            final optionControllers = [TextEditingController(), TextEditingController()];
            showDialog(
              context: context,
              builder: (_) {
                return AlertDialog(
                  title: Text("New Poll", style: context.theme.textTheme.titleLarge),
                  backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                  content: SingleChildScrollView(
                    child: StatefulBuilder(
                      builder: (context, state) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: optionControllers
                            .mapIndexed((i, c) => [
                                  if (i == 0) const Text("Requires iOS 26 or above."),
                                  const SizedBox(height: 10),
                                  TextField(
                                    controller: c,
                                    decoration: InputDecoration(
                                      labelText: "Option ${i + 1}",
                                      border: const OutlineInputBorder(),
                                    ),
                                    onChanged: (v) {
                                      if (optionControllers.last.text.isNotEmpty) {
                                        optionControllers.add(TextEditingController());
                                        state(() {});
                                      }
                                      if (optionControllers.length > 2 &&
                                          optionControllers[optionControllers.length - 2].text.isEmpty) {
                                        optionControllers.removeLast();
                                        state(() {});
                                      }
                                    },
                                  ),
                                ])
                            .flattened
                            .toList(),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      child: Text("Cancel",
                          style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                      onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    ),
                    TextButton(
                      child: Text("OK",
                          style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                      onPressed: () async {
                        final handle = RustPushBBUtils.rustHandleToBB(await controller.chat.ensureHandle());
                        final items = optionControllers.map((i) => i.text).where((e) => e.isNotEmpty).toList();
                        if (items.length < 2) return;
                        final poll = PollMessage(
                          version: 1,
                          item: Item(
                            creatorHandle: handle.address,
                            title: "",
                            orderedPollOptions: items
                                .map(
                                  (item) => OrderedPollOption(
                                    attributedText: item,
                                    canBeEdited: false,
                                    creatorHandle: handle.address,
                                    optionIdentifier: uuid.v4().toUpperCase(),
                                    text: item,
                                  ),
                                )
                                .toList(),
                          ),
                        );
                        controller.pickedApp.value = (
                          null,
                          PayloadData(
                            type: constants.PayloadType.app,
                            appData: [
                              iMessageAppData(
                                appName: "Polls",
                                url: "data:,${base64Encode(utf8.encode(pollMessageToJson(poll)))}?src=p&c=2",
                                session: uuid.v4().toUpperCase(),
                                ldText: items.join(", "),
                                userInfo: UserInfo(
                                  imageSubtitle: "",
                                  imageTitle: "",
                                  caption: "ENG: Update your device",
                                  secondarySubcaption: "",
                                  tertiarySubcaption: "",
                                  subcaption: "Learn about how to update your device to see this content.",
                                ),
                                isLive: true,
                                appIcon: base64Encode(
                                    (await rootBundle.load("assets/images/polls.jpg")).buffer.asUint8List()),
                              ),
                            ],
                          )
                        );
                        Navigator.of(context, rootNavigator: true).pop();
                      },
                    ),
                  ],
                );
              },
            );
          }
        },
      {
        "icon": SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.folder_open : Icons.folder_open_outlined,
        "text": "Files",
        "handle": () async => await _handleFilePicker(),
      },
      {
        "icon": SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.location : Icons.location_on_outlined,
        "text": "Location",
        "handle": () async => await Share.location(controller.chat),
      },
      if (controller.chat.isIMessage)
        {
          "icon": SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.clock_solid : Icons.schedule,
          "text": "Send Later",
          "handle": () async => await _handleSchedule(context),
        },
      {
        "icon": SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.pencil_outline : Icons.draw,
        "text": "Handwritten",
        "handle": () async => await _handleHandwritten(context),
      },
    ];

    if (!controller.chat.isIMessage) return;
    for (final app in ExtensionSvc.cachedStatus) {
      if (app.available == null) continue;
      iconsList.insert(0, {
        "logo": base64Decode(app.available!.icon),
        "text": app.available!.name,
        "handle": () {
          setState(() {
            currentApp = app;
          });
        },
      });
    }
  }

  Future<void> _handleFilePicker() async {
    final res = await FilePicker.platform.pickFiles(withReadStream: true, allowMultiple: true);
    if (res == null || res.files.isEmpty) return;

    for (pf.PlatformFile file in res.files) {
      if (file.size / 1024000 > 1000) {
        showSnackbar("Error", "This file is over 1 GB! Please compress it before sending.");
        continue;
      }

      controller.pickedAttachments.add(PlatformFile(
        path: file.path,
        name: file.name,
        bytes: file.readStream != null ? await readByteStream(file.readStream!) : null,
        size: file.size,
      ));
    }
  }

  Future<Uint8List> readByteStream(Stream<List<int>> stream) async {
    final bytes = BytesBuilder();
    await for (final chunk in stream) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> _handleSchedule(BuildContext context) async {
    if (controller.pickedAttachments.isNotEmpty) {
      showSnackbar("Error", "Remove all attachments before scheduling!");
      return;
    } else if (controller.replyToMessage != null || controller.subjectTextController.text.isNotEmpty) {
      showSnackbar("Error", "Private API features are not supported when scheduling!");
      return;
    }
    final date = await showTimeframePicker("Pick date and time", context, presetsAhead: true);
    if (date != null && date.isAfter(DateTime.now())) {
      controller.scheduledDate.value = date;
    }
  }

  Future<void> _handleHandwritten(BuildContext context) async {
    Color selectedColor = context.theme.colorScheme.bubble(context, controller.chat.isIMessage);
    final result = await ColorPicker(
      color: selectedColor,
      onColorChanged: (Color newColor) {
        selectedColor = newColor;
      },
      title: Text("Select Color", style: context.theme.textTheme.titleLarge),
      width: 40,
      height: 40,
      spacing: 0,
      runSpacing: 0,
      borderRadius: 0,
      wheelDiameter: 165,
      enableOpacity: false,
      showColorCode: true,
      colorCodeHasColor: true,
      pickersEnabled: <ColorPickerType, bool>{ColorPickerType.wheel: true},
      copyPasteBehavior: const ColorPickerCopyPasteBehavior(parseShortHexCode: true),
      actionButtons: const ColorPickerActionButtons(dialogActionButtons: true),
    ).showPickerDialog(
      context,
      barrierDismissible: false,
      constraints: BoxConstraints(
        minHeight: 480,
        minWidth: NavigationSvc.width(context) - 70,
        maxWidth: NavigationSvc.width(context) - 70,
      ),
    );

    if (!(result && context.mounted)) return;
    final control = HandSignatureControl();
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text("Draw Handwritten Message", style: context.theme.textTheme.titleLarge),
          backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
          content: AspectRatio(
            aspectRatio: 1,
            child: HandSignature(
              control: control,
              color: selectedColor,
              width: 1.0,
              maxWidth: 10.0,
              type: SignatureDrawType.shape,
            ),
          ),
          actions: [
            TextButton(
              child: Text("Cancel",
                  style: context.theme.textTheme.bodyLarge!.copyWith(color: Get.context!.theme.colorScheme.primary)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: Text("OK",
                  style: context.theme.textTheme.bodyLarge!.copyWith(color: Get.context!.theme.colorScheme.primary)),
              onPressed: () async {
                Navigator.of(context).pop();
                final bytes = await control.toImage(height: 512, fit: false);
                if (bytes != null) {
                  final uint8 = bytes.buffer.asUint8List();
                  controller.pickedAttachments.add(PlatformFile(
                    path: null,
                    name: "handwritten-${randomString(3)}.png",
                    bytes: uint8,
                    size: uint8.lengthInBytes,
                  ));
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> getAttachments() async {
    if (kIsDesktop || kIsWeb || _isLoadingImages) return;

    setState(() {
      _isLoadingImages = true;
    });

    try {
      // Wait for opening animation to complete
      await Future.delayed(const Duration(milliseconds: 250));

      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) {
        if (mounted) setState(() => _permissionDenied = true);
        return;
      }
      if (mounted && _permissionDenied) setState(() => _permissionDenied = false);

      List<AssetPathEntity> list = await PhotoManager.getAssetPathList(
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(
              type: OrderOptionType.createDate,
              asc: false, // false = descending, newest first
            ),
          ],
        ),
      );
      if (list.isNotEmpty) {
        _images = await list.first.getAssetListRange(start: 0, end: 24);

        // See if there is a recent attachment
        if (_images.isNotEmpty && DateTime.now().toLocal().isWithin(_images.first.modifiedDateTime, minutes: 2)) {
          final file = await _images.first.file;
          if (file != null) {
            // Don't load bytes here - let the attachment service handle it when needed
            EventDispatcherSvc.emit(
                'add-custom-smartreply',
                PlatformFile(
                  path: file.path,
                  name: file.path.split('/').last,
                  size: await file.length(),
                  bytes: null, // Don't preload bytes
                ));
          }
        }
      }
    } catch (e) {
      showSnackbar("Error", "Failed to load attachments: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingImages = false;
        });
      }
    }
  }

  Future<void> openFullCamera({String type = 'camera'}) async {
    bool granted = (await Permission.camera.request()).isGranted;
    if (!granted) {
      showSnackbar("Error", "Camera access was denied!");
      return;
    }

    if (type == 'video') {
      final micGranted = (await Permission.microphone.request()).isGranted;
      if (!micGranted) {
        showSnackbar("Error", "Microphone access was denied!");
        return;
      }
    }

    final XFile? file;
    if (Platform.isAndroid && !kIsWeb) {
      file = await Navigator.of(context).push<XFile?>(
        MaterialPageRoute(
          builder: (_) => CameraScreen(initialMode: type == 'video' ? 'video' : 'photo'),
        ),
      );
    } else if (type == 'camera') {
      file = await ImagePicker().pickImage(source: ImageSource.camera);
    } else {
      file = await ImagePicker().pickVideo(source: ImageSource.camera);
    }

    if (file != null) {
      // Don't preload bytes - only store the path
      controller.pickedAttachments.add(PlatformFile(
        path: file.path,
        name: file.path.split('/').last,
        size: await file.length(),
        bytes: null, // Will be loaded when actually sending
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (currentApp != null) {
      return SizedBox(
        height: 300,
        child: AndroidView(
          viewType: "extension-keyboard",
          layoutDirection: TextDirection.ltr,
          creationParams: {
            "app-id": currentApp!.appId,
            "user-count": controller.chat.handles.length + 1,
          },
          creationParamsCodec: const StandardMessageCodec(),
        ),
      );
    }

    return SizedBox(
      height: 300,
      child: RefreshIndicator(
        onRefresh: () async {
          await getAttachments();
        },
        child: NotificationListener<OverscrollIndicatorNotification>(
          onNotification: (OverscrollIndicatorNotification overscroll) {
            // Prevent stretchy effect
            overscroll.disallowIndicator();
            return true;
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: 300,
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: CustomScrollView(
                  physics: ThemeSwitcher.getScrollPhysics(),
                  scrollDirection: Axis.horizontal,
                  slivers: <Widget>[
                    // Camera and Video buttons
                    SliverPadding(
                      padding: const EdgeInsets.only(bottom: 5),
                      sliver: _buildActionButtons(context),
                    ),
                    const SliverPadding(padding: EdgeInsets.only(left: 5, right: 5)),
                    // App and feature buttons
                    SliverPadding(
                      padding: const EdgeInsets.only(bottom: 5),
                      sliver: _buildFeatureButtons(context),
                    ),
                    const SliverPadding(padding: EdgeInsets.only(left: 5, right: 5)),
                    // Image grid
                    SliverPadding(
                      padding: const EdgeInsets.only(bottom: 5),
                      sliver: _buildImageGrid(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.5,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          return Obx(() {
            final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;
            return _ActionButton(
              icon: index == 0
                  ? (isIOS ? CupertinoIcons.camera : Icons.photo_camera_outlined)
                  : (isIOS ? CupertinoIcons.videocam : Icons.videocam_outlined),
              label: index == 0 ? "Photo" : "Video",
              onPressed: () => openFullCamera(type: index == 0 ? "camera" : "video"),
            );
          });
        },
        childCount: 2,
      ),
    );
  }

  Widget _buildFeatureButtons(BuildContext context) {
    return SliverToBoxAdapter(
      child: SizedBox(
        width: 100,
        child: CustomScrollView(
          physics: ThemeSwitcher.getScrollPhysics(),
          scrollDirection: Axis.vertical,
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = iconsList[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _DynamicFeatureButton(
                      icon: item["icon"],
                      logo: item["logo"],
                      label: item["text"],
                      onPressed: () => item["handle"](),
                    ),
                  );
                },
                childCount: iconsList.length,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusSliver({
    required IconData icon,
    required String message,
    required String buttonLabel,
    required VoidCallback onPressed,
  }) {
    return SliverToBoxAdapter(
      child: SizedBox(
        width: 280,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 36, color: context.theme.colorScheme.outline),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: context.theme.textTheme.bodySmall!.copyWith(
                    color: context.theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    backgroundColor: context.theme.colorScheme.primary,
                    foregroundColor: context.theme.colorScheme.onPrimary,
                  ),
                  onPressed: onPressed,
                  child: Text(buttonLabel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageGrid() {
    if (_isLoadingImages) {
      return const SliverToBoxAdapter(
        // Explicit width so the item occupies space in the horizontal CustomScrollView.
        child: SizedBox(
          width: 280,
          child: Center(child: CupertinoActivityIndicator()),
        ),
      );
    }

    if (_permissionDenied) {
      return _buildStatusSliver(
        icon: Icons.photo_library_outlined,
        message: "Photo access is required to browse your gallery.",
        buttonLabel: "Grant Access",
        onPressed: () async {
          final ps = await PhotoManager.requestPermissionExtend();
          if (ps.hasAccess) {
            await getAttachments();
          } else {
            await openAppSettings();
          }
        },
      );
    }

    // Access was granted but no photos came back. This reliably covers:
    // - Limited access with no photos selected (photo_manager collapses
    //   PermissionState back to 'authorized' after presentLimited(), so
    //   ps.isLimited is not trustworthy post-flow)
    // - Fully authorized but genuinely empty library
    if (_images.isEmpty) {
      // PhotoManager.presentLimited() is broken on Android — it silently does
      // nothing on most devices (known upstream issue #1357). On Android, direct
      // the user to App Settings where they can update their photo selection.
      // On iOS, presentLimited() works correctly.
      final isAndroid = !kIsWeb && Platform.isAndroid;
      return _buildStatusSliver(
        icon: Icons.photo_library_outlined,
        message: isAndroid
            ? "No photos are accessible. Tap below to open Settings and update your photo access."
            : "No photos are accessible. Tap below to choose which photos this app can access.",
        buttonLabel: isAndroid ? "Open Settings" : "Select Photos",
        onPressed: () async {
          if (isAndroid) {
            await openAppSettings();
          } else {
            await PhotoManager.presentLimited();
          }
          await getAttachments();
        },
      );
    }

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final element = _images[index];
          return AttachmentPickerFile(
            key: Key("AttachmentPickerFile-${element.id}"),
            data: element,
            controller: controller,
            onTap: () async {
              final file = await element.file;
              if (file == null) return;

              if ((await file.length()) / 1024000 > 1000) {
                showSnackbar("Error", "This file is over 1 GB! Please compress it before sending.");
                return;
              }

              if (controller.pickedAttachments.firstWhereOrNull((e) => e.path == file.path) != null) {
                controller.pickedAttachments.removeWhere((e) => e.path == file.path);
              } else {
                // Don't preload bytes - only store the path
                controller.pickedAttachments.add(PlatformFile(
                  path: file.path,
                  name: file.path.split('/').last,
                  size: await file.length(),
                  bytes: null, // Will be loaded when actually sending
                ));
              }
            },
          );
        },
        childCount: _images.length,
      ),
    );
  }
}

/// Extracted stateless widget to prevent unnecessary rebuilds
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      ),
      onPressed: onPressed,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            icon,
            color: context.theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8.0),
          Text(
            label,
            style: context.theme.textTheme.labelLarge!.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Extracted stateless widget for feature buttons to prevent rebuilds
class _FeatureButton extends StatelessWidget {
  const _FeatureButton({
    required this.index,
    required this.controller,
  });

  final int index;
  final ConversationViewController controller;

  IconData getIcon() {
    if (SettingsSvc.settings.skin.value == Skins.iOS) {
      switch (index) {
        case 0:
          return CupertinoIcons.folder_open;
        case 1:
          return CupertinoIcons.location;
        case 2:
          return CupertinoIcons.calendar_today;
        case 3:
          return CupertinoIcons.pencil_outline;
      }
    } else {
      switch (index) {
        case 0:
          return Icons.folder_open_outlined;
        case 1:
          return Icons.location_on_outlined;
        case 2:
          return Icons.schedule;
        case 3:
          return Icons.draw;
      }
    }
    return Icons.abc;
  }

  String getText() {
    switch (index) {
      case 0:
        return "Files";
      case 1:
        return "Location";
      case 2:
        return "Schedule";
      case 3:
        return "Handwriten";
    }
    return "";
  }

  Future<void> handlePress(BuildContext context) async {
    switch (index) {
      case 0:
        await _handleFilePicker();
        break;
      case 1:
        await _handleLocation();
        break;
      case 2:
        await _handleSchedule(context);
        break;
      case 3:
        await _handleHandwritten(context);
        break;
    }
  }

  Future<void> _handleFilePicker() async {
    final res = await FilePicker.platform.pickFiles(
      withReadStream: true,
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty) return;

    for (pf.PlatformFile file in res.files) {
      if (file.size / 1024000 > 1000) {
        showSnackbar("Error", "This file is over 1 GB! Please compress it before sending.");
        continue;
      }

      // Don't preload bytes for files - use readStream when sending
      controller.pickedAttachments.add(PlatformFile(
        path: file.path,
        name: file.name,
        bytes: null, // Will be loaded via stream when sending
        size: file.size,
      ));
    }
  }

  Future<void> _handleLocation() async {
    await Share.location(controller.chat);
  }

  Future<void> _handleSchedule(BuildContext context) async {
    if (controller.pickedAttachments.isNotEmpty) {
      return showSnackbar("Error", "Remove all attachments before scheduling!");
    } else if (controller.replyToMessage != null || controller.subjectTextController.text.isNotEmpty) {
      return showSnackbar("Error", "Private API features are not supported when scheduling!");
    }

    final date = await showTimeframePicker("Pick date and time", context, presetsAhead: true);
    if (date != null && date.isAfter(DateTime.now())) {
      controller.scheduledDate.value = date;
    }
  }

  Future<void> _handleHandwritten(BuildContext context) async {
    Color selectedColor = context.theme.colorScheme.bubble(context, controller.chat.isIMessage);

    final result = await ColorPicker(
      color: selectedColor,
      onColorChanged: (Color newColor) {
        selectedColor = newColor;
      },
      title: Text(
        "Select Color",
        style: context.theme.textTheme.titleLarge,
      ),
      width: 40,
      height: 40,
      spacing: 0,
      runSpacing: 0,
      borderRadius: 0,
      wheelDiameter: 165,
      enableOpacity: false,
      showColorCode: true,
      colorCodeHasColor: true,
      pickersEnabled: <ColorPickerType, bool>{
        ColorPickerType.wheel: true,
      },
      copyPasteBehavior: const ColorPickerCopyPasteBehavior(
        parseShortHexCode: true,
      ),
      actionButtons: const ColorPickerActionButtons(
        dialogActionButtons: true,
      ),
    ).showPickerDialog(
      context,
      barrierDismissible: false,
      constraints: BoxConstraints(
        minHeight: 480,
        minWidth: NavigationSvc.width(context) - 70,
        maxWidth: NavigationSvc.width(context) - 70,
      ),
    );

    if (result && context.mounted) {
      final control = HandSignatureControl();
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(
              "Draw Handwriten Message",
              style: context.theme.textTheme.titleLarge,
            ),
            content: AspectRatio(
              aspectRatio: 1,
              child: Container(
                constraints: const BoxConstraints.expand(),
                child: HandSignature(
                  control: control,
                  color: selectedColor,
                  width: 1.0,
                  maxWidth: 10.0,
                  type: SignatureDrawType.shape,
                ),
              ),
            ),
            actions: [
              TextButton(
                child: Text(
                  "Cancel",
                  style: context.theme.textTheme.bodyLarge!.copyWith(color: Get.context!.theme.colorScheme.primary),
                ),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
              TextButton(
                child: Text(
                  "OK",
                  style: context.theme.textTheme.bodyLarge!.copyWith(color: Get.context!.theme.colorScheme.primary),
                ),
                onPressed: () async {
                  Navigator.of(context).pop();
                  final bytes = await control.toImage(height: 512, fit: false);
                  if (bytes != null) {
                    final uint8 = bytes.buffer.asUint8List();
                    controller.pickedAttachments.add(PlatformFile(
                      path: null,
                      name: "handwriten-${controller.pickedAttachments.length + 1}.png",
                      bytes: uint8,
                      size: uint8.lengthInBytes,
                      balloonBundleId: 'com.apple.Handwriting.HandwritingProvider',
                    ));
                  }
                },
              ),
            ],
            backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
          );
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(vertical: 5),
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      ),
      onPressed: () => handlePress(context),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            getIcon(),
            color: context.theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8.0),
          Text(
            getText(),
            style: context.theme.textTheme.labelLarge!.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _DynamicFeatureButton extends StatelessWidget {
  const _DynamicFeatureButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.logo,
  });

  final IconData? icon;
  final Uint8List? logo;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(vertical: 5),
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      ),
      onPressed: onPressed,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (logo != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(logo!, width: 28, height: 28),
            )
          else
            Icon(
              icon,
              color: context.theme.colorScheme.onSurfaceVariant,
            ),
          const SizedBox(height: 8.0),
          Text(
            label,
            textAlign: TextAlign.center,
            style: context.theme.textTheme.labelLarge!.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
