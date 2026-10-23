// Counts retained Windows provenance only. Never grants Canary merge eligibility.
// Run explicitly after the parent releases its live job; opens disposable copies.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_message_dependency.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _project = 'C:/Codex/OpenBubblesReview';
const _evidence =
    '$_project/worktrees/cloudkit-v2-update-seam-live-bbfa/build-evidence';
const _outputRoot = '$_evidence/local-history-recovery-20261020';
const _pairRoot =
    '$_project/device-evidence/alpha-canary-local-backfill-refresh-20261021T064917Z';
const _windowsRoot =
    '$_evidence/message-parent-diagnostics-20261022/CHAT_CONFLICT_SNAPSHOT_20261023_CC';
const _scratchRoot = '$_project/scratch';
const _copyPrefix = 'alpha-windows-provenance-';
const _notReady = 'cloud_sync_local_mutation_predecessor_not_ready';
const _mapConflict = 'semantic_record_mapping_conflict';

typedef _Capture = ({
  String lane,
  File database,
  File qualification,
  String hash,
  int bytes,
  String qualificationHash,
  String capturedAtUtc,
});

String _slash(String path) => path.replaceAll('\\', '/');
void _require(bool condition) {
  if (!condition) {
    throw StateError('alpha_windows_provenance_check_failed');
  }
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
Future<void> _plain(FileSystemEntity entity) async {
  _require(
    _slash(await entity.resolveSymbolicLinks()) == _slash(entity.absolute.path),
  );
  _require(
    await FileSystemEntity.type(entity.path, followLinks: false) ==
        (entity is Directory
            ? FileSystemEntityType.directory
            : FileSystemEntityType.file),
  );
}

Future<_Capture> _qualify(String lane, String pairRoot) async {
  final windows = lane == 'windows';
  final root = Directory(windows ? _windowsRoot : '$pairRoot/$lane');
  await _plain(root);
  final database = File('${root.path}/data.mdb');
  final qualification = File(
    '${root.path}/${windows ? 'QUALIFICATION.json' : 'capture-qualification.json'}',
  );
  await _plain(database);
  await _plain(qualification);
  final encoded = await qualification.readAsBytes();
  final proof = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
  final bytes = windows ? 161165312 : (lane == 'alpha' ? 72388608 : 141053952);
  final hash = switch (lane) {
    'alpha' =>
      'f7dc8557c4e8fc778e8ad429297dcce3ca39e85449f2bafe9ef937d938c1d562',
    'canary' =>
      '50c57e2aca3f031697fdbc4a27bbf8bc8e01870b303573957ce1e57889011c1b',
    _ => 'da2855924e18cb14af59012ffad8fcf57b626cf609cc81c5350a7576d09ac713',
  };
  _require(await database.length() == bytes && proof['bytes'] == bytes);
  _require(await _hash(database) == hash);
  for (final key
      in windows
          ? ['source_before_sha256', 'source_after_sha256', 'copy_sha256']
          : ['databaseSha256', 'remoteBeforeSha256', 'remoteAfterSha256']) {
    _require(proof[key] == hash);
  }
  final captured = DateTime.parse(
    proof[windows ? 'captured_utc' : 'capturedAtUtc'] as String,
  );
  _require(captured.isUtc);
  if (windows) {
    _require(
      proof['write_sharing_denied'] == true &&
          proof['profile_mutex_held'] == true &&
          proof['no_profile_owner'] == true &&
          proof['native_requests'] == 0,
    );
    _require(
      proof['purpose'] ==
          'inspect_mapping_hold_after_group_source_recovery_and_200_chat_applies',
    );
    _require(
      captured.year == 2026 && captured.month == 10 && captured.day == 23,
    );
  } else {
    _require(
      proof['stable'] == true &&
          proof['package'] ==
              (lane == 'alpha'
                  ? 'com.bluebubbles.messaging.alpha'
                  : 'com.bluebubbles.messaging.cloudkitcanary'),
    );
    _require(
      captured ==
          DateTime.parse(
            lane == 'alpha'
                ? '2026-10-21T06:49:29.451999Z'
                : '2026-10-21T06:49:48.563280Z',
          ),
    );
  }
  return (
    lane: lane,
    database: database,
    qualification: qualification,
    hash: hash,
    bytes: bytes,
    qualificationHash: sha256.convert(encoded).toString(),
    capturedAtUtc: captured.toIso8601String(),
  );
}

Future<void> _unchanged(_Capture capture) async {
  await _plain(capture.database);
  await _plain(capture.qualification);
  _require(await capture.database.length() == capture.bytes);
  _require(await _hash(capture.database) == capture.hash);
  _require(await _hash(capture.qualification) == capture.qualificationHash);
}

Future<void> _allUnchanged(List<_Capture> captures) async {
  var intact = true;
  for (final capture in captures) {
    try {
      await _unchanged(capture);
    } catch (_) {
      intact = false;
    }
  }
  _require(intact);
}

Future<T> _readCopy<T>(_Capture capture, T Function(Store) read) async {
  await _unchanged(capture);
  final scratch = Directory(_scratchRoot);
  await _plain(scratch);
  final copy = await scratch.createTemp(_copyPrefix);
  final owned = _slash(copy.absolute.path);
  Store? opened;
  try {
    await _plain(copy);
    _require(
      _slash(copy.parent.absolute.path) == _scratchRoot &&
          owned.startsWith('$_scratchRoot/$_copyPrefix'),
    );
    final database = File('$owned/data.mdb');
    await database.create(exclusive: true);
    await capture.database.openRead().pipe(database.openWrite());
    await _plain(database);
    _require(
      await database.length() == capture.bytes &&
          await _hash(database) == capture.hash,
    );
    final store = await openStore(directory: owned);
    opened = store;
    return store.runInTransaction(TxMode.read, () => read(store));
  } finally {
    try {
      opened?.close();
      await _plain(copy);
      _require(
        _slash(copy.absolute.path) == owned &&
            _slash(copy.parent.absolute.path) == _scratchRoot &&
            owned.startsWith('$_scratchRoot/$_copyPrefix'),
      );
      // Only this createTemp owner may remove this exact disposable directory.
      await for (final child in copy.list(followLinks: false)) {
        _require(
          await FileSystemEntity.type(child.path, followLinks: false) ==
              FileSystemEntityType.file,
        );
      }
      await copy.delete(recursive: true);
      _require(!await copy.exists());
    } finally {
      await _unchanged(capture);
    }
  }
}

List<T> _bounded<T>(QueryBuilder<T> builder) {
  final query = builder.build()..limit = 2;
  try {
    return query.find();
  } finally {
    query.close();
  }
}

Set<String> _guids(Store store) {
  final query = store.box<Message>().query().build();
  final property = query.property(Message_.guid);
  try {
    return property.find().toSet();
  } finally {
    property.close();
    query.close();
  }
}

// This diagnostic never changes a helper verdict or labels every not_ready
// failure a tombstone. It needs positive, same-scope blocking evidence.
bool _blocked(
  Store store,
  CloudSyncScope scope,
  int generation,
  CloudSemanticSnapshotEntity snapshot,
  Message message,
) {
  if (message.dateDeleted != null) {
    return true;
  }
  final guid = message.guid;
  if (guid == null ||
      snapshot.scopeKey != cloudSyncPersistentScopeKey(scope) ||
      snapshot.accountFingerprint != scope.accountFingerprint ||
      snapshot.container != scope.container ||
      snapshot.database != scope.database ||
      snapshot.zone != scope.zone ||
      snapshot.streamKind != scope.streamKind.name ||
      snapshot.schemaVersion != scope.schemaVersion ||
      snapshot.generation != generation ||
      snapshot.entityKind != CloudEntityKind.message.name ||
      snapshot.canonicalGuidHash !=
          CloudCanonicalIdentityDigest.forCanonicalGuid(
            scope: scope,
            generation: generation,
            kind: CloudEntityKind.message,
            logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
            canonicalGuid: guid,
          )) {
    return false;
  }
  if (snapshot.retractedAtMs >= 0) {
    return true;
  }
  final maps = _bounded(
    store.box<CloudRecordMapEntity>().query(
      CloudRecordMapEntity_.mapKey.equals(
        cloudSyncCanonicalRecordMapKey(scope, snapshot.logicalEntityKeyHash),
      ),
    ),
  );
  if (maps.length != 1) {
    return false;
  }
  final map = maps.single;
  if (map.scopeKey != cloudSyncPersistentScopeKey(scope) ||
      map.accountFingerprint != scope.accountFingerprint ||
      map.zone != scope.zone ||
      map.logicalEntityKeyHash != snapshot.logicalEntityKeyHash) {
    return false;
  }
  if (map.generation != generation ||
      map.rawRecordGeneration != generation ||
      map.protectedReadbackLeaseReference != null ||
      map.pendingUpdateOperationId != null ||
      map.pendingUpdatePredecessorEtagHash != null) {
    return true;
  }
  final query =
      (store.box<CloudInboxChangeEntity>().query(
            CloudInboxChangeEntity_.scopeKey
                .equals(map.scopeKey)
                .and(
                  CloudInboxChangeEntity_.accountFingerprint.equals(
                    scope.accountFingerprint,
                  ),
                )
                .and(CloudInboxChangeEntity_.zone.equals(scope.zone))
                .and(CloudInboxChangeEntity_.generation.equals(generation))
                .and(
                  CloudInboxChangeEntity_.serverRecordIdHash.equals(
                    map.serverRecordIdHash,
                  ),
                ),
          )..order(
            CloudInboxChangeEntity_.fetchSequence,
            flags: Order.descending,
          ))
          .build()
        ..limit = 2;
  try {
    final rows = query.find();
    if (rows.isEmpty ||
        (rows.length == 2 && rows[0].fetchSequence == rows[1].fetchSequence)) {
      return false;
    }
    final latest =
        rows[0]; // Ordered latest version, never an ownership selection.
    return latest.isTombstone ||
        latest.changeType == CloudChangeType.delete.name ||
        latest.status != CloudInboxStatus.applied.index;
  } finally {
    query.close();
  }
}

Map<String, Object> _countWindows(Store store, Set<String> candidates) {
  final counts = <String, int>{
    'proved': 0,
    'absent': 0,
    'duplicate': 0,
    'stalePendingTombstone': 0,
    'otherGuardFailure': 0,
    'uniqueMatches': 0,
  };
  final failures = <String, int>{_notReady: 0, _mapConflict: 0};
  final scopeFailures = <String, int>{'zeroScopes': 0, 'multipleScopes': 0};
  void count(String key) => counts[key] = counts[key]! + 1;
  final checkpoints = store.box<CloudSyncCheckpointEntity>().getAll().where(
    (cp) =>
        cp.container == 'com.apple.messages.cloud' &&
        cp.database == 'private' &&
        cp.zone == 'messageManateeZone' &&
        cp.streamKind == CloudSyncStreamKind.messages.name &&
        cp.schemaVersion == cloudSyncSchemaVersion &&
        cp.persistenceLane == CloudSyncPersistenceLane.semantic.name,
  );
  final scopes = <({CloudSyncScope scope, int generation})>[];
  for (final cp in checkpoints) {
    final scope = CloudSyncScope(
      accountFingerprint: cp.accountFingerprint,
      container: cp.container,
      database: cp.database,
      zone: cp.zone,
      streamKind: CloudSyncStreamKind.messages,
      schemaVersion: cp.schemaVersion,
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    if (cp.generation > 0 &&
        cp.checkpointKey == cloudSyncPersistentScopeKey(scope)) {
      scopes.add((scope: scope, generation: cp.generation));
    }
  }
  for (final guid in candidates) {
    final messages = _bounded(
      store.box<Message>().query(
        Message_.guid.equals(guid, caseSensitive: true),
      ),
    );
    if (messages.isEmpty) {
      count('absent');
      continue;
    }
    if (messages.length != 1) {
      count('duplicate');
      continue;
    }
    count('uniqueMatches');
    final message = messages.single;
    _require(message.guid == guid);
    final claims =
        <
          ({
            CloudSyncScope scope,
            int generation,
            CloudSemanticSnapshotEntity snapshot,
          })
        >[];
    var ambiguous = false;
    for (final current in scopes) {
      final lookup = CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
        scope: current.scope,
        generation: current.generation,
        canonicalGuid: guid,
      );
      final snapshots = _bounded(
        store.box<CloudSemanticSnapshotEntity>().query(
          CloudSemanticSnapshotEntity_.scopeKey
              .equals(cloudSyncPersistentScopeKey(current.scope))
              .and(
                CloudSemanticSnapshotEntity_.canonicalGuidLookupHash.equals(
                  lookup,
                ),
              ),
        ),
      );
      if (snapshots.length > 1) {
        ambiguous = true;
      }
      if (snapshots.length == 1) {
        claims.add((
          scope: current.scope,
          generation: current.generation,
          snapshot: snapshots.single,
        ));
      }
    }
    if (ambiguous || claims.length != 1) {
      final reason = ambiguous || claims.length > 1
          ? 'multipleScopes'
          : 'zeroScopes';
      scopeFailures[reason] = scopeFailures[reason]! + 1;
      count('otherGuardFailure');
      continue;
    }
    final claim = claims.single;
    try {
      final outgoing = message.isFromMe;
      if (outgoing == null) {
        count('otherGuardFailure');
        continue;
      }
      final proof = outgoing
          ? requireCloudSyncMessageMutationPredecessor(
              store: store,
              messageScope: claim.scope,
              localMessageId: message.id ?? 0,
              localChatId: message.chat.targetId,
              targetGuidHash:
                  CloudSyncReceivedArchiveJournal.localSendGuidHashFor(guid),
            )
          : requireCloudSyncReceivedMessageMutationPredecessor(
              store: store,
              messageScope: claim.scope,
              localMessageId: message.id ?? 0,
              localChatId: message.chat.targetId,
              origin: CloudSyncReceivedArchiveOrigin.incoming,
              targetGuidHash: CloudSyncReceivedArchiveJournal.guidHashFor(guid),
            );
      _require(
        proof.generation == claim.generation &&
            proof.localMessageId == message.id,
      );
      // The public helper already checked exact owner, map, ETag and applied
      // source. Refuse a tied latest sequence rather than relying on findFirst.
      final rows = _bounded(
        store.box<CloudInboxChangeEntity>().query(
          CloudInboxChangeEntity_.scopeKey
              .equals(cloudSyncPersistentScopeKey(claim.scope))
              .and(CloudInboxChangeEntity_.generation.equals(claim.generation))
              .and(
                CloudInboxChangeEntity_.serverRecordIdHash.equals(
                  proof.recordMapping.serverRecordIdHash,
                ),
              ),
        )..order(
          CloudInboxChangeEntity_.fetchSequence,
          flags: Order.descending,
        ),
      );
      if (rows.isEmpty ||
          (rows.length == 2 &&
              rows[0].fetchSequence == rows[1].fetchSequence)) {
        count('otherGuardFailure');
      } else if (_blocked(
        store,
        claim.scope,
        claim.generation,
        claim.snapshot,
        message,
      )) {
        count('stalePendingTombstone');
      } else {
        count('proved');
      }
    } on CloudSyncFailure catch (failure) {
      final code = failure.safeCode;
      // Unknown codes/errors abort the report through the sanitized outer catch.
      _require(code == _notReady || code == _mapConflict);
      failures[code!] = failures[code]! + 1;
      count(
        code == _notReady &&
                _blocked(
                  store,
                  claim.scope,
                  claim.generation,
                  claim.snapshot,
                  message,
                )
            ? 'stalePendingTombstone'
            : 'otherGuardFailure',
      );
    }
  }
  _require(
    counts['proved']! +
            counts['absent']! +
            counts['duplicate']! +
            counts['stalePendingTombstone']! +
            counts['otherGuardFailure']! ==
        candidates.length,
  );
  return {
    'counts': counts,
    'helperGuardFailureCounts': failures,
    'scopeFailureCounts': scopeFailures,
  };
}

void main() {
  final destination =
      Platform.environment['OPENBUBBLES_ALPHA_WINDOWS_PROVENANCE_RESULT'];
  test(
    'count qualified Alpha GUIDs with retained Windows provenance',
    () async {
      try {
        _require(destination != null && destination.isNotEmpty);
        final output = File(destination!);
        _require(
          output.isAbsolute &&
              _slash(output.parent.absolute.path) == _outputRoot &&
              RegExp(
                r'^[A-Za-z0-9][A-Za-z0-9_-]*\.json$',
              ).hasMatch(output.uri.pathSegments.last),
        );
        await _plain(output.parent);
        _require(
          await FileSystemEntity.type(output.path, followLinks: false) ==
              FileSystemEntityType.notFound,
        );
        final pairRoot =
            Platform
                .environment['OPENBUBBLES_DELETION_COVERAGE_CAPTURE_ROOT'] ??
            _pairRoot;
        _require(_slash(Directory(pairRoot).absolute.path) == _pairRoot);
        await _plain(Directory(pairRoot));
        final captures = <_Capture>[];
        late Map<String, Object> results;
        late int missing;
        try {
          // Qualify every original before any ObjectBox open; only one copy exists
          // at a time. Candidate GUIDs never leave this process or enter the report.
          for (final lane in ['alpha', 'canary', 'windows']) {
            captures.add(await _qualify(lane, pairRoot));
          }
          final candidates = await _readCopy(captures[0], _guids);
          await _readCopy(
            captures[1],
            (store) => candidates.removeAll(_guids(store)),
          );
          missing = candidates.length;
          _require(
            missing == 1918 && candidates.every((guid) => guid.isNotEmpty),
          );
          results = await _readCopy(
            captures[2],
            (store) => _countWindows(store, candidates),
          );
          candidates.clear();
        } finally {
          await _allUnchanged(captures);
        }
        final report = <String, Object>{
          'status': 'offline-alpha-windows-provenance-counts-only',
          'scope':
              'Windows retained provenance; NOT deletion-safe Canary merge',
          'sourceBaseline': '55363477da7aa4173ac45c0b721d26ad6f9ea827',
          'captureBoundMissingGuidSanity': missing,
          'captures': [
            for (final c in captures)
              {
                'lane': c.lane,
                'databaseSha256': c.hash,
                'bytes': c.bytes,
                'capturedAtUtc': c.capturedAtUtc,
                'qualificationSha256': c.qualificationHash,
              },
          ],
          ...results,
          'originalDatabasesChanged': false,
          'originalQualificationsChanged': false,
          'ownedDisposableCopiesRemoved': true,
          'maximumConcurrentCopies': 1,
          'networkCalls': 0,
          'nativeRequests': 0,
          'accountOperations': 0,
          'originalDatabaseWrites': 0,
          'canonicalMutationCalls': 0,
          'outboxDispatches': 0,
          'remoteWrites': 0,
          'deviceWrites': 0,
          'localWrites': 'disposable copies and new aggregate report only',
          'snapshotAccountOwnershipQualified': false,
          'cloudPresenceProved': false,
          'liveMergeEligible': false,
        };
        await output.create(exclusive: true);
        await _plain(output);
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true,
        );
        // ignore: avoid_print
        print('ALPHA_WINDOWS_PROVENANCE_SUBSET=${jsonEncode(report)}');
      } catch (_) {
        // Never emit raw ObjectBox/IO errors or interpolated source identifiers.
        fail('alpha_windows_provenance_subset_failed');
      }
    },
    skip: destination == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
