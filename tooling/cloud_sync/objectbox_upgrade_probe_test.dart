import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens a copied pre-V2 ObjectBox database with the current generated model.
///
/// Invoke explicitly with `OPENBUBBLES_OBJECTBOX_UPGRADE_SOURCE` set to the
/// directory containing `data.mdb`. The source is hashed before and after and
/// is never opened directly. This probe reads only entity counts, never message
/// content, handles, attachment names, or other user data.
void main() {
  test(
    'current model opens a copied legacy database without touching the source',
    () async {
      final sourceDirectory =
          Platform.environment['OPENBUBBLES_OBJECTBOX_UPGRADE_SOURCE'];
      if (sourceDirectory == null || sourceDirectory.isEmpty) {
        fail('OPENBUBBLES_OBJECTBOX_UPGRADE_SOURCE is required');
      }

      final source = File('$sourceDirectory${Platform.pathSeparator}data.mdb');
      expect(source.existsSync(), isTrue, reason: 'legacy data.mdb is missing');
      final sourceDigestBefore = sha256.convert(await source.readAsBytes());

      final temporary = await Directory.systemTemp.createTemp(
        'openbubbles-objectbox-upgrade-',
      );
      addTearDown(() async {
        final resolved = temporary.absolute.path;
        final systemTemp = Directory.systemTemp.absolute.path;
        if (!resolved.startsWith(systemTemp) ||
            !temporary.uri.pathSegments.any(
              (segment) => segment.startsWith('openbubbles-objectbox-upgrade-'),
            )) {
          fail('refusing to remove an unexpected probe directory');
        }
        if (temporary.existsSync()) await temporary.delete(recursive: true);
      });

      await source.copy('${temporary.path}${Platform.pathSeparator}data.mdb');
      final store = await openStore(directory: temporary.path);
      try {
        final canonicalCounts = <String, int>{
          'chats': store.box<Chat>().count(),
          'messages': store.box<Message>().count(),
          'attachments': store.box<Attachment>().count(),
        };
        expect(canonicalCounts.values.every((count) => count >= 0), isTrue);
        expect(store.box<CloudInboxChangeEntity>().count(), 0);
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
        expect(store.box<CloudRecordMapEntity>().count(), 0);
        expect(store.box<CloudSyncCheckpointEntity>().count(), 0);
        expect(store.box<CloudSyncRunEntity>().count(), 0);
        expect(store.box<CloudSyncLeaseEntity>().count(), 0);
        expect(store.box<CloudAttachmentMaterializationEntity>().count(), 0);
        expect(store.box<CloudSemanticReplayEntity>().count(), 0);
        expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
        expect(store.box<CloudProtectedPageLeaseEntity>().count(), 0);
        expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
      } finally {
        store.close();
      }

      expect(sha256.convert(await source.readAsBytes()), sourceDigestBefore);
    },
  );
}
