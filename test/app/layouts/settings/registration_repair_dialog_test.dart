import 'package:bluebubbles/app/layouts/settings/pages/profile/registration_repair_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('showing and cancelling repair do not call the repair action', (
    tester,
  ) async {
    var repairs = 0;
    await tester.pumpWidget(_Harness(repair: () async => repairs++));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(repairs, 0);
    expect(find.textContaining('saved chats'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repairs, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only explicit confirmation invokes repair, once', (
    tester,
  ) async {
    var repairs = 0;
    await tester.pumpWidget(_Harness(repair: () async => repairs++));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair registration'));
    await tester.pumpAndSettle();
    expect(repairs, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back dismisses repair without changing the account', (
    tester,
  ) async {
    var repairs = 0;
    await tester.pumpWidget(_Harness(repair: () async => repairs++));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(AlertDialog));
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(repairs, 0);
    expect(tester.takeException(), isNull);
  });
}

class _Harness extends StatelessWidget {
  const _Harness({required this.repair});

  final Future<void> Function() repair;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => confirmRegistrationRepair(context, repair: repair),
          child: const Text('Open'),
        ),
      ),
    ),
  );
}
