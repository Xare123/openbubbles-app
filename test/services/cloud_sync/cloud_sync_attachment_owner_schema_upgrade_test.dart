import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:objectbox/internal.dart' as obx;

/// Schema upgrade: CloudAttachmentUploadEntity gains ownerKind (23) and
/// ownerIntentId (24) with no index changes. Legacy rows keep every field
/// and read back both new columns as 0; a historical row keeps kind 1, its
/// owner intent, and localSendIntentId 0 without colliding.
///
/// NOTE: authored, not executed here. The host blocks the native ObjectBox
/// DLL (Application Control 4551), so no database test can run locally.
/// Parent runs hosted qualification.
void main() {
  test('owner columns upgrade preserves legacy rows and isolates history', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ob-attachment-owner-upgrade-',
    );
    final current = getObjectBoxModel();
    final beforeMap = current.model.toMap();
    final entity =
        (beforeMap['entities'] as List).singleWhere(
              (e) => e['name'] == 'CloudAttachmentUploadEntity',
            )
            as Map;
    (entity['properties'] as List).removeWhere(
      (p) => const ['ownerKind', 'ownerIntentId'].contains(p['name']),
    );
    entity['lastPropertyId'] = '22:4262532899867805764';
    final before = obx.ModelDefinition(
      obx.ModelInfo.fromMap(beforeMap),
      current.bindings,
    );
    Store? store;
    try {
      store = Store(before, directory: directory.path);
      String key(String tag) => 'synthetic-upload-key-$tag';
      int putRow({
        required String tag,
        required int state,
        String? attemptId,
        String? result,
        String? admittedOperationId,
      }) => store!.box<CloudAttachmentUploadEntity>().put(
        CloudAttachmentUploadEntity(
          uploadKey: key(tag),
          accountFingerprint: 'A' * 43,
          writerEpoch: 2,
          checkpointGeneration: 1,
          localSendIntentId: 5,
          messageGuidHash: 'b' * 64,
          sourceSha256: 'c' * 64,
          protectedStoreIdentity: 'obcs2.store.${'S' * 43}',
          attachmentKeyHash: 'K' * 43,
          serverRecordIdHash: 'M' * 43,
          planReference: 'obcs2.ref.${'P' * 43}',
          planLeaseReference: 'obcs2.lease.${'e' * 32}',
          planPayloadSha256: 'd' * 64,
          state: state,
          attemptId: attemptId,
          resultReference: result,
          resultLeaseReference: result == null
              ? null
              : 'obcs2.lease.${'f' * 32}',
          resultPayloadSha256: result == null ? null : 'e' * 64,
          admittedOperationId: admittedOperationId,
          createdAtMs: 1000,
          updatedAtMs: 2000,
        ),
      );
      const attempt = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      final admitted = 'op1:${'d' * 64}';
      final prepared = putRow(tag: 'prepared', state: 0);
      final started = putRow(tag: 'started', state: 1, attemptId: attempt);
      final unknown = putRow(tag: 'unknown', state: 4, attemptId: attempt);
      final uploaded = putRow(
        tag: 'uploaded',
        state: 2,
        attemptId: attempt,
        result: 'obcs2.ref.${'R' * 43}',
      );
      final adopted = putRow(
        tag: 'adopted',
        state: 3,
        attemptId: attempt,
        result: 'obcs2.ref.${'R' * 43}',
        admittedOperationId: admitted,
      );
      store.close();
      for (var restart = 0; restart < 2; restart++) {
        store = await openStore(directory: directory.path);
        for (final entry in [
          ('prepared', prepared, 0, null, null, null),
          ('started', started, 1, attempt, null, null),
          ('unknown', unknown, 4, attempt, null, null),
          ('uploaded', uploaded, 2, attempt, 'obcs2.ref.${'R' * 43}', null),
          (
            'adopted',
            adopted,
            3,
            attempt,
            'obcs2.ref.${'R' * 43}',
            admitted,
          ),
        ]) {
          final row = store.box<CloudAttachmentUploadEntity>().get(entry.$2)!;
          expect(row.uploadKey, key(entry.$1));
          expect(row.state, entry.$3);
          expect(row.attemptId, entry.$4);
          expect(row.resultReference, entry.$5);
          expect(row.admittedOperationId, entry.$6);
          expect(row.localSendIntentId, 5);
          expect(row.ownerKind, 0);
          expect(row.ownerIntentId, 0);
          expect(row.writerEpoch, 2);
          expect(row.checkpointGeneration, 1);
          expect(row.accountFingerprint, 'A' * 43);
          expect(row.protectedStoreIdentity, 'obcs2.store.${'S' * 43}');
          expect(row.attachmentKeyHash, 'K' * 43);
          expect(row.serverRecordIdHash, 'M' * 43);
          expect(row.planReference, 'obcs2.ref.${'P' * 43}');
          expect(row.planLeaseReference, 'obcs2.lease.${'e' * 32}');
          expect(row.planPayloadSha256, 'd' * 64);
          expect(row.resultLeaseReference,
              entry.$5 == null ? null : 'obcs2.lease.${'f' * 32}');
          expect(row.resultPayloadSha256, entry.$5 == null ? null : 'e' * 64);
          expect(row.messageGuidHash, 'b' * 64);
          expect(row.sourceSha256, 'c' * 64);
          expect(row.createdAtMs, 1000);
          expect(row.updatedAtMs, 2000);
        }
        store.close();
      }
      store = await openStore(directory: directory.path);
      final historical = store.box<CloudAttachmentUploadEntity>().put(
        CloudAttachmentUploadEntity(
          uploadKey: key('historical'),
          accountFingerprint: 'A' * 43,
          writerEpoch: 2,
          checkpointGeneration: 1,
          localSendIntentId: 0,
          ownerKind: 1,
          ownerIntentId: 9,
          messageGuidHash: 'b' * 64,
          sourceSha256: 'c' * 64,
          protectedStoreIdentity: 'obcs2.store.${'S' * 43}',
          attachmentKeyHash: 'H' * 43,
          serverRecordIdHash: 'M' * 43,
          planReference: 'obcs2.ref.${'P' * 43}',
          planLeaseReference: 'obcs2.lease.${'e' * 32}',
          planPayloadSha256: 'd' * 64,
          state: 0,
          createdAtMs: 1000,
          updatedAtMs: 2000,
        ),
      );
      store.close();
      store = await openStore(directory: directory.path);
      final retained = store.box<CloudAttachmentUploadEntity>().get(historical)!;
      expect([prepared, started, unknown, uploaded, adopted], isNot(contains(historical)));
      expect(store.box<CloudAttachmentUploadEntity>().count(), 6);
      expect(retained.ownerKind, 1);
      expect(retained.ownerIntentId, 9);
      expect(retained.localSendIntentId, 0);
      expect(retained.uploadKey, key('historical'));
      final legacy = store.box<CloudAttachmentUploadEntity>().get(prepared)!;
      expect(legacy.ownerKind, 0);
      expect(legacy.ownerIntentId, 0);
      expect(legacy.localSendIntentId, 5);
      store.close();
    } finally {
      if (store != null && !store.isClosed()) store.close();
      if (directory.existsSync()) await directory.delete(recursive: true);
    }
  });
}
