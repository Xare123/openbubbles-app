import 'dart:async';

import 'package:bluebubbles/app/layouts/findmy/findmy_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final failed in ['People', 'Devices', 'Items']) {
    test(
      '$failed failure leaves other sections independently usable',
      () async {
        final states = {
          for (final name in ['People', 'Devices', 'Items'])
            name: FindMyRefreshState<List<String>>(['old-$name']),
        };
        final now = DateTime.utc(2026, 9, 5);
        await Future.wait(
          states.entries.map(
            (entry) => entry.value.refresh(() async {
              if (entry.key == failed) throw StateError('synthetic failure');
              return ['new-${entry.key}'];
            }, clock: () => now),
          ),
        );
        for (final entry in states.entries) {
          expect(entry.value.value, [
            entry.key == failed ? 'old-${entry.key}' : 'new-${entry.key}',
          ]);
          expect(entry.value.error != null, entry.key == failed);
          expect(entry.value.lastSuccessAt, entry.key == failed ? null : now);
        }
      },
    );
  }

  test(
    'a waiting People fetch does not prevent Devices and Items publishing',
    () async {
      final pending = Completer<List<String>>();
      final people = FindMyRefreshState<List<String>>([]);
      final devices = FindMyRefreshState<List<String>>([]);
      final items = FindMyRefreshState<List<String>>([]);
      final peopleRequest = people.refresh(() => pending.future);
      await Future.wait([
        devices.refresh(() async => ['cloud-device']),
        items.refresh(() async => ['item']),
      ]);
      expect(people.loading, isTrue);
      expect(devices.value, ['cloud-device']);
      expect(items.value, ['item']);
      pending.completeError(StateError('synthetic failure'));
      await peopleRequest;
    },
  );

  test('failed item refresh keeps last-good cache and freshness', () async {
    var now = DateTime.utc(2026, 9, 5);
    final items = FindMyRefreshState<List<String>>([]);
    await items.refresh(() async => ['last-good'], clock: () => now);
    final lastSuccess = items.lastSuccessAt;
    now = now.add(const Duration(minutes: 4));
    expect(
      await items.refresh(
        () async => throw StateError('synthetic failure'),
        clock: () => now,
      ),
      isFalse,
    );
    expect(items.value, ['last-good']);
    expect(items.lastSuccessAt, lastSuccess);
    expect(items.error, isNotNull);
    expect(
      await items.refresh(
        () async => ['recovered'],
        force: true,
        clock: () => now,
      ),
      isTrue,
    );
    expect(items.value, ['recovered']);
    expect(items.lastSuccessAt, now);
    expect(items.error, isNull);
  });

  test(
    'failed initial fetch is not held for the successful three-minute cache TTL',
    () async {
      var now = DateTime.utc(2026, 9, 5);
      final items = FindMyRefreshState<List<String>>([]);
      await items.refresh(
        () async => throw StateError('synthetic failure'),
        clock: () => now,
      );
      expect(items.lastSuccessAt, isNull);
      now = now.add(const Duration(minutes: 1));
      expect(
        await items.refresh(
          () async => ['item'],
          maxAge: const Duration(minutes: 3),
          clock: () => now,
        ),
        isTrue,
      );
      expect(items.value, ['item']);
    },
  );

  test(
    'successful empty response clears old cache and advances freshness',
    () async {
      final now = DateTime.utc(2026, 9, 5);
      final items = FindMyRefreshState<List<String>>(['old']);
      expect(await items.refresh(() async => [], clock: () => now), isTrue);
      expect(items.value, isEmpty);
      expect(items.lastSuccessAt, now);
    },
  );

  test(
    'retry backoff and success TTL skip network calls but force bypasses both',
    () async {
      var calls = 0;
      final now = DateTime.utc(2026, 9, 5);
      final items = FindMyRefreshState<List<String>>([]);
      await items.refresh(
        () async => throw StateError('synthetic failure'),
        clock: () => now,
      );
      Future<List<String>> fetch() async {
        calls++;
        return ['new'];
      }

      expect(await items.refresh(fetch, clock: () => now), isFalse);
      expect(calls, 0);
      expect(await items.refresh(fetch, force: true, clock: () => now), isTrue);
      expect(
        await items.refresh(
          fetch,
          maxAge: const Duration(minutes: 3),
          clock: () => now,
        ),
        isFalse,
      );
      expect(calls, 1);
    },
  );

  test('overlapping refreshes cannot replace an active request', () async {
    final pending = Completer<List<String>>();
    final items = FindMyRefreshState<List<String>>([]);
    final first = items.refresh(() => pending.future);
    expect(await items.refresh(() async => ['wrong'], force: true), isFalse);
    pending.complete(['expected']);
    await first;
    expect(items.value, ['expected']);
  });

  test(
    'failure backoff takes precedence over an otherwise fresh successful cache',
    () async {
      var now = DateTime.utc(2026, 9, 5);
      final items = FindMyRefreshState<List<String>>([]);
      await items.refresh(() async => ['old'], clock: () => now);
      await items.refresh(
        () async => throw StateError('synthetic failure'),
        force: true,
        clock: () => now,
      );
      now = now.add(const Duration(minutes: 1));
      expect(
        await items.refresh(
          () async => ['new'],
          maxAge: const Duration(minutes: 3),
          clock: () => now,
        ),
        isTrue,
      );
      expect(items.value, ['new']);
      expect(items.error, isNull);
    },
  );

  test(
    'empty handles retain known person, skip unknown, and preserve valid rows',
    () {
      final records = [
        (id: 'known', handles: <String>[]),
        (id: 'unknown', handles: <String>[]),
        (id: 'blank', handles: [' ', '']),
        (id: 'valid', handles: [' ', 'synthetic-handle']),
      ];
      final result = projectFindMyPeople(
        records,
        handles: (record) => record.handles,
        lastGood: (record) => record.id == 'known' ? 'last-good-person' : null,
        project: (record, address) => '${record.id}:$address',
      );
      expect(result, ['last-good-person', 'valid:synthetic-handle']);
    },
  );
}
