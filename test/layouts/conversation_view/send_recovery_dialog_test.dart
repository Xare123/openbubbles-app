import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/send_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final unavailable in [false, true]) {
    testWidgets(
      'retained send dialog offers only close, unavailable=$unavailable',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                return Scaffold(
                  body: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          SendRecoveryDialog(statusUnavailable: unavailable),
                    ),
                    child: const Text('Show'),
                  ),
                );
              },
            ),
          ),
        );
        await tester.tap(find.text('Show'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            unavailable
                ? 'Send status unavailable'
                : 'Send confirmation needed',
          ),
          findsOneWidget,
        );
        expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Remove'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Close'), findsOneWidget);
        expect(
          find.textContaining('Nothing was resent or removed.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'error dialog rechecks before legacy retry and remove mutate the row',
    () {
      final source = File(
        'lib/app/layouts/conversation_view/widgets/message/message_holder.dart',
      ).readAsStringSync();
      final retry = source.indexOf('child: Text("Retry"');
      final remove = source.indexOf('child: Text("Remove"');
      final cancel = source.indexOf('child: Text("Cancel"', remove);
      expect(retry, greaterThanOrEqualTo(0));
      expect(remove, greaterThan(retry));
      expect(cancel, greaterThan(remove));
      for (final segment in [
        source.substring(retry, remove),
        source.substring(remove, cancel),
      ]) {
        final fence = segment.indexOf(
          '_showSendRecoveryIfNeeded(dismissDialog: context)',
        );
        final deletion = segment.indexOf('Message.delete(message.guid!)');
        expect(fence, greaterThanOrEqualTo(0));
        expect(deletion, greaterThan(fence));
      }
      expect(source, contains('if (_showSendRecoveryIfNeeded()) return;'));
    },
  );
}
