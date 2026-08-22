import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/rust_cloud_sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late CloudSyncScope scope;
  late _FakeBindings bindings;
  late _FakeProtector protector;
  late RustCloudSyncTransport transport;

  setUp(() {
    scope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'messageManateeZone',
    );
    bindings = _FakeBindings();
    protector = _FakeProtector();
    transport = RustCloudSyncTransport(
      cloudMessagesClient: Object(),
      protector: protector,
      bindings: bindings,
    );
  });

  test(
    'maps and protects one ordered raw page without exposing identifiers',
    () async {
      bindings.result = RustCloudSyncRawFetchResult(
        page: RustCloudSyncRawPage(
          changes: [
            RustCloudSyncRawChange(
              kind: RustCloudSyncRawRecordKind.encryptedUpsert,
              recordName: 'server-record-secret',
              recordType: 'Message',
              changeType: 1,
              systemFields: const RustCloudSyncRawSystemFields(
                etag: 'etag-secret',
                modifiedAt: 123,
              ),
              encryptedRecord: Uint8List.fromList([1, 2, 3, 4]),
            ),
          ],
          nextToken: Uint8List.fromList([5, 6, 7]),
          status: 3,
          complete: true,
        ),
      );

      final batch = await transport.fetchChanges(
        scope,
        previousToken: base64UrlEncode([9]).replaceAll('=', ''),
        generation: 7,
        limit: 999,
      );

      expect(bindings.stream, 'messages');
      expect(bindings.maximumChanges, 200);
      expect(bindings.continuationToken, [9]);
      expect(batch.generation, 7);
      expect(batch.hasMore, isFalse);
      expect(batch.nextToken, 'BQYH');
      expect(batch.changes, hasLength(1));
      final change = batch.changes.single;
      expect(change.recordIdHash, isNot(contains('server-record-secret')));
      expect(change.etagHash, isNot(contains('etag-secret')));
      expect(
        change.encryptedPayloadReference,
        startsWith('protected:rawRecord:'),
      );
      expect(change.preflightFailure, isNull);
      expect(protector.plaintexts.single, contains('server-record-secret'));
      expect(protector.plaintexts.single, contains('AQIDBA=='));
    },
  );

  test('unsupported records are preserved but preflight-quarantined', () async {
    bindings.result = RustCloudSyncRawFetchResult(
      page: RustCloudSyncRawPage(
        changes: [
          RustCloudSyncRawChange(
            kind: RustCloudSyncRawRecordKind.unsupportedRecordType,
            recordName: 'unknown-record',
            recordType: 'FutureAppleType',
            encryptedRecord: Uint8List.fromList([8, 9]),
          ),
        ],
        status: 3,
        complete: true,
      ),
    );

    final batch = await transport.fetchChanges(
      scope,
      previousToken: null,
      generation: 1,
      limit: 10,
    );

    expect(
      batch.changes.single.preflightFailure,
      CloudFailureCategory.malformedRecord,
    );
    expect(batch.changes.single.encryptedPayloadReference, isNotNull);
  });

  test('accepts a raw page under the configured byte limit', () async {
    transport = RustCloudSyncTransport(
      cloudMessagesClient: Object(),
      protector: protector,
      bindings: bindings,
      // 64 page + 2 * 128 changes + 5 opaque bytes = 325.
      maximumRawPageBytes: 326,
    );
    bindings.result = RustCloudSyncRawFetchResult(
      page: RustCloudSyncRawPage(
        changes: [
          RustCloudSyncRawChange(
            kind: RustCloudSyncRawRecordKind.encryptedUpsert,
            encryptedRecord: Uint8List.fromList([1, 2]),
          ),
          RustCloudSyncRawChange(
            kind: RustCloudSyncRawRecordKind.tombstone,
            tombstonePayload: Uint8List.fromList([3, 4]),
          ),
        ],
        nextToken: Uint8List.fromList([5]),
        status: 3,
        complete: true,
      ),
    );

    final batch = await transport.fetchChanges(
      scope,
      previousToken: null,
      generation: 1,
      limit: 10,
    );

    expect(batch.changes, hasLength(2));
    expect(protector.plaintexts, hasLength(2));
  });

  test('accepts a raw page exactly at the configured byte limit', () async {
    transport = RustCloudSyncTransport(
      cloudMessagesClient: Object(),
      protector: protector,
      bindings: bindings,
      // 64 page + 2 * 128 changes + 5 opaque bytes = 325.
      maximumRawPageBytes: 325,
    );
    bindings.result = RustCloudSyncRawFetchResult(
      page: RustCloudSyncRawPage(
        changes: [
          RustCloudSyncRawChange(
            kind: RustCloudSyncRawRecordKind.encryptedUpsert,
            encryptedRecord: Uint8List.fromList([1, 2]),
          ),
          RustCloudSyncRawChange(
            kind: RustCloudSyncRawRecordKind.tombstone,
            tombstonePayload: Uint8List.fromList([3, 4]),
          ),
        ],
        nextToken: Uint8List.fromList([5]),
        status: 3,
        complete: true,
      ),
    );

    final batch = await transport.fetchChanges(
      scope,
      previousToken: null,
      generation: 1,
      limit: 10,
    );

    expect(batch.changes, hasLength(2));
    expect(protector.plaintexts, hasLength(2));
  });

  test('rejects a raw page over the configured byte limit', () async {
    transport = RustCloudSyncTransport(
      cloudMessagesClient: Object(),
      protector: protector,
      bindings: bindings,
      // 64 page + 128 change + 4 opaque bytes = 196.
      maximumRawPageBytes: 195,
    );
    bindings.result = RustCloudSyncRawFetchResult(
      page: RustCloudSyncRawPage(
        changes: [
          RustCloudSyncRawChange(
            kind: RustCloudSyncRawRecordKind.encryptedUpsert,
            encryptedRecord: Uint8List.fromList([1, 2, 3, 4]),
          ),
        ],
        status: 3,
        complete: true,
      ),
    );

    await expectLater(
      () => transport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 10,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'oversized_raw_page',
        ),
      ),
    );
    expect(protector.plaintexts, isEmpty);
  });

  test('rejects an oversized page before any partial protection', () async {
    transport = RustCloudSyncTransport(
      cloudMessagesClient: Object(),
      protector: protector,
      bindings: bindings,
      // 64 page + 2 * 128 changes + 5 opaque bytes = 325.
      maximumRawPageBytes: 324,
    );
    bindings.result = RustCloudSyncRawFetchResult(
      page: RustCloudSyncRawPage(
        changes: [
          RustCloudSyncRawChange(
            kind: RustCloudSyncRawRecordKind.encryptedUpsert,
            encryptedRecord: Uint8List.fromList([1, 2, 3]),
          ),
          RustCloudSyncRawChange(
            kind: RustCloudSyncRawRecordKind.encryptedUpsert,
            encryptedRecord: Uint8List.fromList([4, 5]),
          ),
        ],
        status: 3,
        complete: true,
      ),
    );

    await expectLater(
      () => transport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 10,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'oversized_raw_page',
        ),
      ),
    );

    // No CloudFetchBatch is returned for the engine to persist, and even the
    // first individually valid record never reaches the protector.
    expect(protector.plaintexts, isEmpty);
  });

  test('rejects a page whose UTF-8 metadata alone exceeds the limit', () async {
    transport = RustCloudSyncTransport(
      cloudMessagesClient: Object(),
      protector: protector,
      bindings: bindings,
      // 64 page + 128 change + 64 system + UTF-8 metadata (3 + 7 + 2)
      // = 268 bytes, without any encrypted record or tombstone payload.
      maximumRawPageBytes: 267,
    );
    bindings.result = const RustCloudSyncRawFetchResult(
      page: RustCloudSyncRawPage(
        changes: [
          RustCloudSyncRawChange(
            kind: RustCloudSyncRawRecordKind.encryptedUpsert,
            recordName: '名',
            recordType: 'Message',
            systemFields: RustCloudSyncRawSystemFields(etag: 'é'),
          ),
        ],
        status: 3,
        complete: true,
      ),
    );

    await expectLater(
      () => transport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 10,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'oversized_raw_page',
        ),
      ),
    );
    expect(protector.plaintexts, isEmpty);
  });

  test('rejects a non-positive raw page byte limit', () {
    expect(
      () => RustCloudSyncTransport(
        cloudMessagesClient: Object(),
        protector: protector,
        bindings: bindings,
        maximumRawPageBytes: 0,
      ),
      throwsArgumentError,
    );
  });

  test('maps typed retry metadata without parsing server text', () async {
    bindings.result = const RustCloudSyncRawFetchResult(
      failure: RustCloudSyncRawFailure(
        category: RustCloudSyncRawFailureCategory.throttled,
        safeCode: 'cloudkit-throttled',
        retryAfterSeconds: 901,
      ),
    );

    await expectLater(
      () => transport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 10,
      ),
      throwsA(
        isA<CloudSyncFailure>()
            .having(
              (failure) => failure.category,
              'category',
              CloudFailureCategory.throttled,
            )
            .having(
              (failure) => failure.retryAfter,
              'retryAfter',
              const Duration(seconds: 901),
            )
            .having(
              (failure) => failure.safeCode,
              'safeCode',
              'cloudkit-throttled',
            ),
      ),
    );
  });

  test('rejects malformed result envelopes and unsupported zones', () async {
    bindings.result = const RustCloudSyncRawFetchResult();
    await expectLater(
      () => transport.fetchChanges(
        scope,
        previousToken: null,
        generation: 1,
        limit: 10,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'invalid_transport_envelope',
        ),
      ),
    );

    final unsupported = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'futureZone',
    );
    await expectLater(
      () => transport.fetchChanges(
        unsupported,
        previousToken: null,
        generation: 1,
        limit: 10,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'unsupported_cloud_zone',
        ),
      ),
    );
  });

  test('accepts the expanded raw-zone allowlist without remapping', () async {
    bindings.result = const RustCloudSyncRawFetchResult(
      page: RustCloudSyncRawPage(
        changes: [],
        nextToken: null,
        status: 3,
        complete: true,
      ),
    );
    final cases = <(String zone, String stream)>[
      ('chatManateeZone', 'chats'),
      ('messageManateeZone', 'messages'),
      ('attachmentManateeZone', 'attachments'),
      ('messageUpdateZone', 'messageUpdateZone'),
      ('recoverableMessageDeleteZone', 'recoverableMessageDeleteZone'),
      ('scheduledMessageZone', 'scheduledMessageZone'),
      ('chat1ManateeZone', 'chat1ManateeZone'),
    ];

    for (final (zone, stream) in cases) {
      final batch = await transport.fetchChanges(
        CloudSyncScope(
          accountFingerprint: testAccountFingerprintA,
          container: 'com.apple.messages.cloud',
          database: 'private',
          zone: zone,
        ),
        previousToken: null,
        generation: 1,
        limit: 10,
      );
      expect(batch.changes, isEmpty);
      expect(bindings.stream, stream);
    }
  });
}

final class _FakeBindings implements RustCloudSyncTransportBindings {
  RustCloudSyncRawFetchResult result = const RustCloudSyncRawFetchResult();
  String? stream;
  Uint8List? continuationToken;
  int? maximumChanges;

  @override
  Future<RustCloudSyncRawFetchResult> fetchRawPage({
    required Object cloudMessagesClient,
    required String stream,
    required Uint8List? continuationToken,
    required int maximumChanges,
  }) async {
    this.stream = stream;
    this.continuationToken = continuationToken;
    this.maximumChanges = maximumChanges;
    return result;
  }
}

final class _FakeProtector implements CloudSyncProtector {
  final List<String> plaintexts = [];

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      'fingerprint';

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async {
    plaintexts.add(plaintext);
    return 'protected:${kind.name}:${plaintext.length}';
  }

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => throw UnimplementedError();
}
