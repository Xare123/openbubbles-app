import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/widgets/color_editor_section.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/widgets/preset_theme_strip.dart'
    show ThemeSelectorSection;
import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/widgets/theme_management_section.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/widgets/theme_preview_card.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/widgets/typography_editor.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

// ─── Controller ───────────────────────────────────────────────────────────────

class ThemeStudioController extends StatefulController {
  late ThemeStruct lightTheme;
  late ThemeStruct darkTheme;

  /// The names of what's actually live in the running app (saved to prefs).
  String appliedLightName = '';
  String appliedDarkName = '';

  final RxBool isDark = false.obs;

  /// Controls which theme variant the preview shows — independent of the
  /// actively-selected editing theme.
  final RxBool previewDark = false.obs;

  final RxList<ThemeStruct> allThemes = <ThemeStruct>[].obs;

  /// Bumped when active theme data (colors, font, sizes) changes, or when the
  /// active theme selection changes.
  final RxInt themeDataVersion = 0.obs;

  /// Bumped when the list of available themes changes (add/remove/rename/select).
  final RxInt themeListVersion = 0.obs;

  /// True when changes have been staged but not yet applied to the running UI.
  final RxBool pendingChanges = false.obs;

  ThemeStruct get activeTheme => isDark.value ? darkTheme : lightTheme;

  ThemeStruct get previewTheme => previewDark.value ? darkTheme : lightTheme;

  bool get isEditable => !activeTheme.isPreset && SettingsSvc.settings.monetTheming.value == Monet.none;

  void init(bool isDarkMode) {
    isDark.value = isDarkMode;
    previewDark.value = isDarkMode;
    _reload();
    appliedLightName = lightTheme.name;
    appliedDarkName = darkTheme.name;
  }

  void _reload() {
    lightTheme = ThemeStruct.getLightTheme();
    darkTheme = ThemeStruct.getDarkTheme();
    allThemes.value = ThemeStruct.getThemes();
    themeDataVersion.value++;
    themeListVersion.value++;
  }

  /// Refreshes only the list of all themes without resetting the staged
  /// light/dark selections.
  void _reloadThemesList() {
    allThemes.value = ThemeStruct.getThemes();
    themeListVersion.value++;
  }

  void bump() {
    themeDataVersion.value++;
  }

  // ── Theme selection ────────────────────────────────────────────────────────

  /// Stages a theme selection for preview. Call [applyChanges] to make it live.
  void applyTheme(BuildContext context, ThemeStruct struct) {
    final isThemeDark = struct.data.colorScheme.brightness == Brightness.dark;
    isDark.value = isThemeDark;
    previewDark.value = isThemeDark;
    if (isThemeDark) {
      darkTheme = struct;
    } else {
      lightTheme = struct;
    }
    themeDataVersion.value++;
    themeListVersion.value++;
    pendingChanges.value = true;
  }

  // ── Apply staged changes to the running app ────────────────────────────────

  Future<void> applyChanges(BuildContext context) async {
    lightTheme.save();
    darkTheme.save();
    appliedLightName = lightTheme.name;
    appliedDarkName = darkTheme.name;
    await ThemeSvc.changeTheme(context, light: lightTheme);
    await ThemeSvc.changeTheme(context, dark: darkTheme);
    pendingChanges.value = false;
    EventDispatcherSvc.emit('theme-update', null);
  }

  /// Discards all staged edits by reloading themes from the DB.
  void discardChanges() {
    _reload();
    pendingChanges.value = false;
  }

  // ── Color editing ──────────────────────────────────────────────────────────

  void updateColorKey(BuildContext context, String colorKey, Color newColor) {
    if (!isEditable) return;
    final map = activeTheme.toMap();
    map["data"]["colorScheme"][colorKey] = newColor.toARGB32();
    activeTheme.data = ThemeStruct.fromMap(map).data;
    themeDataVersion.value++;
    pendingChanges.value = true;
  }

  // ── Typography ─────────────────────────────────────────────────────────────

  void updateFont(BuildContext context, String fontName) {
    final map = activeTheme.toMap();
    map["data"]["textTheme"]["font"] = fontName;
    activeTheme.googleFont = fontName;
    activeTheme.data = ThemeStruct.fromMap(map).data;
    // Do not save to DB here — font changes are staged in memory only and
    // persisted when the user explicitly clicks Apply (applyChanges). This
    // ensures re-entering the page always shows the currently applied font.
    themeDataVersion.value++;
    pendingChanges.value = true;
  }

  void updateTextSize(BuildContext context, String key, double multiplier) {
    final map = activeTheme.toMap();
    final keys = key == 'master' ? activeTheme.textSizes.keys.toList() : [key];
    for (final k in keys) {
      map["data"]["textTheme"][k]['fontSize'] = ThemeStruct.defaultTextSizes[k]! * multiplier;
    }
    activeTheme.data = ThemeStruct.fromMap(map).data;
    themeDataVersion.value++;
    pendingChanges.value = true;
  }

  // ── Theme management ───────────────────────────────────────────────────────

  ThemeStruct createTheme(BuildContext context, String name, {bool? forDark}) {
    final darkMode = forDark ?? isDark.value;
    isDark.value = darkMode;
    previewDark.value = darkMode;
    final tuple = ThemeSvc.getStructsFromData(activeTheme.data, activeTheme.data);
    final newData = darkMode ? tuple.dark : tuple.light;
    final newTheme = ThemeStruct(name: name, themeData: newData);
    newTheme.save();
    if (darkMode) {
      darkTheme = newTheme;
    } else {
      lightTheme = newTheme;
    }
    _reloadThemesList();
    themeDataVersion.value++;
    pendingChanges.value = true;
    return newTheme;
  }

  /// Clones [source] into a new theme with [name] and makes it the staged
  /// active theme for its brightness mode.
  ThemeStruct cloneTheme(String name, ThemeStruct source) {
    final clone = ThemeStruct(
      name: name,
      themeData: source.data,
      gradientBg: source.gradientBg,
      googleFont: source.googleFont,
    );
    clone.save();
    final isDarkClone = clone.data.colorScheme.brightness == Brightness.dark;
    isDark.value = isDarkClone;
    previewDark.value = isDarkClone;
    if (isDarkClone) {
      darkTheme = clone;
    } else {
      lightTheme = clone;
    }
    _reloadThemesList();
    themeDataVersion.value++;
    pendingChanges.value = true;
    return clone;
  }

  Future<bool> renameTheme(BuildContext context, String newName) async {
    if (activeTheme.isPreset || newName.isEmpty) return false;
    if (ThemeStruct.findOne(newName) != null) return false;
    final oldName = activeTheme.name;
    activeTheme.name = newName;
    activeTheme.save();
    if (PrefsSvc.i.getString("selected-light") == oldName) {
      await PrefsSvc.i.setString("selected-light", newName);
    }
    if (PrefsSvc.i.getString("selected-dark") == oldName) {
      await PrefsSvc.i.setString("selected-dark", newName);
    }
    // Keep applied name tracking in sync if the applied theme was renamed.
    if (appliedLightName == oldName) appliedLightName = newName;
    if (appliedDarkName == oldName) appliedDarkName = newName;
    _reloadThemesList();
    return true;
  }

  void generateFromSeed(BuildContext context, Color seed) {
    if (!isEditable) return;
    final brightness = isDark.value ? Brightness.dark : Brightness.light;
    final swatch = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    activeTheme.data = activeTheme.data.copyWith(colorScheme: swatch);
    themeDataVersion.value++;
    pendingChanges.value = true;
  }

  Future<void> generateFromImage(BuildContext context) async {
    if (!isEditable) return;
    final res = await FilePicker.platform
        .pickFiles(withData: true, type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg']);
    if (res == null || res.files.isEmpty || res.files.first.bytes == null) return;
    final image = MemoryImage(res.files.first.bytes!);
    final swatch = await ColorScheme.fromImageProvider(
        provider: image, brightness: isDark.value ? Brightness.dark : Brightness.light);
    activeTheme.data = activeTheme.data.copyWith(colorScheme: swatch);
    themeDataVersion.value++;
    pendingChanges.value = true;
  }

  void resetToDefault(BuildContext context) {
    if (activeTheme.isPreset) return;
    final defaultTheme = isDark.value
        ? ThemesService.defaultThemes.firstWhere((e) => e.name == "OLED Dark")
        : ThemesService.defaultThemes.firstWhere((e) => e.name == "Bright White");
    activeTheme.data = defaultTheme.data;
    themeDataVersion.value++;
    pendingChanges.value = true;
  }

  Future<void> deleteTheme(BuildContext context) async {
    if (activeTheme.isPreset) return;
    activeTheme.delete();
    if (isDark.value) {
      darkTheme = await ThemeSvc.revertToPreviousDarkTheme();
      await ThemeSvc.changeTheme(context, dark: darkTheme);
    } else {
      lightTheme = await ThemeSvc.revertToPreviousLightTheme();
      await ThemeSvc.changeTheme(context, light: lightTheme);
    }
    _reload();
    EventDispatcherSvc.emit('theme-update', null);
  }

  String exportThemeJson() {
    return const JsonEncoder.withIndent('  ').convert(activeTheme.toMap());
  }

  Future<ThemeStruct?> importThemeFromJson(String json) async {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      // Remove source device's ROWID so ObjectBox assigns a new one
      map["ROWID"] = null;
      final imported = ThemeStruct.fromMap(map);
      // Resolve name conflict with auto-suffix
      String name = imported.name;
      int suffix = 2;
      while (ThemeStruct.findOne(name) != null) {
        name = "${imported.name} ($suffix)";
        suffix++;
      }
      final finalTheme = ThemeStruct(
        name: name,
        themeData: imported.data,
        gradientBg: imported.gradientBg,
        googleFont: imported.googleFont,
      );
      finalTheme.save();
      _reload();
      return finalTheme;
    } catch (_) {
      return null;
    }
  }
}

// ─── Panel ────────────────────────────────────────────────────────────────────

class ThemeStudioPanel extends CustomStateful<ThemeStudioController> {
  ThemeStudioPanel({super.key}) : super(parentController: Get.put(ThemeStudioController()));

  @override
  State<StatefulWidget> createState() => _ThemeStudioPanelState();
}

class _ThemeStudioPanelState extends CustomState<ThemeStudioPanel, void, ThemeStudioController> {
  bool _initialized = false;

  /// False until the first frame is committed. Colors / Typography / Manage
  /// sections are deferred behind this flag so the visible content (preview +
  /// theme selector) can appear without blocking on below-fold layout work.
  bool _contentReady = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      controller.init(ThemeSvc.inDarkMode(context));
      // Defer below-fold sections two frames out:
      //  - Frame 2: ThemeSelectorSection builds its full theme card list.
      //  - Frame 3: Colors/Typography/Manage sections appear.
      // Using a nested postFrameCallback ensures they never land in the same
      // rasterize pass, keeping each frame small.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _contentReady = true);
        });
      });
    }
  }

  /// Shows a dialog asking the user what to do with unsaved changes.
  /// Returns true if navigation should proceed (discard or apply+navigate).
  Future<bool> _confirmDiscard(BuildContext context) async {
    final result = await showDialog<_PendingAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Unsaved Changes"),
        content: const Text("You have pending changes that haven't been applied. What would you like to do?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_PendingAction.cancel),
            child: const Text("Keep Editing"),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_PendingAction.discard),
            child: Text("Discard", style: TextStyle(color: context.theme.colorScheme.error)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_PendingAction.apply),
            child: const Text("Apply & Exit"),
          ),
        ],
      ),
    );
    if (result == _PendingAction.apply) {
      await controller.applyChanges(context);
      return true;
    }
    if (result == _PendingAction.discard) {
      controller.discardChanges();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!controller.pendingChanges.value) {
          Navigator.of(context).pop();
          return;
        }
        final shouldPop = await _confirmDiscard(context);
        if (shouldPop && context.mounted) Navigator.of(context).pop();
      },
      child: Obx(() {
        final hasPending = controller.pendingChanges.value;
        return SettingsScaffold(
          title: "Theme Studio",
          initialHeader: null,
          iosSubtitle: iosSubtitle,
          materialSubtitle: materialSubtitle,
          tileColor: tileColor,
          headerColor: headerColor,
          leading: hasPending
              ? _PendingBackButton(
                  onPressed: () => _confirmDiscard(context).then((ok) {
                        if (ok && context.mounted) Navigator.of(context).pop();
                      }))
              : null,
          actions: hasPending
              ? [
                  TextButton(
                    onPressed: () => controller.discardChanges(),
                    child: Text("Discard", style: TextStyle(color: context.theme.colorScheme.error)),
                  ),
                  TextButton(
                    onPressed: () => controller.applyChanges(context),
                    child: const Text("Apply"),
                  ),
                ]
              : [],
          fab: hasPending
              ? FloatingActionButton.extended(
                  onPressed: () => controller.applyChanges(context),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text("Apply"),
                )
              : null,
          bodySlivers: [
            // Light/dark preview toggle
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                child: Row(
                  children: [
                    Text(
                      "Preview",
                      style: context.theme.textTheme.titleSmall?.copyWith(
                        color: context.theme.colorScheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    _PreviewToggle(controller: controller),
                  ],
                ),
              ),
            ),

            // Live preview
            SliverToBoxAdapter(
              child: Obx(() {
                controller.themeDataVersion.value;
                controller.previewDark.value;
                // Also subscribe to skin so the preview rebuilds when the user
                // switches between iOS / Material / Samsung themes.
                SettingsSvc.settings.skin.value;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: context.theme.colorScheme.outline.withValues(alpha: 0.35),
                        width: 1.5,
                      ),
                    ),
                    child: RepaintBoundary(
                      child: ThemePreviewCard(struct: controller.previewTheme),
                    ),
                  ),
                );
              }),
            ),

            // Themes
            SliverToBoxAdapter(child: _sectionHeader(context, "Themes")),
            SliverToBoxAdapter(
              child: Obx(() {
                controller.themeListVersion.value;
                controller.pendingChanges.value;
                return ThemeSelectorSection(controller: controller);
              }),
            ),

            // Colors / Typography / Manage — deferred until after first frame
            // so the visible sections (preview + theme selector) appear immediately.
            if (_contentReady) ...[
              // Colors
              SliverToBoxAdapter(child: _sectionHeader(context, "Colors")),
              SliverToBoxAdapter(
                child: Obx(() {
                  controller.themeDataVersion.value;
                  if (!controller.isEditable) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, size: 14, color: context.theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              "To customize the app colors, create a new theme.",
                              style: context.theme.textTheme.bodySmall?.copyWith(
                                color: context.theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                }),
              ),
              SliverToBoxAdapter(
                child: Obx(() {
                  controller.themeDataVersion.value;
                  return _ColorEditorBody(controller: controller);
                }),
              ),

              // Typography
              SliverToBoxAdapter(child: _sectionHeader(context, "Typography")),
              SliverToBoxAdapter(
                child: Obx(() {
                  controller.themeDataVersion.value;
                  return TypographyEditor(controller: controller);
                }),
              ),

              // Manage
              SliverToBoxAdapter(child: _sectionHeader(context, "Manage Theme")),
              SliverToBoxAdapter(
                child: Obx(() {
                  controller.themeListVersion.value;
                  return ThemeManagementSection(controller: controller);
                }),
              ),
            ],

            const SliverToBoxAdapter(child: SizedBox(height: 48)),
          ],
        );
      }),
    );
  }

  Widget _sectionHeader(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6, left: 20, right: 20),
      child: Text(
        text.toUpperCase(),
        style: context.theme.textTheme.bodySmall?.copyWith(
          color: context.theme.colorScheme.outline,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ─── Preview light/dark toggle ────────────────────────────────────────────────

class _PreviewToggle extends StatelessWidget {
  const _PreviewToggle({required this.controller});
  final ThemeStudioController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final isDark = controller.previewDark.value;
      return Container(
        height: 28,
        decoration: BoxDecoration(
          color: context.theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tab(context, label: "Light", icon: Icons.light_mode_outlined, selected: !isDark, onTap: () {
              controller.previewDark.value = false;
            }),
            _tab(context, label: "Dark", icon: Icons.dark_mode_outlined, selected: isDark, onTap: () {
              controller.previewDark.value = true;
            }),
          ],
        ),
      );
    });
  }

  Widget _tab(BuildContext context,
      {required String label, required IconData icon, required bool selected, required VoidCallback onTap}) {
    final cs = context.theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? cs.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: selected ? cs.onPrimary : cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: context.theme.textTheme.labelSmall?.copyWith(
                color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Color editor body ────────────────────────────────────────────────────────

class _ColorEditorBody extends StatelessWidget {
  const _ColorEditorBody({required this.controller});
  final ThemeStudioController controller;

  static const _groups = [
    ColorGroup(
      title: "Brand",
      icon: Icons.palette_outlined,
      pairs: [
        ColorPair("primary", "onPrimary"),
        ColorPair("primaryContainer", "onPrimaryContainer"),
        ColorPair("secondary", "onSecondary"),
        ColorPair("tertiaryContainer", "onTertiaryContainer"),
      ],
    ),
    ColorGroup(
      title: "Surfaces & Backgrounds",
      icon: Icons.layers_outlined,
      pairs: [
        ColorPair("background", "onBackground"),
        ColorPair("surface", "onSurface"),
        ColorPair("surfaceVariant", "onSurfaceVariant"),
        ColorPair("inverseSurface", "onInverseSurface"),
      ],
    ),
    ColorGroup(
      title: "Chat Bubbles",
      icon: Icons.chat_bubble_outline,
      pairs: [
        ColorPair("smsBubble", "onSmsBubble"),
      ],
    ),
    ColorGroup(
      title: "Semantic",
      icon: Icons.warning_amber_outlined,
      pairs: [
        ColorPair("error", "onError"),
        ColorPair("errorContainer", "onErrorContainer"),
      ],
    ),
    ColorGroup(
      title: "Borders & Outlines",
      icon: Icons.border_outer_outlined,
      pairs: [
        ColorPair("outline", null),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = controller.activeTheme.colors(controller.isDark.value, returnMaterialYou: false);
    final editable = controller.isEditable;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _groups
            .map((group) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ColorEditorSection(
                    group: group,
                    colors: colors,
                    editable: editable,
                    controller: controller,
                  ),
                ))
            .toList(),
      ),
    );
  }
}

// ─── Helpers for pending-changes UX ──────────────────────────────────────────

enum _PendingAction { apply, discard, cancel }

/// Custom back button shown when there are pending changes. It triggers the
/// confirmation dialog rather than navigating directly.
class _PendingBackButton extends StatelessWidget {
  const _PendingBackButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: 48,
        child: IconButton(
          iconSize: SettingsSvc.settings.skin.value != Skins.Material ? 30 : 24,
          icon: Obx(() => Icon(
                SettingsSvc.settings.skin.value != Skins.Material ? CupertinoIcons.back : Icons.arrow_back,
                color: context.theme.colorScheme.primary,
              )),
          onPressed: onPressed,
        ),
      ),
    );
  }
}
