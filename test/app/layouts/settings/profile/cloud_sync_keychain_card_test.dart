import 'package:bluebubbles/app/layouts/settings/pages/profile/cloud_sync_keychain_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
Future<void> pumpCard(WidgetTester tester, {Future<bool?> Function()? check, bool Function()? hasDefault, Future<void> Function(String)? change}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: CloudSyncKeychainCard(checkReadiness: check, hasDefaultCode: hasDefault, changeCode: change))));
  await tester.pumpAndSettle();
}
void main() {
  testWidgets('ready status with default code kind and no secret value', (tester) async {
    await pumpCard(tester, check: () async => true, hasDefault: () => true, change: (_) async {});
    expect(find.text('Ready for iCloud encryption.'), findsOneWidget);
    expect(find.text('Using the default code set up on this device.'), findsOneWidget);
    expect(find.bySemanticsLabel('Keychain status: Ready'), findsOneWidget);
    expect(find.text('Change code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('not-ready status explains next step without changing anything', (tester) async {
    var calls = 0;
    await pumpCard(tester, check: () async { calls++; return false; }, hasDefault: () => false, change: (_) async {});
    expect(find.textContaining('Not ready'), findsOneWidget);
    expect(find.text('A custom code is set.'), findsOneWidget);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed check shows unknown with a retry path', (tester) async {
    var fail = true;
    await pumpCard(tester, check: () async { if (fail) throw StateError('nope'); return true; }, hasDefault: () => false, change: (_) async {});
    expect(find.textContaining('Status unknown'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(find.text('Ready for iCloud encryption.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('successful change submits once and refreshes', (tester) async {
    final codes = <String>[];
    await pumpCard(tester, check: () async => true, hasDefault: () => true, change: (code) async { codes.add(code); });
    await tester.tap(find.text('Change code'));
    await tester.pumpAndSettle();
    expect(find.text('Change iCloud Keychain code'), findsOneWidget);
    await tester.tap(find.text('Use password'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'correct-horse-123');
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(codes, ['correct-horse-123']);
    expect(find.text('Change iCloud Keychain code'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed change keeps the dialog with an inline error', (tester) async {
    var calls = 0;
    await pumpCard(tester, check: () async => true, hasDefault: () => false, change: (_) async { calls++; throw StateError('denied'); });
    await tester.tap(find.text('Change code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use password'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'weak');
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Could not change the code. Check the entry and try again.'), findsOneWidget);
    expect(find.text('Change iCloud Keychain code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('cancel never submits', (tester) async {
    var calls = 0;
    await pumpCard(tester, check: () async => true, hasDefault: () => false, change: (_) async { calls++; });
    await tester.tap(find.text('Change code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Change iCloud Keychain code'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('passcode entry is labeled with a numeric keyboard', (tester) async {
    await pumpCard(tester, check: () async => true, hasDefault: () => true, change: (_) async {});
    await tester.tap(find.text('Change code'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('New passcode')), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.keyboardType, TextInputType.number);
    expect(field.decoration?.labelText, 'New passcode');
    await tester.tap(find.text('Use password'));
    await tester.pumpAndSettle();
    final passwordField = tester.widget<TextField>(find.byType(TextField));
    expect(passwordField.keyboardType, TextInputType.text);
    expect(passwordField.obscureText, isTrue);
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('large text renders without overflow', (tester) async {
    tester.binding.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.binding.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpCard(tester, check: () async => true, hasDefault: () => true, change: (_) async {});
    expect(find.text('iCloud Keychain code'), findsOneWidget);
    await tester.tap(find.text('Change code'));
    await tester.pumpAndSettle();
    expect(find.text('Change iCloud Keychain code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
