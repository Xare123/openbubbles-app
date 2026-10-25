import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_windows_writer.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory directory;
  late Store store;
  setUp(() async {
    directory = await Directory(
      'test/backend_harness',
    ).createTemp('archive-queue-');
    store = await openStore(directory: directory.path);
  });
  tearDown(() async {
    store.close();
    final resolved = directory.resolveSymbolicLinksSync();
    expect(
      path.isWithin(
        Directory('test/backend_harness').resolveSymbolicLinksSync(), resolved,
      ),
      isTrue,
    );
    expect(path.basename(resolved), startsWith('archive-queue-'));
    await directory.delete(recursive: true);
  });
  void send(String key, int state, {String account = 'a', String? readback}) =>
      store.box<CloudSyncLocalSendIntentEntity>().put(
        CloudSyncLocalSendIntentEntity(
          intentKey: key,
          accountFingerprint: account,
          writerEpoch: 1,
          localMessageId: 1,
          messageGuidHash: 'hash',
          sourceSha256: 'digest',
          state: state,
          confirmedReadbackBindingSha256: readback,
          createdAtMs: 1,
          updatedAtMs: 1,
        ),
      );
  void outbox(String key, int state, {String account = 'a', String? lease}) =>
      store.box<CloudOutboxOperationEntity>().put(
        CloudOutboxOperationEntity(
          operationId: key,
          accountFingerprint: account,
          scopeKey: 'scope',
          zone: 'zone',
          logicalEntityKeyHash: 'hash',
          action: 0,
          mutationRevision: 1,
          state: state,
          protectedLeaseReference: lease,
          createdAtMs: 1,
          updatedAtMs: 1,
        ),
      );

  test(
    'zero inventory and completed retained rows do not imply archive proof',
    () {
      expect(backendHarnessArchiveQueueCounts(store, 'a'), {
        'ready_intents': 0,
        'held_intents': 0,
        'unresolved_operations': 0,
      });
      send('done', 2, readback: 'digest');
      outbox('done', 2);
      expect(
        backendHarnessArchiveQueueCounts(store, 'a')['unresolved_operations'],
        0,
      );
    },
  );

  test(
    'held, ready and save-only sources stay visible with account fencing',
    () {
      send('awaiting-ids', 0);
      send('ready', 1);
      send('promotion-deferred', 3);
      send('adopted-no-readback', 2);
      send('other-account', 0, account: 'other');
      outbox('retained-lease', 2, lease: 'lease');
      outbox('pending', 0);
      outbox('uncertain', 5);
      outbox('other-account', 5, account: 'other');
      expect(backendHarnessArchiveQueueCounts(store, 'a'), {
        'ready_intents': 2,
        'held_intents': 1,
        'unresolved_operations': 4,
      });
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 5);
      expect(store.box<CloudOutboxOperationEntity>().count(), 4);
    },
  );
}
