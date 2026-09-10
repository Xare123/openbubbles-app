import "package:bluebubbles/app/layouts/findmy/findmy_page.dart";
import "package:bluebubbles/database/global/findmy_friend.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter/widgets.dart";
import "package:flutter_map/flutter_map.dart";
import "package:latlong2/latlong.dart";

void main() {
  test('friend marker replacement preserves current/device/item markers', () {
    Marker marker(String key) => Marker(
      key: ValueKey(key), point: const LatLng(1, 1), child: const SizedBox(),
    );
    final current = marker('current');
    final device = marker('device-synthetic');
    final item = marker('item-synthetic');
    final markers = <String, Marker>{
      'current': current, 'device': device, 'item': item,
      'old-friend': marker('friend-synthetic'),
    };
    removeFindMyFriendMarkers(markers);
    expect(markers, {'current': current, 'device': device, 'item': item});
    removeFindMyFriendMarkers(markers);
    expect(markers.length, 3);
  });

  group("deriveFindMyStateCode", () {
    test("returns null for null, empty, and single-character areas", () {
      expect(deriveFindMyStateCode(null), isNull);
      expect(deriveFindMyStateCode(""), isNull);
      expect(deriveFindMyStateCode("C"), isNull);
    });
    test("returns uppercased first two characters", () {
      expect(deriveFindMyStateCode("California"), "CA");
      expect(deriveFindMyStateCode("ca"), "CA");
      expect(deriveFindMyStateCode("TX"), "TX");
    });
  });
  group("live friend merge precedence", () {
    test("unknown friend appends instead of indexing -1", () {
      expect(
        decideLiveFriendMerge(
          existingIndex: -1,
          existingStatus: null,
          incomingStatus: LocationStatus.live,
          incomingLocatingInProgress: false,
        ),
        LiveFriendMergeAction.append,
      );
    });
    test("known friend replaces on equal or newer status", () {
      expect(
        decideLiveFriendMerge(
          existingIndex: 0,
          existingStatus: LocationStatus.legacy,
          incomingStatus: LocationStatus.live,
          incomingLocatingInProgress: false,
        ),
        LiveFriendMergeAction.replace,
      );
      expect(
        decideLiveFriendMerge(
          existingIndex: 0,
          existingStatus: LocationStatus.live,
          incomingStatus: LocationStatus.live,
          incomingLocatingInProgress: false,
        ),
        LiveFriendMergeAction.replace,
      );
    });
    test("known friend ignores stale status unless locating", () {
      expect(
        decideLiveFriendMerge(
          existingIndex: 0,
          existingStatus: LocationStatus.live,
          incomingStatus: LocationStatus.legacy,
          incomingLocatingInProgress: false,
        ),
        LiveFriendMergeAction.ignore,
      );
      expect(
        decideLiveFriendMerge(
          existingIndex: 0,
          existingStatus: LocationStatus.live,
          incomingStatus: LocationStatus.legacy,
          incomingLocatingInProgress: true,
        ),
        LiveFriendMergeAction.replace,
      );
    });
  });
}
