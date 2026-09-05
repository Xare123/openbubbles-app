import 'package:bluebubbles/app/layouts/settings/pages/misc/cloud_sync_outbound_recipient_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('recipient controller survives the route closing animation', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(_Harness(onResult: (value) => result = value));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  test@example.com  ');
    final field = tester.widget<TextField>(find.byType(TextField));
    final controller = field.controller!;

    await tester.tap(find.text('Use Exact Recipient'));
    await tester.pump();
    expect(result, 'test@example.com');
    expect(find.byType(CloudSyncOutboundRecipientDialog), findsOneWidget);

    // showDialog has returned, but the route and its animated TextField are
    // still mounted. These listener operations failed with caller-owned
    // disposal in the awaiting function's finally block.
    void listener() {}
    expect(() => controller.addListener(listener), returnsNormally);
    controller.removeListener(listener);
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byType(CloudSyncOutboundRecipientDialog), findsNothing);
    expect(() => controller.addListener(listener), throwsFlutterError);
  });

  testWidgets('cancel dismisses safely and reopening owns a fresh controller', (
    tester,
  ) async {
    final results = <String?>[];
    await tester.pumpWidget(_Harness(onResult: results.add));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'discard@example.com');
    final first = tester.widget<TextField>(find.byType(TextField)).controller;
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final second = tester.widget<TextField>(find.byType(TextField)).controller;
    expect(identical(first, second), isFalse);
    expect(second!.text, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty recipient neither dismisses nor accepts a destination', (
    tester,
  ) async {
    final results = <String?>[];
    await tester.pumpWidget(_Harness(onResult: results.add));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Use Exact Recipient'));
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(find.byType(CloudSyncOutboundRecipientDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}

class _Harness extends StatelessWidget {
  const _Harness({required this.onResult});
  final ValueChanged<String?> onResult;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            final result = await showDialog<String>(
              context: context,
              barrierDismissible: false,
              builder: (_) => const CloudSyncOutboundRecipientDialog(),
            );
            onResult(result);
          },
          child: const Text('Open'),
        ),
      ),
    ),
  );
}
