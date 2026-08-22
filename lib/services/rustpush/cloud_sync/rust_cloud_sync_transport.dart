import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;
import 'package:crypto/crypto.dart';

import 'cloud_sync_models.dart';
import 'cloud_sync_protector.dart';
import 'cloud_sync_transport.dart';

const int _maximumRawRecordBytes = 8 * 1024 * 1024;
const int _defaultMaximumRawPageBytes = 32 * 1024 * 1024;
const int _maximumContinuationTokenBytes = 1024 * 1024;

// These deliberately conservative estimates cover list/option framing and the
// fixed page/change/system scalars that are not represented by byte arrays or
// strings below. At the 200-change transport maximum they consume less than
// 40 KiB of the default page budget.
const int _rawPageFixedOverheadBytes = 64;
const int _rawChangeFixedOverheadBytes = 128;
const int _rawSystemFieldsFixedOverheadBytes = 64;

enum RustCloudSyncRawRecordKind {
  encryptedUpsert,
  tombstone,
  unsupportedRecordType,
  malformedMetadata,
}

enum RustCloudSyncRawFailureCategory {
  network,
  throttled,
  server,
  authorization,
  pcsUnavailable,
  malformedRecord,
  conflict,
  localStorage,
  unknown,
}

class RustCloudSyncRawSystemFields {
  const RustCloudSyncRawSystemFields({
    this.etag,
    this.createdAt,
    this.modifiedAt,
    this.permission,
  });

  final String? etag;
  final double? createdAt;
  final double? modifiedAt;
  final int? permission;
}

class RustCloudSyncRawChange {
  const RustCloudSyncRawChange({
    required this.kind,
    this.recordName,
    this.recordType,
    this.changeType,
    this.systemFields,
    this.encryptedRecord,
    this.tombstonePayload,
  });

  final RustCloudSyncRawRecordKind kind;
  final String? recordName;
  final String? recordType;
  final int? changeType;
  final RustCloudSyncRawSystemFields? systemFields;
  final Uint8List? encryptedRecord;
  final Uint8List? tombstonePayload;
}

class RustCloudSyncRawPage {
  const RustCloudSyncRawPage({
    required this.changes,
    required this.status,
    required this.complete,
    this.nextToken,
  });

  final List<RustCloudSyncRawChange> changes;
  final Uint8List? nextToken;
  final int status;
  final bool complete;
}

class RustCloudSyncRawFailure {
  const RustCloudSyncRawFailure({
    required this.category,
    required this.safeCode,
    this.retryAfterSeconds,
  });

  final RustCloudSyncRawFailureCategory category;
  final int? retryAfterSeconds;
  final String safeCode;
}

class RustCloudSyncRawFetchResult {
  const RustCloudSyncRawFetchResult({this.page, this.failure});

  final RustCloudSyncRawPage? page;
  final RustCloudSyncRawFailure? failure;
}

/// Narrow seam around the generated FRB page call. Tests inject this boundary
/// so malformed pages can be exercised without loading a native library.
abstract interface class RustCloudSyncTransportBindings {
  Future<RustCloudSyncRawFetchResult> fetchRawPage({
    required Object cloudMessagesClient,
    required String stream,
    required Uint8List? continuationToken,
    required int maximumChanges,
  });
}

/// Read-only production transport for the dormant Cloud Sync V2 shadow phase.
///
/// The adapter protects one canonical raw envelope per change before any value
/// reaches ObjectBox. It does not expose save, delete, allocation, or conflict
/// write paths.
final class RustCloudSyncTransport implements CloudSyncTransport {
  RustCloudSyncTransport({
    required this._cloudMessagesClient,
    required this._protector,
    RustCloudSyncTransportBindings? bindings,
    this._refreshAuthentication,
    this._refreshPcsAccess,
    this.maximumRawPageBytes = _defaultMaximumRawPageBytes,
  }) : _bindings = bindings ?? FrbRustCloudSyncTransportBindings() {
    if (maximumRawPageBytes <= 0) {
      throw ArgumentError.value(maximumRawPageBytes, 'maximumRawPageBytes');
    }
  }

  final Object _cloudMessagesClient;
  final CloudSyncProtector _protector;
  final RustCloudSyncTransportBindings _bindings;
  final Future<bool> Function(CloudSyncScope scope)? _refreshAuthentication;
  final Future<bool> Function(CloudSyncScope scope)? _refreshPcsAccess;

  /// Maximum estimated raw-page size before local protection.
  ///
  /// Admission includes the opaque continuation token, encrypted-record and
  /// tombstone byte fields, UTF-8 metadata, and conservative fixed overhead
  /// for each page, change, and system-fields structure.
  ///
  /// The complete page is admitted before the first record is protected, so an
  /// over-limit page cannot produce a partial [CloudFetchBatch].
  final int maximumRawPageBytes;

  @override
  Future<CloudFetchBatch> fetchChanges(
    CloudSyncScope scope, {
    required String? previousToken,
    required int generation,
    required int limit,
  }) async {
    final stream = _streamForScope(scope);
    final token = _decodeToken(previousToken);
    final result = await _bindings.fetchRawPage(
      cloudMessagesClient: _cloudMessagesClient,
      stream: stream,
      continuationToken: token,
      maximumChanges: limit.clamp(1, 200).toInt(),
    );

    final page = result.page;
    final failure = result.failure;
    if ((page == null) == (failure == null)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'invalid_transport_envelope',
      );
    }
    if (failure != null) throw _mapFailure(failure);

    _ensureRawPageWithinByteLimit(page!);
    final nextToken = _encodeToken(page.nextToken);
    if (!page.complete && nextToken == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'missing_continuation_token',
      );
    }

    final changes = <CloudFetchedChange>[];
    for (var index = 0; index < page.changes.length; index++) {
      changes.add(await _protectChange(scope, page.changes[index], index));
    }
    final batchId = _digest(
      [
        'cloud-sync-batch-v2',
        scope.storageKey,
        _digestValue(previousToken ?? 'initial'),
        _digestValue(nextToken ?? 'complete'),
        page.status.toString(),
        ...changes.map((change) => change.changeId),
      ].join('\u001f'),
    );

    return CloudFetchBatch(
      scope: scope,
      changes: changes,
      batchId: 'batch2:$batchId',
      generation: generation,
      nextToken: nextToken,
      hasMore: !page.complete,
    );
  }

  void _ensureRawPageWithinByteLimit(RustCloudSyncRawPage page) {
    var totalBytes = 0;

    void addLength(int length) {
      // Subtracting from the validated positive limit avoids a wrapping
      // addition in runtimes whose integer representation is bounded.
      if (length > maximumRawPageBytes - totalBytes) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.malformedRecord,
          safeCode: 'oversized_raw_page',
        );
      }
      totalBytes += length;
    }

    void addBytes(Uint8List? bytes) {
      if (bytes != null) addLength(bytes.length);
    }

    void addString(String? value) {
      if (value != null) addLength(_utf8ByteLength(value));
    }

    addLength(_rawPageFixedOverheadBytes);
    addBytes(page.nextToken);
    for (final change in page.changes) {
      addLength(_rawChangeFixedOverheadBytes);
      addString(change.recordName);
      addString(change.recordType);
      addBytes(change.encryptedRecord);
      addBytes(change.tombstonePayload);
      final systemFields = change.systemFields;
      if (systemFields != null) {
        addLength(_rawSystemFieldsFixedOverheadBytes);
        addString(systemFields.etag);
      }
    }
  }

  Future<CloudFetchedChange> _protectChange(
    CloudSyncScope scope,
    RustCloudSyncRawChange change,
    int pageIndex,
  ) async {
    final encryptedRecord = change.encryptedRecord;
    final tombstonePayload = change.tombstonePayload;
    final rawBytes = encryptedRecord ?? tombstonePayload ?? Uint8List(0);
    final rawDigest = sha256.convert(rawBytes).toString();
    final oversize = rawBytes.length > _maximumRawRecordBytes;
    final preflightFailure = switch (change.kind) {
      RustCloudSyncRawRecordKind.encryptedUpsert ||
      RustCloudSyncRawRecordKind.tombstone =>
        oversize ? CloudFailureCategory.malformedRecord : null,
      RustCloudSyncRawRecordKind.unsupportedRecordType ||
      RustCloudSyncRawRecordKind.malformedMetadata =>
        CloudFailureCategory.malformedRecord,
    };

    final systemFields = change.systemFields;
    final canonicalEnvelope = jsonEncode({
      'v': 1,
      'kind': change.kind.name,
      'recordName': change.recordName,
      'recordType': change.recordType,
      'changeType': change.changeType,
      'system': systemFields == null
          ? null
          : {
              'etag': systemFields.etag,
              'createdAt': systemFields.createdAt,
              'modifiedAt': systemFields.modifiedAt,
              'permission': systemFields.permission,
            },
      // An oversized record is represented by its digest and metadata only.
      // This prevents one hostile page from exceeding the protector's hard
      // plaintext limit while retaining enough evidence to quarantine it.
      'rawEncoding': oversize
          ? null
          : encryptedRecord != null
          ? 'record'
          : tombstonePayload != null
          ? 'tombstone'
          : null,
      'raw': oversize ? null : base64UrlEncode(rawBytes),
      'rawSha256': rawDigest,
      'rawLength': rawBytes.length,
    });
    final protectedEnvelope = await _protector.protect(
      scope: scope,
      kind: CloudSyncProtectedValueKind.rawRecord,
      plaintext: canonicalEnvelope,
    );

    final recordIdentity = change.recordName?.trim();
    final recordIdHash = _digestValue(
      recordIdentity == null || recordIdentity.isEmpty
          ? 'missing\u001f$rawDigest\u001f$pageIndex'
          : recordIdentity,
    );
    final etag = systemFields?.etag;
    final etagHash = etag == null || etag.isEmpty ? null : _digestValue(etag);
    final isTombstone = change.kind == RustCloudSyncRawRecordKind.tombstone;
    final changeId = _digest(
      [
        'cloud-sync-change-v2',
        scope.storageKey,
        recordIdHash,
        change.kind.name,
        change.changeType?.toString() ?? 'none',
        etagHash ?? 'none',
        rawDigest,
      ].join('\u001f'),
    );

    return CloudFetchedChange(
      changeId: 'change2:$changeId',
      recordIdHash: recordIdHash,
      etagHash: etagHash,
      type: isTombstone ? CloudChangeType.delete : CloudChangeType.save,
      encryptedPayloadReference: protectedEnvelope,
      payloadSha256: rawDigest,
      isTombstone: isTombstone,
      preflightFailure: preflightFailure,
    );
  }

  @override
  Future<bool> refreshAuthentication(CloudSyncScope scope) async {
    final callback = _refreshAuthentication;
    return callback == null ? false : await callback(scope);
  }

  @override
  Future<bool> refreshPcsAccess(CloudSyncScope scope) async {
    final callback = _refreshPcsAccess;
    return callback == null ? false : await callback(scope);
  }

  @override
  Future<CloudPushBatchResult> pushOperations(
    CloudSyncScope scope, {
    required List<CloudOutboxOperation> operations,
  }) => throw _readOnlyFailure();

  @override
  Future<CloudUnknownOutcomeResolution> reconcileUnknownOutcome(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) => throw _readOnlyFailure();

  @override
  Future<CloudRecordMapEntry> allocateServerRecordMapping(
    CloudSyncScope scope, {
    required String logicalEntityKeyHash,
  }) => throw _readOnlyFailure();

  @override
  Future<CloudServerConflictResolution> reconcileServerRecordChanged(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) => throw _readOnlyFailure();

  CloudSyncFailure _readOnlyFailure() => CloudSyncFailure(
    category: CloudFailureCategory.cancelled,
    safeCode: 'cloud_sync_shadow_read_only',
  );

  String _streamForScope(CloudSyncScope scope) {
    if (scope.database != 'private' ||
        scope.streamKind != CloudSyncStreamKind.messages) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.cancelled,
        safeCode: 'unsupported_cloud_scope',
      );
    }
    return switch (scope.zone) {
      'chatManateeZone' => 'chats',
      'messageManateeZone' => 'messages',
      'attachmentManateeZone' => 'attachments',
      'messageUpdateZone' => 'messageUpdateZone',
      'recoverableMessageDeleteZone' => 'recoverableMessageDeleteZone',
      'scheduledMessageZone' => 'scheduledMessageZone',
      'chat1ManateeZone' => 'chat1ManateeZone',
      _ => throw CloudSyncFailure(
        category: CloudFailureCategory.cancelled,
        safeCode: 'unsupported_cloud_zone',
      ),
    };
  }

  Uint8List? _decodeToken(String? value) {
    if (value == null) return null;
    try {
      final normalized = value.padRight((value.length + 3) ~/ 4 * 4, '=');
      final decoded = base64Url.decode(normalized);
      if (decoded.length > _maximumContinuationTokenBytes) {
        throw const FormatException('token too large');
      }
      return Uint8List.fromList(decoded);
    } on FormatException {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'invalid_checkpoint_token',
      );
    }
  }

  String? _encodeToken(Uint8List? value) {
    if (value == null) return null;
    if (value.length > _maximumContinuationTokenBytes) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'oversized_continuation_token',
      );
    }
    return base64UrlEncode(value).replaceAll('=', '');
  }

  CloudSyncFailure _mapFailure(RustCloudSyncRawFailure failure) {
    final retryAfter = failure.retryAfterSeconds == null
        ? null
        : Duration(seconds: failure.retryAfterSeconds!);
    final category = switch (failure.category) {
      RustCloudSyncRawFailureCategory.network => CloudFailureCategory.network,
      RustCloudSyncRawFailureCategory.throttled =>
        CloudFailureCategory.throttled,
      RustCloudSyncRawFailureCategory.server => CloudFailureCategory.server,
      RustCloudSyncRawFailureCategory.authorization =>
        CloudFailureCategory.authorization,
      RustCloudSyncRawFailureCategory.pcsUnavailable =>
        CloudFailureCategory.pcsUnavailable,
      RustCloudSyncRawFailureCategory.malformedRecord =>
        CloudFailureCategory.malformedRecord,
      RustCloudSyncRawFailureCategory.conflict => CloudFailureCategory.conflict,
      RustCloudSyncRawFailureCategory.localStorage =>
        CloudFailureCategory.localStorage,
      RustCloudSyncRawFailureCategory.unknown => CloudFailureCategory.unknown,
    };
    return CloudSyncFailure(
      category: category,
      retryAfter: retryAfter,
      safeCode: failure.safeCode,
    );
  }
}

/// Typed façade over generated FRB internals. The public adapter above keeps
/// generated DTOs behind an injectable seam, while binding drift is caught by
/// the analyzer instead of at runtime.
final class FrbRustCloudSyncTransportBindings
    implements RustCloudSyncTransportBindings {
  FrbRustCloudSyncTransportBindings({RustLibApi? api})
    // ignore: invalid_use_of_internal_member
    : _api = api ?? RustLib.instance.api;

  final RustLibApi _api;

  @override
  Future<RustCloudSyncRawFetchResult> fetchRawPage({
    required Object cloudMessagesClient,
    required String stream,
    required Uint8List? continuationToken,
    required int maximumChanges,
  }) async {
    final result = await _api.crateApiApiCloudSyncFetchRawPage(
      cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
      stream: stream,
      continuationToken: continuationToken,
      maxChanges: maximumChanges,
    );
    final page = result.page;
    final failure = result.failure;
    return RustCloudSyncRawFetchResult(
      page: page == null ? null : _pageFromFrb(page),
      failure: failure == null ? null : _failureFromFrb(failure),
    );
  }

  frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider
  _requireCloudMessagesClient(Object value) {
    if (value is! frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw ArgumentError(
        'cloudMessagesClient must be the generated FRB Cloud Messages client',
      );
    }
    return value;
  }

  RustCloudSyncRawPage _pageFromFrb(frb_api.CloudSyncRawPage page) {
    return RustCloudSyncRawPage(
      changes: page.changes.map(_changeFromFrb).toList(growable: false),
      nextToken: _bytesOrNull(page.nextToken),
      status: page.status,
      complete: page.complete,
    );
  }

  RustCloudSyncRawChange _changeFromFrb(frb_api.CloudSyncRawChange change) {
    final system = change.systemFields;
    return RustCloudSyncRawChange(
      kind: _recordKind(change.kind),
      recordName: change.recordName,
      recordType: change.recordType,
      changeType: change.changeType,
      systemFields: system == null
          ? null
          : RustCloudSyncRawSystemFields(
              etag: system.etag,
              createdAt: system.createdAt,
              modifiedAt: system.modifiedAt,
              permission: system.permission,
            ),
      encryptedRecord: _bytesOrNull(change.encryptedRecord),
      tombstonePayload: _bytesOrNull(change.tombstonePayload),
    );
  }

  RustCloudSyncRawFailure _failureFromFrb(frb_api.CloudSyncRawFailure failure) {
    return RustCloudSyncRawFailure(
      category: _failureCategory(failure.category),
      retryAfterSeconds: failure.retryAfterSeconds?.toInt(),
      safeCode: failure.safeCode,
    );
  }

  Uint8List? _bytesOrNull(Uint8List? value) =>
      value == null ? null : Uint8List.fromList(value);

  RustCloudSyncRawRecordKind _recordKind(frb_api.CloudSyncRawRecordKind kind) =>
      switch (kind) {
        frb_api.CloudSyncRawRecordKind.encryptedUpsert =>
          RustCloudSyncRawRecordKind.encryptedUpsert,
        frb_api.CloudSyncRawRecordKind.tombstone =>
          RustCloudSyncRawRecordKind.tombstone,
        frb_api.CloudSyncRawRecordKind.unsupportedRecordType =>
          RustCloudSyncRawRecordKind.unsupportedRecordType,
        frb_api.CloudSyncRawRecordKind.malformedMetadata =>
          RustCloudSyncRawRecordKind.malformedMetadata,
      };

  RustCloudSyncRawFailureCategory _failureCategory(
    frb_api.CloudSyncRawFailureCategory category,
  ) => switch (category) {
    frb_api.CloudSyncRawFailureCategory.network =>
      RustCloudSyncRawFailureCategory.network,
    frb_api.CloudSyncRawFailureCategory.throttled =>
      RustCloudSyncRawFailureCategory.throttled,
    frb_api.CloudSyncRawFailureCategory.server =>
      RustCloudSyncRawFailureCategory.server,
    frb_api.CloudSyncRawFailureCategory.authorization =>
      RustCloudSyncRawFailureCategory.authorization,
    frb_api.CloudSyncRawFailureCategory.pcsUnavailable =>
      RustCloudSyncRawFailureCategory.pcsUnavailable,
    frb_api.CloudSyncRawFailureCategory.malformedRecord =>
      RustCloudSyncRawFailureCategory.malformedRecord,
    frb_api.CloudSyncRawFailureCategory.conflict =>
      RustCloudSyncRawFailureCategory.conflict,
    frb_api.CloudSyncRawFailureCategory.localStorage =>
      RustCloudSyncRawFailureCategory.localStorage,
    frb_api.CloudSyncRawFailureCategory.unknown =>
      RustCloudSyncRawFailureCategory.unknown,
  };
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

String _digestValue(String value) =>
    'sha256:${sha256.convert(utf8.encode(value))}';

int _utf8ByteLength(String value) {
  var bytes = 0;
  for (var index = 0; index < value.length; index++) {
    final codeUnit = value.codeUnitAt(index);
    if (codeUnit <= 0x7f) {
      bytes += 1;
    } else if (codeUnit <= 0x7ff) {
      bytes += 2;
    } else if (codeUnit >= 0xd800 &&
        codeUnit <= 0xdbff &&
        index + 1 < value.length) {
      final next = value.codeUnitAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        index++;
      } else {
        // Match the UTF-8 replacement width for a malformed surrogate.
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}
