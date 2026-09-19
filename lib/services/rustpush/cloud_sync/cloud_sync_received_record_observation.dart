import 'dart:convert';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'cloud_sync_received_archive_source_binding.dart';

enum CloudSyncReceivedRecordState {
  equivalent,
  needsProjection,
  conflictingIdentity,
  absent,
  unresolved,
}

/// Bound read evidence only. Even Absent is not a durable create permit.
/// Found observations own the exact protected raw version for later normal
/// projection/adoption; no existing record may be overwritten by this lane.
final class CloudSyncReceivedRecordObservation {
  CloudSyncReceivedRecordObservation({
    required this.state,
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.messageGuidHash,
    required this.sourceSha256,
    required this.logicalEntityKeyHash,
    required this.serverRecordIdHash,
    required this.generation,
    required this.parentBinding,
    required this.observedAtMs,
    this.etagHash,
    this.rawReference,
    this.rawLeaseReference,
  }) {
    final found =
        state == CloudSyncReceivedRecordState.equivalent ||
        state == CloudSyncReceivedRecordState.needsProjection ||
        state == CloudSyncReceivedRecordState.conflictingIdentity;
    if (!_hash.hasMatch(accountFingerprint) ||
        !_store.hasMatch(protectedStoreIdentity) ||
        !_sha.hasMatch(messageGuidHash) ||
        !_sha.hasMatch(sourceSha256) ||
        !_hash.hasMatch(logicalEntityKeyHash) ||
        !_hash.hasMatch(serverRecordIdHash) ||
    generation <= 0 ||
    observedAtMs <= 0 ||
    parentBinding.isEmpty ||
    parentBinding.length > 1536 ||
        (found
            ? etagHash == null ||
                  !_hash.hasMatch(etagHash!) ||
                  rawReference == null ||
                  !_ref.hasMatch(rawReference!) ||
                  rawLeaseReference == null ||
                  !_lease.hasMatch(rawLeaseReference!)
            : etagHash != null ||
                  rawReference != null ||
                  rawLeaseReference != null) ||
        encode().length > 4096) {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
  }
  factory CloudSyncReceivedRecordObservation.fromNative(
    api.CloudSyncReceivedRecordObservation value, {
    required CloudSyncReceivedArchiveSourceBinding source,
    required String parentBinding,
    required DateTime now,
  }) => CloudSyncReceivedRecordObservation(
    state: switch (value.disposition) {
      api.CloudSyncReceivedRecordDisposition.equivalent =>
        CloudSyncReceivedRecordState.equivalent,
      api.CloudSyncReceivedRecordDisposition.needsProjection =>
        CloudSyncReceivedRecordState.needsProjection,
      api.CloudSyncReceivedRecordDisposition.conflictingIdentity =>
        CloudSyncReceivedRecordState.conflictingIdentity,
      api.CloudSyncReceivedRecordDisposition.absent =>
        CloudSyncReceivedRecordState.absent,
      api.CloudSyncReceivedRecordDisposition.unresolved =>
        CloudSyncReceivedRecordState.unresolved,
    },
    accountFingerprint: source.accountFingerprint,
    protectedStoreIdentity: source.protectedStoreIdentity,
    messageGuidHash: value.messageGuidHash,
    sourceSha256: value.sourceSha256,
    logicalEntityKeyHash: value.logicalEntityKeyHash,
    serverRecordIdHash: value.serverRecordIdHash,
    generation: value.rawGeneration.toInt(),
    parentBinding: parentBinding,
    observedAtMs: now.toUtc().millisecondsSinceEpoch,
    etagHash: value.etagHash,
    rawReference: value.protectedRawRecordReference,
    rawLeaseReference: value.protectedRawRecordLeaseReference,
  );

  final CloudSyncReceivedRecordState state;
  final String accountFingerprint,
      protectedStoreIdentity,
      messageGuidHash,
      sourceSha256;
  final String logicalEntityKeyHash, serverRecordIdHash, parentBinding;
  final int generation, observedAtMs;
  final String? etagHash, rawReference, rawLeaseReference;
  static final _hash = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _sha = RegExp(r'^[0-9a-f]{64}$');
  static final _store = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
  static final _ref = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
  static final _lease = RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$');
  void requireSource(CloudSyncReceivedArchiveSourceBinding source) {
    if (source.isSeed ||
        accountFingerprint != source.accountFingerprint ||
        protectedStoreIdentity != source.protectedStoreIdentity ||
        messageGuidHash != source.messageGuidHash ||
        sourceSha256 != source.sourceSha256) {
      throw StateError('cloud_sync_received_archive_observation_changed');
    }
  }

  String encode() => jsonEncode([
    1,
    state.index,
    accountFingerprint,
    protectedStoreIdentity,
    messageGuidHash,
    sourceSha256,
    logicalEntityKeyHash,
    serverRecordIdHash,
    generation,
    parentBinding,
    observedAtMs,
    etagHash,
    rawReference,
    rawLeaseReference,
  ]);
  static CloudSyncReceivedRecordObservation decode(String encoded) {
    if (encoded.length > 4096) {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
    dynamic v;
    try {
      v = jsonDecode(encoded);
    } on FormatException {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
    if (v is! List ||
        v.length != 14 ||
        v[0] != 1 ||
        v[1] is! int ||
        v[1] < 0 ||
        v[1] >= CloudSyncReceivedRecordState.values.length ||
        v.sublist(2, 8).any((f) => f is! String) ||
        v[8] is! int ||
        v[9] is! String ||
        v[10] is! int ||
        v.sublist(11).any((f) => f != null && f is! String)) {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
    final result = CloudSyncReceivedRecordObservation(
      state: CloudSyncReceivedRecordState.values[v[1]],
      accountFingerprint: v[2],
      protectedStoreIdentity: v[3],
      messageGuidHash: v[4],
      sourceSha256: v[5],
      logicalEntityKeyHash: v[6],
      serverRecordIdHash: v[7],
      generation: v[8],
      parentBinding: v[9],
      observedAtMs: v[10],
      etagHash: v[11],
      rawReference: v[12],
      rawLeaseReference: v[13],
    );
    if (result.encode() != encoded) {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
    return result;
  }

  @override
  String toString() => 'CloudSyncReceivedRecordObservation(redacted)';
}

/// Source-bound discovery adoption marker. Version 2 encoding carries NO
/// logical-entity hash and NO parent binding: both are unavailable without
/// a proven parent, and this representation makes that absence explicit
/// instead of fabricating values into the v1 codec. Readers must check
/// the version tag before interpreting it as a parent-bound observation.
final class CloudSyncReceivedDiscoveryObservation {
  CloudSyncReceivedDiscoveryObservation({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.messageGuidHash,
    required this.sourceSha256,
    required this.serverRecordIdHash,
    required this.generation,
    required this.observedAtMs,
  }) {
    if (!_hash.hasMatch(accountFingerprint) ||
        !_store.hasMatch(protectedStoreIdentity) ||
        !_sha.hasMatch(messageGuidHash) ||
        !_sha.hasMatch(sourceSha256) ||
        !_hash.hasMatch(serverRecordIdHash) ||
        generation <= 0 ||
        observedAtMs <= 0 ||
        encode().length > 4096) {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
  }

  final String accountFingerprint;
  final String protectedStoreIdentity;
  final String messageGuidHash;
  final String sourceSha256;
  final String serverRecordIdHash;
  final int generation;
  final int observedAtMs;
  static final _hash = CloudSyncReceivedRecordObservation._hash;
  static final _sha = CloudSyncReceivedRecordObservation._sha;
  static final _store = CloudSyncReceivedRecordObservation._store;
  void requireSource(CloudSyncReceivedArchiveSourceBinding source) {
    if (source.isSeed ||
        accountFingerprint != source.accountFingerprint ||
        protectedStoreIdentity != source.protectedStoreIdentity ||
        messageGuidHash != source.messageGuidHash ||
        sourceSha256 != source.sourceSha256) {
      throw StateError('cloud_sync_received_archive_observation_changed');
    }
  }

  String encode() => jsonEncode([
    2,
    accountFingerprint,
    protectedStoreIdentity,
    messageGuidHash,
    sourceSha256,
    serverRecordIdHash,
    generation,
    observedAtMs,
  ]);
  static CloudSyncReceivedDiscoveryObservation decode(String encoded) {
    if (encoded.length > 4096) {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
    dynamic v;
    try {
      v = jsonDecode(encoded);
    } on FormatException {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
    if (v is! List ||
        v.length != 8 ||
        v[0] != 2 ||
        v.sublist(1, 6).any((f) => f is! String) ||
        v[6] is! int ||
        v[7] is! int) {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
    final result = CloudSyncReceivedDiscoveryObservation(
      accountFingerprint: v[1],
      protectedStoreIdentity: v[2],
      messageGuidHash: v[3],
      sourceSha256: v[4],
      serverRecordIdHash: v[5],
      generation: v[6],
      observedAtMs: v[7],
    );
    if (result.encode() != encoded) {
      throw StateError('cloud_sync_received_archive_observation_invalid');
    }
    return result;
  }

  static bool isEncoded(String? encoded) =>
      encoded != null && encoded.startsWith('[2,');

  @override
  String toString() => 'CloudSyncReceivedDiscoveryObservation(redacted)';
}
