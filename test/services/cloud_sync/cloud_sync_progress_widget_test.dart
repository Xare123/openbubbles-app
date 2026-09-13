import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/settings/pages/profile/cloud_sync_progress_card.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_drain_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'cloud_sync_progress_test.dart' as fixtures;

void main() {
  Widget host(
    CloudSyncProgress progress,
    Future<void> Function(CloudSyncSpeed) start, {
    bool available = true,
    double scale = 1,
  }) => MaterialApp(
    theme: ThemeData(fontFamily: 'Inter'),
    debugShowCheckedModeBanner: false,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: CloudSyncProgressCard(
            progress: progress,
            isAvailable: () => available,
            onStart: start,
          ),
        ),
      ),
    ),
  );

  testWidgets('uncertain PCS explains restart and disables resume', (
    tester,
  ) async {
    final p = CloudSyncProgress();
    await p.start(CloudSyncSpeed.regular, () async {
      throw StateError('cloud_sync_v2_pcs_restart_required');
    });
    await tester.pumpWidget(host(p, (_) async => fail('must not retry')));
    expect(
      find.textContaining('Native work may still be running'),
      findsOneWidget,
    );
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
      expect(
        find.textContaining('Regular is the default: smaller chunks'),
        findsOneWidget,
      );
      expect(
        find.textContaining('more frequent opportunities for other work'),
        findsOneWidget,
      );
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
      expect(find.textContaining('Developer Mode'), findsOneWidget);
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
}
