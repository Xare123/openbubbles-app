import 'dart:io';

import 'package:bluebubbles/app/layouts/findmy/findmy_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Row = ({String id, List<String> handles, int? location, bool? optedNotToShare});
typedef Person = ({String address, int? location});

void main() {
  test('page projects native location without interpreting opaque sharing flag', () {
    final source = File(
      const String.fromEnvironment('FINDMY_PAGE_SOURCE',
          defaultValue: 'lib/app/layouts/findmy/findmy_page.dart'),
    ).readAsStringSync();
    expect(source.contains('final visibleLocation = e.lastLocation;'), isTrue);
    expect(source.contains('findMyVisibleLocation('), isFalse);
  });

  List<Person> project(Row row, Person previous) => projectFindMyPeople(
    [row],
    handles: (row) => row.handles,
    lastKnownHandle: (row) => row.id == 'known' ? previous.address : null,
    project: (row, address) => (
      address: address,
      location: row.location,
    ),
  );

  test(
    'handle-less known response replaces absent location with fresh data',
    () {
      final result = project(
        (id: 'known', handles: [], location: 2, optedNotToShare: null),
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
          (id: 'known', handles: [' '], location: 2, optedNotToShare: false),
          (address: 'synthetic@example.test', location: 1),
        ).single.location,
        2,
      );
    },
  );

  test('explicit missing location never resurrects the old coordinates', () {
    expect(
      project(
        (id: 'known', handles: [], location: null, optedNotToShare: null),
        (address: 'synthetic@example.test', location: 1),
      ).single.location,
      isNull,
    );
  });

  // The upstream page projects the native location directly. This flag has
  // no established directional permission meaning in the available source.
  for (final handles in <List<String>>[
    [],
    ['synthetic@example.test'],
  ]) {
    for (final flag in <bool?>[true, false, null]) {
      test('fresh native location survives opaque flag=$flag handles=$handles', () {
        expect(
          project(
            (id: 'known', handles: handles, location: 2, optedNotToShare: flag),
            (address: 'synthetic@example.test', location: 1),
          ).single.location,
          2,
        );
      });

      test('native null clears old location for flag=$flag handles=$handles', () {
        expect(
          project(
            (id: 'known', handles: handles, location: null, optedNotToShare: flag),
            (address: 'synthetic@example.test', location: 1),
          ).single.location,
          isNull,
        );
      });
    }
  }

  test('empty current roster cannot retain the previous person', () {
    final result = projectFindMyPeople<Row, Person>(
      [],
      handles: (row) => row.handles,
      lastKnownHandle: (row) => 'synthetic@example.test',
      project: (row, address) => (address: address, location: row.location),
    );
    expect(result, isEmpty);
  });

  test('unknown identity cannot borrow another person\'s previous handle', () {
    expect(
      project(
        (id: 'unknown', handles: [], location: 2, optedNotToShare: null),
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
          optedNotToShare: false,
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
