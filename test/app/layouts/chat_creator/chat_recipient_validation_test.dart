import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/app/layouts/chat_creator/chat_recipient_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pending and failed validation block while unsupported does not', () {
    const pending = ChatRecipientValidationState.pending();
    const supported = ChatRecipientValidationState.supported();
    const unsupported = ChatRecipientValidationState.unsupported();
    const failed = ChatRecipientValidationState.failed(
      ChatRecipientValidationFailure(
        ChatRecipientValidationFailureKind.unavailable,
      ),
    );

    expect(pending.blocksSend, isTrue);
    expect(failed.blocksSend, isTrue);
    expect(supported.blocksSend, isFalse);
    expect(unsupported.blocksSend, isFalse);
    expect(unsupported.isIMessage, isFalse);
  });

  test('terminal registration 6005 points to explicit Profile repair', () {
    final failure = ChatRecipientValidationFailure.fromError(
      Exception(
        'Failed to generate resource Registration Error Bad authentication (6005); not retrying',
      ),
    );

    expect(
      failure.kind,
      ChatRecipientValidationFailureKind.registrationRepairRequired,
    );
    expect(failure.message, contains('Settings > Profile'));
    expect(failure.message, contains('Repair registration'));
  });

  test('generic validation errors do not recommend account repair', () {
    final failure = ChatRecipientValidationFailure.fromError(
      TimeoutException('network unavailable'),
    );

    expect(failure.kind, ChatRecipientValidationFailureKind.unavailable);
    expect(failure.message, contains('Check your connection'));
    expect(failure.message, isNot(contains('Repair registration')));
  });

  test('removed recipient rejects its in-flight validation result', () {
    final gate = ChatRecipientValidationGate(address: 'recipient@example.com');
    final request = gate.begin();

    gate.invalidate();

    expect(
      gate.accept(request, const ChatRecipientValidationState.supported()),
      isFalse,
    );
    expect(gate.state.status, ChatRecipientValidationStatus.pending);
  });

  test('newer validation request wins over an older completion', () {
    final gate = ChatRecipientValidationGate(address: 'recipient@example.com');
    final first = gate.begin();
    final second = gate.begin();

    expect(
      gate.accept(first, const ChatRecipientValidationState.unsupported()),
      isFalse,
    );
    expect(
      gate.accept(second, const ChatRecipientValidationState.supported()),
      isTrue,
    );
    expect(gate.state.status, ChatRecipientValidationStatus.supported);
  });

  test('failed validation retries only after an explicit new request', () {
    final gate = ChatRecipientValidationGate(address: 'recipient@example.com');
    final first = gate.begin();
    const failure = ChatRecipientValidationFailure(
      ChatRecipientValidationFailureKind.unavailable,
    );
    expect(
      gate.accept(first, const ChatRecipientValidationState.failed(failure)),
      isTrue,
    );
    expect(gate.state.status, ChatRecipientValidationStatus.failed);

    final retry = gate.begin();
    expect(gate.state.status, ChatRecipientValidationStatus.pending);
    expect(
      gate.accept(retry, const ChatRecipientValidationState.supported()),
      isTrue,
    );
  });

  test('chat creation gate completes normally and idempotently', () async {
    final gate = Completer<void>();

    completeChatCreationGate(gate);
    completeChatCreationGate(gate);

    await expectLater(gate.future, completes);
  });

  test(
    'chat creator preserves validation failures and settles errors normally',
    () {
      final source = File(
        'lib/app/layouts/chat_creator/chat_creator.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('ChatRecipientValidationFailure.fromError(error)'),
      );
      expect(
        source,
        contains('if (_showBlockingRecipientValidation()) return;'),
      );
      expect(source, contains('recipientValidationFailure.value = null;'));
      expect(source, contains('contact.validationGate.invalidate();'));
      expect(source, isNot(contains('completeError(error)')));
      expect(source, contains('completeChatCreationGate(createCompleter);'));
      expect(source, contains('child: const Text("Retry validation")'));
    },
  );

  test('validation gates preserve the existing composer and attachments', () {
    final source = File(
      'lib/app/layouts/chat_creator/chat_creator.dart',
    ).readAsStringSync();
    final validationStart = source.indexOf(
      'Future<void> _validateSelectedContact(',
    );
    final validationEnd = source.indexOf(
      'void addSelectedList(',
      validationStart,
    );
    final blockedStart = source.indexOf(
      'if (_blockingRecipientValidation != null)',
    );
    final blockedEnd = source.indexOf('if (selectedContacts.any', blockedStart);

    expect(validationStart, greaterThanOrEqualTo(0));
    expect(validationEnd, greaterThan(validationStart));
    expect(blockedStart, greaterThanOrEqualTo(0));
    expect(blockedEnd, greaterThan(blockedStart));
    final noRecipientBranch = source.substring(
      source.indexOf('if (selectedContacts.isEmpty)'),
      blockedStart,
    );
    expect(noRecipientBranch, contains('await cm.setAllInactive();'));
    expect(noRecipientBranch, contains('fakeController.value = null;'));
    expect(
      source.substring(validationStart, validationEnd),
      isNot(contains('fakeController.value = null')),
    );
    expect(
      source.substring(blockedStart, blockedEnd),
      isNot(contains('fakeController.value = null')),
    );
    expect(
      source.substring(blockedStart, blockedEnd),
      isNot(contains('cm.setAllInactive()')),
    );
  });
}
