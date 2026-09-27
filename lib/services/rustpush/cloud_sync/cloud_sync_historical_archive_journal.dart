import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';

/// Validate a retained row using its own scope, not the current signed-in user.
/// GC and interrupted lease recovery must retain old accounts and snapshots.
/// This metadata check grants no native lease proof or remote-write authority.
CloudSyncHistoricalProtectedSourceBinding validateCloudSyncHistoricalArchiveRow(
  CloudSyncHistoricalArchiveIntentEntity row,
) {
  final source = CloudSyncHistoricalProtectedSourceBinding.decode(
    row.protectedSourceBinding,
  );
  final scopeKey = CloudSyncHistoricalArchiveJournal._hash([
    'historical-archive-scope-v1',
    source.accountFingerprint,
    source.protectedStoreIdentity,
    source.snapshotSha256,
  ]);
  final intentKey = CloudSyncHistoricalArchiveJournal._hash([
    'historical-archive-intent-v1',
    scopeKey,
    source.messageGuidHash,
  ]);
  if (row.id < 1 ||
      row.scopeKey != scopeKey ||
      row.intentKey != intentKey ||
      (row.state != 0 && row.state != 1 && row.state != 2) ||
      row.createdAtMs < 1 ||
      row.updatedAtMs < row.createdAtMs) {
    throw StateError('cloud_sync_historical_journal_record_invalid');
  }
  _historicalReaderChangeId(row, source);
  return source;
}

// A reader handoff is bound to the complete historical source, not just its
// GUID. It records no write permission, parent proof or live-receive receipt.
String? _historicalReaderChangeId(
  CloudSyncHistoricalArchiveIntentEntity row,
  CloudSyncHistoricalProtectedSourceBinding source,
) {
  final encoded = row.readerObservationBinding;
  if (row.state != 2) {
    if (encoded != null) {
      throw StateError('cloud_sync_historical_reader_binding_invalid');
    }
    return null;
  }
  final dynamic value;
  try {
    if (encoded == null || encoded.length > 1024) throw const FormatException();
    value = jsonDecode(encoded);
  } on FormatException {
    throw StateError('cloud_sync_historical_reader_binding_invalid');
  }
  final token = RegExp(r'^[A-Za-z0-9_-]{43}$');
  final digest = RegExp(r'^[a-f0-9]{64}$');
  if (value is! List ||
      value.length != 7 ||
      value[0] != 1 ||
      value[1] != sha256.convert(utf8.encode(source.encode())).toString() ||
      value.sublist(2, 5).any((v) => v is! String || !token.hasMatch(v)) ||
      value[5] is! String ||
      !digest.hasMatch(value[5] as String) ||
      value[6] is! int ||
      (value[6] as int) < 1 ||
      jsonEncode(value) != encoded) {
    throw StateError('cloud_sync_historical_reader_binding_invalid');
  }
  return value[2] as String;
}

/// A local staging record. Even [sourceLeaseCommitted] does not mean uploaded.
final class CloudSyncHistoricalArchiveIntent {
  const CloudSyncHistoricalArchiveIntent._({
    required this.id,
    required this.source,
    required this.sourceLeaseCommitted,
    required this.readerChangeId,
  });

  final int id;
  final CloudSyncHistoricalProtectedSourceBinding source;
  final bool sourceLeaseCommitted;
  final String? readerChangeId;

  @override
  String toString() => 'CloudSyncHistoricalArchiveIntent(redacted)';
}

/// Durable source adoption for one qualified snapshot/account/installation.
///
/// The producer must look up an already-adopted source before staging another
/// envelope. Identical re-adoption is safe; a different envelope for an owned
/// key is retained as a conflict, never substituted or silently rolled back.
/// After adoption, the caller commits the exact native lease and records that
/// success here. A crash between those steps leaves a resumable adopted row.
/// No method sends IDS messages, writes CloudKit, deletes sources or grants
/// remote-write authority. Remote deduplication/readback integration is separate.
final class CloudSyncHistoricalArchiveJournal {
  CloudSyncHistoricalArchiveJournal({
    required Store store,
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.snapshotSha256,
    DateTime Function()? clock,
    // Keep the public named-store constructor and private backing store.
    // ignore: prefer_initializing_formals
  }) : _store = store,
       _clock = clock ?? DateTime.now {
    if (!_token.hasMatch(accountFingerprint) ||
        !_storeIdentity.hasMatch(protectedStoreIdentity) ||
        !_digest.hasMatch(snapshotSha256)) {
      throw StateError('cloud_sync_historical_journal_scope_invalid');
    }
  }

  final Store _store;
  final DateTime Function() _clock;
  final String accountFingerprint;
  final String protectedStoreIdentity;
  final String snapshotSha256;

  bool isBoundToStore(Store store) => identical(store, _store);

  static final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _storeIdentity = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
  static final _digest = RegExp(r'^[a-f0-9]{64}$');

  String get _scopeKey => _hash([
    'historical-archive-scope-v1',
    accountFingerprint,
    protectedStoreIdentity,
    snapshotSha256,
  ]);

  String _intentKey(String guidHash) =>
      _hash(['historical-archive-intent-v1', _scopeKey, guidHash]);

  static String _hash(List<String> fields) =>
      sha256.convert(utf8.encode(jsonEncode(fields))).toString();

  int _now() {
    final now = _clock().millisecondsSinceEpoch;
    if (now < 1) {
      throw StateError('cloud_sync_historical_journal_clock_invalid');
    }
    return now;
  }

  void _requireScope(CloudSyncHistoricalProtectedSourceBinding source) =>
      source.requireOrigin(
        accountFingerprint: accountFingerprint,
        protectedStoreIdentity: protectedStoreIdentity,
        snapshotSha256: snapshotSha256,
        messageGuidHash: source.messageGuidHash,
        sourceSha256: source.sourceSha256,
      );

  CloudSyncHistoricalArchiveIntent _decode(
    CloudSyncHistoricalArchiveIntentEntity row,
  ) {
    final source = validateCloudSyncHistoricalArchiveRow(row);
    _requireScope(source);
    return CloudSyncHistoricalArchiveIntent._(
      id: row.id,
      source: source,
      sourceLeaseCommitted: row.state >= 1,
      readerChangeId: _historicalReaderChangeId(row, source),
    );
  }

  CloudSyncHistoricalArchiveIntentEntity? _find(String guidHash) {
    final query = _store
        .box<CloudSyncHistoricalArchiveIntentEntity>()
        .query(
          CloudSyncHistoricalArchiveIntentEntity_.intentKey.equals(
            _intentKey(guidHash),
          ),
        )
        .build();
    try {
      return query.findUnique();
    } finally {
      query.close();
    }
  }

  /// Lookup before native staging, with exact reassessed source identity.
  CloudSyncHistoricalArchiveIntent? read({
    required String messageGuidHash,
    required String sourceSha256,
  }) {
    if (!_digest.hasMatch(messageGuidHash) || !_digest.hasMatch(sourceSha256)) {
      throw StateError('cloud_sync_historical_journal_source_invalid');
    }
    return _store.runInTransaction(TxMode.read, () {
      final row = _find(messageGuidHash);
      if (row == null) return null;
      final result = _decode(row);
      if (result.source.sourceSha256 != sourceSha256) {
        throw StateError('cloud_sync_historical_journal_source_conflict');
      }
      return result;
    });
  }

  /// Atomically owns the source before a producer cursor may advance past it.
  CloudSyncHistoricalArchiveIntent adopt(
    CloudSyncHistoricalProtectedSourceBinding source,
  ) {
    _requireScope(source);
    return _store.runInTransaction(TxMode.write, () {
      final existing = _find(source.messageGuidHash);
      if (existing != null) {
        final result = _decode(existing);
        if (result.source.encode() != source.encode()) {
          throw StateError('cloud_sync_historical_journal_source_conflict');
        }
        return result;
      }
      final now = _now();
      final row = CloudSyncHistoricalArchiveIntentEntity(
        intentKey: _intentKey(source.messageGuidHash),
        scopeKey: _scopeKey,
        protectedSourceBinding: source.encode(),
        createdAtMs: now,
        updatedAtMs: now,
      );
      _store.box<CloudSyncHistoricalArchiveIntentEntity>().put(row);
      return _decode(row);
    });
  }

  /// Call only after the exact native lease commit succeeds. This local marker
  /// never replaces native committed-lease verification when reopening bytes.
  CloudSyncHistoricalArchiveIntent markSourceLeaseCommitted({
    required int intentId,
    required CloudSyncHistoricalProtectedSourceBinding expectedSource,
  }) {
    _requireScope(expectedSource);
    if (intentId < 1) {
      throw StateError('cloud_sync_historical_journal_record_invalid');
    }
    return _store.runInTransaction(TxMode.write, () {
      final box = _store.box<CloudSyncHistoricalArchiveIntentEntity>();
      final row = box.get(intentId);
      if (row == null) {
        throw StateError('cloud_sync_historical_journal_record_missing');
      }
      final result = _decode(row);
      if (result.source.encode() != expectedSource.encode()) {
        throw StateError('cloud_sync_historical_journal_source_conflict');
      }
      if (result.sourceLeaseCommitted) return result;
      row.state = 1;
      final now = _now();
      row.updatedAtMs = now < row.updatedAtMs ? row.updatedAtMs : now;
      box.put(row);
      return _decode(row);
    });
  }

  /// Joins the caller's inbox write transaction. Both the source and the reader
  /// lease must be adopted atomically; this method never advances a server token
  /// or changes a Message. An already-owned exact observation is idempotent.
  void markDiscoveryAdopted({
    required Store transactionStore,
    required CloudSyncScope scope,
    required int intentId,
    required CloudSyncHistoricalProtectedSourceBinding source,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required CloudFetchedChange change,
    required int generation,
    required int observedAtMs,
  }) {
    if (!isBoundToStore(transactionStore) ||
        !stillCurrent() ||
        intentId < 1 ||
        scope.accountFingerprint != accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'messageManateeZone' ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        currentAuth.accountFingerprint != accountFingerprint ||
        currentAuth.protectedStoreIdentity != protectedStoreIdentity ||
        generation < 1 ||
        observedAtMs < 1 ||
        change.type != CloudChangeType.save ||
        change.isTombstone ||
        change.preflightFailure != null) {
      throw StateError('cloud_sync_historical_reader_admission_changed');
    }
    _requireScope(source);
    final box = _store.box<CloudSyncHistoricalArchiveIntentEntity>();
    final row = box.get(intentId);
    if (row == null) {
      throw StateError('cloud_sync_historical_journal_record_missing');
    }
    final retained = _decode(row);
    if (!retained.sourceLeaseCommitted ||
        retained.source.encode() != source.encode()) {
      throw StateError('cloud_sync_historical_reader_source_changed');
    }
    final encoded = jsonEncode(<Object?>[
      1,
      sha256.convert(utf8.encode(source.encode())).toString(),
      change.changeId,
      change.recordIdHash,
      change.etagHash,
      change.payloadSha256,
      generation,
    ]);
    if (row.readerObservationBinding != null) {
      if (row.readerObservationBinding != encoded) {
        throw StateError('cloud_sync_historical_reader_admission_changed');
      }
      return;
    }
    row
      ..state = 2
      ..readerObservationBinding = encoded;
    _historicalReaderChangeId(row, source);
    if (!stillCurrent()) {
      throw StateError('cloud_sync_historical_reader_admission_changed');
    }
    if (observedAtMs > row.updatedAtMs) row.updatedAtMs = observedAtMs;
    box.put(row);
  }

  /// Bounded recovery of adopted sources whose native commit may have been
  /// interrupted. It does not infer that a prior native commit failed.
  List<CloudSyncHistoricalArchiveIntent> pendingSourceCommits({
    int limit = 50,
  }) {
    if (limit < 1 || limit > 500) {
      throw ArgumentError('cloud_sync_historical_journal_limit_invalid');
    }
    return _store.runInTransaction(TxMode.read, () {
      final query =
          _store
              .box<CloudSyncHistoricalArchiveIntentEntity>()
              .query(
                CloudSyncHistoricalArchiveIntentEntity_.scopeKey
                    .equals(_scopeKey)
                    .and(
                      CloudSyncHistoricalArchiveIntentEntity_.state.equals(0),
                    ),
              )
              .order(CloudSyncHistoricalArchiveIntentEntity_.id)
              .build()
            ..limit = limit;
      try {
        return query.find().map(_decode).toList(growable: false);
      } finally {
        query.close();
      }
    });
  }
}
