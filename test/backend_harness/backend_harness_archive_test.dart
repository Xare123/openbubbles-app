import 'dart:async';

import 'package:bluebubbles/backend_harness/backend_harness_archive.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final identity = CloudSyncAutomaticArchiveIdentity(
    accountFingerprint: List.filled(43, 'a').join(),
    protectedStoreIdentity: 'obcs2.store.${List.filled(43, 'b').join()}',
    ownershipEpoch: 7,
  );
  final expected = CloudSyncAutomaticArchivePreference(
    identity: identity,
    storedValue: null,
  );
  Map<String, Object?> scope(String id, {bool ack = true}) => {
    'confirmationId': id,
    'enabled': true,
    'acknowledgeQueuedUploads': ack,
    'includeReceived': true,
    'includeReceivedMedia': true,
  };
  String confirmation(BackendHarnessPayload value) => value.challenge!.id;

  test(
    'the exact native-bound preference reaches the normal writer once',
    () async {
      var writes = 0;
      final adapter = BackendHarnessArchive(
        read: () async => expected,
        write: (actual, enabled, ack, received, media) async {
          writes++;
          expect(identical(actual, expected), isTrue);
          expect([enabled, ack, received, media], everyElement(isTrue));
          return expected;
        },
      );
      final id = confirmation(await adapter.prepare());
    await expectLater(
      adapter.setScope(scope(id, ack: false)),
        throwsA(isA<BackendHarnessFailure>()),
      );
      expect(writes, 0);
      await adapter.setScope(scope(id));
      expect(writes, 1);
      await expectLater(
        adapter.setScope(scope(id)),
        throwsA(isA<BackendHarnessFailure>()),
      );
      expect(writes, 1);
    },
  );

  test(
    'uncertain preference save consumes confirmation before returning',
    () async {
      final entered = Completer<void>();
      final result = Completer<CloudSyncAutomaticArchivePreference>();
      var writes = 0;
      final adapter = BackendHarnessArchive(
        read: () async => expected,
        write: (_, _, _, _, _) {
          writes++;
          entered.complete();
          return result.future;
        },
      );
      final id = confirmation(await adapter.prepare());
      final pending = adapter.setScope(scope(id));
      await entered.future;
      await expectLater(
        adapter.setScope(scope(id)),
        throwsA(isA<BackendHarnessFailure>()),
      );
      expect(writes, 1);
      result.completeError(StateError('synthetic save uncertainty'));
      await expectLater(pending, throwsStateError);
      expect(writes, 1);
    },
  );

  test('expired or replaced confirmations cannot reach the writer', () async {
    var now = DateTime.utc(2026, 10, 24);
    var writes = 0;
    final adapter = BackendHarnessArchive(
      read: () async => expected,
      now: () => now,
      write: (_, _, _, _, _) async {
        writes++;
        return expected;
      },
    );
    final first = confirmation(await adapter.prepare());
    final second = confirmation(await adapter.prepare());
    await expectLater(
      adapter.setScope(scope(first)),
      throwsA(isA<BackendHarnessFailure>()),
    );
    now = now.add(const Duration(minutes: 2));
    await expectLater(
      adapter.setScope(scope(second)),
      throwsA(isA<BackendHarnessFailure>()),
    );
    expect(writes, 0);
  });
}
