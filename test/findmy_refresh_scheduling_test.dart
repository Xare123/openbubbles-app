import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/app/layouts/findmy/findmy_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pending Items allows subsequent People and Devices polls', () async {
    final scheduler = FindMyRefreshScheduler();
    final pendingItems = Completer<void>();
    var peoplePolls = 0;
    var devicePolls = 0;
    var itemPolls = 0;
    final people = FindMyPeopleRefreshState<int, int>([]);
    final devices = FindMyRefreshState<int>(0);
    var peoplePublications = 0;
    var firstCompleted = false;
    Future<void> poll() => scheduler.refresh(
      people: () async {
        await people.refreshAndPublish(
          fetch: () async => [++peoplePolls],
          project: (rows) => rows.toList(),
          publish: () {
            peoplePublications++;
          },
        );
      },
      devices: () async {
        await devices.refresh(() async => ++devicePolls);
      },
      items: () {
        itemPolls++;
        return pendingItems.future;
      },
    );

    final first = poll().then((_) {
      firstCompleted = true;
    });
    try {
      await Future<void>.delayed(Duration.zero);
      expect(peoplePolls, 1);
      expect(devicePolls, 1);
      await poll();
      expect(peoplePolls, 2);
      expect(devicePolls, 2);
      expect(itemPolls, 1);
      expect(people.value, [2]);
      expect(peoplePublications, 2);
      expect(devices.value, 2);
      expect(firstCompleted, isFalse);
      expect(scheduler.allBusy, isFalse);
    } finally {
      pendingItems.complete();
      await first;
      scheduler.dispose();
    }
  });

  testWidgets('30-second timer continues polling with Items pending', (
    tester,
  ) async {
    final scheduler = FindMyRefreshScheduler();
    final pending = Completer<void>();
    var people = 0;
    var devices = 0;
    var items = 0;
    Future<void> poll() => scheduler.refresh(
      people: () async {
        people++;
      },
      devices: () async {
        devices++;
      },
      items: () {
        items++;
        return pending.future;
      },
    );
    final first = poll();
    final timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(poll()),
    );
    try {
      await tester.pump();
      for (var tick = 0; tick < 3; tick++) {
        await tester.pump(const Duration(seconds: 30));
      }
      expect(people, 4);
      expect(devices, 4);
      expect(items, 1);
    } finally {
      timer.cancel();
      scheduler.dispose();
      pending.complete();
      await first;
    }
  });

  test(
    'busy People and Items coalesce without queues while Devices advances',
    () async {
      final scheduler = FindMyRefreshScheduler();
      final pendingPeople = Completer<void>();
      final pendingItems = Completer<void>();
      var people = 0;
      var devices = 0;
      var items = 0;
      Future<void> poll() => scheduler.refresh(
        people: () {
          people++;
          return pendingPeople.future;
        },
        devices: () async {
          devices++;
        },
        items: () {
          items++;
          return pendingItems.future;
        },
      );
      final first = poll();
      try {
        await Future<void>.delayed(Duration.zero);
        for (var tick = 0; tick < 100; tick++) {
          await poll();
          await scheduler.refreshItems(() async {
            items++;
          });
        }
        expect(people, 1);
        expect(items, 1);
        expect(devices, 101);
        pendingPeople.complete();
        pendingItems.complete();
        await first;
        // Completion does not replay 100 deferred requests.
        expect(people, 1);
        expect(items, 1);
        await poll();
        expect(people, 2);
        expect(items, 2);
      } finally {
        scheduler.dispose();
        if (!pendingPeople.isCompleted) pendingPeople.complete();
        if (!pendingItems.isCompleted) pendingItems.complete();
        await first;
      }
    },
  );

  test('Items-only retry owns the slot through post-fetch geocoding', () async {
    final scheduler = FindMyRefreshScheduler();
    final geocoding = Completer<void>();
    final fetched = Completer<void>();
    var items = 0;
    var people = 0;
    final retry = scheduler.refreshItems(() async {
      items++;
      fetched.complete();
      await geocoding.future;
    });
    try {
      await fetched.future;
      await scheduler.refresh(
        people: () async {
          people++;
        },
        devices: () async {},
        items: () async {
          items++;
        },
      );
      await scheduler.refreshItems(() async {
        items++;
      });
      expect(people, 1);
      expect(items, 1);
      geocoding.complete();
      await retry;
      await scheduler.refreshItems(() async {
        items++;
      });
      expect(items, 2);
    } finally {
      scheduler.dispose();
      if (!geocoding.isCompleted) geocoding.complete();
      await retry;
    }
  });

  for (final fail in [false, true]) {
    test(
      'disposed lanes reject new work and late state updates (failure=$fail)',
      () async {
        final scheduler = FindMyRefreshScheduler();
        final pending = Completer<int>();
        final state = FindMyRefreshState<int>(7);
        var active = true;
        var calls = 0;
        var publications = 0;
        final first = scheduler.refreshItems(() async {
          await state.refresh(() {
            calls++;
            return pending.future;
          }, isActive: () => active);
          if (active) publications++;
        });
        active = false;
        scheduler.dispose();
        Future<void> forbidden() async {
          calls++;
        }

        await scheduler.refresh(
          people: forbidden,
          devices: forbidden,
          items: forbidden,
        );
        if (fail) {
          pending.completeError(StateError('synthetic failure'));
        } else {
          pending.complete(8);
        }
        await first;
        await scheduler.refreshItems(forbidden);
        expect(calls, 1);
        expect(publications, 0);
        expect(state.value, 7);
        expect(state.lastSuccessAt, isNull);
        expect(state.error, isNull);
        expect(state.loading, isFalse);
      },
    );
  }

  test(
    'unexpected lane error releases its slot and preserves other lanes',
    () async {
      final scheduler = FindMyRefreshScheduler();
      var devices = 0;
      var items = 0;
      await expectLater(
        scheduler.refresh(
          people: () => throw StateError('synthetic failure'),
          devices: () async {
            devices++;
          },
          items: () async {
            items++;
          },
        ),
        throwsStateError,
      );
      var people = 0;
      await scheduler.refresh(
        people: () async {
          people++;
        },
        devices: () async {
          devices++;
        },
        items: () async {
          items++;
        },
      );
      expect(people, 1);
      expect(devices, 2);
      expect(items, 2);
      scheduler.dispose();
    },
  );

  test('page uses independent admission and liveness guards (source contract)', () {
    final page = File(
      'lib/app/layouts/findmy/findmy_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(page, contains('final _cloudRefresh = FindMyRefreshScheduler();'));
    expect(page, isNot(contains('locationsRequestInFlight')));
    expect(page, contains('await _cloudRefresh.refresh('));
    expect(page, contains('people: () => refreshPeople('));
    expect(page, contains('devices: () => refreshCloudDevices('));
    expect(page, contains('items: () => refreshItems('));
    expect(
      page,
      contains('_cloudRefresh.refreshItems(() => refreshItems(force: true))'),
    );
    expect(page, contains('_cloudRefresh.dispose();'));
    expect(
      RegExp(r'child: _cloudRefresh.allBusy').allMatches(page),
      hasLength(3),
    );
    final devices = page.substring(
      page.indexOf('Future<void> refreshCloudDevices'),
      page.indexOf('Future<void> refreshItems'),
    );
    final items = page.substring(
      page.indexOf('Future<void> refreshItems'),
      page.indexOf('void publishDevicesAndItems'),
    );
    for (final lane in [devices, items]) {
      expect(lane, contains('isActive: () => mounted'));
      expect(
        lane,
        contains('if (!mounted) return;\n    publishDevicesAndItems();'),
      );
    }
    expect(
      devices,
      contains(
        'await withFmipLock(() async {\n          if (!mounted) return <api.FoundDevice>[];',
      ),
    );
    expect(
      items,
      contains(
        'if (!mounted) return <api.DartBeacon>[];\n        isInClique = inClique;',
      ),
    );
    expect(
      items,
      contains('if (!mounted) return;\n            if (placemark != null)'),
    );
  });
}
