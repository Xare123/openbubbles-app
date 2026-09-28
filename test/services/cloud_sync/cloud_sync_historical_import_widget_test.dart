import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/settings/pages/profile/cloud_sync_historical_import_card.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_import_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_producer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_historical_import_controller_test.dart' as fixtures;

final class _NoOwners extends HistoricalOwnershipRegistry {}

void main() {
  late CloudSyncHistoricalImportController controller;
  late bool available;
  late int calls;
  late Future<void> Function() beforeLoad;
  late Future<void> Function() beforeArchive;
  late CloudSyncHistoricalImportPlan plan;

  setUp(() {
    controller = CloudSyncHistoricalImportController();
    available = true;
    calls = 0;
    beforeLoad = () async {};
    beforeArchive = () async {};
    plan = CloudSyncHistoricalImportPlan(
      snapshot: fixtures.historicalImportTestSnapshot(),
      accountLabel: 'test-account@example.com',
      archiveCursors: MemoryHistoricalCursorStore(),
      registry: _NoOwners(),
      stillCurrent: () => true,
      validateIdentity: () async {},
      archive: (request, bytes) async {
        calls++;
        await beforeArchive();
        return (
          source: StagedHistoricalSource(
            key: request.sourceSha256,
            sha256: historicalBytesSha256(bytes),
            byteLength: bytes.length,
            guid: request.guid,
          ),
          disposition: CloudSyncHistoricalArchiveDisposition.confirmedCreate,
        );
      },
    );
  });

  Widget host({double scale = 1, GlobalKey? previewKey}) => MaterialApp(
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
    ),
    debugShowCheckedModeBanner: false,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: RepaintBoundary(
          key: previewKey,
          child: SingleChildScrollView(
            child: CloudSyncHistoricalImportCard(
              controller: controller,
              isAvailable: () => available,
              onPrepare: () => controller.prepare(() async {
                await beforeLoad();
                return plan;
              }),
              onConfirm: controller.confirm,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> review(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Review history'));
    await tester.tap(find.text('Review history'));
    await tester.pumpAndSettle();
  }

  testWidgets('preview names destination and cancel performs no archive', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await review(tester);
    expect(find.text('test-account@example.com'), findsOneWidget);
    expect(find.text('Messages on this device'), findsOneWidget);
    expect(find.textContaining('3 local messages captured'), findsOneWidget);
    expect(calls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(controller.phase, CloudSyncHistoricalImportPhase.idle);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('external source is named before the exact import is confirmed', (
    tester,
  ) async {
    final original = plan;
    plan = CloudSyncHistoricalImportPlan(
      snapshot: original.snapshot,
      accountLabel: original.accountLabel,
      sourceLabel: 'Alpha history',
      archiveCursors: original.archiveCursors,
      registry: original.registry,
      stillCurrent: original.stillCurrent,
      validateIdentity: original.validateIdentity,
      archive: original.archive,
    );
    await tester.pumpWidget(host());
    await review(tester);
    expect(find.text('Alpha history'), findsOneWidget);
    expect(find.text('test-account@example.com'), findsOneWidget);
    expect(calls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'confirmed action reports actual session confirmations, not sync complete',
    (tester) async {
      await tester.pumpWidget(host());
      await review(tester);
      await tester.tap(find.text('Upload history'));
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.text('History scan finished'), findsOneWidget);
      expect(
        find.text('This session: 3 reviewed, 3 confirmed in iCloud.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('does not mean every message was uploaded'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('changed readiness after preview cancels without uploading', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await review(tester);
    available = false;
    await tester.tap(find.text('Upload history'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(controller.phase, CloudSyncHistoricalImportPhase.idle);
    expect(find.textContaining('Sync is busy'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unmount during preparation discards returned consent', (
    tester,
  ) async {
    final gate = Completer<void>();
    beforeLoad = () => gate.future;
    await tester.pumpWidget(host());
    await tester.tap(find.text('Review history'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.pump();
    expect(calls, 0);
    expect(controller.phase, CloudSyncHistoricalImportPhase.idle);
    expect(controller.active, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving Profile does not cancel admitted service work', (
    tester,
  ) async {
    final gate = Completer<void>();
    beforeArchive = () async {
      if (calls == 1) await gate.future;
    };
    await tester.pumpWidget(host());
    await review(tester);
    await tester.tap(find.text('Upload history'));
    await tester.pump();
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.pump();
    expect(calls, 3);
    expect(controller.scanComplete, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pause waits for the current row then offers review/resume', (
    tester,
  ) async {
    final gate = Completer<void>();
    beforeArchive = () async {
      if (calls == 1) await gate.future;
    };
    await tester.pumpWidget(host());
    await review(tester);
    await tester.tap(find.text('Upload history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Pause history upload'));
    await tester.tap(find.text('Pause history upload'));
    await tester.pump();
    expect(calls, 1);
    expect(controller.phase, CloudSyncHistoricalImportPhase.pausing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('History upload paused'), findsOneWidget);
    expect(find.text('Review / resume history'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('narrow large-text status remains scrollable without overflow', (
    tester,
  ) async {
    // The default widget-test Ahem face renders solid rectangles. Load the
    // shipped font/icons so this review also exercises realistic text widths.
    final font = FontLoader('Inter')
      ..addFont(
        rootBundle.load('assets/fonts/Inter-VariableFont_opsz,wght.ttf'),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    controller.phase = CloudSyncHistoricalImportPhase.paused;
    controller.sourceRows = 100;
    controller.assessed = 24;
    controller.confirmedCreates = 8;
    controller.readerHandoffs = 12;
    controller.retainedConflicts = 2;
    controller.ineligibleByReason = const {'media': 2};
    final key = GlobalKey();
    await tester.pumpWidget(host(scale: 1.8, previewKey: key));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Review / resume history'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Optional synthetic-only review render. CI does not need to write a PNG.
    final directory = Platform.environment['OPENBUBBLES_UI_PREVIEW_DIR'];
    if (directory != null) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$directory/historical-import-large-text.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('native error content is never shown in the card', (
    tester,
  ) async {
    beforeLoad = () async {
      throw StateError('private body and credential');
    };
    await tester.pumpWidget(host());
    await review(tester);
    expect(find.textContaining('private body'), findsNothing);
    expect(find.textContaining('stopped safely'), findsOneWidget);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
