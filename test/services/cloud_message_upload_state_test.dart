import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_message_upload_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes desktop sync and manual attachment operations', () async {
    final coordinator = CloudKitOperationCoordinator();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = coordinator.run(() async {
      events.add('first-start');
      firstStarted.complete();
      await releaseFirst.future;
      events.add('first-end');
    });
    await firstStarted.future;

    final second = coordinator.run(() async {
      events.add('second-start');
    });
    await Future<void>.delayed(Duration.zero);

    expect(events, ['first-start']);

    releaseFirst.complete();
    await Future.wait([first, second]);

    expect(events, ['first-start', 'first-end', 'second-start']);
  });

  test('only explicit CloudKit successes are confirmed', () {
    final result = CloudMessageSaveOutcome.fromResponse(
      attemptedRecordIds: const ['saved', 'failed'],
      response: const {
        'saved': true,
        'failed': false,
      },
    );

    expect(result.confirmedRecordIds, {'saved'});
    expect(result.retryableRecordIds, {'failed'});
  });

  test('missing and unrelated response records never suppress retries', () {
    final result = CloudMessageSaveOutcome.fromResponse(
      attemptedRecordIds: const ['saved', 'missing'],
      response: const {
        'saved': true,
        'unrelated': true,
      },
    );

    expect(result.confirmedRecordIds, {'saved'});
    expect(result.retryableRecordIds, {'missing'});
  });

  test('failed attachment records keep their owning messages retryable', () {
    final result = CloudAttachmentSaveOutcome.fromResponse(
      attemptedRecordIds: const ['saved-attachment', 'failed-attachment'],
      response: const {
        'saved-attachment': true,
        'failed-attachment': false,
      },
      messageRecordIdByAttachmentRecordId: const {
        'saved-attachment': 'saved-message',
        'failed-attachment': 'retry-message',
      },
    );

    expect(result.confirmedRecordIds, {'saved-attachment'});
    expect(result.retryableRecordIds, {'failed-attachment'});
    expect(result.retryableMessageRecordIds, {'retry-message'});
  });

  test('missing attachment results are retryable without inventing an owner', () {
    final result = CloudAttachmentSaveOutcome.fromResponse(
      attemptedRecordIds: const ['owned', 'chat-photo'],
      response: const {},
      messageRecordIdByAttachmentRecordId: const {
        'owned': 'message',
      },
    );

    expect(result.retryableRecordIds, {'owned', 'chat-photo'});
    expect(result.retryableMessageRecordIds, {'message'});
  });
}
