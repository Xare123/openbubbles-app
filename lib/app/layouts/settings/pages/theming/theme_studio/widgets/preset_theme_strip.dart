import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/theme_studio_panel.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';

/// Two grouped sections — Light Themes and Dark Themes — each with a
/// prominent full-width Default card (Bright White / OLED Dark) and a
/// horizontal scroll of other presets, custom themes, and action cards.
///
/// Rendering is deferred until after the first frame so the page appears
/// immediately on navigation rather than blocking for the full build time.
class ThemeSelectorSection extends StatefulWidget {
  const ThemeSelectorSection({super.key, required this.controller});

  final ThemeStudioController controller;

  @override
  State<ThemeSelectorSection> createState() => _ThemeSelectorSectionState();
}

class _ThemeSelectorSectionState extends State<ThemeSelectorSection> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      // Approximate placeholder height keeps the page layout stable once
      // content appears. Adjust if the rendered height changes significantly.
      return const SizedBox(height: 380);
    }

    final controller = widget.controller;
    final all = controller.allThemes;

    // Partition by brightness
    final lightAll = all.where((t) => t.data.colorScheme.brightness == Brightness.light).toList();
    final darkAll = all.where((t) => t.data.colorScheme.brightness == Brightness.dark).toList();

    // Canonical defaults shown full-width; everything else goes in the scroll row
    final brightWhite = lightAll.firstWhereOrNull((t) => t.name == "Bright White");
    final oledDark = darkAll.firstWhereOrNull((t) => t.name == "OLED Dark");
    final lightOther = lightAll.where((t) => t.name != "Bright White").toList();
    final darkOther = darkAll.where((t) => t.name != "OLED Dark").toList();

    final pendingChanges = controller.pendingChanges.value;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ModeGroup(
            controller: controller,
            title: "Light Themes",
            defaultTheme: brightWhite,
            otherThemes: lightOther,
            isForDark: false,
            activeTheme: controller.lightTheme,
            appliedThemeName: controller.appliedLightName,
            pendingChanges: pendingChanges,
          ),
          const SizedBox(height: 24),
          _ModeGroup(
            controller: controller,
            title: "Dark Themes",
            defaultTheme: oledDark,
            otherThemes: darkOther,
            isForDark: true,
            activeTheme: controller.darkTheme,
            appliedThemeName: controller.appliedDarkName,
            pendingChanges: pendingChanges,
          ),
        ],
      ),
    );
  }
}

// ─── One mode group (Light or Dark) ───────────────────────────────────────────

class _ModeGroup extends StatelessWidget {
  const _ModeGroup({
    required this.controller,
    required this.title,
    required this.defaultTheme,
    required this.otherThemes,
    required this.isForDark,
    required this.activeTheme,
    required this.appliedThemeName,
    required this.pendingChanges,
  });

  final ThemeStudioController controller;
  final String title;
  final ThemeStruct? defaultTheme;
  final List<ThemeStruct> otherThemes;
  final bool isForDark;
  final ThemeStruct activeTheme;
  final String appliedThemeName;
  final bool pendingChanges;

  /// Whether a different theme is staged (pending) for this mode.
  bool get _selectionIsPending => pendingChanges && activeTheme.name != appliedThemeName;

  @override
  Widget build(BuildContext context) {
    // Presets before custom in the scroll row
    final presets = otherThemes.where((t) => t.isPreset).toList();
    final custom = otherThemes.where((t) => !t.isPreset).toList();

    final bool isCurrentMode = controller.isDark.value == isForDark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Mode header with action buttons
        Row(
          children: [
            Text(
              title,
              style: context.theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: isCurrentMode ? context.theme.colorScheme.primary : context.theme.colorScheme.onSurface,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _showImportDialog(context),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: context.theme.colorScheme.secondary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: const Icon(Icons.file_upload_outlined, size: 16),
              label: const Text("Import", style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: () => _showCreateDialog(context),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: const TextStyle(fontSize: 13),
              ),
              icon: const Icon(Icons.add, size: 16),
              label: const Text("New"),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 11, color: context.theme.colorScheme.outline),
            const SizedBox(width: 4),
            Text(
              "Tap and hold on a theme for more options",
              style: context.theme.textTheme.labelSmall?.copyWith(
                color: context.theme.colorScheme.outline,
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ─ Default card ───────────────────────────────────────────────────
        if (defaultTheme != null) ...[
          const _SubLabel("Default"),
          const SizedBox(height: 6),
          _DefaultCard(
            struct: defaultTheme!,
            isActive: activeTheme.name == defaultTheme!.name,
            isApplied: appliedThemeName == defaultTheme!.name,
            selectionIsPending: _selectionIsPending,
            onTap: () => controller.applyTheme(context, defaultTheme!),
            onLongPress: () => _showContextMenu(context, defaultTheme!),
          ),
          const SizedBox(height: 14),
        ],

        // ─ Custom themes ──────────────────────────────────────────────────
        if (custom.isNotEmpty) ...[
          const _SubLabel("Custom"),
          const SizedBox(height: 6),
          SizedBox(
            height: 110,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: custom.length,
              itemBuilder: (ctx, i) {
                final t = custom[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _ThemeCard(
                    struct: t,
                    isActive: activeTheme.name == t.name,
                    isApplied: appliedThemeName == t.name,
                    selectionIsPending: _selectionIsPending,
                    onTap: () => controller.applyTheme(context, t),
                    onLongPress: () => _showContextMenu(context, t),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
        ],

        // ─ Other presets ──────────────────────────────────────────────────
        if (presets.isNotEmpty) ...[
          const _SubLabel("More"),
          const SizedBox(height: 6),
          SizedBox(
            height: 110,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: presets.length,
              itemBuilder: (ctx, i) {
                final t = presets[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _ThemeCard(
                    struct: t,
                    isActive: activeTheme.name == t.name,
                    isApplied: appliedThemeName == t.name,
                    selectionIsPending: _selectionIsPending,
                    onTap: () => controller.applyTheme(context, t),
                    onLongPress: () => _showContextMenu(context, t),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  void _showContextMenu(BuildContext context, ThemeStruct theme) {
    final isCustom = !theme.isPreset;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Row(
                  children: [
                    const Icon(Icons.palette_outlined, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      theme.name,
                      style: context.theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const Divider(height: 8),
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text("Clone"),
                subtitle: const Text("Create a copy of this theme"),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _showCloneDialog(context, theme);
                },
              ),
              if (isCustom) ...[
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text("Rename"),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showRenameDialogForTheme(context, theme);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline, color: context.theme.colorScheme.error),
                  title: Text("Delete", style: TextStyle(color: context.theme.colorScheme.error)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _confirmDelete(context, theme);
                  },
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _showCloneDialog(BuildContext context, ThemeStruct source) {
    final textController = TextEditingController(text: "${source.name} Copy");
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text("Clone \"${source.name}\"", style: context.theme.textTheme.titleLarge),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: "New Theme Name",
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: context.theme.colorScheme.outline)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: context.theme.colorScheme.primary)),
          ),
          onSubmitted: (_) => _doClone(ctx, context, source, textController.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel", style: TextStyle(color: context.theme.colorScheme.primary)),
          ),
          TextButton(
            onPressed: () => _doClone(ctx, context, source, textController.text),
            child: Text("Clone", style: TextStyle(color: context.theme.colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  void _doClone(BuildContext dialogCtx, BuildContext pageCtx, ThemeStruct source, String name) {
    if (name.trim().isEmpty) {
      showSnackbar("Error", "Please enter a theme name");
      return;
    }
    if (ThemeStruct.findOne(name.trim()) != null) {
      showSnackbar("Error", "A theme with that name already exists");
      return;
    }
    Navigator.of(dialogCtx).pop();
    controller.cloneTheme(name.trim(), source);
  }

  void _showRenameDialogForTheme(BuildContext context, ThemeStruct theme) {
    // Rename only works on the active theme via the controller, so select it first
    controller.applyTheme(context, theme);
    final textController = TextEditingController(text: theme.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text("Rename \"${theme.name}\"", style: context.theme.textTheme.titleLarge),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: "New Name",
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: context.theme.colorScheme.outline)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: context.theme.colorScheme.primary)),
          ),
          onSubmitted: (_) => _doRename(ctx, context, textController.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel", style: TextStyle(color: context.theme.colorScheme.primary)),
          ),
          TextButton(
            onPressed: () => _doRename(ctx, context, textController.text),
            child: Text("Rename", style: TextStyle(color: context.theme.colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _doRename(BuildContext dialogCtx, BuildContext pageCtx, String newName) async {
    Navigator.of(dialogCtx).pop();
    final ok = await controller.renameTheme(pageCtx, newName.trim());
    if (!ok) showSnackbar("Error", "Could not rename — name is empty or already taken");
  }

  void _confirmDelete(BuildContext context, ThemeStruct theme) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete Theme"),
        content: Text("Delete \"${theme.name}\"? This cannot be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel", style: TextStyle(color: context.theme.colorScheme.primary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Select it so deleteTheme acts on the right one, then delete
              controller.applyTheme(context, theme);
              controller.deleteTheme(context);
            },
            child: Text("Delete", style: TextStyle(color: context.theme.colorScheme.error)),
          ),
        ],
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text(
          "New ${isForDark ? 'Dark' : 'Light'} Theme",
          style: context.theme.textTheme.titleLarge,
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: "Theme Name",
            hintText: "e.g. My Custom Theme",
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: context.theme.colorScheme.outline)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: context.theme.colorScheme.primary)),
          ),
          onSubmitted: (_) => _doCreate(ctx, context, textController.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel", style: TextStyle(color: context.theme.colorScheme.primary)),
          ),
          TextButton(
            onPressed: () => _doCreate(ctx, context, textController.text),
            child: Text("Create", style: TextStyle(color: context.theme.colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  void _doCreate(BuildContext dialogCtx, BuildContext pageCtx, String name) {
    if (name.trim().isEmpty) {
      showSnackbar("Error", "Please enter a theme name");
      return;
    }
    if (ThemeStruct.findOne(name.trim()) != null) {
      showSnackbar("Error", "A theme with that name already exists");
      return;
    }
    Navigator.of(dialogCtx).pop();
    controller.createTheme(pageCtx, name.trim(), forDark: isForDark);
  }

  void _showImportDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => _ImportDialog(controller: controller, pageContext: context),
    );
  }
}

// ─── Sub-label ─────────────────────────────────────────────────────────────────

class _SubLabel extends StatelessWidget {
  const _SubLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: context.theme.textTheme.labelSmall?.copyWith(
        color: context.theme.colorScheme.outline,
        letterSpacing: 0.7,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

// ─── Full-width default card ───────────────────────────────────────────────────

class _DefaultCard extends StatelessWidget {
  const _DefaultCard({
    required this.struct,
    required this.isActive,
    required this.isApplied,
    required this.selectionIsPending,
    required this.onTap,
    this.onLongPress,
  });

  final ThemeStruct struct;
  final bool isActive;
  final bool isApplied;
  final bool selectionIsPending;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = struct.data.colorScheme;
    // isPending: staged for this slot but not yet applied
    final isPending = isActive && selectionIsPending;
    // wasApplied: this is the current live theme but something else is staged
    final wasApplied = isApplied && !isActive;

    final borderColor = isPending
        ? context.theme.colorScheme.tertiary
        : isActive
            ? context.theme.colorScheme.primary
            : wasApplied
                ? context.theme.colorScheme.secondary.withValues(alpha: 0.5)
                : context.theme.colorScheme.outline.withValues(alpha: 0.3);
    final borderWidth = (isActive || wasApplied) ? 2.0 : 1.0;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: context.tileColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Row(
          children: [
            // 2×2 color swatch preview
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [_FixedSwatch(cs.primary), _FixedSwatch(cs.secondary)]),
                  Row(children: [_FixedSwatch(cs.tertiary), _FixedSwatch(cs.surface)]),
                ],
              ),
            ),
            // Name + caption
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      struct.name,
                      style: context.theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Built-in default",
                      style: context.theme.textTheme.bodySmall?.copyWith(
                        color: context.theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Selection indicator
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: _SelectionIcon(
                isActive: isActive,
                isPending: isPending,
                wasApplied: wasApplied,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FixedSwatch extends StatelessWidget {
  const _FixedSwatch(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: 36, height: 30, child: ColoredBox(color: color));
  }
}

// ─── Individual theme card ─────────────────────────────────────────────────────

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.struct,
    required this.isActive,
    required this.isApplied,
    required this.selectionIsPending,
    required this.onTap,
    this.onLongPress,
  });

  final ThemeStruct struct;
  final bool isActive;
  final bool isApplied;
  final bool selectionIsPending;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = struct.data.colorScheme;
    final isPending = isActive && selectionIsPending;
    final wasApplied = isApplied && !isActive;

    final borderColor = isPending
        ? context.theme.colorScheme.tertiary
        : isActive
            ? context.theme.colorScheme.primary
            : wasApplied
                ? context.theme.colorScheme.secondary.withValues(alpha: 0.5)
                : context.theme.colorScheme.outline.withValues(alpha: 0.3);
    final borderWidth = (isActive || wasApplied) ? 2.0 : 1.0;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 76,
        decoration: BoxDecoration(
          color: context.theme.colorScheme.surfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Color swatch grid
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                topRight: Radius.circular(10),
              ),
              child: SizedBox(
                height: 60,
                child: Stack(
                  children: [
                    Column(
                      children: [
                        Row(
                          children: [
                            _Swatch(cs.primary),
                            _Swatch(cs.secondary),
                          ],
                        ),
                        Row(
                          children: [
                            _Swatch(cs.tertiary),
                            _Swatch(cs.surface),
                          ],
                        ),
                      ],
                    ),
                    if (isActive || wasApplied)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: _SelectionIcon(
                          isActive: isActive,
                          isPending: isPending,
                          wasApplied: wasApplied,
                          size: 14,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Theme name
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text(
                  struct.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: context.theme.textTheme.labelSmall?.copyWith(
                    color: context.theme.colorScheme.onSurfaceVariant,
                    fontSize: 9.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(child: SizedBox(height: 30, child: ColoredBox(color: color)));
  }
}

// ─── Selection icon (applied / pending / was-applied) ─────────────────────────

class _SelectionIcon extends StatelessWidget {
  const _SelectionIcon({
    required this.isActive,
    required this.isPending,
    required this.wasApplied,
    required this.size,
  });

  final bool isActive;
  final bool isPending;
  final bool wasApplied;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    if (isPending) {
      // Staged but not yet applied — shown with tertiary ring color + clock icon
      return Container(
        decoration: BoxDecoration(color: cs.tertiary, shape: BoxShape.circle),
        padding: const EdgeInsets.all(2),
        child: Icon(Icons.schedule_rounded, size: size - 4, color: cs.onTertiary),
      );
    }
    if (isActive) {
      // Staged == applied; confirmed live selection
      return Container(
        decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
        padding: const EdgeInsets.all(2),
        child: Icon(Icons.check, size: size - 4, color: cs.onPrimary),
      );
    }
    if (wasApplied) {
      // Currently live but being replaced by pending selection
      return Icon(Icons.check_circle_outline_rounded, size: size, color: cs.secondary.withValues(alpha: 0.55));
    }
    return Icon(Icons.radio_button_unchecked, size: size, color: cs.outline.withValues(alpha: 0.5));
  }
}

// ─── Import dialog ─────────────────────────────────────────────────────────────

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.controller, required this.pageContext});

  final ThemeStudioController controller;
  final BuildContext pageContext;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _textController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'txt'],
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    final path = result.files.first.path;
    String? json;
    if (bytes != null) {
      json = String.fromCharCodes(bytes);
    } else if (path != null) {
      json = await File(path).readAsString();
    }
    if (json != null) _textController.text = json;
  }

  Future<void> _doImport() async {
    final json = _textController.text.trim();
    if (json.isEmpty) return;
    setState(() => _loading = true);
    final theme = await widget.controller.importThemeFromJson(json);
    setState(() => _loading = false);
    if (!mounted) return;
    Navigator.of(context).pop();
    if (theme != null) {
      showSnackbar("Imported", "Theme \"${theme.name}\" imported successfully");
    } else {
      showSnackbar("Error", "Could not parse theme — make sure it's a valid exported JSON");
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      title: Text("Import Theme", style: context.theme.textTheme.titleLarge),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Paste the exported theme JSON below, or pick a .json file.",
              style: context.theme.textTheme.bodySmall?.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: '{ "name": "...", "data": { ... } }',
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: context.theme.colorScheme.outline)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: context.theme.colorScheme.primary)),
              ),
              style: context.theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text("Pick File"),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text("Cancel", style: TextStyle(color: context.theme.colorScheme.primary)),
        ),
        FilledButton(
          onPressed: _loading ? null : _doImport,
          child: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text("Import"),
        ),
      ],
    );
  }
}
