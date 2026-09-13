// Opt-in proof over verified before/after copies only. No native bridge,
// account access, network, message content output or canonical mutations.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_source_resolver.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

T _one<T>(Query<T> query) {
  try {
    query.limit = 2;
    final rows = query.find();
    if (rows.length != 1) throw StateError('copy_proof_identity_not_unique');
    return rows.single;
  } finally {
    query.close();
  }
}

void main() {
  final root = Platform.environment['OPENBUBBLES_ATTACHMENT_DATE_COPIES'];
  final proof = Platform.environment['OPENBUBBLES_ATTACHMENT_DATE_PROOF'];
  test(
    'repaired attachment dates commit exact sources and canonical links',
    () async {
      expect(root, isNotEmpty);
      expect(proof, isNotEmpty);
      expect(File('$root/before/data.mdb').existsSync(), isTrue);
      expect(File('$root/after/data.mdb').existsSync(), isTrue);
      final evidence = jsonDecode(File(proof!).readAsStringSync()) as Map;
      final hashes = (evidence['cases'] as List)
          .map((item) => (item as Map)['record_hash'] as String)
          .toSet();
      expect(hashes.length, 8);
      expect(
        hashes.every((hash) => RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(hash)),
        isTrue,
      );
      Store? before;
      Store? after;
      try {
        before = await openStore(directory: '$root/before');
        after = await openStore(directory: '$root/after');
        final snapshots =
            <String, (CloudSemanticSnapshotEntity, CloudInboxChangeEntity)>{};
        for (final hash in hashes) {
          final old = _one(
            before
                .box<CloudInboxChangeEntity>()
                .query(
                  CloudInboxChangeEntity_.serverRecordIdHash
                      .equals(hash)
                      .and(
                        CloudInboxChangeEntity_.zone.equals(
                          'attachmentManateeZone',
                        ),
                      )
                      .and(
                        CloudInboxChangeEntity_.status.equals(
                          CloudInboxStatus.retainedUnprojected.index,
                        ),
                      )
                      .and(
                        CloudInboxChangeEntity_.failureCategory.equals(
                          'malformedRecord',
                        ),
                      ),
                )
                .build(),
          );
          final current = _one(
            after
                .box<CloudInboxChangeEntity>()
                .query(CloudInboxChangeEntity_.changeKey.equals(old.changeKey))
                .build(),
          );
          expect(current.status, CloudInboxStatus.applied.index);
          expect(
            current.generation == old.generation &&
                current.scopeKey == old.scopeKey &&
                current.accountFingerprint == old.accountFingerprint &&
                current.etagHash == old.etagHash &&
                current.encryptedPayloadRef == old.encryptedPayloadRef &&
                current.payloadSha256 == old.payloadSha256,
            isTrue,
          );
          final map = _one(
            after
                .box<CloudRecordMapEntity>()
                .query(
                  CloudRecordMapEntity_.scopeKey
                      .equals(old.scopeKey)
                      .and(
                        CloudRecordMapEntity_.generation.equals(old.generation),
                      )
                      .and(
                        CloudRecordMapEntity_.serverRecordIdHash.equals(hash),
                      ),
                )
                .build(),
          );
          expect(map.etagHash == old.etagHash, isTrue);
          final snapshot = _one(
            after
                .box<CloudSemanticSnapshotEntity>()
                .query(
                  CloudSemanticSnapshotEntity_.scopeKey
                      .equals(old.scopeKey)
                      .and(
                        CloudSemanticSnapshotEntity_.generation.equals(
                          old.generation,
                        ),
                      )
                      .and(
                        CloudSemanticSnapshotEntity_.entityKind.equals(
                          'attachment',
                        ),
                      )
                      .and(
                        CloudSemanticSnapshotEntity_.logicalEntityKeyHash
                            .equals(map.logicalEntityKeyHash),
                      ),
                )
                .build(),
          );
          expect(snapshot.etagHash == old.etagHash, isTrue);
          expect(
            snapshot.createdAtMs,
            inInclusiveRange(978307200000, 4102444799999),
          );
          expect(snapshot.canonicalGuidLookupHash, isNotNull);
          expect(
            snapshots.containsKey(snapshot.canonicalGuidLookupHash),
            isFalse,
          );
          snapshots[snapshot.canonicalGuidLookupHash!] = (snapshot, current);
        }
        final sample = snapshots.values.first.$1;
        expect(
          snapshots.values.every(
            (pair) =>
                pair.$1.scopeKey == sample.scopeKey &&
                pair.$1.generation == sample.generation,
          ),
          isTrue,
        );
        final scope = CloudSyncScope(
          accountFingerprint: sample.accountFingerprint,
          container: sample.container,
          database: sample.database,
          zone: sample.zone,
          streamKind: CloudSyncStreamKind.values.byName(sample.streamKind),
          schemaVersion: sample.schemaVersion,
          persistenceLane: CloudSyncPersistenceLane.semantic,
        );
        final attachments = after.box<Attachment>();
        final query = attachments.query().build();
        late final List<int> ids;
        try {
          ids = query.findIds();
        } finally {
          query.close();
        }
        expect(ids.length, lessThan(100000));
        final matched = <String>{};
        final resolver = CloudAttachmentSourceResolver(store: after);
        for (final id in ids) {
          final attachment = attachments.get(id)!;
          final guid = attachment.guid;
          if (guid == null ||
              guid.isEmpty ||
              guid.length > 1024 ||
              guid.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
            continue;
          }
          final lookup = CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: scope,
            generation: sample.generation,
            canonicalGuid: guid,
          );
          final pair = snapshots[lookup];
          if (pair == null) continue;
          expect(matched.add(lookup), isTrue);
          expect(attachment.message.targetId, greaterThan(0));
          expect(attachment.message.target, isNotNull);
          final source = resolver.resolve(
            scope: scope,
            generation: sample.generation,
            canonicalGuid: guid,
          );
          expect(
            source.recordIdHash == pair.$2.serverRecordIdHash &&
                source.etagHash == pair.$2.etagHash &&
                source.inboxChange.changeKey == pair.$2.changeKey,
            isTrue,
          );
        }
        expect(matched.length, hashes.length);
        print(
          'attachment_date_copy_proof=${jsonEncode({'exact_records': hashes.length, 'applied_records': snapshots.length, 'canonical_parent_links_and_download_sources': matched.length, 'live_profile_opened': false, 'media_bytes_downloaded': false})}',
        );
      } finally {
        after?.close();
        before?.close();
      }
    },
    skip: root == null,
  );
}
