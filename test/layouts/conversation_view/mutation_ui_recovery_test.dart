import 'dart:async';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/mutation_feedback.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Recovery tests for the Canary edit-stuck / unsend failure:
/// `CloudSyncLocalMutationSourceStaging.prepareSubmission` throws
/// `CloudKitOperationInterlockException(cloudkit_interlock_busy)` before IDS
/// send. A generic failure can also surface after dispatch, so copy never
/// claims a mutation was (or was not) sent or removed.
void main() {
  group('mutation failure copy', () {
    test(
      'busy edit names the blocker, keeps draft, defers to status check',
      () {
        const error = CloudKitOperationInterlockException(
          'cloudkit_interlock_busy',
        );
        final feedback = mutationFailureFeedback(error, isEdit: true);
        expect(feedback.title, 'Edit not confirmed');
        expect(feedback.message, contains('Another iCloud operation'));
        expect(feedback.message, contains('draft was kept'));
        expect(
          feedback.message,
          contains('Check the latest message status before retrying'),
        );
      },
    );

    test('generic edit admits unknown outcome, leaks no content', () {
      final feedback = mutationFailureFeedback(
        Exception('secret text from Test Contact guid:ABC-123'),
        isEdit: true,
      );
      expect(feedback.title, 'Edit not confirmed');
      expect(feedback.message, contains('outcome is unknown'));
      expect(feedback.message, contains('draft was kept'));
      expect(feedback.message, contains('Check the latest message status'));
      for (final leak in [
        'Test Contact',
        'secret',
        'ABC-123',
        'Not Sent',
        'Nothing was removed',
      ]) {
        expect(feedback.title, isNot(contains(leak)));
        expect(feedback.message, isNot(contains(leak)));
      }
    });

    test('busy unsend stays distinct from generic unsend', () {
      const busy = CloudKitOperationInterlockException(
        'cloudkit_interlock_busy',
      );
      final busyFeedback = mutationFailureFeedback(busy, isEdit: false);
      expect(busyFeedback.title, 'Unsend not confirmed');
      expect(busyFeedback.message, contains('Another iCloud operation'));
      expect(
        busyFeedback.message,
        contains('Check the latest message status before retrying'),
      );
      expect(busyFeedback.message, isNot(contains('Nothing was removed')));

      final genericFeedback = mutationFailureFeedback(
        Exception('boom'),
        isEdit: false,
      );
      expect(genericFeedback.title, 'Unsend not confirmed');
      expect(genericFeedback.message, contains('outcome is unknown'));
      expect(
        genericFeedback.message,
        isNot(contains('Another iCloud operation')),
      );
    });

    test('ambiguous failure collapses to generic, never raw text', () {
      expect(
        mutationSafeCode(StateError('some-new-engine-string')),
        'cloud_sync_unknown_failure',
      );
      final feedback = mutationFailureFeedback(
        StateError('some-new-engine-string guid:XYZ'),
        isEdit: false,
      );
      expect(feedback.message, isNot(contains('some-new-engine-string')));
      expect(feedback.message, isNot(contains('XYZ')));
    });
  });

  group('async gate recovery', () {
    test(
      'duplicate attempt while a failing Future is pending is blocked',
      () async {
        final gate = MutationUiGate();
        expect(gate.tryAcquire(), isTrue);
        final pending = Future<void>.delayed(
          const Duration(milliseconds: 10),
          () => throw Exception('burst'),
        );
        // Duplicate tap while the first attempt is still pending.
        expect(gate.tryAcquire(), isFalse);
        Object? caught;
        try {
          await pending;
        } catch (error) {
          caught = error;
        } finally {
          gate.release(); // production finally path
        }
        expect(caught, isNotNull);
        final feedback = mutationFailureFeedback(caught!, isEdit: true);
        expect(feedback.title, 'Edit not confirmed');
        expect(gate.isBusy, isFalse);
        expect(gate.tryAcquire(), isTrue); // retry possible after release
        gate.release();
      },
    );

    test('successful Future leaves the gate reusable', () async {
      final gate = MutationUiGate();
      expect(gate.tryAcquire(), isTrue);
      final value = await Future<int>.delayed(
        const Duration(milliseconds: 5),
        () => 7,
      );
      gate.release();
      expect(value, 7);
      expect(gate.isBusy, isFalse);
    });
  });

  group('owned dialog cleanup', () {
    testWidgets('failure before the first dialog build leaves no stuck modal', (
      tester,
    ) async {
      final owned = OwnedDialog();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('home'))),
      );
      final host = tester.element(find.text('home'));
      unawaited(
        showDialog<void>(
          context: host,
          builder: (context) {
            owned.capture(context);
            return const AlertDialog(title: Text('early-dialog'));
          },
        ),
      );
      // A synchronously completed backend future fails before any frame.
      owned.close();
      expect(owned.isArmed, isFalse);
      await tester.pumpAndSettle();
      expect(find.text('early-dialog'), findsNothing);
      expect(Navigator.of(host).canPop(), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('late first build cannot remove the next attempt dialog', (
      tester,
    ) async {
      final failedAttempt = OwnedDialog();
      final nextAttempt = OwnedDialog();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('home'))),
      );
      final host = tester.element(find.text('home'));
      unawaited(
        showDialog<void>(
          context: host,
          builder: (context) {
            failedAttempt.capture(context);
            return const AlertDialog(title: Text('failed-dialog'));
          },
        ),
      );
      failedAttempt.close();
      unawaited(
        showDialog<void>(
          context: host,
          builder: (context) {
            nextAttempt.capture(context);
            return const AlertDialog(title: Text('next-dialog'));
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('failed-dialog'), findsNothing);
      expect(find.text('next-dialog'), findsOneWidget);
      failedAttempt.close();
      nextAttempt.close();
      await tester.pumpAndSettle();
      expect(Navigator.of(host).canPop(), isFalse);
      expect(tester.takeException(), isNull);
    });

    Future<void> showOwned(
      WidgetTester tester,
      OwnedDialog owned,
      String tag,
    ) async {
      final hostContext = tester.element(find.text('home'));
      unawaited(
        showDialog(
          context: hostContext,
          builder: (dialogContext) {
            owned.capture(dialogContext);
            return AlertDialog(title: Text('owned-$tag'));
          },
        ),
      );
      await tester.pump();
    }

    testWidgets('close removes only the owned dialog', (tester) async {
      final owned = OwnedDialog();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('home'))),
      );
      await showOwned(tester, owned, 'a');
      expect(find.text('owned-a'), findsOneWidget);
      expect(owned.isArmed, isTrue);

      final hostContext = tester.element(find.text('home'));
      Navigator.of(hostContext).push(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('other'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('other'), findsOneWidget);

      owned.close();
      await tester.pumpAndSettle();
      expect(find.text('owned-a'), findsNothing);
      expect(find.text('other'), findsOneWidget);
    });

    testWidgets('close after host disposal throws nothing', (tester) async {
      final owned = OwnedDialog();
      final gate = MutationUiGate();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('home'))),
      );
      expect(gate.tryAcquire(), isTrue);
      await showOwned(tester, owned, 'b');
      expect(find.text('owned-b'), findsOneWidget);
      await tester.pumpWidget(Container()); // dispose host + navigator
      owned.close(); // must not throw; owned route already gone
      gate.release(); // production finally path
      expect(owned.isArmed, isFalse);
      expect(gate.isBusy, isFalse);
    });
  });
}
