import 'package:bluebubbles/services/backend/notifications/desktop_notification_actions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const reactionEmojis = <String, String>{
    'love': 'heart',
    'like': 'thumbs-up',
  };

  test('keeps mark read and maps supported selected reactions', () {
    expect(
      resolveDesktopNotificationActions(
        actionList: const <String>['Mark Read', 'love', 'like'],
        selectedIndices: const <int>[0, 2],
        privateApiEnabled: true,
        sourceIsReaction: false,
        sourceIsGroupEvent: false,
        reactionEmojis: reactionEmojis,
      ),
      const <String>['Mark Read', 'thumbs-up'],
    );
  });

  test('ignores stale indices and unsupported custom actions', () {
    expect(
      resolveDesktopNotificationActions(
        actionList: const <String>['Mark Read', 'custom', 'love'],
        selectedIndices: const <int>[-1, 0, 1, 9],
        privateApiEnabled: true,
        sourceIsReaction: false,
        sourceIsGroupEvent: false,
        reactionEmojis: reactionEmojis,
      ),
      const <String>['Mark Read'],
    );
  });

  test('only exposes mark read when tapbacks are unavailable', () {
    expect(
      resolveDesktopNotificationActions(
        actionList: const <String>['Mark Read', 'love'],
        selectedIndices: const <int>[0, 1],
        privateApiEnabled: false,
        sourceIsReaction: false,
        sourceIsGroupEvent: false,
        reactionEmojis: reactionEmojis,
      ),
      const <String>['Mark Read'],
    );

    expect(
      resolveDesktopNotificationActions(
        actionList: const <String>['Mark Read', 'love'],
        selectedIndices: const <int>[0, 1],
        privateApiEnabled: true,
        sourceIsReaction: true,
        sourceIsGroupEvent: false,
        reactionEmojis: reactionEmojis,
      ),
      const <String>['Mark Read'],
    );
  });
}
