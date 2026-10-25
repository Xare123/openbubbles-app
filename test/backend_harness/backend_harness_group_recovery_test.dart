import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/backend_harness/backend_harness_windows_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> valid() => {
    'operationId': 'op1:${'a' * 64}',
    'chatId': 3,
    'intentId': 2,
    'retainedRecoveryOwner': '11111111-2222-4333-8444-555555555555',
  };

  test(
    'exact recovery request is bounded to one operation, Chat, intent and owner',
    () {
      expect(backendHarnessValidFreshGroupRecovery(valid()), isTrue);
      for (final key in valid().keys) {
        expect(
          backendHarnessValidFreshGroupRecovery({...valid()}..remove(key)),
          isFalse,
        );
      }
      expect(
        backendHarnessValidFreshGroupRecovery({...valid(), 'resend': true}),
        isFalse,
      );
      for (final operation in [
        '',
        'a' * 64,
        'op1:${'A' * 64}',
        'op1:${'a' * 65}',
      ]) {
        expect(
          backendHarnessValidFreshGroupRecovery({
            ...valid(),
            'operationId': operation,
          }),
          isFalse,
        );
      }
      for (final key in ['chatId', 'intentId']) {
        for (final value in [null, 0, -1, '18', 18.0, true]) {
          expect(
            backendHarnessValidFreshGroupRecovery({...valid(), key: value}),
            isFalse,
          );
        }
      }
      for (final owner in [
        '',
        'other',
      'AAAAAAAA-2222-4333-8444-555555555555',
      ]) {
        expect(
          backendHarnessValidFreshGroupRecovery({
            ...valid(),
            'retainedRecoveryOwner': owner,
          }),
          isFalse,
        );
      }
    },
  );

  test('local recovery reports do not claim archive or readback success', () {
    expect(backendHarnessActions, contains('archive.recover-group'));
    final payload = const BackendHarnessPayload(
      flags: {
        'group_recovery_ready': true,
        'group_recovery_record_retained': true,
      },
    ).toJson();
    expect(payload['flags'], {
      'group_recovery_ready': true,
      'group_recovery_record_retained': true,
    });
    expect(payload.toString(), isNot(contains('operationId')));
    expect((payload['flags'] as Map).containsKey('readback_verified'), isFalse);
    expect((payload['flags'] as Map).containsKey('archive_enabled'), isFalse);
  });
}
