import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_download_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_production_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_source_resolver.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('production attachment evidence probe', () {
    late CloudSyncNativeAuthSnapshot auth;

    setUp(() {
      auth = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'session',
        accountFingerprint: _repeat('a', 43),
        protectedStoreIdentity: 'obcs2.store.${_repeat('b', 43)}',
        cloudMessagesClient: Object(),
      );
    });

    test('missing auth is unavailable without reading local state', () async {
      var generationReads = 0;
      var downloads = 0;
      final adapter = CloudAttachmentProductionAdapter(
        readAuthSnapshot: () async => null,
        readActiveGeneration: (_) async {
          generationReads++;
          return 1;
        },
        resolveSource: _unexpectedResolver,
        download: ({required canonicalGuid, required expectedBytes}) async {
          downloads++;
          return CloudAttachmentDownloadUnavailable(
            CloudAttachmentSourceResolutionCode.missingSource,
          );
        },
      );

      final result = await adapter.downloadIfAvailable(
        canonicalGuid: 'attachment-guid',
        expectedBytes: 8,
      );

      expect(
        (result as CloudAttachmentDownloadUnavailable).code,
        CloudAttachmentSourceResolutionCode.missingIdentity,
      );
      expect(generationReads, 0);
      expect(downloads, 0);
    });

    test(
      'missing checkpoint is unavailable without coordinator work',
      () async {
        var resolves = 0;
        var downloads = 0;
        final adapter = CloudAttachmentProductionAdapter(
          readAuthSnapshot: () async => auth,
          readActiveGeneration: (_) async => null,
          resolveSource:
              ({required scope, required generation, required canonicalGuid}) {
                resolves++;
                return _dummySource(scope, generation);
              },
          download: ({required canonicalGuid, required expectedBytes}) async {
            downloads++;
            return CloudAttachmentDownloadUnavailable(
              CloudAttachmentSourceResolutionCode.missingSource,
            );
          },
        );

        final result = await adapter.downloadIfAvailable(
          canonicalGuid: 'attachment-guid',
          expectedBytes: 8,
        );

        expect(
          (result as CloudAttachmentDownloadUnavailable).code,
          CloudAttachmentSourceResolutionCode.missingSource,
        );
        expect(resolves, 0);
        expect(downloads, 0);
      },
    );

    test(
      'explicit missing source permits fallback without coordinator',
      () async {
        var downloads = 0;
        final adapter = CloudAttachmentProductionAdapter(
          readAuthSnapshot: () async => auth,
          readActiveGeneration: (_) async => 7,
          resolveSource:
              ({required scope, required generation, required canonicalGuid}) =>
                  throw const CloudAttachmentSourceResolutionFailure(
                    CloudAttachmentSourceResolutionCode.pendingSource,
                  ),
          download: ({required canonicalGuid, required expectedBytes}) async {
            downloads++;
            return CloudAttachmentDownloadUnavailable(
              CloudAttachmentSourceResolutionCode.missingSource,
            );
          },
        );

        final result = await adapter.downloadIfAvailable(
          canonicalGuid: 'attachment-guid',
          expectedBytes: 8,
        );

        expect(
          (result as CloudAttachmentDownloadUnavailable).code,
          CloudAttachmentSourceResolutionCode.pendingSource,
        );
        expect(downloads, 0);
      },
    );

    test('exact source delegates once using the attachment V2 scope', () async {
      CloudSyncScope? resolvedScope;
      var downloads = 0;
      final sentinel = CloudAttachmentDownloadUnavailable(
        CloudAttachmentSourceResolutionCode.quarantinedSource,
      );
      final adapter = CloudAttachmentProductionAdapter(
        readAuthSnapshot: () async => auth,
        readActiveGeneration: (scope) async {
          expect(scope.zone, 'attachmentManateeZone');
          expect(scope.persistenceLane, CloudSyncPersistenceLane.semanticV2);
          return 7;
        },
        resolveSource:
            ({required scope, required generation, required canonicalGuid}) {
              resolvedScope = scope;
              expect(generation, 7);
              expect(canonicalGuid, 'attachment-guid');
              return _dummySource(scope, generation);
            },
        download: ({required canonicalGuid, required expectedBytes}) async {
          downloads++;
          expect(canonicalGuid, 'attachment-guid');
          expect(expectedBytes, 8);
          return sentinel;
        },
      );

      final result = await adapter.downloadIfAvailable(
        canonicalGuid: 'attachment-guid',
        expectedBytes: 8,
      );

      expect(identical(result, sentinel), isTrue);
      expect(resolvedScope!.container, 'com.apple.messages.cloud');
      expect(resolvedScope!.database, 'private');
      expect(downloads, 1);
    });

    test('ambiguous evidence invokes the fail-closed coordinator', () async {
      var downloads = 0;
      final adapter = CloudAttachmentProductionAdapter(
        readAuthSnapshot: () async => auth,
        readActiveGeneration: (_) async => 7,
        resolveSource:
            ({required scope, required generation, required canonicalGuid}) =>
                throw const CloudAttachmentSourceResolutionFailure(
                  CloudAttachmentSourceResolutionCode.ambiguousSource,
                ),
        download: ({required canonicalGuid, required expectedBytes}) async {
          downloads++;
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'cloud_attachment_source_conflict',
          );
        },
      );

      await expectLater(
        adapter.downloadIfAvailable(
          canonicalGuid: 'attachment-guid',
          expectedBytes: 8,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_attachment_source_conflict',
          ),
        ),
      );
      expect(downloads, 1);
    });

    test(
      'cold auth capture delegates to the fail-closed coordinator',
      () async {
        var downloads = 0;
        final adapter = CloudAttachmentProductionAdapter(
          readAuthSnapshot: () async => throw StateError('fixed-auth-failure'),
          readActiveGeneration: (_) async => 7,
          resolveSource: _unexpectedResolver,
          download: ({required canonicalGuid, required expectedBytes}) async {
            downloads++;
            throw CloudSyncFailure(
              category: CloudFailureCategory.authorization,
              safeCode: 'cloud_attachment_account_changed',
            );
          },
        );

        await expectLater(
          adapter.downloadIfAvailable(
            canonicalGuid: 'attachment-guid',
            expectedBytes: 8,
          ),
          throwsA(
            isA<CloudSyncFailure>().having(
              (failure) => failure.safeCode,
              'safeCode',
              'cloud_attachment_account_changed',
            ),
          ),
        );
        expect(downloads, 1);
      },
    );
  });

  group('read-only attachment generation reader', () {
    late Directory directory;
    late Store store;
    late ObjectBoxCloudAttachmentGenerationReader reader;
    late CloudSyncScope scope;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'openbubbles-cloud-attachment-generation-',
      );
      store = await openStore(directory: directory.path);
      reader = ObjectBoxCloudAttachmentGenerationReader(store: store);
      scope = CloudSyncScope(
        accountFingerprint: _repeat('a', 43),
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'attachmentManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semanticV2,
      );
    });

    tearDown(() async {
      store.close();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    test('missing read does not create a checkpoint', () async {
      final box = store.box<CloudSyncCheckpointEntity>();
      expect(box.count(), 0);

      expect(await reader.readIfPresent(scope), isNull);

      expect(box.count(), 0);
    });

    test('returns only the exact existing semantic generation', () async {
      store.box<CloudSyncCheckpointEntity>().put(
        _checkpoint(scope: scope, generation: 7),
      );

      expect(await reader.readIfPresent(scope), 7);
      expect(await reader.readRequired(scope), 7);
    });

    test('same key with mismatched scope fields fails closed', () async {
      final checkpoint = _checkpoint(scope: scope, generation: 7)
        ..accountFingerprint = _repeat('z', 43);
      store.box<CloudSyncCheckpointEntity>().put(checkpoint);

      await expectLater(
        reader.readIfPresent(scope),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_attachment_checkpoint_invalid',
          ),
        ),
      );
    });
  });

  test('V2 provenance marker is exact and content-free', () {
    expect(
      hasCloudAttachmentV2Provenance(<String, dynamic>{
        cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
      }),
      isTrue,
    );
    expect(
      hasCloudAttachmentV2Provenance(<String, dynamic>{
        cloudAttachmentV2MetadataKey: cloudAttachmentV2LegacyMetadataVersion,
      }),
      isTrue,
    );
    expect(
      hasCloudAttachmentV2Provenance(<String, dynamic>{
        cloudAttachmentV2MetadataKey: cloudAttachmentV2NoAssetsMetadataVersion,
      }),
      isTrue,
    );
    expect(
      hasCloudAttachmentV2Provenance(<String, dynamic>{
        cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion + 1,
      }),
      isFalse,
    );
    expect(
      hasCloudAttachmentV2Provenance(<String, dynamic>{
        cloudAttachmentV2MetadataKey: true,
      }),
      isFalse,
    );
    expect(
      hasCloudAttachmentV2Provenance(<String, dynamic>{
        cloudAttachmentV2MetadataKey: 2.0,
      }),
      isFalse,
    );
    expect(hasCloudAttachmentV2Provenance(null), isFalse);
  });

  test(
    'attachment transport selection never downgrades exact V2 provenance',
    () {
      expect(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
          cloudAttachmentV2BodyCapabilityKey:
              CloudAttachmentBodyCapability.materializable.metadataValue,
          'cloud': 'legacy-source',
          'rustpush': 'ids-source',
        }),
        CloudAttachmentDownloadLane.cloudSyncV2,
      );
      expect(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          cloudAttachmentV2MetadataKey: cloudAttachmentV2LegacyMetadataVersion,
          'cloud': 'legacy-source',
          'rustpush': 'ids-source',
        }),
        CloudAttachmentDownloadLane.cloudSyncV2,
      );
      expect(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          cloudAttachmentV2MetadataKey:
              cloudAttachmentV2NoAssetsMetadataVersion,
          cloudAttachmentV2BodyCapabilityKey:
              CloudAttachmentBodyCapability.materializable.metadataValue,
        }),
        CloudAttachmentDownloadLane.cloudSyncV2,
      );
      expect(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          cloudAttachmentV2MetadataKey:
              cloudAttachmentV2NoAssetsMetadataVersion,
          cloudAttachmentV2BodyCapabilityKey: CloudAttachmentBodyCapability
              .metadataOnlyUnsupportedMediaCredentials
              .metadataValue,
        }),
        CloudAttachmentDownloadLane.unavailable,
      );
      expect(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
          cloudAttachmentV2BodyCapabilityKey: CloudAttachmentBodyCapability
              .metadataOnlyUnsupportedMediaCredentials
              .metadataValue,
          'cloud': 'legacy-source',
          'rustpush': 'ids-source',
        }),
        CloudAttachmentDownloadLane.unavailable,
      );
      expect(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
          'cloud': 'legacy-source',
          'rustpush': 'ids-source',
        }),
        CloudAttachmentDownloadLane.unavailable,
      );
      expect(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          'cloud': 'legacy-source',
          'rustpush': 'ids-source',
        }),
        CloudAttachmentDownloadLane.legacyCloudKit,
      );
      expect(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          'rustpush': 'ids-source',
        }),
        CloudAttachmentDownloadLane.ids,
      );
      expect(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          cloudAttachmentV2MetadataKey: true,
          'cloud': 'legacy-source',
          'rustpush': 'ids-source',
        }),
        CloudAttachmentDownloadLane.unavailable,
      );
      expect(
        cloudAttachmentDownloadLaneFor(null),
        CloudAttachmentDownloadLane.unavailable,
      );
    },
  );

  test('V2 download queue and failure cleanup preserve native ownership', () {
    final v2 = <String, dynamic>{
      cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
      cloudAttachmentV2BodyCapabilityKey:
          CloudAttachmentBodyCapability.materializable.metadataValue,
    };
    final legacy = <String, dynamic>{'cloud': 'legacy-source'};

    expect(
      canStartCloudAttachmentDownload(
        candidateLane: cloudAttachmentDownloadLaneFor(v2),
        cloudSyncV2DownloadActive: true,
      ),
      isFalse,
    );
    expect(
      canStartCloudAttachmentDownload(
        candidateLane: cloudAttachmentDownloadLaneFor(legacy),
        cloudSyncV2DownloadActive: true,
      ),
      isTrue,
    );
    expect(
      canStartCloudAttachmentDownload(
        candidateLane: cloudAttachmentDownloadLaneFor(v2),
        cloudSyncV2DownloadActive: false,
      ),
      isTrue,
    );
    expect(
      shouldDeleteFailedAttachmentTarget(cloudAttachmentDownloadLaneFor(v2)),
      isFalse,
    );
    expect(
      shouldDeleteFailedAttachmentTarget(
        cloudAttachmentDownloadLaneFor(legacy),
      ),
      isTrue,
    );
    expect(
      shouldDeleteFailedAttachmentTarget(
        cloudAttachmentDownloadLaneFor(<String, dynamic>{
          cloudAttachmentV2MetadataKey: true,
          'cloud': 'legacy-source',
        }),
      ),
      isFalse,
    );
    expect(
      shouldDeleteFailedAttachmentTarget(cloudAttachmentDownloadLaneFor(null)),
      isFalse,
    );
  });
}

CloudAttachmentSource _unexpectedResolver({
  required CloudSyncScope scope,
  required int generation,
  required String canonicalGuid,
}) => throw StateError('resolver must not run');

CloudAttachmentSource _dummySource(CloudSyncScope scope, int generation) {
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final inbox = CloudInboxChangeEntity(
    changeKey: 'change-key',
    changeIdHash: _repeat('c', 43),
    scopeKey: scopeKey,
    accountFingerprint: scope.accountFingerprint,
    zone: scope.zone,
    serverRecordIdHash: _repeat('d', 43),
    etagHash: _repeat('e', 43),
    changeType: 'save',
    encryptedPayloadRef: 'obcs2.ref.${_repeat('f', 43)}',
    payloadSha256: _repeat('0', 64),
    batchId: 'batch',
    generation: generation,
    fetchSequence: 1,
    createdAtMs: 1,
    updatedAtMs: 1,
  );
  final recordMap = CloudRecordMapEntity(
    mapKey: 'map-key',
    scopeKey: scopeKey,
    accountFingerprint: scope.accountFingerprint,
    zone: scope.zone,
    logicalEntityKeyHash: _repeat('g', 43),
    serverRecordIdHash: inbox.serverRecordIdHash,
    generation: generation,
    encryptedServerRecordId: 'protected-record',
    etagHash: inbox.etagHash,
    encryptedRawRecordRef: inbox.encryptedPayloadRef,
    updatedAtMs: 1,
  );
  return CloudAttachmentSource(
    recordMap: recordMap,
    inboxChange: inbox,
    logicalEntityKeyHash: recordMap.logicalEntityKeyHash,
    expectedCanonicalGuidSha256: _repeat('1', 64),
    protectedSourceReference: inbox.encryptedPayloadRef!,
    recordIdHash: inbox.serverRecordIdHash,
    etagHash: inbox.etagHash!,
    payloadSha256: inbox.payloadSha256!,
    replayOutcome: 'applied',
  );
}

CloudSyncCheckpointEntity _checkpoint({
  required CloudSyncScope scope,
  required int generation,
}) => CloudSyncCheckpointEntity(
  checkpointKey: cloudSyncPersistentScopeKey(scope),
  accountFingerprint: scope.accountFingerprint,
  container: scope.container,
  database: scope.database,
  zone: scope.zone,
  streamKind: scope.streamKind.name,
  schemaVersion: scope.schemaVersion,
  persistenceLane: scope.persistenceLane.name,
  generation: generation,
  updatedAtMs: 1,
);

String _repeat(String value, int count) => List.filled(count, value).join();
