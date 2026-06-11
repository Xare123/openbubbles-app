import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// BlueBubbles base page wrapper that handles system UI overlay styling
///
/// Provides consistent status bar and navigation bar styling across the app
/// with support for immersive mode and theme-aware colors.
///
/// Example:
/// ```dart
/// @override
/// Widget build(BuildContext context) {
///   return BBAnnotatedRegion(
///     child: Scaffold(
///       body: YourContent(),
///     ),
///   );
/// }
/// ```
class BBAnnotatedRegion extends StatelessWidget {
  /// The child widget to wrap
  final Widget child;

  /// Custom status bar icon brightness (defaults to theme-based)
  final Brightness? statusBarIconBrightness;

  /// Custom navigation bar icon brightness (defaults to theme-based)
  final Brightness? systemNavigationBarIconBrightness;

  /// Custom navigation bar color (defaults to theme background or transparent in immersive mode)
  final Color? systemNavigationBarColor;

  /// Custom status bar color (defaults to transparent)
  final Color? statusBarColor;

  const BBAnnotatedRegion({
    super.key,
    required this.child,
    this.statusBarIconBrightness,
    this.systemNavigationBarIconBrightness,
    this.systemNavigationBarColor,
    this.statusBarColor,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final immersiveMode = SettingsSvc.settings.immersiveMode.value;
      final colorScheme = Theme.of(context).colorScheme;
      final brightness = colorScheme.brightness;

      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarColor:
              systemNavigationBarColor ?? (immersiveMode ? Colors.transparent : colorScheme.surface),
          systemNavigationBarIconBrightness: systemNavigationBarIconBrightness ?? brightness.opposite,
          statusBarColor: statusBarColor ?? Colors.transparent,
          statusBarIconBrightness: statusBarIconBrightness ?? brightness.opposite,
        ),
        child: child,
      );
    });
  }
}
