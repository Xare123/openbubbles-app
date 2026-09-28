library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'cloud_sync_historical_archive_request.dart';

/// Canonical encoding plus dry-run staging for one assessed historical row.
///
/// Encoding binds the request plus the row text observed at stage time into
/// canonical bytes. Hashing is integrity checking, not encryption. The
/// injected HistoricalByteStore below is a test double only: production
/// protects sources through the native store behind a single stage-and-adopt
/// callback owned by the parent, never through this Dart byte store.
/// No network, no uploads, no record saves happen here.

/// Result of one atomic put-if-absent attempt.
enum HistoricalPutOutcome { stored, identicalExists, conflictingExists }

/// Atomic byte store contract for dry-run staging tests only. The store
/// must guarantee that only one writer wins a key: [putIfAbsent] returns
/// [HistoricalPutOutcome.conflictingExists] without overwriting when the
/// key already holds different bytes, and [HistoricalPutOutcome.identicalExists] when the bytes
/// match. This is not the production path: production protects sources
/// natively behind the parent-owned stage-and-adopt boundary.
abstract class HistoricalByteStore {
  Future<HistoricalPutOutcome> putIfAbsent(String key, List<int> bytes);
  Future<List<int>?> get(String key);
}

/// In-memory store for dry-run tests only.
class MemoryHistoricalByteStore implements HistoricalByteStore {
  final Map<String, List<int>> _bytes = {};

  @override
  Future<HistoricalPutOutcome> putIfAbsent(String key, List<int> bytes) async {
    final existing = _bytes[key];
    if (existing != null) {
      return _sameBytes(existing, bytes)
          ? HistoricalPutOutcome.identicalExists
          : HistoricalPutOutcome.conflictingExists;
    }
    _bytes[key] = List<int>.of(bytes);
    return HistoricalPutOutcome.stored;
  }

  @override
  Future<List<int>?> get(String key) async {
    final found = _bytes[key];
    return found == null ? null : List<int>.of(found);
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Lowercase hex SHA-256 over exact bytes. Shared by dry-run staging and
/// producer validation of stage-and-adopt results.
String historicalBytesSha256(List<int> bytes) =>
    sha256.convert(bytes).toString();

/// Sealed staged source: key plus integrity metadata, never content.
class StagedHistoricalSource {
  const StagedHistoricalSource({
    required this.key,
    required this.sha256,
    required this.byteLength,
    required this.guid,
  });

  /// Storage key, equal to the request source digest.
  final String key;
  final String sha256;
  final int byteLength;
  final String guid;
}

/// Exact canonical bytes plus the request they bind. Produced by pure
/// reassessment only; storing or adopting them is the caller's decision.
/// Bytes are defensively copied and unmodifiable, so an injected callback
/// receiving them cannot mutate the producer's copy after the fact.
class EncodedHistoricalSource {
  EncodedHistoricalSource({
    required this.request,
    required List<int> canonicalBytes,
  }) : canonicalBytes = List<int>.unmodifiable(canonicalBytes);

  final CloudSyncHistoricalArchiveRequest request;
  final List<int> canonicalBytes;
}

/// Canonical staged payload, fixed field order for stable hashes. Sender
/// and peer route are sealed alongside the text so a later stage cannot
/// substitute content or reroute the row under an unchanged key.
Map<String, Object?> stagedHistoricalPayload({
  required CloudSyncHistoricalArchiveRequest request,
  required String text,
}) => <String, Object?>{
  'format': request.parentState != null
      ? 'cloud-sync-historical-source-v3'
      : request.groupMetadata == null
          ? 'cloud-sync-historical-source-v1'
          : 'cloud-sync-historical-source-v2',
  'guid': request.guid,
  'text': text,
  'origin': request.origin.name,
  'isFromMe': request.isFromMe,
  'senderAddress': request.senderAddress,
  'peerAddress': request.peerAddress,
  'chatGuid': request.chatGuid,
  'dateCreatedMs': request.dateCreatedMs,
  'snapshotSha256': request.snapshotSha256,
  'accountFingerprint': request.accountFingerprint,
  'protectedStoreIdentity': request.protectedStoreIdentity,
  if (request.groupMetadata case final group?) 'groupMetadata': group.toWire(),
  if (request.parentState case final parent?) 'parentState': parent.toWire(),
};

/// Pure reassessment plus canonical encoding for one assessed request and
/// a completely re-read row view. The full row is re-assessed and one
/// canonical source binding is recomputed; any drift in route, time,
/// origin, sender, direction, chat, or text from the original request
/// throws instead of encoding. No bytes are stored here: the caller
/// passes the result to its own stage-and-adopt boundary.
EncodedHistoricalSource encodeHistoricalSource({
  required CloudSyncHistoricalArchiveRequest request,
  required CloudSyncHistoricalRowView currentRow,
  required CloudSyncHistoricalSourceManifest manifest,
  required CloudSyncHistoricalAccountBinding account,
  int? nowMs,
}) {
  final reassessed = assessHistoricalArchiveRow(
    currentRow,
    manifest,
    account,
    nowMs: nowMs,
  );
  if (reassessed is! CloudSyncHistoricalArchiveEligible) {
    throw StateError(
      (reassessed as CloudSyncHistoricalArchiveIneligible).reason,
    );
  }
  final fresh = reassessed.request;
  if (fresh.guid != request.guid ||
      fresh.snapshotSha256 != request.snapshotSha256 ||
      fresh.accountFingerprint != request.accountFingerprint ||
      fresh.protectedStoreIdentity != request.protectedStoreIdentity ||
      fresh.sourceSha256 != request.sourceSha256 ||
      fresh.guidHash != request.guidHash ||
      fresh.textSha256 != request.textSha256 ||
      fresh.senderAddress != request.senderAddress ||
      fresh.peerAddress != request.peerAddress ||
      fresh.chatGuid != request.chatGuid ||
      jsonEncode(fresh.groupMetadata?.toWire()) !=
          jsonEncode(request.groupMetadata?.toWire()) ||
      jsonEncode(fresh.parentState?.toWire()) !=
          jsonEncode(request.parentState?.toWire()) ||
      fresh.dateCreatedMs != request.dateCreatedMs ||
      fresh.origin != request.origin ||
      fresh.isFromMe != request.isFromMe) {
    throw StateError('cloud_sync_historical_archive_source_changed');
  }
  final text = currentRow.text;
  if (text == null || text.isEmpty) {
    throw StateError('cloud_sync_historical_archive_body_changed');
  }
  final bytes = utf8.encode(
    jsonEncode(stagedHistoricalPayload(request: request, text: text)),
  );
  if (bytes.length > cloudSyncHistoricalMaxSourceBytes) {
    throw StateError('cloud_sync_historical_archive_source_too_large');
  }
  return EncodedHistoricalSource(request: request, canonicalBytes: bytes);
}

/// Dry-run staging into an injected byte store. Shared with the producer's
/// canonical encoding above, then put/get through the test store. This is
/// for existing memory/file staging tests only; production binds the native
/// protected store through a single stage-and-adopt callback, never this.
Future<StagedHistoricalSource> stageHistoricalSource({
  required HistoricalByteStore store,
  required CloudSyncHistoricalArchiveRequest request,
  required CloudSyncHistoricalRowView currentRow,
  required CloudSyncHistoricalSourceManifest manifest,
  required CloudSyncHistoricalAccountBinding account,
  int? nowMs,
}) async {
  final encoded = encodeHistoricalSource(
    request: request,
    currentRow: currentRow,
    manifest: manifest,
    account: account,
    nowMs: nowMs,
  );
  final bytes = encoded.canonicalBytes;
  final sha = sha256.convert(bytes).toString();
  final outcome = await store.putIfAbsent(request.sourceSha256, bytes);
  if (outcome == HistoricalPutOutcome.conflictingExists) {
    throw StateError('cloud_sync_historical_archive_source_conflict');
  }
  final stored = await store.get(request.sourceSha256);
  if (stored == null || !_sameBytes(stored, bytes)) {
    throw StateError('cloud_sync_historical_archive_stage_unverified');
  }
  return StagedHistoricalSource(
    key: request.sourceSha256,
    sha256: sha,
    byteLength: bytes.length,
    guid: request.guid,
  );
}

/// Opens and revalidates one staged source. Throws on missing or changed
/// bytes; never returns unverified content.
Future<Map<String, Object?>> openHistoricalSource({
  required HistoricalByteStore store,
  required StagedHistoricalSource staged,
}) async {
  final bytes = await store.get(staged.key);
  if (bytes == null ||
      bytes.length != staged.byteLength ||
      sha256.convert(bytes).toString() != staged.sha256) {
    throw StateError('cloud_sync_historical_archive_source_changed');
  }
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, Object?>) {
    throw StateError('cloud_sync_historical_archive_source_changed');
  }
  return decoded;
}
