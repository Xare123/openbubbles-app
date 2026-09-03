import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_sync_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('returns immediately when no semantic pull is active', () async {
    await waitForCloudAttachmentSyncGate(null);
  });

  test('waits for the active semantic pull to finish', () async {
    final pull = Completer<Object?>();
    var released = false;

    final waiting = waitForCloudAttachmentSyncGate(pull.future).then((_) {
      released = true;
    });

    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);

    pull.complete();
    await waiting;
    expect(released, isTrue);
  });

  test('releases after a failed semantic pull', () async {
    final pull = Completer<Object?>();
    final waiting = waitForCloudAttachmentSyncGate(pull.future);

    pull.completeError(StateError('read failed'));

    await expectLater(waiting, completes);
  });
}
