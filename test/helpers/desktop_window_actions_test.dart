import 'package:bluebubbles/helpers/backend/desktop_window_actions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'close-to-tray hides directly without entering the native close path',
    () async {
      final calls = <String>[];

      await performDesktopWindowClose(
        behavior: DesktopCloseBehavior.hideToTray,
        hideWindow: () async {
          calls.add('hide');
        },
        isPreventClose: () async {
          calls.add('isPreventClose');
          return true;
        },
        setPreventClose: (value) async {
          calls.add('setPreventClose:$value');
        },
        closeWindow: () async {
          calls.add('close');
        },
      );

      expect(calls, ['hide']);
    },
  );

  test('exit clears prevent-close before closing', () async {
    final calls = <String>[];

    await performDesktopWindowClose(
      behavior: DesktopCloseBehavior.exit,
      hideWindow: () async {
        calls.add('hide');
      },
      isPreventClose: () async {
        calls.add('isPreventClose');
        return true;
      },
      setPreventClose: (value) async {
        calls.add('setPreventClose:$value');
      },
      closeWindow: () async {
        calls.add('close');
      },
    );

    expect(calls, ['isPreventClose', 'setPreventClose:false', 'close']);
  });

  test(
    'exit does not rewrite prevent-close when it is already disabled',
    () async {
      final calls = <String>[];

      await performDesktopWindowClose(
        behavior: DesktopCloseBehavior.exit,
        hideWindow: () async {
          calls.add('hide');
        },
        isPreventClose: () async {
          calls.add('isPreventClose');
          return false;
        },
        setPreventClose: (value) async {
          calls.add('setPreventClose:$value');
        },
        closeWindow: () async {
          calls.add('close');
        },
      );

      expect(calls, ['isPreventClose', 'close']);
    },
  );
}
