import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/layouts/settings/pages/profile/cloud_sync_automatic_archive_card.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncAutomaticArchiveIdentity _identity({int epoch = 3}) =>
    CloudSyncAutomaticArchiveIdentity(
      accountFingerprint: 'A' * 43,
      protectedStoreIdentity: 'obcs2.store.${'S' * 43}',
      writerEpoch: epoch,
    );

CloudSyncAutomaticArchivePreference _preference({
  bool enabled = false,
  int epoch = 3,
}) => CloudSyncAutomaticArchivePreference(
  identity: _identity(epoch: epoch),
  storedValue: enabled
      ? jsonEncode([1, 'queued-and-future-local-sends', epoch, 'f' * 32])
      : jsonEncode([1, 'off']),
);

void main() {
  late int writes;
  late bool? lastEnabled;
  late bool? lastAcknowledged;
  late Future<CloudSyncAutomaticArchivePreference> Function() load;
  late Future<CloudSyncAutomaticArchivePreference> Function(
    CloudSyncAutomaticArchivePreference,
    bool, {
    required bool acknowledgeQueuedUploads,
  })
  save;

  setUp(() {
    writes = 0;
    lastEnabled = null;
    lastAcknowledged = null;
    load = () async => _preference();
    save = (expected, enabled, {required bool acknowledgeQueuedUploads}) async {
      writes++;
      lastEnabled = enabled;
      lastAcknowledged = acknowledgeQueuedUploads;
      return _preference(enabled: enabled);
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
          child: CloudSyncAutomaticArchiveCard(onLoad: load, onChanged: save),
        ),
      ),
    ),
  );

  Future<void> openEnableDialog(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
  }

  testWidgets('opening loads a preference without side effects', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(writes, 0);
    expect(find.text('Archive sent messages to iCloud'), findsWidgets);
    expect(
      find.textContaining('A batch already running may finish'),
      findsOneWidget,
    );
  });

  testWidgets('cancel causes zero callbacks and keeps the switch off', (
    tester,
  ) async {
    await openEnableDialog(tester);
    expect(find.text('Enable automatic archival?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('repeated enable callbacks open only one confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final onChanged = tester.widget<Switch>(find.byType(Switch)).onChanged!;
    onChanged(true);
    onChanged(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(writes, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(writes, 0);
  });

  testWidgets('enable requires the unchecked acknowledgment first', (
    tester,
  ) async {
    await openEnableDialog(tester);
    final button = find.widgetWithText(
      FilledButton,
      'Enable automatic archival',
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.tap(button);
    await tester.pump();
    expect(writes, 0);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(lastEnabled, isTrue);
    expect(lastAcknowledged, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('disabling needs no dialog and passes false acknowledgment', (
    tester,
  ) async {
    load = () async => _preference(enabled: true);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(lastEnabled, isFalse);
    expect(lastAcknowledged, isFalse);
    expect(find.text('Enable automatic archival?'), findsNothing);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('busy save disables a second request', (tester) async {
    final result = Completer<CloudSyncAutomaticArchivePreference>();
    save = (_, _, {required bool acknowledgeQueuedUploads}) {
      writes++;
      return result.future;
    };
    await openEnableDialog(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Enable automatic archival'));
    await tester.pump();
    expect(writes, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    result.complete(_preference(enabled: true));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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
      save = (_, _, {required bool acknowledgeQueuedUploads}) async {
        writes++;
        throw StateError('private-scope-value');
      };
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Enable automatic archival'),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(find.textContaining('could not be confirmed'), findsOneWidget);
      expect(find.textContaining('private-scope-value'), findsNothing);
      await tester.tap(find.text('Reload setting'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
      expect(writes, 1);
    },
  );

  testWidgets('navigation away during save is safe', (tester) async {
    final result = Completer<CloudSyncAutomaticArchivePreference>();
    save = (_, _, {required bool acknowledgeQueuedUploads}) {
      writes++;
      return result.future;
    };
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Enable automatic archival'),
    );
    await tester.pump();
    expect(
      writes,
      1,
      reason: 'the asynchronous save must actually have started',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    result.complete(_preference(enabled: true));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow large text stays legible without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(scale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Archive sent messages to iCloud'), findsOneWidget);
    tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
