import 'package:bluebubbles/app/wrappers/bb_annotated_region.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/window_effect.dart';

/// BlueBubbles standardized Scaffold wrapper
///
/// Combines BBAnnotatedRegion with Scaffold and handles common patterns:
/// - Automatic window effect transparency
/// - System UI overlay styling
/// - Theme-aware defaults
///
/// Example:
/// ```dart
/// @override
/// Widget build(BuildContext context) {
///   return BBScaffold(
///     appBar: AppBar(title: Text('My Page')),
///     body: YourContent(),
///   );
/// }
/// ```
class BBScaffold extends StatelessWidget {
  /// The primary content of the scaffold
  final Widget? body;

  /// App bar for the scaffold
  final PreferredSizeWidget? appBar;

  /// Background color override
  ///
  /// If null, automatically uses transparent for window effects or theme background
  final Color? backgroundColor;

  /// Floating action button
  final Widget? floatingActionButton;

  /// Position of the floating action button
  final FloatingActionButtonLocation? floatingActionButtonLocation;

  /// Bottom navigation bar
  final Widget? bottomNavigationBar;

  /// Drawer widget
  final Widget? drawer;

  /// End drawer widget
  final Widget? endDrawer;

  /// Bottom sheet widget
  final Widget? bottomSheet;

  /// Whether the body should extend behind app bar
  final bool extendBodyBehindAppBar;

  /// Whether the body should extend behind bottom navigation bar
  final bool extendBody;

  /// Resize to avoid bottom inset
  final bool? resizeToAvoidBottomInset;

  /// Custom status bar icon brightness (defaults to theme-based)
  final Brightness? statusBarIconBrightness;

  /// Custom navigation bar icon brightness (defaults to theme-based)
  final Brightness? systemNavigationBarIconBrightness;

  /// Custom navigation bar color (defaults to theme background or transparent in immersive mode)
  final Color? systemNavigationBarColor;

  /// Custom status bar color (defaults to transparent)
  final Color? statusBarColor;

  /// Persistent footer buttons
  final List<Widget>? persistentFooterButtons;

  /// Persistent footer alignment
  final AlignmentDirectional? persistentFooterAlignment;

  const BBScaffold({
    super.key,
    this.body,
    this.appBar,
    this.backgroundColor,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.drawer,
    this.endDrawer,
    this.bottomSheet,
    this.extendBodyBehindAppBar = false,
    this.extendBody = false,
    this.resizeToAvoidBottomInset,
    this.statusBarIconBrightness,
    this.systemNavigationBarIconBrightness,
    this.systemNavigationBarColor,
    this.statusBarColor,
    this.persistentFooterButtons,
    this.persistentFooterAlignment,
  });

  @override
  Widget build(BuildContext context) {
    // Wrapping this in Obx may cause issues, so removingit for now.
    // If we need to react to changes in settings, this needs to come from the "top down",
    // instead of going through GetX's reactive system here.
    final effectiveBackgroundColor = backgroundColor ??
        (SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
            ? Colors.transparent
            : Theme.of(context).colorScheme.surface);

    return BBAnnotatedRegion(
      statusBarIconBrightness: statusBarIconBrightness,
      systemNavigationBarIconBrightness: systemNavigationBarIconBrightness,
      systemNavigationBarColor: systemNavigationBarColor,
      statusBarColor: statusBarColor,
      child: Scaffold(
        backgroundColor: effectiveBackgroundColor,
        appBar: appBar,
        body: body,
        floatingActionButton: floatingActionButton,
        floatingActionButtonLocation: floatingActionButtonLocation,
        bottomNavigationBar: bottomNavigationBar,
        drawer: drawer,
        endDrawer: endDrawer,
        bottomSheet: bottomSheet,
        extendBodyBehindAppBar: extendBodyBehindAppBar,
        extendBody: extendBody,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        persistentFooterButtons: persistentFooterButtons,
        persistentFooterAlignment: persistentFooterAlignment ?? AlignmentDirectional.centerEnd,
      ),
    );
  }
}
