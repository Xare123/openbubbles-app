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
      ownershipEpoch: epoch,
    );

CloudSyncAutomaticArchivePreference _preference({
  bool enabled = false,
  int epoch = 3,
  bool includeReceived = false,
}) => CloudSyncAutomaticArchivePreference(
  identity: _identity(epoch: epoch),
  storedValue: enabled
      ? jsonEncode([
          includeReceived ? 2 : 1,
          includeReceived
              ? 'queued-and-future-local-sends-and-receives'
              : 'queued-and-future-local-sends',
          epoch,
          'f' * 32,
        ])
      : jsonEncode([1, 'off']),
);

void main() {
  late int writes;
  late bool? lastEnabled;
  late bool? lastAcknowledged;
  late bool? lastIncludeReceived;
  late Future<CloudSyncAutomaticArchivePreference> Function() load;
  late Future<CloudSyncAutomaticArchivePreference> Function(
    CloudSyncAutomaticArchivePreference,
    bool, {
    required bool acknowledgeQueuedUploads,
    bool includeReceived,
  })
  save;

  setUp(() {
    writes = 0;
    lastEnabled = null;
    lastAcknowledged = null;
    lastIncludeReceived = null;
    load = () async => _preference();
    save =
        (
          expected,
          enabled, {
          required bool acknowledgeQueuedUploads,
          bool includeReceived = false,
        }) async {
          writes++;
          lastEnabled = enabled;
          lastAcknowledged = acknowledgeQueuedUploads;
          lastIncludeReceived = includeReceived;
          return _preference(
            enabled: enabled,
            includeReceived: includeReceived,
          );
        };
  });

  Widget host({double scale = 1, bool receivedArchiveAvailable = false}) =>
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CloudSyncAutomaticArchiveCard(
              onLoad: load,
              onChanged: save,
              receivedArchiveAvailable: receivedArchiveAvailable,
            ),
          ),
        ),
      );

  Future<void> openEnableDialog(
    WidgetTester tester, {
    bool receivedArchiveAvailable = false,
  }) async {
    await tester.pumpWidget(
      host(receivedArchiveAvailable: receivedArchiveAvailable),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
  }

  final receivedCheckbox = find.byKey(
    const ValueKey('automaticArchiveIncludeReceived'),
  );
  final acknowledgmentCheckbox = find.byKey(
    const ValueKey('automaticArchiveQueuedAcknowledgment'),
  );

  testWidgets('opening loads a preference without side effects', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(writes, 0);
    expect(find.text('Archive sent messages to iCloud'), findsWidgets);
    expect(receivedCheckbox, findsNothing);
    expect(find.text('Change archival scope'), findsNothing);
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
    expect(lastIncludeReceived, isFalse);
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
    expect(lastIncludeReceived, isFalse);
    expect(find.text('Enable automatic archival?'), findsNothing);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('busy save disables a second request', (tester) async {
    final result = Completer<CloudSyncAutomaticArchivePreference>();
    save =
        (
          _,
          _, {
          required bool acknowledgeQueuedUploads,
          bool includeReceived = false,
        }) {
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
      save =
          (
            _,
            _, {
            required bool acknowledgeQueuedUploads,
            bool includeReceived = false,
          }) async {
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
    save =
        (
          _,
          _, {
          required bool acknowledgeQueuedUploads,
          bool includeReceived = false,
        }) {
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

  testWidgets(
    'available received archival is explicit and unchecked by default',
    (tester) async {
      await openEnableDialog(tester, receivedArchiveAvailable: true);
      expect(tester.widget<CheckboxListTile>(receivedCheckbox).value, isFalse);
      expect(
        tester.widget<CheckboxListTile>(acknowledgmentCheckbox).value,
        isFalse,
      );
      expect(
        find.textContaining('queued and future supported received text'),
        findsOneWidget,
      );
      expect(find.text('Include supported received text'), findsOneWidget);
      expect(find.textContaining('direct and group chats'), findsOneWidget);
      expect(
        find.textContaining('Attachments, replies, reactions, edits'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Existing iCloud restores can still include media already archived by Apple.',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(acknowledgmentCheckbox);
      await tester.tap(acknowledgmentCheckbox);
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Enable automatic archival'),
      );
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(lastEnabled, isTrue);
      expect(lastAcknowledged, isTrue);
      expect(lastIncludeReceived, isFalse);
      expect(find.text('Archive sent messages to iCloud'), findsOneWidget);
      expect(find.text('Change archival scope'), findsOneWidget);
    },
  );

  testWidgets('received opt-in still needs queued upload acknowledgment', (
    tester,
  ) async {
    await openEnableDialog(tester, receivedArchiveAvailable: true);
    await tester.ensureVisible(receivedCheckbox);
    await tester.tap(receivedCheckbox);
    await tester.pump();
    final button = find.widgetWithText(
      FilledButton,
      'Enable automatic archival',
    );
    expect(tester.widget<CheckboxListTile>(receivedCheckbox).value, isTrue);
    expect(
      tester.widget<CheckboxListTile>(acknowledgmentCheckbox).value,
      isFalse,
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(writes, 0);
    await tester.ensureVisible(acknowledgmentCheckbox);
    await tester.tap(acknowledgmentCheckbox);
    await tester.pump();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(lastEnabled, isTrue);
    expect(lastAcknowledged, isTrue);
    expect(lastIncludeReceived, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(
      find.text('Archive sent messages and supported received text to iCloud'),
      findsOneWidget,
    );
    expect(find.textContaining('plus supported received text'), findsOneWidget);
    expect(
      find.textContaining('Attachments, replies, reactions, edits'),
      findsOneWidget,
    );
  });

  testWidgets('canceling received opt-in does not save or retain selection', (
    tester,
  ) async {
    await openEnableDialog(tester, receivedArchiveAvailable: true);
    await tester.ensureVisible(receivedCheckbox);
    await tester.tap(receivedCheckbox);
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(receivedCheckbox).value, isFalse);
    expect(
      tester.widget<CheckboxListTile>(acknowledgmentCheckbox).value,
      isFalse,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('sent-only users change scope without first disabling', (
    tester,
  ) async {
    load = () async => _preference(enabled: true);
    await tester.pumpWidget(host(receivedArchiveAvailable: true));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('Archive sent messages to iCloud'), findsOneWidget);
    await tester.tap(find.text('Change archival scope'));
    await tester.pumpAndSettle();
    expect(find.text('Change archival scope?'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(tester.widget<CheckboxListTile>(receivedCheckbox).value, isFalse);
    expect(
      tester.widget<CheckboxListTile>(acknowledgmentCheckbox).value,
      isFalse,
    );
    final button = find.widgetWithText(FilledButton, 'Save archival scope');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.ensureVisible(receivedCheckbox);
    await tester.tap(receivedCheckbox);
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.ensureVisible(acknowledgmentCheckbox);
    await tester.tap(acknowledgmentCheckbox);
    await tester.pump();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(lastEnabled, isTrue);
    expect(lastAcknowledged, isTrue);
    expect(lastIncludeReceived, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('changing a scope selection requires a new acknowledgment', (
    tester,
  ) async {
    load = () async => _preference(enabled: true, includeReceived: true);
    await tester.pumpWidget(host(receivedArchiveAvailable: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change archival scope'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(receivedCheckbox).value, isTrue);
    expect(
      tester.widget<CheckboxListTile>(acknowledgmentCheckbox).value,
      isFalse,
    );
    await tester.ensureVisible(acknowledgmentCheckbox);
    await tester.tap(acknowledgmentCheckbox);
    await tester.pump();
    final button = find.widgetWithText(FilledButton, 'Save archival scope');
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await tester.ensureVisible(receivedCheckbox);
    await tester.tap(receivedCheckbox);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(receivedCheckbox).value, isFalse);
    expect(
      tester.widget<CheckboxListTile>(acknowledgmentCheckbox).value,
      isFalse,
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.ensureVisible(acknowledgmentCheckbox);
    await tester.tap(acknowledgmentCheckbox);
    await tester.pump();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(lastEnabled, isTrue);
    expect(lastAcknowledged, isTrue);
    expect(lastIncludeReceived, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('Archive sent messages to iCloud'), findsOneWidget);
  });

  testWidgets('canceling a scope change preserves enabled sent-only archival', (
    tester,
  ) async {
    load = () async => _preference(enabled: true);
    await tester.pumpWidget(host(receivedArchiveAvailable: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change archival scope'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(receivedCheckbox);
    await tester.tap(receivedCheckbox);
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('Archive sent messages to iCloud'), findsOneWidget);
    await tester.tap(find.text('Change archival scope'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(receivedCheckbox).value, isFalse);
    expect(
      tester.widget<CheckboxListTile>(acknowledgmentCheckbox).value,
      isFalse,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('unavailable received support hides scope changes for v1 grants', (
    tester,
  ) async {
    load = () async => _preference(enabled: true);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('Archive sent messages to iCloud'), findsOneWidget);
    expect(
      find.text(
        'Archive messages you send to iCloud automatically after sending is confirmed.',
      ),
      findsOneWidget,
    );
    expect(find.text('Change archival scope'), findsNothing);
    expect(
      find.textContaining('Supported received and mirrored'),
      findsNothing,
    );
    expect(writes, 0);
  });

  testWidgets(
    'unavailable received support preserves and explains a v2 grant',
    (tester) async {
      load = () async => _preference(enabled: true, includeReceived: true);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('Archive sent messages to iCloud'), findsOneWidget);
      expect(
        find.text(
          'Archive sent messages and supported received text to iCloud',
        ),
        findsNothing,
      );
      expect(
        find.textContaining(
          'Supported received and mirrored text archival is unavailable',
        ),
        findsOneWidget,
      );
      expect(find.text('Change archival scope'), findsNothing);
      expect(receivedCheckbox, findsNothing);
      expect(writes, 0);
    },
  );

  testWidgets('available received controls fit narrow large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(scale: 2, receivedArchiveAvailable: true));
    await tester.pumpAndSettle();
    tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
    await tester.pumpAndSettle();
    expect(receivedCheckbox, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
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
    expect(
      MediaQuery.textScalerOf(
        tester.element(find.byType(AlertDialog)),
      ).scale(16),
      32,
      reason: 'root dialog routes must use the same large text as Profile',
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
