import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/imessage_reaction_submission.dart';
import 'package:flutter_test/flutter_test.dart';

const _stable = 'EA6165FC-EFF7-40A7-8F11-C0D3D397597B';
Message _pending() => Message(
  id: 17,
  guid: 'temp-12345678',
  associatedMessageGuid: 'parent-guid',
  associatedMessageType: 'love',
  isFromMe: true,
);

void main() {
  test('retry keeps the original native ID through queue preparation', () {
    for (final staged in [true, false]) {
      final row = _pending()
        ..guid = staged ? 'error-timeout-12345678' : _stable
        ..stagingGuid = staged ? _stable : null
        ..error = 400
        ..associatedMessageType = '-love'
        ..associatedMessagePart = null;
      prepareIMessageReactionRetry(row);
      row.generateTempGuid(); // The real outgoing queue performs this step.
      expect(row.id, 17);
      expect(row.stagingGuid, _stable);
      expect(row.guid, startsWith('temp-'));
      expect(row.error, 0);
      expect(row.associatedMessageGuid, 'parent-guid');
      expect(row.associatedMessageType, '-love');
      expect(row.associatedMessagePart, isNull);
    }
  });

  test('retry before native construction does not invent a stable ID', () {
    final row = _pending()..error = 400;
    prepareIMessageReactionRetry(row);
    expect(row.id, 17);
    expect(row.stagingGuid, isNull);
  });

  test('active, restored or malformed retry leaves the row untouched', () {
    for (final change in <void Function(Message)>[
      (row) => row.sendingServiceId = 'active-job',
      (row) => row.ckRecordId = 'restored-record',
      (row) => row.stagingGuid = 'invalid-native-id',
      (row) => row.isFromMe = false,
    ]) {
      final row = _pending()..error = 400;
      change(row);
      expect(() => prepareIMessageReactionRetry(row), throwsStateError);
      expect(row.id, 17);
      expect(row.error, 400);
      expect(row.guid, 'temp-12345678');
    }
  });

  test(
    'only actual synchronous success clears an in-flight local error',
    () async {
      for (final pending in [true, false]) {
        final row = _pending();
        await submitTrackedIMessageReaction(
          message: row,
          stableGuid: _stable,
          persistPending: () async {},
          send: () async {
            row.error = 400;
            return pending;
          },
          persistCompletion: (_) async {},
        );
        expect(row.error, pending ? 400 : 0);
      }
    },
  );

  test(
    'waits for the original pending row before a fast native callback',
    () async {
      final row = _pending();
      final persisted = Completer<void>();
      final events = <String>[];
      final run = submitTrackedIMessageReaction(
        message: row,
        stableGuid: _stable,
        persistPending: () async {
          expect(row.id, 17);
          expect(row.guid, 'temp-12345678');
          expect(row.stagingGuid, _stable);
          events.add('pending');
          await persisted.future;
        },
        send: () async {
          expect(persisted.isCompleted, isTrue);
          expect(row.stagingGuid, _stable);
          events.add('native-confirm');
          return false;
        },
        persistCompletion: (backgroundPending) async {
          expect(backgroundPending, isFalse);
          expect(row.guid, _stable);
          expect(row.stagingGuid, isNull);
          expect(row.id, 17);
          events.add('confirmed');
        },
      );
      expect(events, ['pending']);
      persisted.complete();
      await run;
      expect(events, ['pending', 'native-confirm', 'confirmed']);
    },
  );

  test('background return remains explicitly unconfirmed', () async {
    final row = _pending();
    await submitTrackedIMessageReaction(
      message: row,
      stableGuid: _stable,
      persistPending: () async {},
      send: () async => true,
      persistCompletion: (pending) async => expect(pending, isTrue),
    );
    expect(row.id, 17);
    expect(row.guid, _stable);
  });

  test(
    'native failure retains retry identity and never completes the row',
    () async {
      final row = _pending();
      var completed = false;
      await expectLater(
        submitTrackedIMessageReaction(
          message: row,
          stableGuid: _stable,
          persistPending: () async {},
          send: () async => throw StateError('fixture-send-failure'),
          persistCompletion: (_) async {
            completed = true;
          },
        ),
        throwsStateError,
      );
      expect(completed, isFalse);
      expect(row.guid, 'temp-12345678');
      expect(row.stagingGuid, _stable);
      expect(row.id, 17);
    },
  );

  test('persistence failure prevents native submission', () async {
    var sent = false;
    await expectLater(
      submitTrackedIMessageReaction(
        message: _pending(),
        stableGuid: _stable,
        persistPending: () async => throw StateError('fixture-store-failure'),
        send: () async {
          sent = true;
          return false;
        },
        persistCompletion: (_) async {},
      ),
      throwsStateError,
    );
    expect(sent, isFalse);
  });

  test(
    'remove and nullable target part survive the submission unchanged',
    () async {
      for (final part in <int?>[null, 0, 2]) {
        final row = _pending()
          ..associatedMessageType = '-love'
          ..associatedMessagePart = part;
        await submitTrackedIMessageReaction(
          message: row,
          stableGuid: _stable,
          persistPending: () async {},
          send: () async => false,
          persistCompletion: (_) async {},
        );
        expect(row.associatedMessageGuid, 'parent-guid');
        expect(row.associatedMessageType, '-love');
        expect(row.associatedMessagePart, part);
      }
    },
  );
}
