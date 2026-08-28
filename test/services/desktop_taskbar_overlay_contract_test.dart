import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unsupported Windows taskbar overlays fail closed for the session', () {
    final source = File('lib/main.dart').readAsStringSync();
    final methodStart = source.indexOf(
      'Future<void> _updateWindowsTaskbarOverlay(int count)',
    );
    final initStart = source.indexOf('void initState()', methodStart);

    expect(methodStart, greaterThanOrEqualTo(0));
    expect(initStart, greaterThan(methodStart));
    final method = source.substring(methodStart, initStart);
    expect(method, contains('if (!_windowsTaskbarOverlayAvailable) return;'));
    expect(method, contains('_windowsTaskbarOverlayAvailable = false;'));
    expect(method, contains('WindowsTaskbar.resetOverlayIcon()'));
    expect(method, contains('WindowsTaskbar.setOverlayIcon('));
    expect(method, contains('catch (error, trace)'));
    expect(
      source,
      contains(
        'GlobalChatService.unreadCount.listen(_updateWindowsTaskbarOverlay)',
      ),
    );
  });
}
