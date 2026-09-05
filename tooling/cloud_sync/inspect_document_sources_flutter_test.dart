import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_source_resolver.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/utils/attachment_mime_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Local-only aggregate inspection. Never invoke this with credentials on CI.
void main() {
  test('classifies document download sources on an offline copy', () async {
    final input = Platform.environment['OPENBUBBLES_OBJECTBOX_INSPECT_DIR'];
    expect(input, isNotNull);
    final source = File('$input/data.mdb');
    final digest = await sha256.bind(source.openRead()).first;
    final scratch = Directory(r'C:\Codex\OpenBubblesReview\scratch');
    final copy = await scratch.createTemp('document-source-check-');
    Store? store;
    try {
      await source.copy('${copy.path}/data.mdb');
      store = await openStore(directory: copy.path);
      final checkpoints = store
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .where(
            (row) =>
                row.container == 'com.apple.messages.cloud' &&
                row.database == 'private' &&
                row.zone == 'attachmentManateeZone' &&
                row.streamKind == 'messages' &&
                row.persistenceLane == 'semantic',
          )
          .toList();
      expect(checkpoints, hasLength(1));
      final checkpoint = checkpoints.single;
      final scope = CloudSyncScope(
        accountFingerprint: checkpoint.accountFingerprint,
        container: checkpoint.container,
        database: checkpoint.database,
        zone: checkpoint.zone,
        streamKind: CloudSyncStreamKind.messages,
        schemaVersion: checkpoint.schemaVersion,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final resolver = CloudAttachmentSourceResolver(store: store);
      final counts = <String, int>{};
      var documents = 0;
      store.runInTransaction(TxMode.read, () {
        for (final attachment in store!.box<Attachment>().getAll()) {
          final mime = resolveAttachmentMimeType(
            attachment.transferName ?? '',
            null,
            uti: attachment.uti,
            declaredMimeType: attachment.mimeType,
          );
          if (mime?.startsWith('image/') == true ||
              mime?.startsWith('video/') == true ||
              mime?.startsWith('audio/') == true) {
            continue;
          }
          documents++;
          final type = switch (mime) {
            'application/pdf' => 'pdf',
            'application/msword' ||
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
              'word',
            'application/zip' => 'zip',
            'text/plain' => 'text',
            _ => 'other',
          };
          final metadata = attachment.metadata;
          final lane = cloudAttachmentDownloadLaneFor(metadata).name;
          final capability =
              cloudAttachmentBodyCapabilityFor(metadata)?.name ?? 'unspecified';
          var sourceState = 'notV2';
          if (hasCloudAttachmentV2Provenance(metadata)) {
            try {
              resolver.resolve(
                scope: scope,
                generation: checkpoint.generation,
                canonicalGuid: attachment.guid ?? '',
              );
              sourceState = 'resolved';
            } on CloudAttachmentSourceResolutionFailure catch (failure) {
              sourceState = failure.code.name;
            }
          }
          final size = (attachment.totalBytes ?? 0) > 0
              ? 'positiveSize'
              : 'missingOrZeroSize';
          final key = '$type/$lane/$capability/$sourceState/$size';
          counts.update(key, (value) => value + 1, ifAbsent: () => 1);
        }
      });
      final unchanged = (await sha256.bind(source.openRead()).first) == digest;
      expect(unchanged, isTrue);
      // Only closed vocabularies and counts, no names, IDs, bodies or paths.
      // ignore: avoid_print
      print(
        'DOCUMENT_SOURCE_REPORT=${jsonEncode({'documents': documents, 'classifications': counts, 'remoteCalls': 0, 'sourceUnchanged': unchanged})}',
      );
    } finally {
      store?.close();
      if (copy.parent.absolute.path != scratch.absolute.path ||
          !copy.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('document-source-check-')) {
        throw StateError('document_inspection_cleanup_target_invalid');
      }
      await copy.delete(recursive: true);
    }
  });
}
