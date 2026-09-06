import 'dart:async';

import 'package:bluebubbles/services/rustpush/icloud_maintenance.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class Fixture {
  Fixture({ICloudMaintenance? maintenance})
    : maintenance = maintenance ?? ICloudMaintenance();
  final ICloudMaintenance maintenance;
  final stateIdentity = Object();
  bool current = true;
  bool enabled = true;
  bool cached = true;
  int passwords = 0;
  int cliques = 0;
  int clouds = 0;
  int publications = 0;
  final errors = <Object>[];
  Completer<void>? passwordPending;
  Completer<bool>? cliquePending;
  Completer<void>? cloudPending;
  bool trusted = true;
  bool reportThrows = false;

  Future<void> run({bool initial = true}) => maintenance.run(
    stateIdentity: stateIdentity,
    stillCurrent: () => current,
    syncPasswords: () async {
      passwords++;
      await passwordPending?.future;
    },
    readClique: !initial
        ? null
        : () async {
            cliques++;
            return cliquePending == null
                ? trusted
                : await cliquePending!.future;
          },
    publishClique: (value) {
      publications++;
      cached = value;
    },
    syncEnabled: () => enabled,
    syncCloudKit: () async {
      clouds++;
      await cloudPending?.future;
    },
    report: (_, error, stack) {
      errors.add(error);
      if (reportThrows) throw StateError('synthetic reporter failure');
    },
  );
}

void main() {
  test('A pending then B startup runs B once only after A settles', () {
    fakeAsync((clock) {
      final shared = ICloudMaintenance();
      final a = Fixture(maintenance: shared)..cliquePending = Completer<bool>();
      final b = Fixture(maintenance: shared);
      final active = a.run();
      clock.flushMicrotasks();
      expect(shared.cliqueRefresh, ICloudCliqueRefresh.pending);
      a.current = false;
      final queued = b.run();
      expect(identical(active, queued), isFalse);
      expect(identical(b.run(), queued), isTrue);
      expect(identical(b.run(initial: false), queued), isTrue);
      expect(shared.cliqueRefresh, ICloudCliqueRefresh.unknown);
      clock.elapse(const Duration(seconds: 30));
      expect(b.passwords, 0);
      expect(b.cliques, 0);
      var finished = false;
      queued.then((_) => finished = true);
      a.cliquePending!.complete(false);
      clock.flushMicrotasks();
      expect(a.publications, 0);
      expect(a.clouds, 0);
      expect(b.passwords, 1);
      expect(b.cliques, 1);
      expect(b.publications, 1);
      expect(b.cached, isTrue);
      expect(finished, isTrue);
      expect(shared.cliqueRefresh, ICloudCliqueRefresh.trusted);
    });
  });

  test(
    'latest pending state replaces older queued state and stale triggers do not replace it',
    () {
      fakeAsync((clock) {
        final shared = ICloudMaintenance();
        final a = Fixture(maintenance: shared)
          ..passwordPending = Completer<void>();
        final b = Fixture(maintenance: shared);
        final c = Fixture(maintenance: shared);
        a.run();
        a.current = false;
        var superseded = false;
        b.run().then((_) => superseded = true);
        b.current = false;
        final latest = c.run();
        b.run();
        clock.flushMicrotasks();
        expect(superseded, isTrue);
        expect(identical(c.run(), latest), isTrue);
        expect(c.passwords, 0);
        a.passwordPending!.complete();
        clock.flushMicrotasks();
        expect(b.passwords, 0);
        expect(b.publications, 0);
        expect(c.passwords, 1);
        expect(c.publications, 1);
      });
    },
  );

  test('new password phase resets prior successful clique status', () {
    fakeAsync((clock) {
      final shared = ICloudMaintenance();
      final a = Fixture(maintenance: shared);
      a.run();
      clock.flushMicrotasks();
      expect(shared.cliqueRefresh, ICloudCliqueRefresh.trusted);
      a.current = false;
      final b = Fixture(maintenance: shared)
        ..passwordPending = Completer<void>();
      b.run();
      expect(shared.cliqueRefresh, ICloudCliqueRefresh.unknown);
      clock.elapse(const Duration(seconds: 30));
      expect(shared.cliqueRefresh, ICloudCliqueRefresh.unknown);
      b.passwordPending!.complete();
      clock.flushMicrotasks();
      expect(b.publications, 0);
    });
  });

  test(
    'throwing reports neither escape timer nor release pending ownership',
    () {
      fakeAsync((clock) {
        final f = Fixture()
          ..reportThrows = true
          ..passwordPending = Completer<void>();
        final pending = f.run();
        clock.elapse(const Duration(seconds: 30));
        expect(identical(f.run(), pending), isTrue);
        f.passwordPending!.completeError(
          StateError('synthetic native failure'),
        );
        clock.flushMicrotasks();
        expect(f.errors, hasLength(2));
        expect(f.cliques, 0);
        f.passwordPending = null;
        f.run();
        clock.flushMicrotasks();
        expect(f.publications, 1);
      });
    },
  );

  test(
    'password timeout retains startup/recurring singleflight until settlement',
    () {
      fakeAsync((clock) {
        final f = Fixture()..passwordPending = Completer<void>();
        final original = f.run();
        var settled = false;
        original.then((_) => settled = true);
        clock.elapse(const Duration(seconds: 30));
        expect(f.errors.single, isA<TimeoutException>());
        expect(settled, isFalse);
        expect(identical(f.run(initial: false), original), isTrue);
        expect(f.passwords, 1);
        expect(f.cliques, 0);
        expect(f.clouds, 0);
        f.passwordPending!.complete();
        clock.flushMicrotasks();
        expect(settled, isTrue);
        expect(f.cliques, 0);
        f.passwordPending = null;
        f.run(initial: false);
        clock.flushMicrotasks();
        expect(f.passwords, 2);
        expect(f.clouds, 1);
      });
    },
  );

  test(
    'clique timeout is unknown, late false never overwrites cached success',
    () {
      fakeAsync((clock) {
        final f = Fixture()..cliquePending = Completer<bool>();
        final original = f.run();
        clock.flushMicrotasks();
        expect(f.maintenance.cliqueRefresh, ICloudCliqueRefresh.pending);
        clock.elapse(const Duration(seconds: 30));
        expect(f.maintenance.cliqueRefresh, ICloudCliqueRefresh.unknown);
        expect(f.cached, isTrue);
        expect(identical(f.run(initial: false), original), isTrue);
        f.cliquePending!.complete(false);
        clock.flushMicrotasks();
        expect(f.publications, 0);
        expect(f.cached, isTrue);
        expect(f.clouds, 0);
      });
    },
  );

  test(
    'late native error is observed and releases ownership without follow-on work',
    () {
      fakeAsync((clock) {
        final f = Fixture()..passwordPending = Completer<void>();
        f.run();
        clock.elapse(const Duration(seconds: 30));
        f.passwordPending!.completeError(StateError('synthetic'));
        clock.flushMicrotasks();
        expect(f.errors, hasLength(2));
        expect(f.cliques, 0);
        f.passwordPending = null;
        f.run();
        clock.flushMicrotasks();
        expect(f.passwords, 2);
        expect(f.clouds, 1);
      });
    },
  );

  test('state change during clique await prevents publication and sync', () {
    fakeAsync((clock) {
      final f = Fixture()..cliquePending = Completer<bool>();
      f.run();
      clock.flushMicrotasks();
      f.current = false;
      f.cliquePending!.complete(false);
      clock.flushMicrotasks();
      expect(f.publications, 0);
      expect(f.cached, isTrue);
      expect(f.maintenance.cliqueRefresh, ICloudCliqueRefresh.unknown);
      expect(f.clouds, 0);
    });
  });

  test('state change during password await prevents clique call', () {
    fakeAsync((clock) {
      final f = Fixture()..passwordPending = Completer<void>();
      f.run();
      f.current = false;
      f.passwordPending!.complete();
      clock.flushMicrotasks();
      expect(f.cliques, 0);
      expect(f.clouds, 0);
    });
  });

  test('timely false is published, errors are unknown rather than false', () {
    fakeAsync((clock) {
      final f = Fixture()..trusted = false;
      f.run();
      clock.flushMicrotasks();
      expect(f.cached, isFalse);
      expect(f.maintenance.cliqueRefresh, ICloudCliqueRefresh.notTrusted);
      f.cached = true;
      f.cliquePending = Completer<bool>();
      f.run();
      clock.flushMicrotasks();
      f.cliquePending!.completeError(StateError('synthetic'));
      clock.flushMicrotasks();
      expect(f.cached, isTrue);
      expect(f.maintenance.cliqueRefresh, ICloudCliqueRefresh.unknown);
      expect(f.clouds, 1);
    });
  });

  test(
    'recurring run excludes startup and retains ownership through CloudKit timeout',
    () {
      fakeAsync((clock) {
        final f = Fixture()..cloudPending = Completer<void>();
        final original = f.run(initial: false);
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 30));
        expect(identical(f.run(), original), isTrue);
        expect(f.cliques, 0);
        expect(f.passwords, 1);
        f.cloudPending!.complete();
        clock.flushMicrotasks();
        f.cloudPending = null;
        f.run();
        clock.flushMicrotasks();
        expect(f.cliques, 1);
        expect(f.clouds, 2);
      });
    },
  );

  test('disabled sync still refreshes clique but does not sync CloudKit', () {
    fakeAsync((clock) {
      final f = Fixture()..enabled = false;
      f.run();
      clock.flushMicrotasks();
      expect(f.publications, 1);
      expect(f.maintenance.cliqueRefresh, ICloudCliqueRefresh.trusted);
      expect(f.clouds, 0);
      expect(clock.pendingTimers, isEmpty);
    });
  });
}
