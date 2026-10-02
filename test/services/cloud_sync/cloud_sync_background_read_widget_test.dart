import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/settings/pages/profile/cloud_sync_background_read_card.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_background_read_preference.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final identity = CloudSyncBackgroundReadIdentity(
    scopeHash: 'a' * 64,
    protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
  );
  CloudSyncBackgroundReadPreference preference(bool enabled) =>
      CloudSyncBackgroundReadPreference(identity: identity, enabled: enabled);
  late int writes;
  late Future<CloudSyncBackgroundReadPreference> Function() load;
  late Future<CloudSyncBackgroundReadPreference> Function(
    CloudSyncBackgroundReadPreference,
    bool,
  )
  save;

  setUp(() {
    writes = 0;
    load = () async => preference(false);
    save = (expected, enabled) async {
      writes++;
      expect(expected.identity.sameIdentity(identity), isTrue);
      return preference(enabled);
    };
  });

  Widget host({double scale = 1}) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
    ),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: CloudSyncBackgroundReadCard(onLoad: load, onChanged: save),
        ),
      ),
    ),
  );

  testWidgets('opening Profile loads a preference without enabling anything', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(writes, 0);
    expect(find.textContaining('does not enable uploads'), findsOneWidget);
    expect(
      find.textContaining('A batch already running may finish'),
      findsOneWidget,
    );
  });

  testWidgets('one explicit toggle saves the bound preference', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('failed load is not rendered as a confirmed off choice', (
    tester,
  ) async {
    load = () async => throw StateError('secret-detail');
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(find.textContaining('settings are unavailable'), findsOneWidget);
    expect(find.textContaining('secret-detail'), findsNothing);
    expect(find.text('Reload setting'), findsOneWidget);
    expect(writes, 0);
  });

  testWidgets(
    'failure to save requires a fresh read and never shows raw errors',
    (tester) async {
      save = (_, _) async => throw StateError('private-scope-value');
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(find.textContaining('could not be confirmed'), findsOneWidget);
      expect(find.textContaining('private-scope-value'), findsNothing);
      await tester.tap(find.text('Reload setting'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
      expect(writes, 0);
    },
  );

  testWidgets(
    'saved choice with rejected scheduling shows the recovery action',
    (tester) async {
      save = (_, _) async =>
          throw StateError('cloud_sync_background_preference_schedule_pending');
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.textContaining('Your choice was saved'), findsOneWidget);
      expect(
        find.textContaining('Tap Start / resume to try again'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'cloud_sync_background_preference_schedule_pending',
        ),
        findsNothing,
      );
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    },
  );

  testWidgets(
    'notification setup pending does not claim local scheduling failed',
    (tester) async {
      save = (_, _) async => throw StateError(
        'cloud_sync_background_preference_notifications_pending',
      );
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.textContaining('local sync is scheduled'), findsOneWidget);
      expect(find.textContaining('setup will retry'), findsOneWidget);
      expect(find.textContaining('could not be scheduled'), findsNothing);
      expect(find.textContaining('notifications_pending'), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    },
  );

  testWidgets(
    'busy save disables a second request and survives navigation away',
    (tester) async {
      final result = Completer<CloudSyncBackgroundReadPreference>();
      save = (_, _) {
        writes++;
        return result.future;
      };
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(writes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      result.complete(preference(true));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text in a narrow Profile remains legible without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(host(scale: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Background history sync'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Background history sync'), findsWidgets);
      semantics.dispose();
    },
  );

  testWidgets('renders the account background preference for local review', (
    tester,
  ) async {
    final font = FontLoader('Inter')
      ..addFont(
        rootBundle.load('assets/fonts/Inter-VariableFont_opsz,wght.ttf'),
      );
    await font.load();
    tester.view.physicalSize = const Size(390, 550);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: host()));
    await tester.pumpAndSettle();
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('build/cloud-sync-background-preference-review.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
    expect(writes, 0);
  });
}
