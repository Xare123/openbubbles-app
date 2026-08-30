import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  final scope = CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'attachmentManateeZone',
  );
  final now = DateTime.utc(2026, 8, 1);
  late Directory directory;
  late Store objectBox;
  late ObjectBoxCloudAttachmentMaterializationStore store;

  CloudAttachmentMaterialization metadata() =>
      CloudAttachmentMaterialization.metadata(
        scope: scope,
        generation: 3,
        logicalEntityKeyHash: 'attachment-key-hash',
        expectedBytes: 10,
        expectedIntegrityTagHash: 'integrity-tag-hash',
        updatedAt: now,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-attachment-state-',
    );
    objectBox = await openStore(directory: directory.path);
    store = ObjectBoxCloudAttachmentMaterializationStore(store: objectBox);
  });

  tearDown(() async {
    objectBox.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('persists protected state and restores it after reopen', () async {
    final initial = metadata();
    expect(await store.create(initial), isTrue);
    final streaming = initial.beginStreaming(
      activeGeneration: 3,
      protectedTempReference: 'protected-temp',
      protectedResumeManifestReference: 'protected-manifest',
      now: now.add(const Duration(seconds: 1)),
    );
    expect(
      await store.compareAndSwap(expected: initial, next: streaming),
      isTrue,
    );

    objectBox.close();
    objectBox = await openStore(directory: directory.path);
    store = ObjectBoxCloudAttachmentMaterializationStore(store: objectBox);
    final restored = await store.read(
      scope: scope,
      generation: 3,
      logicalEntityKeyHash: 'attachment-key-hash',
    );

    expect(restored!.stage, CloudAttachmentMaterializationStage.tempStreaming);
    expect(restored.protectedTempReference, 'protected-temp');
  });

  test(
    'stale compare-and-swap cannot overwrite a newer verified boundary',
    () async {
      final initial = metadata();
      await store.create(initial);
      final streaming = initial.beginStreaming(
        activeGeneration: 3,
        protectedTempReference: 'protected-temp',
        protectedResumeManifestReference: 'protected-manifest-0',
        now: now.add(const Duration(seconds: 1)),
      );
      await store.compareAndSwap(expected: initial, next: streaming);
      final advanced = streaming.recordVerifiedBoundary(
        activeGeneration: 3,
        cumulativeVerifiedBytes: 5,
        protectedResumeManifestReference: 'protected-manifest-1',
        now: now.add(const Duration(seconds: 2)),
      );
      expect(
        await store.compareAndSwap(expected: streaming, next: advanced),
        isTrue,
      );

      final staleAdvance = streaming.recordVerifiedBoundary(
        activeGeneration: 3,
        cumulativeVerifiedBytes: 4,
        protectedResumeManifestReference: 'stale-manifest',
        now: now.add(const Duration(seconds: 3)),
      );
      expect(
        await store.compareAndSwap(expected: streaming, next: staleAdvance),
        isFalse,
      );
      expect(
        (await store.read(
          scope: scope,
          generation: 3,
          logicalEntityKeyHash: 'attachment-key-hash',
        ))!.verifiedBytes,
        5,
      );
    },
  );

  test('account scope and generation cannot bleed', () async {
    await store.create(metadata());
    final other = CloudSyncScope(
      accountFingerprint: testAccountFingerprintB,
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'attachmentManateeZone',
    );

    expect(
      await store.read(
        scope: other,
        generation: 3,
        logicalEntityKeyHash: 'attachment-key-hash',
      ),
      isNull,
    );
    expect(
      await store.read(
        scope: scope,
        generation: 4,
        logicalEntityKeyHash: 'attachment-key-hash',
      ),
      isNull,
    );

    final nextGeneration = CloudAttachmentMaterialization.metadata(
      scope: scope,
      generation: 4,
      logicalEntityKeyHash: 'attachment-key-hash',
      expectedBytes: 10,
      expectedIntegrityTagHash: 'next-generation-integrity-tag',
      updatedAt: now.add(const Duration(minutes: 1)),
    );
    expect(await store.create(nextGeneration), isTrue);
    expect(
      await store.read(
        scope: scope,
        generation: 4,
        logicalEntityKeyHash: 'attachment-key-hash',
      ),
      isNotNull,
    );
  });
}
