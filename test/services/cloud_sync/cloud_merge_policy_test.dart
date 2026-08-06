import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = CloudMergePolicy();
  final baseTime = DateTime.utc(2026, 7, 31);

  CloudSemanticSnapshot message({
    String content = 'content-digest-a',
    DateTime? readAt,
    DateTime? deliveredAt,
    Map<String, CloudEditPart> edits = const {},
    DateTime? retractedAt,
    String etag = 'etag-a',
  }) {
    return CloudSemanticSnapshot(
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: 'message-key-digest',
      immutableContentDigest: content,
      readAt: readAt,
      deliveredAt: deliveredAt,
      editParts: edits,
      retractedAt: retractedAt,
      etagHash: etag,
      encryptedRawRecordReference: 'protected:$etag',
    );
  }

  test('creates an absent entity without exposing content', () {
    final incoming = message();
    final result = policy.merge(local: null, incoming: incoming);

    expect(result.action, CloudMergeAction.create);
    expect(result.snapshot, same(incoming));
  });

  test('quarantines conflicting immutable content', () {
    final result = policy.merge(
      local: message(),
      incoming: message(content: 'content-digest-b'),
    );

    expect(result.action, CloudMergeAction.quarantine);
    expect(
      result.conflicts,
      contains(CloudMergeConflict.immutableContentMismatch),
    );
  });

  test('fills missing canonical digest without replacing a valid one', () {
    final local = CloudSemanticSnapshot(
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: 'message-key-digest',
      etagHash: 'etag-a',
    );
    final incoming = message();

    final result = policy.merge(local: local, incoming: incoming);

    expect(result.action, CloudMergeAction.update);
    expect(result.snapshot!.immutableContentDigest, 'content-digest-a');
  });

  test('read and delivery timestamps move monotonically forward', () {
    final result = policy.merge(
      local: message(
        readAt: baseTime.add(const Duration(minutes: 5)),
        deliveredAt: baseTime.add(const Duration(minutes: 3)),
      ),
      incoming: message(
        readAt: baseTime.add(const Duration(minutes: 2)),
        deliveredAt: baseTime.add(const Duration(minutes: 9)),
        etag: 'etag-b',
      ),
    );

    expect(result.action, CloudMergeAction.update);
    expect(result.snapshot!.readAt, baseTime.add(const Duration(minutes: 5)));
    expect(
      result.snapshot!.deliveredAt,
      baseTime.add(const Duration(minutes: 9)),
    );
  });

  test('unions edits by revision and flags equal-revision conflicts', () {
    final localPart = CloudEditPart(
      partKeyHash: 'part-digest',
      revision: 2,
      contentDigest: 'edit-a',
      modifiedAt: baseTime,
    );
    final incomingPart = CloudEditPart(
      partKeyHash: 'part-digest',
      revision: 2,
      contentDigest: 'edit-b',
      modifiedAt: baseTime.add(const Duration(minutes: 1)),
    );
    final result = policy.merge(
      local: message(edits: {'part-digest': localPart}),
      incoming: message(edits: {'part-digest': incomingPart}, etag: 'etag-b'),
    );

    expect(result.snapshot!.editParts['part-digest']!.contentDigest, 'edit-a');
    expect(result.conflicts, contains(CloudMergeConflict.editRevisionMismatch));
  });

  test('newer retraction wins and older retraction cannot undo it', () {
    final currentRetraction = baseTime.add(const Duration(minutes: 5));
    final result = policy.merge(
      local: message(retractedAt: currentRetraction),
      incoming: message(retractedAt: baseTime.add(const Duration(minutes: 2))),
    );

    expect(result.snapshot!.retractedAt, currentRetraction);
  });

  test('higher group version wins while equal conflict retains local base', () {
    CloudSemanticSnapshot chat(int version, String metadata, String etag) {
      return CloudSemanticSnapshot(
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: 'chat-key-digest',
        groupVersion: version,
        groupMetadataDigest: metadata,
        etagHash: etag,
        encryptedRawRecordReference: 'protected:$etag',
      );
    }

    final higher = policy.merge(
      local: chat(3, 'metadata-a', 'etag-a'),
      incoming: chat(4, 'metadata-b', 'etag-b'),
    );
    expect(higher.snapshot!.groupVersion, 4);
    expect(higher.snapshot!.groupMetadataDigest, 'metadata-b');

    final equalConflict = policy.merge(
      local: chat(4, 'metadata-b', 'etag-b'),
      incoming: chat(4, 'metadata-c', 'etag-c'),
    );
    expect(equalConflict.snapshot!.groupMetadataDigest, 'metadata-b');
    expect(
      equalConflict.conflicts,
      contains(CloudMergeConflict.equalGroupVersionMismatch),
    );
  });

  test('reaction is deferred until its parent exists', () {
    final reaction = CloudSemanticSnapshot(
      kind: CloudEntityKind.reaction,
      logicalEntityKeyHash: 'reaction-key-digest',
      parentLogicalKeyHash: 'parent-key-digest',
      immutableContentDigest: 'reaction-content-digest',
    );

    final result = policy.merge(
      local: null,
      incoming: reaction,
      parentExists: false,
    );

    expect(result.action, CloudMergeAction.defer);
  });

  test('snapshot timestamps normalize to UTC millisecond precision', () {
    final localTime = DateTime.parse('2026-07-31T09:10:11.123456-07:00');
    final snapshot = CloudSemanticSnapshot(
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: 'message-key-digest',
      createdAt: localTime,
      editParts: {
        'part-digest': CloudEditPart(
          partKeyHash: 'part-digest',
          revision: 1,
          contentDigest: 'content-digest',
          modifiedAt: localTime,
        ),
      },
    );

    expect(snapshot.createdAt!.isUtc, isTrue);
    expect(snapshot.createdAt!.microsecond, 0);
    expect(snapshot.createdAt!.millisecond, 123);
    expect(snapshot.editParts['part-digest']!.modifiedAt.isUtc, isTrue);
    expect(snapshot.editParts['part-digest']!.modifiedAt.microsecond, 0);
  });

  test('copyWith supports an explicit clear without conflating omission', () {
    final original = message(readAt: baseTime, deliveredAt: baseTime);

    final omitted = original.copyWith();
    final cleared = original.copyWith(
      clearReadAt: true,
      clearEtagHash: true,
      clearEncryptedRawRecordReference: true,
    );

    expect(omitted.readAt, baseTime);
    expect(omitted.etagHash, 'etag-a');
    expect(cleared.readAt, isNull);
    expect(cleared.etagHash, isNull);
    expect(cleared.encryptedRawRecordReference, isNull);
    expect(
      () => original.copyWith(readAt: baseTime, clearReadAt: true),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          'cloud_semantic_snapshot_clear_conflict',
        ),
      ),
    );
  });
}
