import 'dart:convert';

import 'package:bluebubbles/database/io/cloud_sync_records.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_body_materializer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_download_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_source_resolver.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  tearDown(
    CloudAttachmentDownloadCoordinator.debugResetProcessSafetyLatchForTesting,
  );

  test(
    'success uses the exact operation, scope, generation, and ordering',
    () async {
      final fixture = _Fixture();
      final coordinator = fixture.build();

      final result = await coordinator.download(
        canonicalGuid: 'attachment-guid',
        expectedBytes: 8,
      );

      expect(result, isA<CloudAttachmentDownloadMaterialized>());
      expect(fixture.events, <String>[
        'operation:v2SemanticRead',
        'pause',
        'prepare-auth',
        'auth-check',
        'generation',
        'resolve',
        'body',
        'resume',
      ]);
      expect(fixture.operationKind, CloudKitOperationKind.v2SemanticRead);
      expect(fixture.resolvedScope!.container, 'com.apple.messages.cloud');
      expect(fixture.resolvedScope!.database, 'private');
      expect(fixture.resolvedScope!.zone, 'attachmentManateeZone');
      expect(
        fixture.resolvedScope!.persistenceLane,
        CloudSyncPersistenceLane.semanticV2,
      );
      expect(fixture.resolvedGeneration, 7);
      expect(
        fixture.bodyNative!.request!.nativeWriterPauseToken,
        BigInt.from(7),
      );
      expect(
        fixture.bodyNative!.request!.expectedCanonicalGuidSha256,
        fixture.expectedCanonicalGuidSha256,
      );
    },
  );

  test(
    'missing source is unavailable and never calls the body materializer',
    () async {
      final fixture = _Fixture();
      final coordinator = fixture.build(
        resolutionCode: CloudAttachmentSourceResolutionCode.missingSource,
      );

      final result = await coordinator.download(
        canonicalGuid: 'attachment-guid',
        expectedBytes: 8,
      );

      expect(result, isA<CloudAttachmentDownloadUnavailable>());
      expect(
        (result as CloudAttachmentDownloadUnavailable).code,
        CloudAttachmentSourceResolutionCode.missingSource,
      );
      expect(fixture.bodyNative!.calls, 0);
      expect(fixture.events.last, 'resume');
    },
  );

  test('ambiguous and stale resolution never fall back', () async {
    for (final code in <CloudAttachmentSourceResolutionCode>[
      CloudAttachmentSourceResolutionCode.ambiguousSource,
      CloudAttachmentSourceResolutionCode.staleIdentity,
    ]) {
      final fixture = _Fixture();
      final coordinator = fixture.build(resolutionCode: code);

      await expectLater(
        coordinator.download(
          canonicalGuid: 'attachment-guid',
          expectedBytes: 8,
        ),
        throwsA(
          isA<CloudSyncFailure>()
              .having(
                (failure) => failure.category,
                'category',
                CloudFailureCategory.conflict,
              )
              .having(
                (failure) => failure.safeCode,
                'safeCode',
                'cloud_attachment_source_conflict',
              ),
        ),
      );
      expect(fixture.bodyNative!.calls, 0);
      expect(fixture.events.last, 'resume');
    }
  });

  test('resume is attempted when body materialization fails', () async {
    final fixture = _Fixture();
    final coordinator = fixture.build(
      bodyResult: const CloudAttachmentBodyNativeResult.failed(
        CloudAttachmentBodyNativeFailure.retryableUpstream,
      ),
    );

    await expectLater(
      coordinator.download(canonicalGuid: 'attachment-guid', expectedBytes: 8),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.category,
          'category',
          CloudFailureCategory.network,
        ),
      ),
    );
    expect(fixture.bodyNative!.calls, 1);
    expect(fixture.events.last, 'resume');
  });

  test('null and changed auth surface authorization failures', () async {
    final nullFixture = _Fixture();
    final nullCoordinator = nullFixture.build(prepareAuthReturnsNull: true);
    await _expectAuthorizationFailure(
      nullCoordinator.download(
        canonicalGuid: 'attachment-guid',
        expectedBytes: 8,
      ),
    );
    expect(nullFixture.bodyNative!.calls, 0);
    expect(nullFixture.events.last, 'resume');

    final changedFixture = _Fixture();
    final changedCoordinator = changedFixture.build(
      currentAuth: _auth(session: 'changed-session'),
    );
    await _expectAuthorizationFailure(
      changedCoordinator.download(
        canonicalGuid: 'attachment-guid',
        expectedBytes: 8,
      ),
    );
    expect(changedFixture.bodyNative!.calls, 0);
    expect(changedFixture.events.last, 'resume');
  });

  test(
    'invalid checkpoint generation is a fixed failure and resumes',
    () async {
      final fixture = _Fixture();
      final coordinator = fixture.build(generation: 0);

      await expectLater(
        coordinator.download(
          canonicalGuid: 'attachment-guid',
          expectedBytes: 8,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_attachment_source_invalid',
          ),
        ),
      );
      expect(fixture.bodyNative!.calls, 0);
      expect(fixture.events.last, 'resume');
    },
  );

  test('conversion preserves the complete validated inbox envelope', () async {
    final fixture = _Fixture();
    final coordinator = fixture.build();

    final result =
        await coordinator.download(
              canonicalGuid: 'attachment-guid',
              expectedBytes: 8,
            )
            as CloudAttachmentDownloadMaterialized;
    final source = result.source;
    final change = source.change;

    expect(change.changeId, fixture.changeIdHash);
    expect(change.recordIdHash, fixture.recordIdHash);
    expect(change.etagHash, fixture.etagHash);
    expect(change.type, CloudChangeType.save);
    expect(change.encryptedServerRecordId, fixture.encryptedServerRecordId);
    expect(
      change.protectedSystemFieldsReference,
      fixture.protectedSystemFieldsReference,
    );
    expect(change.encryptedPayloadReference, fixture.encryptedPayloadReference);
    expect(change.payloadSha256, fixture.payloadSha256);
    expect(change.serverModifiedAt, fixture.serverModifiedAt);
    expect(source.sequence, 9);
    expect(source.status, CloudInboxStatus.applied);
    expect(source.attemptCount, 3);
    expect(source.completedAt, fixture.completedAt);
  });

  test(
    'unexpected resolver text is replaced by content-free failure text',
    () async {
      final fixture = _Fixture();
      final coordinator = fixture.build(
        resolverError: 'record-id-secret payload-ref-secret',
      );

      try {
        await coordinator.download(
          canonicalGuid: 'attachment-guid',
          expectedBytes: 8,
        );
        fail('expected a CloudSyncFailure');
      } on CloudSyncFailure catch (failure) {
        expect(failure.toString(), isNot(contains('record-id-secret')));
        expect(failure.toString(), isNot(contains('payload-ref-secret')));
        expect(failure.safeCode, 'cloud_attachment_source_invalid');
      }
    },
  );

  test('request and pause-token bounds fail before body access', () async {
    final fixture = _Fixture();
    final coordinator = fixture.build(pauseToken: BigInt.one << 64);

    await expectLater(
      coordinator.download(canonicalGuid: 'attachment-guid', expectedBytes: 8),
      throwsA(isA<CloudSyncFailure>()),
    );
    expect(fixture.bodyNative!.calls, 0);

    final requestFixture = _Fixture();
    final requestCoordinator = requestFixture.build();
    await expectLater(
      requestCoordinator.download(
        canonicalGuid: ' ',
        expectedBytes:
            CloudAttachmentDownloadCoordinator.maximumExpectedBytes + 1,
      ),
      throwsA(isA<CloudSyncFailure>()),
    );
    expect(requestFixture.events, isEmpty);
  });

  test('an uncertain pause latches the coordinator until restart', () async {
    final fixture = _Fixture();
    final coordinator = fixture.build(
      pauseError: const CloudSyncNativeWriterPauseUncertain(),
    );

    await expectLater(
      coordinator.download(canonicalGuid: 'attachment-guid', expectedBytes: 8),
      throwsA(isA<CloudSyncNativeWriterPauseUncertain>()),
    );
    expect(fixture.writerPause!.pauseCalls, 1);
    expect(fixture.operationExclusion!.poisonCalls, 1);

    final secondCoordinator = fixture.build();
    final secondWriterPause = fixture.writerPause!;
    await expectLater(
      secondCoordinator.download(
        canonicalGuid: 'attachment-guid',
        expectedBytes: 8,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_attachment_state_contention',
        ),
      ),
    );
    expect(secondWriterPause.pauseCalls, 0);
  });

  test('an unconfirmed resume latches the coordinator until restart', () async {
    final fixture = _Fixture();
    final coordinator = fixture.build(resumeError: StateError('bridge-lost'));

    await expectLater(
      coordinator.download(canonicalGuid: 'attachment-guid', expectedBytes: 8),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_sync_native_writer_resume_failed',
        ),
      ),
    );
    expect(fixture.writerPause!.resumeCalls, 1);
    expect(fixture.operationExclusion!.poisonCalls, 1);

    await expectLater(
      coordinator.download(canonicalGuid: 'attachment-guid', expectedBytes: 8),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_attachment_state_contention',
        ),
      ),
    );
    expect(fixture.writerPause!.resumeCalls, 1);
  });
}

Future<void> _expectAuthorizationFailure(Future<Object?> operation) async {
  await expectLater(
    operation,
    throwsA(
      isA<CloudSyncFailure>().having(
        (failure) => failure.category,
        'category',
        CloudFailureCategory.authorization,
      ),
    ),
  );
}

final class _Fixture {
  final events = <String>[];
  final auth = _auth();
  final changeIdHash = List.filled(43, 'C').join();
  final recordIdHash = List.filled(43, 'R').join();
  final etagHash = List.filled(43, 'E').join();
  final payloadSha256 = testSha256('a');
  final expectedCanonicalGuidSha256 =
      '6c3649d22f60dc030886b73028b97cc737a563388c2b0eb7b2c916d3ebb3235f';
  final encryptedServerRecordId = testProtectedReference('S');
  final protectedSystemFieldsReference = testProtectedReference('Y');
  final encryptedPayloadReference = testProtectedReference('P');
  final serverModifiedAt = DateTime.utc(2026, 8, 30, 12, 1);
  final completedAt = DateTime.utc(2026, 8, 30, 12, 2);

  CloudKitOperationKind? operationKind;
  CloudSyncScope? resolvedScope;
  int? resolvedGeneration;
  _BodyNative? bodyNative;
  _RecordingWriterPause? writerPause;
  _RecordingOperationExclusion? operationExclusion;

  CloudAttachmentDownloadCoordinator build({
    CloudAttachmentSourceResolutionCode? resolutionCode,
    int generation = 7,
    BigInt? pauseToken,
    CloudAttachmentBodyNativeResult bodyResult =
        const CloudAttachmentBodyNativeResult.completed(8),
    bool prepareAuthReturnsNull = false,
    CloudSyncNativeAuthSnapshot? currentAuth,
    String? resolverError,
    Object? pauseError,
    Object? resumeError,
  }) {
    final native = _BodyNative(events: events, result: bodyResult);
    bodyNative = native;
    final materializer = CloudAttachmentBodyMaterializer(
      store: _MemoryMaterializationStore(),
      nativeBindings: native,
      readAuthSnapshot: () async => currentAuth ?? auth,
    );
    final operation = _RecordingOperationExclusion(events, (kind) {
      operationKind = kind;
    });
    operationExclusion = operation;
    final writerPause = _RecordingWriterPause(
      events: events,
      token: pauseToken ?? BigInt.from(7),
      pauseError: pauseError,
      resumeError: resumeError,
    );
    this.writerPause = writerPause;
    return CloudAttachmentDownloadCoordinator(
      operationExclusion: operation,
      nativeWriterPause: writerPause,
      prepareAuthUnderPause: (token) async {
        expect(token, pauseToken ?? BigInt.from(7));
        events.add('prepare-auth');
        return prepareAuthReturnsNull ? null : auth;
      },
      readAuthSnapshot: () async {
        events.add('auth-check');
        return currentAuth ?? auth;
      },
      readActiveGeneration: (scope) async {
        events.add('generation');
        resolvedScope = scope;
        resolvedGeneration = generation;
        return generation;
      },
      resolveSource:
          ({required scope, required generation, required canonicalGuid}) {
            events.add('resolve');
            if (resolverError != null) throw StateError(resolverError);
            if (resolutionCode != null) {
              throw CloudAttachmentSourceResolutionFailure(resolutionCode);
            }
            return _source(scope, generation);
          },
      bodyMaterializer: materializer,
      storageDirectory: 'private-storage',
      applicationDocumentsDirectory: 'application-documents',
    );
  }

  CloudAttachmentSource _source(CloudSyncScope scope, int generation) {
    final logicalHash = List.filled(43, 'L').join();
    final entity = CloudInboxChangeEntity(
      changeKey: 'change-key',
      changeIdHash: changeIdHash,
      scopeKey: _scopeKey(scope),
      accountFingerprint: scope.accountFingerprint,
      zone: scope.zone,
      serverRecordIdHash: recordIdHash,
      etagHash: etagHash,
      changeType: CloudChangeType.save.name,
      encryptedServerRecordId: encryptedServerRecordId,
      protectedSystemFieldsRef: protectedSystemFieldsReference,
      encryptedPayloadRef: encryptedPayloadReference,
      payloadSha256: payloadSha256,
      batchId: 'batch-id',
      generation: generation,
      fetchSequence: 9,
      status: CloudInboxStatus.applied.index,
      retryCount: 3,
      nextEligibleAtMs: 0,
      serverModifiedAtMs: serverModifiedAt.millisecondsSinceEpoch,
      createdAtMs: DateTime.utc(2026, 8, 30, 12).millisecondsSinceEpoch,
      updatedAtMs: completedAt.millisecondsSinceEpoch,
      completedAtMs: completedAt.millisecondsSinceEpoch,
    );
    return CloudAttachmentSource(
      recordMap: CloudRecordMapEntity(
        mapKey: 'map-key',
        scopeKey: _scopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        logicalEntityKeyHash: logicalHash,
        serverRecordIdHash: recordIdHash,
        generation: generation,
        encryptedServerRecordId: encryptedServerRecordId,
        etagHash: etagHash,
        encryptedRawRecordRef: encryptedPayloadReference,
        updatedAtMs: completedAt.millisecondsSinceEpoch,
      ),
      inboxChange: entity,
      logicalEntityKeyHash: logicalHash,
      expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
      protectedSourceReference: encryptedPayloadReference,
      recordIdHash: recordIdHash,
      etagHash: etagHash,
      payloadSha256: payloadSha256,
      replayOutcome: 'applied',
    );
  }
}

CloudSyncNativeAuthSnapshot _auth({String session = 'auth-session'}) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: session,
      accountFingerprint: testAccountFingerprintA,
      protectedStoreIdentity: testProtectedReference(
        'T',
      ).replaceFirst('obcs2.ref.', 'obcs2.store.'),
      cloudMessagesClient: session,
    );

String _scopeKey(CloudSyncScope scope) =>
    'scope2:${sha256.convert(utf8.encode(scope.storageKey))}';

final class _RecordingOperationExclusion implements CloudKitOperationExclusion {
  _RecordingOperationExclusion(this.events, this.onKind);

  final List<String> events;
  final void Function(CloudKitOperationKind kind) onKind;
  int poisonCalls = 0;

  @override
  void poisonUntilProcessRestart() {
    poisonCalls++;
  }

  @override
  Future<T> runExclusive<T>({
    required CloudKitOperationKind kind,
    required CloudKitOperationBody<T> action,
  }) {
    onKind(kind);
    events.add('operation:${kind.name}');
    return action();
  }
}

final class _RecordingWriterPause implements CloudSyncNativeWriterPause {
  _RecordingWriterPause({
    required this.events,
    required this.token,
    this.pauseError,
    this.resumeError,
  });

  final List<String> events;
  final BigInt token;
  final Object? pauseError;
  final Object? resumeError;
  int pauseCalls = 0;
  int resumeCalls = 0;

  @override
  Future<Object> pause() async {
    pauseCalls++;
    events.add('pause');
    if (pauseError != null) throw pauseError!;
    return token;
  }

  @override
  Future<void> resume(Object value) async {
    resumeCalls++;
    expect(value, token);
    events.add('resume');
    if (resumeError != null) throw resumeError!;
  }
}

final class _BodyNative implements CloudAttachmentBodyNativeBindings {
  _BodyNative({required this.events, required this.result});

  final List<String> events;
  final CloudAttachmentBodyNativeResult result;
  int calls = 0;
  CloudAttachmentBodyNativeRequest? request;

  @override
  Future<CloudAttachmentBodyNativeResult> materialize(
    CloudAttachmentBodyNativeRequest value,
  ) async {
    calls++;
    request = value;
    events.add('body');
    return result;
  }
}

final class _MemoryMaterializationStore
    implements CloudAttachmentMaterializationStore {
  CloudAttachmentMaterialization? value;

  @override
  Future<CloudAttachmentMaterialization?> read({
    required CloudSyncScope scope,
    required int generation,
    required String logicalEntityKeyHash,
  }) async => value;

  @override
  Future<bool> create(CloudAttachmentMaterialization initial) async {
    if (value != null) return false;
    value = initial;
    return true;
  }

  @override
  Future<bool> compareAndSwap({
    required CloudAttachmentMaterialization expected,
    required CloudAttachmentMaterialization next,
  }) async {
    value = next;
    return true;
  }
}
