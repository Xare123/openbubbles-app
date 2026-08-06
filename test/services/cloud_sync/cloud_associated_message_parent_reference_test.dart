import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes an exact parent reference to local GUID and numeric part', () {
    final reference = CloudAssociatedMessageParentReference.parse(
      'p:3/ABCDEF12-3456-7890-ABCD-EF1234567890',
    );

    expect(reference.part, 3);
    expect(reference.localMessageGuid, 'ABCDEF12-3456-7890-ABCD-EF1234567890');
  });

  test('accepts a bare GUID as the partless form', () {
    // Apple drops the wrapper when a reaction targets no particular part.
    // Requiring the prefix quarantined every partless reaction.
    final reference = CloudAssociatedMessageParentReference.parse(
      'ABCDEF12-3456-7890-ABCD-EF1234567890',
    );

    expect(reference.part, isNull);
    expect(reference.localMessageGuid, 'ABCDEF12-3456-7890-ABCD-EF1234567890');
  });

  test('rejects an empty reference', () {
    expect(
      () => CloudAssociatedMessageParentReference.parse(''),
      throwsA(isA<CloudAssociatedMessageParentReferenceFormatException>()),
    );
  });

  test('rejects a non-canonical part spelling', () {
    // The native parser rejects leading zeros. Accepting them here made the
    // same wire value convert on one side of the bridge and quarantine on the
    // other.
    for (final value in <String>[
      'p:0003/message-guid',
      'p:00/message-guid',
      'p:01/message-guid',
    ]) {
      expectInvalid(value);
    }
  });

  test('rejects wrappers and structured values that are not bare GUIDs', () {
    for (final value in <String>[
      'bp:0/message-guid',
      'bpdi:0/message-guid',
      '0/message-guid',
      'P:0/message-guid',
      'r:0:message-guid',
      'message-guid/extra',
      'message-guid:extra',
    ]) {
      expectInvalid(value);
    }
  });

  test('rejects missing negative and non-numeric parts', () {
    for (final value in <String>[
      'p:/message-guid',
      'p:-1/message-guid',
      'p:+1/message-guid',
      'p:1.0/message-guid',
      'p:one/message-guid',
      'p:0message-guid',
    ]) {
      expectInvalid(value);
    }
  });

  test('rejects empty unsafe oversized and extra-separator GUIDs', () {
    for (final value in <String>[
      'p:0/',
      'p:0/message/guid',
      'p:0/message-guid\nsecret',
      'p:0/message-guid\u0000secret',
      'p:0/message-guid\u007fsecret',
      'p:0/ leading-space',
      'p:0/trailing-space ',
      'p:0/${'g' * (CloudAssociatedMessageParentReference.maximumGuidCodeUnits + 1)}',
    ]) {
      expectInvalid(value);
    }
  });

  test('toString and parse errors never reveal the input', () {
    const secret = 'SECRET-PARENT-GUID';
    final valid = CloudAssociatedMessageParentReference.parse('p:7/$secret');

    expect(valid.toString(), contains('redacted'));
    expect(valid.toString(), isNot(contains(secret)));
    expect(valid.toString(), isNot(contains('7')));

    Object? caught;
    try {
      CloudAssociatedMessageParentReference.parse('bpdi:7/$secret');
    } catch (error) {
      caught = error;
    }
    expect(caught, isA<CloudAssociatedMessageParentReferenceFormatException>());
    expect(caught.toString(), isNot(contains(secret)));
    expect(caught.toString(), isNot(contains('bpdi')));
    expect(
      caught.toString(),
      contains(CloudAssociatedMessageParentReferenceFormatException.safeCode),
    );

    final formatError = caught as FormatException;
    expect(formatError.source, isNull);
    expect(formatError.offset, isNull);
    expect(formatError.message, isNot(contains(secret)));
  });
}

void expectInvalid(String value) {
  Object? caught;
  try {
    CloudAssociatedMessageParentReference.parse(value);
  } catch (error) {
    caught = error;
  }

  expect(
    caught,
    isA<CloudAssociatedMessageParentReferenceFormatException>(),
    reason: 'Rejected inputs must use the redacted parser error',
  );
  expect(caught.toString(), isNot(contains(value)));
}
