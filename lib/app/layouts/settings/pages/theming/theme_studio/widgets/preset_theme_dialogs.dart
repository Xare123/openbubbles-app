import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/theme_studio_panel.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:flutter/material.dart';

import 'preset_theme_actions.dart';

class PresetThemeDialogs {
  final ThemeStudioController controller;
  final bool isForDark;
  final void Function(BuildContext context) showImportDialog;

  PresetThemeDialogs({
    required this.controller,
    required this.isForDark,
    required this.showImportDialog,
  });

  void showContextMenu(BuildContext context, ThemeStruct theme) {
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
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const Divider(height: 8),
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text(PresetThemeActions.cloneLabel),
                subtitle: const Text("Create a copy of this theme"),
                onTap: () {
                  Navigator.of(ctx).pop();
                  showCloneDialog(context, theme);
                },
              ),
              if (isCustom) ...[
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text(PresetThemeActions.renameLabel),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    showRenameDialog(context, theme);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                  title: Text(PresetThemeActions.deleteLabel,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    confirmDelete(context, theme);
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

  void showCloneDialog(BuildContext context, ThemeStruct source) {
    final textController = TextEditingController(text: "${source.name} Copy");
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        title: Text("Clone \"${source.name}\"", style: Theme.of(context).textTheme.titleLarge),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: "New Theme Name",
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Theme.of(context).colorScheme.outline)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Theme.of(context).colorScheme.primary)),
          ),
          onSubmitted: (_) => _doClone(ctx, source, textController.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel", style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ),
          TextButton(
            onPressed: () => _doClone(ctx, source, textController.text),
            child: Text("Clone", style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  void showRenameDialog(BuildContext context, ThemeStruct theme) {
    controller.applyTheme(context, theme);
    final textController = TextEditingController(text: theme.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        title: Text("Rename \"${theme.name}\"", style: Theme.of(context).textTheme.titleLarge),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: "New Name",
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Theme.of(context).colorScheme.outline)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Theme.of(context).colorScheme.primary)),
          ),
          onSubmitted: (_) => _doRename(ctx, context, textController.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel", style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ),
          TextButton(
            onPressed: () => _doRename(ctx, context, textController.text),
            child: Text("Rename", style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  void confirmDelete(BuildContext context, ThemeStruct theme) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete Theme"),
        content: Text("Delete \"${theme.name}\"? This cannot be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel", style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              controller.applyTheme(context, theme);
              controller.deleteTheme(context);
            },
            child: Text("Delete", style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
  }

  void showCreateDialog(BuildContext context) {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        title: Text(
          "New ${isForDark ? 'Dark' : 'Light'} Theme",
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: "Theme Name",
            hintText: "e.g. My Custom Theme",
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Theme.of(context).colorScheme.outline)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Theme.of(context).colorScheme.primary)),
          ),
          onSubmitted: (_) => _doCreate(ctx, context, textController.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel", style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ),
          TextButton(
            onPressed: () => _doCreate(ctx, context, textController.text),
            child: Text("Create", style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  void _doClone(BuildContext dialogCtx, ThemeStruct source, String name) {
    final err = PresetThemeActions.validateThemeName(name);
    if (err != null) {
      showSnackbar("Error", err);
      return;
    }
    Navigator.of(dialogCtx).pop();
    controller.cloneTheme(name.trim(), source);
  }

  Future<void> _doRename(BuildContext dialogCtx, BuildContext pageCtx, String newName) async {
    Navigator.of(dialogCtx).pop();
    final ok = await controller.renameTheme(pageCtx, newName.trim());
    if (!ok) showSnackbar("Error", "Could not rename — name is empty or already taken");
  }

  void _doCreate(BuildContext dialogCtx, BuildContext pageCtx, String name) {
    final err = PresetThemeActions.validateThemeName(name);
    if (err != null) {
      showSnackbar("Error", err);
      return;
    }
    Navigator.of(dialogCtx).pop();
    controller.createTheme(pageCtx, name.trim(), forDark: isForDark);
  }
}
