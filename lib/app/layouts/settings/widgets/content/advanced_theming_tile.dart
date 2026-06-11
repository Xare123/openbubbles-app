import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

@immutable
class AdvancedThemingEntry {
  final MapEntry<String, Color> primary;
  final MapEntry<String, Color>? textColor;
  const AdvancedThemingEntry({required this.primary, this.textColor});
}

class AdvancedThemingTile extends StatefulWidget {
  const AdvancedThemingTile({super.key, required this.currentTheme, required this.colorEntry, required this.editable});
  final ThemeStruct currentTheme;
  final AdvancedThemingEntry colorEntry;
  final bool editable;

  @override
  State<AdvancedThemingTile> createState() => _AdvancedThemingTileState();
}

class _AdvancedThemingTileState extends State<AdvancedThemingTile> {
  @override
  Widget build(BuildContext context) {
    final textColor = widget.colorEntry.textColor?.value ?? Colors.black;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Material(
              color: widget.colorEntry.primary.value,
              child: Container(
                decoration: widget.colorEntry.primary.value.computeDifference(
                            ThemeSvc.inDarkMode(context) || SettingsSvc.settings.skin.value == Skins.Samsung
                                ? context.theme.colorScheme.surface
                                : context.theme.colorScheme.surfaceContainerHighest) <
                        15
                    ? BoxDecoration(
                        border: Border.all(width: 0.5, color: context.theme.colorScheme.outline),
                        borderRadius: BorderRadius.circular(20))
                    : null,
                child: InkWell(
                  onTap: () async {
                    BuildContext _context = context;
                    if (widget.editable) {
                      final result = await showThemeDialog(widget.colorEntry.primary.value);
                      if (result != null) {
                        final map = widget.currentTheme.toMap();
                        map["data"]["colorScheme"][widget.colorEntry.primary.key] = result.toARGB32();
                        widget.currentTheme.data = ThemeStruct.fromMap(map).data;
                        widget.currentTheme.save();
                        if (widget.currentTheme.name == PrefsSvc.i.getString("selected-dark")) {
                          await ThemeSvc.changeTheme(_context, dark: widget.currentTheme);
                        } else if (widget.currentTheme.name == PrefsSvc.i.getString("selected-light")) {
                          await ThemeSvc.changeTheme(_context, light: widget.currentTheme);
                        }
                      }
                    } else {
                      if (SettingsSvc.settings.monetTheming.value != Monet.none) {
                        showSnackbar('Notice', "Turn off Material You to start customizing!");
                      } else {
                        showSnackbar('Notice', "Create a new theme to start customizing!");
                      }
                    }
                  },
                  onLongPress: widget.colorEntry.textColor != null
                      ? () async {
                          BuildContext _context = context;
                          if (widget.editable) {
                            final result = await showThemeDialog(widget.colorEntry.textColor!.value);
                            if (result != null) {
                              final map = widget.currentTheme.toMap();
                              map["data"]["colorScheme"][widget.colorEntry.textColor!.key] = result.toARGB32();
                              widget.currentTheme.data = ThemeStruct.fromMap(map).data;
                              widget.currentTheme.save();
                              if (widget.currentTheme.name == PrefsSvc.i.getString("selected-dark")) {
                                await ThemeSvc.changeTheme(_context, dark: widget.currentTheme);
                              } else if (widget.currentTheme.name == PrefsSvc.i.getString("selected-light")) {
                                await ThemeSvc.changeTheme(_context, light: widget.currentTheme);
                              }
                            }
                          } else {
                            if (SettingsSvc.settings.monetTheming.value != Monet.none) {
                              showSnackbar('Notice', "Turn off Material You to start customizing!");
                            } else {
                              showSnackbar('Notice', "Create a new theme to start customizing!");
                            }
                          }
                        }
                      : null,
                  onDoubleTap: () {
                    showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: Text(
                            "Info - ${widget.colorEntry.primary.key} ${widget.colorEntry.textColor != null ? "/ ${widget.colorEntry.textColor!.key}" : ""}",
                            style: context.theme.textTheme.titleLarge,
                          ),
                          backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                          content: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(
                                "${ThemeStruct.colorDescriptions[widget.colorEntry.primary.key]}${widget.colorEntry.textColor != null ? "\n\n${ThemeStruct.colorDescriptions[widget.colorEntry.textColor!.key]}" : ""}",
                                style: context.theme.textTheme.bodyLarge),
                          ),
                          actions: <Widget>[
                            TextButton(
                              child: Text("OK",
                                  style: context.theme.textTheme.bodyLarge!
                                      .copyWith(color: context.theme.colorScheme.primary)),
                              onPressed: () {
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        );
                      },
                    );
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.color_lens,
                        size: 40,
                        color: textColor.computeDifference(widget.colorEntry.primary.value) < 15
                            ? widget.colorEntry.primary.value.lightenOrDarken(50)
                            : textColor,
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          widget.colorEntry.primary.key +
                              (widget.colorEntry.textColor != null ? " / ${widget.colorEntry.textColor!.key}" : ""),
                          style: context.textTheme.titleMedium?.copyWith(
                              color: textColor.computeDifference(widget.colorEntry.primary.value) < 15
                                  ? widget.colorEntry.primary.value.lightenOrDarken(20)
                                  : textColor),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ))),
    );
  }

  Future<Color?> showThemeDialog(Color newColor) async {
    return await showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            scrollable: true,
            content: ColorPicker(
              color: newColor,
              onColorChanged: (color) {
                newColor = color;
              },
              title: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('Choose a Color', style: Theme.of(context).textTheme.titleLarge)),
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
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(null);
                },
                child: const Text('CANCEL'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(newColor);
                },
                child: const Text('SAVE'),
              ),
            ],
          );
        });
  }
}
