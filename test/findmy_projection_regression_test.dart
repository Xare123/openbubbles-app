import 'package:bluebubbles/app/layouts/findmy/findmy_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Row = ({String id, List<String> handles, int? location, bool? revoked});
typedef Person = ({String address, int? location});

void main() {
  List<Person> project(Row row, Person previous) => projectFindMyPeople(
    [row],
    handles: (row) => row.handles,
    lastKnownHandle: (row) => row.id == 'known' ? previous.address : null,
    project: (row, address) => (
      address: address,
      location: findMyVisibleLocation(
        row.location,
        optedNotToShare: row.revoked,
      ),
    ),
  );

  test(
    'handle-less known response replaces absent location with fresh data',
    () {
      final result = project(
        (id: 'known', handles: [], location: 2, revoked: null),
        (address: 'synthetic@example.test', location: null),
      );
      expect(result.single.location, 2);
      expect(result.single.address, 'synthetic@example.test');
    },
  );

  test(
    'handle-less response replaces old location rather than freezing it',
    () {
      expect(
        project(
          (id: 'known', handles: [' '], location: 2, revoked: false),
          (address: 'synthetic@example.test', location: 1),
        ).single.location,
        2,
      );
    },
  );

  test('explicit missing location never resurrects the old coordinates', () {
    expect(
      project(
        (id: 'known', handles: [], location: null, revoked: null),
        (address: 'synthetic@example.test', location: 1),
      ).single.location,
      isNull,
    );
  });

  for (final handles in <List<String>>[
    [],
    ['synthetic@example.test'],
  ]) {
    test(
      'explicit revocation hides even a retained native location: $handles',
      () {
        expect(
          project(
            (id: 'known', handles: handles, location: 2, revoked: true),
            (address: 'synthetic@example.test', location: 1),
          ).single.location,
          isNull,
        );
      },
    );
  }

  test('unknown identity cannot borrow another person\'s previous handle', () {
    expect(
      project(
        (id: 'unknown', handles: [], location: 2, revoked: null),
        (address: 'synthetic@example.test', location: 1),
      ),
      isEmpty,
    );
  });

  test('fresh accepted handle wins over previous identity and is trimmed', () {
    expect(
      project(
        (
          id: 'known',
          handles: [' ', ' new@example.test '],
          location: 2,
          revoked: false,
        ),
        (address: 'old@example.test', location: 1),
      ).single.address,
      'new@example.test',
    );
  });

  test('valid location without geocoding is not labeled as missing', () {
    for (final address in <String?>[null, '', '  ']) {
      expect(
        findMyLocationLabel(latitude: 1, longitude: 2, address: address),
        'Location available',
      );
    }
    expect(
      findMyLocationLabel(latitude: 1, longitude: 2, address: ' Test address '),
      'Test address',
    );
  });

  test(
    'stale address cannot make absent or invalid coordinates look available',
    () {
      for (final coordinates in <(double?, double?)>[
        (null, null),
        (1, null),
        (null, 2),
        (0, 0),
        (91, 2),
        (1, 181),
        (double.nan, 2),
        (1, double.infinity),
      ]) {
        expect(
          findMyLocationLabel(
            latitude: coordinates.$1,
            longitude: coordinates.$2,
            address: 'Old address',
          ),
          'No location found',
        );
      }
      expect(
        findMyLocationLabel(latitude: 0, longitude: 2),
        'Location available',
      );
      expect(
        findMyLocationLabel(latitude: 1, longitude: 0),
        'Location available',
      );
    },
  );
}
