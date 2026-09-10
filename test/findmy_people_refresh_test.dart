import 'dart:async';

import 'package:bluebubbles/app/layouts/findmy/findmy_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'disposal skips queued fetch and active-result projection/publication',
    () async {
      final state = FindMyPeopleRefreshState<String, String>(['last-good']);
      final started = Completer<void>();
      final pending = Completer<Iterable<String>>();
      var active = true;
      var queuedCalls = 0;
      var projections = 0;
      var publications = 0;
      var summaries = 0;
      Future<bool> request(Future<Iterable<String>> Function() fetch) =>
          state.refreshAndPublish(
            fetch: fetch,
            project: (rows) {
              projections++;
              return rows.toList();
            },
            publish: () {
              publications++;
            },
            isActive: () => active,
            onSuccess: (_, __) {
              summaries++;
            },
            force: true,
          );
      final poll = request(() {
        started.complete();
        return pending.future;
      });
      await started.future;
      final selection = request(() async {
        queuedCalls++;
        return ['selected'];
      });
      active = false;
      pending.complete(['poll']);
      expect(await poll, isFalse);
      expect(await selection, isFalse);
      expect(queuedCalls, 0);
      expect(projections, 0);
      expect(publications, 0);
      expect(summaries, 0);
      expect(state.value, ['last-good']);
      expect(state.lastSuccessAt, isNull);
      expect(state.error, isNull);
    },
  );

  test(
    'diagnostics run once per actual result/failure, never skipped polls',
    () async {
      final state = FindMyPeopleRefreshState<String, String>([]);
      final summaries = <String>[];
      Future<bool> request({bool fail = false, bool projectionFail = false}) =>
          state.refreshAndPublish(
            fetch: () async {
              if (fail) throw StateError('must-not-log-this-body');
              return ['synthetic'];
            },
            project: (rows) {
              if (projectionFail) throw StateError('must-not-log-this-body');
              return rows.toList();
            },
            publish: () {},
            onSuccess: (_, __) => summaries.add('success'),
            onFailure: (stage, error) =>
                summaries.add('$stage:${error.runtimeType}'),
          );
      expect(await request(), isTrue);
      expect(await request(projectionFail: true), isFalse);
      expect(await request(), isFalse);
      expect(summaries, ['success', 'projection:StateError']);
      state.retryAfter = null;
      expect(await request(fail: true), isFalse);
      expect(summaries, [
        'success',
        'projection:StateError',
        'fetch:StateError',
      ]);
    },
  );

  test(
    'People summary contains only aggregate fields and selection booleans',
    () {
      expect(
        findMyPeopleSummary(
          selection: true,
          roster: 3,
          nativeLocations: 2,
          projectedLocations: 1,
          locating: 1,
          selectedPresent: true,
          selectedHasLocation: false,
        ),
        'Find My People source=selection roster=3 native_locations=2 '
        'projected_valid_locations=1 locating=1 selected_present=true selected_has_location=false',
      );
      expect(
        findMyPeopleSummary(
          selection: false,
          roster: 0,
          nativeLocations: 0,
          projectedLocations: 0,
          locating: 0,
        ),
        'Find My People source=poll roster=0 native_locations=0 '
        'projected_valid_locations=0 locating=0',
      );
    },
  );

  test(
    'popup echoes and repeated hide events do not repeat selection intent',
    () {
      final intent = FindMySelectionIntent();
      // Manual/default selection records intent before awaiting native work.
      intent.selected = 'synthetic-friend';
      expect(intent.acceptPopup('synthetic-friend'), isFalse);
      expect(intent.acceptPopup('synthetic-friend'), isFalse);
      expect(intent.acceptPopup('synthetic-other'), isTrue);
      expect(intent.acceptPopup('synthetic-other'), isFalse);
      expect(intent.acceptPopup(null), isTrue);
      expect(intent.acceptPopup(null), isFalse);
    },
  );

  group('serialized People projection and publication', () {
    late FindMyPeopleRefreshState<String, String> state;
    late List<List<String>> publications;

    setUp(() {
      state = FindMyPeopleRefreshState(['last-good']);
      publications = [];
    });

    Future<bool> request(
      Future<Iterable<String>> Function() fetch, {
      bool force = false,
    }) {
      return state.refreshAndPublish(
        fetch: fetch,
        project: (rows) => rows.map((row) => 'projected-$row').toList(),
        publish: () => publications.add(List.of(state.value)),
        force: force,
      );
    }

    test(
      'selection result is projected, cached and published before completion',
      () async {
        expect(await request(() async => ['selected'], force: true), isTrue);
        expect(state.value, ['projected-selected']);
        expect(publications, [
          ['projected-selected'],
        ]);
        expect(state.error, isNull);
        expect(state.lastSuccessAt, isNotNull);
      },
    );

    test(
      'failed selection preserves cache and freshness; skipped poll is not success',
      () async {
        await request(() async => ['poll']);
        final lastSuccess = state.lastSuccessAt;
        final failure = StateError('synthetic selection failure');
        expect(await request(() async => throw failure, force: true), isFalse);
        expect(state.value, ['projected-poll']);
        expect(state.lastSuccessAt, lastSuccess);
        expect(state.error, same(failure));
        expect(publications.last, ['projected-poll']);
        var called = false;
        expect(
          await request(() async {
            called = true;
            return ['wrong'];
          }),
          isFalse,
        );
        expect(called, isFalse);
        expect(state.error, same(failure));
        expect(await request(() async => ['recovered'], force: true), isTrue);
        expect(state.error, isNull);
        expect(state.retryAfter, isNull);
        expect(publications.last, ['projected-recovered']);
      },
    );

    test(
      'active poll, queued selection and later poll execute and publish FIFO',
      () async {
        final pollResult = Completer<Iterable<String>>();
        final pollStarted = Completer<void>();
        final selectionResult = Completer<Iterable<String>>();
        final selectionStarted = Completer<void>();
        final calls = <String>[];
        final poll = request(() {
          calls.add('poll');
          pollStarted.complete();
          return pollResult.future;
        });
        await pollStarted.future;
        final selection = request(() {
          calls.add('selection');
          selectionStarted.complete();
          return selectionResult.future;
        }, force: true);
        final laterPoll = request(() async {
          calls.add('later-poll');
          return ['later'];
        });
        expect(calls, ['poll']);
        pollResult.complete(['poll']);
        expect(await poll, isTrue);
        await selectionStarted.future;
        expect(calls, ['poll', 'selection']);
        expect(publications, [
          ['projected-poll'],
        ]);
        selectionResult.complete(['selected']);
        expect(await selection, isTrue);
        expect(await laterPoll, isTrue);
        expect(calls, ['poll', 'selection', 'later-poll']);
        expect(publications, [
          ['projected-poll'],
          ['projected-selected'],
          ['projected-later'],
        ]);
      },
    );

    test(
      'selection queued behind failed poll bypasses backoff and clears error',
      () async {
        final pending = Completer<Iterable<String>>();
        final poll = request(() => pending.future);
        final selection = request(() async => ['selected'], force: true);
        pending.completeError(StateError('synthetic poll failure'));
        expect(await poll, isFalse);
        expect(await selection, isTrue);
        expect(publications, [
          ['last-good'],
          ['projected-selected'],
        ]);
        expect(state.error, isNull);
      },
    );

    test(
      'default-style follow-up after poll can await selection without deadlock',
      () async {
        Future<void> pollThenSelect() async {
          if (await request(() async => ['poll'])) {
            expect(
              await request(() async => ['selected'], force: true),
              isTrue,
            );
          }
        }

        await pollThenSelect().timeout(const Duration(seconds: 2));
        expect(publications, [
          ['projected-poll'],
          ['projected-selected'],
        ]);
      },
    );

    test(
      'projection failure preserves last-good and does not poison queue',
      () async {
        expect(
          await state.refreshAndPublish(
            fetch: () async => ['bad'],
            project: (_) => throw StateError('synthetic projection failure'),
            publish: () => publications.add(List.of(state.value)),
          ),
          isFalse,
        );
        expect(state.value, ['last-good']);
        expect(state.lastSuccessAt, isNull);
        expect(state.error, isNotNull);
        expect(await request(() async => ['selected'], force: true), isTrue);
        expect(publications.last, ['projected-selected']);
      },
    );
  });

  group('People coordinate classification', () {
    final cases = <(double?, double?, bool)>[
      (12, 34, true), (0, 34, true), (12, 0, true),
      (-90, -180, true), (90, 180, true),
      (0, 0, false), // Explicit legacy unknown-location sentinel.
      (null, null, false), (null, 34, false), (12, null, false),
      (double.nan, 34, false), (12, double.nan, false),
      (double.infinity, 34, false), (12, double.negativeInfinity, false),
      (91, 34, false), (12, 181, false), (-91, 34, false), (12, -181, false),
    ];
    test(
      'finite, in-range pairs accept either zero axis but not the sentinel',
      () {
        for (final entry in cases) {
          expect(hasFindMyLocation(entry.$1, entry.$2), entry.$3);
        }
      },
    );
    test('complementary buckets preserve every row exactly once', () {
      final withLocation = cases
          .where((e) => hasFindMyLocation(e.$1, e.$2))
          .toList();
      final withoutLocation = cases
          .where((e) => !hasFindMyLocation(e.$1, e.$2))
          .toList();
      expect(withLocation.length + withoutLocation.length, cases.length);
      expect(withLocation.every((e) => e.$3), isTrue);
      expect(withoutLocation.every((e) => !e.$3), isTrue);
    });
  });
}
