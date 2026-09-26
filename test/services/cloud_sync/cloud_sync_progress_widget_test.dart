import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/settings/pages/profile/cloud_sync_progress_card.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_drain_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_user_copy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'cloud_sync_progress_test.dart' as fixtures;

void main() {
  testWidgets(
    'Profile header can own the title without duplicating it in the card',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CloudSyncProgressCard(
                showTitle: false,
                progress: CloudSyncProgress(),
                isAvailable: () => true,
                onStart: (_) async {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('iCloud Message Sync'), findsNothing);
      expect(find.text('Ready to sync'), findsOneWidget);
      expect(find.text('Start / resume'), findsOneWidget);
    },
  );
  Widget host(
    CloudSyncProgress progress,
    Future<void> Function(CloudSyncSpeed) start, {
    bool available = true,
    double scale = 1,
    bool Function()? isReading,
    bool Function()? availability,
    String? Function()? unavailableMessage,
  }) => MaterialApp(
    theme: ThemeData(fontFamily: 'Inter'),
    debugShowCheckedModeBanner: false,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: CloudSyncProgressCard(
            progress: progress,
            isAvailable: availability ?? () => available,
            isReading: isReading,
            onStart: start,
            unavailableMessage: unavailableMessage,
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'external sync state refreshes without a user tap and cannot start a second run',
    (tester) async {
      final p = CloudSyncProgress();
      var reading = true;
      var starts = 0;
      await tester.pumpWidget(
        host(
          p,
          (_) async {
            starts++;
          },
          isReading: () => reading,
          availability: () => !reading,
        ),
      );
      expect(find.text('Sync is already running'), findsOneWidget);
      expect(find.textContaining('Another sync is finishing'), findsOneWidget);
      expect(find.text('Ready to sync'), findsNothing);
      expect(find.textContaining('restored to your chats'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      reading = false;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Ready to sync'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      expect(starts, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'elapsed display updates while waiting and stops owning a timer on page exit',
    (tester) async {
      var now = DateTime.utc(2026, 9, 15);
      final p = CloudSyncProgress(clock: () => now);
      final done = Completer<CloudSyncSemanticDrainResult>();
      final work = p.start(CloudSyncSpeed.regular, () => done.future);
      await tester.pumpWidget(host(p, (_) async {}));
      expect(find.text('Elapsed 0m 00s'), findsOneWidget);
      now = now.add(const Duration(seconds: 65));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed 1m 05s'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(p.active, isTrue);
      done.complete(fixtures.result());
      await tester.pump();
      await work;
    },
  );

  testWidgets(
    'unavailable relay explains recovery without requesting account reset',
    (tester) async {
      final p = CloudSyncProgress();
      await p.start(CloudSyncSpeed.regular, () async {
        throw StateError('cloud_sync_native_auth_refresh_relay_unavailable');
      });
      await tester.pumpWidget(host(p, (_) async {}));
      expect(
        find.textContaining('Your saved relay is unavailable'),
        findsOneWidget,
      );
      expect(find.textContaining('Fully close and restart'), findsNothing);
      expect(p.restartRequired, isFalse);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('uncertain PCS explains restart and disables resume', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    await p.start(CloudSyncSpeed.regular, () async {
      throw StateError('cloud_sync_v2_pcs_restart_required');
    });
    await tester.pumpWidget(host(p, (_) async => fail('must not retry')));
    expect(find.textContaining('may still be running'), findsOneWidget);
    expect(find.textContaining('Fully close and restart'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Paused'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(host(p, (_) async => fail('must not retry')));
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('normal settings action starts once and survives page closure', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    final done = Completer<CloudSyncSemanticDrainResult>();
    final prepared = Completer<bool>();
    var starts = 0;
    await tester.pumpWidget(
      host(p, (speed) {
        starts++;
        expect(speed, CloudSyncSpeed.regular);
        return p.startPrepared(
          speed,
          validate: () {},
          preparePcs: () => prepared.future,
          readOnlyCatchUp: () => done.future,
        );
      }),
    );
    await tester.ensureVisible(find.text('Start / resume'));
    await tester.tap(find.text('Start / resume'));
    await tester.pump();
    expect(starts, 1);
    expect(find.text('Pause catch-up'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(p.active, isTrue);
    expect(p.pauseRequested, isFalse);
    expect(p.phase, CloudSyncProgressPhase.pcs);
    prepared.complete(true);
    done.complete(fixtures.result());
    await tester.pump();
    expect(p.phase, CloudSyncProgressPhase.remoteHead);
  });

  testWidgets(
    'Turbo requires warning acceptance and does not itself start work',
    (tester) async {
      final p = CloudSyncProgress();
      CloudSyncSpeed? started;
      await tester.pumpWidget(
        host(p, (speed) async {
          started = speed;
        }),
      );
      expect(find.textContaining('Regular leaves more room'), findsOneWidget);
      expect(find.textContaining('Turbo uses larger batches'), findsOneWidget);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.text('Use Turbo sync?'), findsOneWidget);
      expect(find.textContaining('make it hot'), findsOneWidget);
      final warning = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Turbo uses larger chunks'),
      );
      expect(warning, findsOneWidget);
      expect(tester.widget<Text>(warning).data, contains('drain the battery'));
      expect(tester.widget<Text>(warning).data, contains('slow your phone'));
      expect(find.textContaining('instead of 8'), findsNothing);
      expect(started, isNull);
      await tester.tap(find.text('Keep Regular'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use Turbo'));
      await tester.pumpAndSettle();
      expect(started, isNull);
      await tester.ensureVisible(find.text('Start / resume'));
      await tester.tap(find.text('Start / resume'));
      expect(started, CloudSyncSpeed.turbo);
    },
  );

  testWidgets(
    'unavailable rollout cannot start, and narrow large text has no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        host(
          CloudSyncProgress(),
          (_) async => fail('not authorized'),
          available: false,
          scale: 1.6,
        ),
      );
      await tester.ensureVisible(find.text('Start / resume'));
      await tester.tap(find.text('Start / resume'));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('authorized test build'), findsOneWidget);
      expect(find.textContaining('After an app restart'), findsOneWidget);
    },
  );

  testWidgets('renders progress for local visual review', (tester) async {
    final loader = FontLoader('Inter')
      ..addFont(
        rootBundle.load('assets/fonts/Inter-VariableFont_opsz,wght.ttf'),
      );
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final p = CloudSyncProgress();
    final done = Completer<CloudSyncSemanticDrainResult>();
    final work = p.start(CloudSyncSpeed.regular, () => done.future);
    await tester.pump();
    p.activity(CloudSyncProgressPhase.replaying, 'messageManateeZone');
    p.projectionWindow(240, 182);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: boundary, child: host(p, (_) async {})),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Sync details'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('240 row visits'), findsOneWidget);
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('build/sync-progress-review.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
    done.complete(fixtures.result());
    await tester.pump();
    await work;
  });

  testWidgets('auth failure explains device verification and hides the code', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    await p.start(CloudSyncSpeed.regular, () async {
      throw StateError('cloud_sync_native_auth_credentials_rejected');
    });
    await tester.pumpWidget(host(p, (_) async {}));
    expect(find.text('iCloud Message Sync'), findsOneWidget);
    expect(find.text('Sign-in or device check needed'), findsOneWidget);
    expect(find.textContaining('trusted Apple device'), findsOneWidget);
    expect(
      find.textContaining('cloud_sync_native_auth_credentials_rejected'),
      findsNothing,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(
      p.userNotice(readingElsewhere: false).state,
      CloudSyncUserState.needsAuth,
    );
    await tester.tap(find.text('Sync details'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining('cloud_sync_native_auth_credentials_rejected'),
      findsOneWidget,
    );
  });

  testWidgets('offline failure asks for a connection check with resume on', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    await p.start(CloudSyncSpeed.regular, () async {
      throw StateError('network');
    });
    await tester.pumpWidget(host(p, (_) async {}));
    expect(find.text('Connection issue, try again'), findsOneWidget);
    expect(find.textContaining('Check that you are online'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(
      p.userNotice(readingElsewhere: false).state,
      CloudSyncUserState.offlineRetry,
    );
  });

  testWidgets('canceled preparation pauses without an error', (tester) async {
    final p = CloudSyncProgress();
    var ranCatchUp = false;
    final work = p.startPrepared(
      CloudSyncSpeed.regular,
      validate: () {},
      preparePcs: () async => false,
      readOnlyCatchUp: () async {
        ranCatchUp = true;
        return fixtures.result();
      },
    );
    await work;
    expect(ranCatchUp, isFalse);
    expect(p.safeFailure, isNull);
    expect(p.phase, CloudSyncProgressPhase.paused);
    await tester.pumpWidget(host(p, (_) async {}));
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Sync needs attention'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('busy run hides start and locks pause while it finishes', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    final done = Completer<CloudSyncSemanticDrainResult>();
    final work = p.start(CloudSyncSpeed.regular, () => done.future);
    await tester.pumpWidget(host(p, (_) async {}));
    expect(find.text('Start / resume'), findsNothing);
    expect(find.text('Pause catch-up'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .semanticsLabel,
      'Syncing, total size unknown',
    );
    await tester.tap(find.text('Pause catch-up'));
    await tester.pump();
    expect(find.text('Pausing...'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    done.complete(fixtures.result());
    await tester.pump();
    await work;
  });

  testWidgets('parent readiness reason overrides the default checklist', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        CloudSyncProgress(),
        (_) async => fail('not authorized'),
        available: false,
        unavailableMessage: () => 'Sign in with the canary profile first.',
      ),
    );
    expect(find.text('Sign in with the canary profile first.'), findsOneWidget);
    expect(find.textContaining('authorized test build'), findsNothing);
  });

  testWidgets('remote head never claims media is fully downloaded', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    await p.start(CloudSyncSpeed.regular, () async => fixtures.result());
    await tester.pumpWidget(host(p, (_) async {}));
    expect(find.text('Caught up to the newest iCloud change'), findsOneWidget);
    expect(
      find.textContaining('does not mean everything is on the phone yet'),
      findsOneWidget,
    );
    expect(find.textContaining('every photo is downloaded'), findsNothing);
    await tester.tap(find.text('Sync details'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining('does not mean every photo is downloaded'),
      findsOneWidget,
    );
  });

  testWidgets('long error copy fits a narrow large-text screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final p = CloudSyncProgress();
    await p.start(CloudSyncSpeed.regular, () async {
      throw StateError('cloud_sync_native_auth_credentials_rejected');
    });
    await tester.pumpWidget(host(p, (_) async {}, scale: 1.6));
    expect(find.text('Sign-in or device check needed'), findsOneWidget);
    await tester.ensureVisible(find.text('Sync details'));
    await tester.tap(find.text('Sync details'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('settling and restart beat the running-elsewhere headline', (
    tester,
  ) async {
    final settling = CloudSyncProgress();
    await settling.start(CloudSyncSpeed.regular, () async {
      throw StateError('cloud_sync_v2_pcs_preparation_quiescing');
    });
    await tester.pumpWidget(
      host(settling, (_) async {}, isReading: () => true),
    );
    expect(find.text('Sync is still settling'), findsOneWidget);
    expect(find.text('Sync is already running'), findsNothing);

    final restart = CloudSyncProgress();
    await restart.start(CloudSyncSpeed.regular, () async {
      throw StateError('cloud_sync_v2_pcs_restart_required');
    });
    await tester.pumpWidget(host(restart, (_) async {}, isReading: () => true));
    expect(find.text('Restart needed before resuming'), findsOneWidget);
    expect(find.text('Sync is already running'), findsNothing);
  });

  testWidgets('account-change stays generic with the code in details', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    await p.start(CloudSyncSpeed.regular, () async {
      throw StateError('cloud_sync_native_auth_account_changed');
    });
    await tester.pumpWidget(host(p, (_) async {}));
    expect(find.text('Sync needs attention'), findsOneWidget);
    expect(find.text('Sign-in or device check needed'), findsNothing);
    expect(
      find.textContaining('cloud_sync_native_auth_account_changed'),
      findsNothing,
    );
    await tester.tap(find.text('Sync details'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining('cloud_sync_native_auth_account_changed'),
      findsOneWidget,
    );
  });
  testWidgets('blocked idle shows blocked headline without a start invitation', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    await tester.pumpWidget(
      host(
        p,
        (_) async => fail('must not start while blocked'),
        availability: () => false,
        unavailableMessage: () => 'Legacy sync is still finishing.',
      ),
    );
    expect(find.text('Sync is not available right now'), findsOneWidget);
    expect(find.text('Ready to sync'), findsNothing);
    expect(find.text('Legacy sync is still finishing.'), findsOneWidget);
    expect(find.textContaining('Start gets encryption ready'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('paused notice action is suppressed while blocked', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    p.safeFailure = 'cloud_sync_semantic_drain_cancelled';
    await tester.pumpWidget(
      host(p, (_) async => fail('must not start while blocked'), availability: () => false),
    );
    expect(find.text('Tap Start / resume to continue.'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('changed blocker text refreshes while still disabled', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    var reason = 'First blocker.';
    await tester.pumpWidget(
      host(
        p,
        (_) async => fail('must not start while blocked'),
        availability: () => false,
        unavailableMessage: () => reason,
      ),
    );
    expect(find.text('First blocker.'), findsOneWidget);
    reason = 'Second blocker.';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Second blocker.'), findsOneWidget);
    expect(find.text('First blocker.'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
  test('cancelled code maps to real paused state', () {
    final notice = describeCloudSyncUserNotice(
      phase: CloudSyncProgressPhase.idle,
      safeFailure: 'cloud_sync_semantic_drain_cancelled',
      restartRequired: false,
      pauseRequested: false,
      readingElsewhere: false,
      projectionComplete: false,
    );
    expect(notice.state, CloudSyncUserState.paused);
    expect(notice.canStart, isTrue);
  });
  testWidgets('blocked restart keeps its repair instruction', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    p.safeFailure = 'cloud_sync_v2_pcs_restart_required';
    await tester.pumpWidget(
      host(p, (_) async => fail('must not start while blocked'), availability: () => false),
    );
    expect(find.text('Restart needed before resuming'), findsOneWidget);
    expect(find.textContaining('Fully close and restart'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('recovered availability restores ready headline without starting', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    var available = false;
    await tester.pumpWidget(
      host(
        p,
        (_) async => fail('must not start without a tap'),
        availability: () => available,
      ),
    );
    expect(find.text('Sync is not available right now'), findsOneWidget);
    available = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Ready to sync'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}
