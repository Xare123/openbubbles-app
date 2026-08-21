import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

enum DesktopCloseBehavior { hideToTray, exit }

DesktopCloseBehavior desktopCloseBehavior({required bool closeToTray}) =>
    closeToTray ? DesktopCloseBehavior.hideToTray : DesktopCloseBehavior.exit;

Future<void> requestDesktopWindowClose({required bool closeToTray}) async {
  final behavior = desktopCloseBehavior(closeToTray: closeToTray);
  Logger.info('Desktop window close requested action=${behavior.name}');
  await performDesktopWindowClose(behavior: behavior);
}

Future<void> exitDesktopWindow() async {
  Logger.info(
    'Desktop window close requested action=${DesktopCloseBehavior.exit.name}',
  );
  await performDesktopWindowClose(behavior: DesktopCloseBehavior.exit);
}

@visibleForTesting
Future<void> performDesktopWindowClose({
  required DesktopCloseBehavior behavior,
  Future<void> Function()? hideWindow,
  Future<bool> Function()? isPreventClose,
  Future<void> Function(bool)? setPreventClose,
  Future<void> Function()? closeWindow,
}) async {
  hideWindow ??= windowManager.hide;
  isPreventClose ??= windowManager.isPreventClose;
  setPreventClose ??= windowManager.setPreventClose;
  closeWindow ??= windowManager.close;

  if (behavior == DesktopCloseBehavior.hideToTray) {
    await hideWindow();
    return;
  }

  if (await isPreventClose()) {
    await setPreventClose(false);
  }
  await closeWindow();
}
