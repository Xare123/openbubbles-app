import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_delivery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Message value({int? id}) => Message(
    id: id,
    guid: 'synthetic-receive',
    text: 'hello',
    isFromMe: false,
  );

  for (final committed in [false, true]) {
    test('capture failure preserves delivery, committed=$committed', () async {
      final message = value();
      final saved = value(id: 10);
      var ordinary = 0;
      final result = await persistReceivedMessageWithoutLoss(
        message: message,
        capture: () async {
          message.id = 99;
          throw StateError('cloud_sync_received_archive_identity_changed');
        },
        persistOrdinary: () {
          expect(message.id, isNull);
          ordinary++;
          return saved;
        },
        findCommitted: () => committed ? saved : null,
        isExpectedCommitted: (_) => true,
        sameReceiveIdentity: () => true,
        onDeferred: (code, alreadySaved) => expect(alreadySaved, committed),
      );
      expect(identical(result, saved), isTrue);
      expect(ordinary, committed ? 0 : 1);
    });
  }

  test('successful capture does not invoke ordinary fallback', () async {
    final message = value(id: 10);
    final result = await persistReceivedMessageWithoutLoss(
      message: message,
      capture: () async => message,
      persistOrdinary: () => throw StateError('no second save'),
      findCommitted: () => throw StateError('no lookup'),
      isExpectedCommitted: (_) => true,
      sameReceiveIdentity: () => true,
      onDeferred: (_, __) => throw StateError('no failure'),
    );
    expect(identical(result, message), isTrue);
  });

  test('queued work from a replaced profile never starts capture', () async {
    await expectLater(
      persistReceivedMessageWithoutLoss(
        message: value(),
        capture: () async => throw TestFailure('must not start'),
        persistOrdinary: () => throw TestFailure('must not persist'),
        findCommitted: () => throw TestFailure('must not query'),
        isExpectedCommitted: (_) => true,
        sameReceiveIdentity: () => false,
        onDeferred: (_, __) => throw TestFailure('must not inspect'),
      ),
      throwsStateError,
    );
  });

  test(
    'account or store change cannot fall back into a replacement profile',
    () async {
      var touched = false;
      var checks = 0;
      await expectLater(
        persistReceivedMessageWithoutLoss(
          message: value(),
          capture: () async => throw StateError('changed'),
          persistOrdinary: () {
            touched = true;
            return value();
          },
          findCommitted: () {
            touched = true;
            return null;
          },
          isExpectedCommitted: (_) => true,
          sameReceiveIdentity: () => ++checks == 1,
          onDeferred: (_, __) {
            touched = true;
          },
        ),
        throwsStateError,
      );
      expect(touched, isFalse);
    },
  );

  test('conflicting durable row is not accepted by GUID alone', () async {
    await expectLater(
      persistReceivedMessageWithoutLoss(
        message: value(),
        capture: () async => throw StateError('failed'),
        persistOrdinary: () => throw StateError('no second save'),
        findCommitted: () => value(id: 10),
        isExpectedCommitted: (_) => false,
        sameReceiveIdentity: () => true,
        onDeferred: (_, __) {},
      ),
      throwsStateError,
    );
  });

  test('diagnostic failure cannot prevent ordinary persistence', () async {
    final saved = value(id: 10);
    final result = await persistReceivedMessageWithoutLoss(
      message: value(),
      capture: () async => throw StateError('failed'),
      persistOrdinary: () => saved,
      findCommitted: () => null,
      isExpectedCommitted: (_) => true,
      sameReceiveIdentity: () => true,
      onDeferred: (_, __) => throw StateError('logger failed'),
    );
    expect(identical(result, saved), isTrue);
  });
}
