import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:bluebubbles/database/global/findmy_friend.dart';
import 'package:flutter_test/flutter_test.dart';

FindMyFriend friend({required String id, LocationStatus? status}) =>
    FindMyFriend(
      latitude: 32.0,
      longitude: -117.0,
      longAddress: null,
      shortAddress: null,
      title: null,
      subtitle: null,
      handle: null,
      lastUpdated: null,
      status: status,
      locatingInProgress: false,
      id: id,
    );

void main() {
  group('Find My friends', () {
    test('uses a non-empty accepted handle', () {
      expect(
        findMyFriendAddress(
          acceptedHandles: const ['', ' gizelle@example.com '],
          invitationFromHandles: const ['fallback@example.com'],
        ),
        'gizelle@example.com',
      );
    });

    test(
      'falls back to the invitation sender when accepted handles are empty',
      () {
        expect(
          findMyFriendAddress(
            acceptedHandles: const [],
            invitationFromHandles: const ['gizelle@example.com'],
          ),
          'gizelle@example.com',
        );
      },
    );

    test('returns null instead of throwing when all handles are empty', () {
      expect(
        findMyFriendAddress(
          acceptedHandles: const ['', '  '],
          invitationFromHandles: const [],
        ),
        isNull,
      );
    });

    test(
      'inserts a newly received friend instead of writing index minus one',
      () {
        final friends = <FindMyFriend>[friend(id: 'existing')];

        expect(upsertFindMyFriendLocation(friends, friend(id: 'new')), isTrue);
        expect(friends.map((item) => item.id), ['existing', 'new']);
      },
    );

    test('replaces an existing friend with the same stable id', () {
      final friends = <FindMyFriend>[
        friend(id: 'same', status: LocationStatus.legacy),
      ];
      final update = friend(id: 'same', status: LocationStatus.live);

      expect(upsertFindMyFriendLocation(friends, update), isTrue);
      expect(friends, hasLength(1));
      expect(friends.single, same(update));
    });

    test('preserves the stable id from socket JSON', () {
      final parsed = FindMyFriend.fromJson({
        'id': 'friend-id',
        'coordinates': [32.0, -117.0],
      });

      expect(parsed.id, 'friend-id');
      expect(parsed.toJson()['id'], 'friend-id');
    });
  });
}
