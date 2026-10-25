import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_fresh_group_recovery_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

// Persisted scalar audit tests only. Constructors do not open a Store, profile
// or native client; synthetic values are not evidence of dispatch eligibility.
const _operationName = 'CloudOutboxOperationEntity';
const _mapName = 'CloudRecordMapEntity';
const _sourceName = 'CloudSyncLocalSendIntentEntity';
const _nullable = <String, Set<String>>{
  _operationName: {
    'appleRequestUuid', 'appleOperationUuid', 'encryptedPayloadRef',
    'payloadSha256', 'protectedLeaseReference', 'localChatOrigin',
    'lastErrorCategory', 'serverRecordIdHash', 'leaseIdHash',
  },
  _mapName: {
    'etagHash', 'encryptedRawRecordRef', 'protectedReadbackLeaseReference',
    'pendingUpdateOperationId', 'pendingUpdatePredecessorEtagHash',
  },
  _sourceName: {
    'admittedOperationId', 'admittedBindingSha256', 'admittedChatBinding',
    'confirmedReadbackBindingSha256', 'protectedSourceBinding',
  },
};

late Map<String, List<Map<String, dynamic>>> _properties;

Map<String, Object?> _values(String entity, {bool nullOptionals = false}) => {
  for (final property in _properties[entity]!)
    property['name'] as String:
        nullOptionals && _nullable[entity]!.contains(property['name'])
        ? null
        : property['type'] == 6
        ? int.parse((property['id'] as String).split(':').first) + 100
        : 'synthetic:$entity:${property['name']}',
};

CloudOutboxOperationEntity _operation(Map<String, Object?> v) =>
    CloudOutboxOperationEntity(
      id: v['id'] as int,
      operationId: v['operationId'] as String,
      scopeKey: v['scopeKey'] as String,
      accountFingerprint: v['accountFingerprint'] as String,
      zone: v['zone'] as String,
      logicalEntityKeyHash: v['logicalEntityKeyHash'] as String,
      action: v['action'] as int,
      dependencyOperationIdsJson: v['dependencyOperationIdsJson'] as String,
      payloadVersion: v['payloadVersion'] as int,
      mutationRevision: v['mutationRevision'] as int,
      checkpointGeneration: v['checkpointGeneration'] as int,
      appleRequestUuid: v['appleRequestUuid'] as String?,
      appleOperationUuid: v['appleOperationUuid'] as String?,
      encryptedPayloadRef: v['encryptedPayloadRef'] as String?,
      payloadSha256: v['payloadSha256'] as String?,
      protectedLeaseReference: v['protectedLeaseReference'] as String?,
      localChatOrigin: v['localChatOrigin'] as String?,
      state: v['state'] as int,
      attemptCount: v['attemptCount'] as int,
      nextEligibleAtMs: v['nextEligibleAtMs'] as int,
      lastErrorCategory: v['lastErrorCategory'] as String?,
      serverRecordIdHash: v['serverRecordIdHash'] as String?,
      leaseIdHash: v['leaseIdHash'] as String?,
      leaseExpiresAtMs: v['leaseExpiresAtMs'] as int,
      confirmedAtMs: v['confirmedAtMs'] as int,
      createdAtMs: v['createdAtMs'] as int,
      updatedAtMs: v['updatedAtMs'] as int,
    );

CloudRecordMapEntity _recordMap(Map<String, Object?> v) => CloudRecordMapEntity(
  id: v['id'] as int,
  mapKey: v['mapKey'] as String,
  scopeKey: v['scopeKey'] as String,
  accountFingerprint: v['accountFingerprint'] as String,
  zone: v['zone'] as String,
  logicalEntityKeyHash: v['logicalEntityKeyHash'] as String,
  serverRecordIdHash: v['serverRecordIdHash'] as String,
  generation: v['generation'] as int,
  encryptedServerRecordId: v['encryptedServerRecordId'] as String,
  etagHash: v['etagHash'] as String?,
  encryptedRawRecordRef: v['encryptedRawRecordRef'] as String?,
  rawRecordGeneration: v['rawRecordGeneration'] as int,
  protectedReadbackLeaseReference: v['protectedReadbackLeaseReference'] as String?,
  pendingUpdateOperationId: v['pendingUpdateOperationId'] as String?,
  pendingUpdatePredecessorEtagHash: v['pendingUpdatePredecessorEtagHash'] as String?,
  updatedAtMs: v['updatedAtMs'] as int,
);

CloudSyncLocalSendIntentEntity _source(Map<String, Object?> v) =>
    CloudSyncLocalSendIntentEntity(
      id: v['id'] as int,
      intentKey: v['intentKey'] as String,
      accountFingerprint: v['accountFingerprint'] as String,
      writerEpoch: v['writerEpoch'] as int,
      localMessageId: v['localMessageId'] as int,
      messageGuidHash: v['messageGuidHash'] as String,
      sourceSha256: v['sourceSha256'] as String,
      state: v['state'] as int,
      admittedOperationId: v['admittedOperationId'] as String?,
      admittedBindingSha256: v['admittedBindingSha256'] as String?,
      admittedChatBinding: v['admittedChatBinding'] as String?,
      confirmedReadbackBindingSha256: v['confirmedReadbackBindingSha256'] as String?,
      idsConfirmationVersion: v['idsConfirmationVersion'] as int,
      protectedSourceBinding: v['protectedSourceBinding'] as String?,
      createdAtMs: v['createdAtMs'] as int,
      updatedAtMs: v['updatedAtMs'] as int,
    );

Map<String, Object?> _capture(String entity, Map<String, Object?> values) =>
    switch (entity) {
      _operationName => freshGroupRecoveryOperationSnapshot(_operation(values)),
      _mapName => freshGroupRecoveryMapSnapshot(_recordMap(values)),
      _sourceName => freshGroupRecoverySourceSnapshot(_source(values)),
      _ => throw ArgumentError.value(entity),
    };

void main() {
  setUpAll(() {
    // Compare behavior with the actual persisted schema, not Dart source text.
    final model = jsonDecode(File('lib/objectbox-model.json').readAsStringSync())
        as Map<String, dynamic>;
    final entities = (model['entities'] as List).cast<Map<String, dynamic>>();
    _properties = {
      for (final name in _nullable.keys)
        name: (entities.singleWhere((e) => e['name'] == name)['properties'] as List)
            .cast<Map<String, dynamic>>(),
    };
  });

  for (final entity in _nullable.keys) {
    test('$entity snapshot matches all actual model properties and values', () {
      final properties = _properties[entity]!;
      // Type6 is an ObjectBox integer and type9 is a String. New persisted
      // kinds must be reviewed rather than silently assigned fake values.
      expect(properties.map((p) => p['type']).toSet(), everyElement(isIn([6, 9])));
      for (final nullOptionals in [false, true]) {
        final expected = _values(entity, nullOptionals: nullOptionals);
        final snapshot = _capture(entity, expected);
        expect(snapshot.keys, unorderedEquals(properties.map((p) => p['name'])));
        expect(snapshot, expected);
        for (final key in _nullable[entity]!) {
          expect(snapshot.containsKey(key), isTrue, reason: '$entity.$key');
          if (nullOptionals) expect(snapshot[key], isNull, reason: '$entity.$key');
        }
      }
    });

    test('$entity fingerprint changes for each persisted scalar mutation', () {
      for (final nullOptionals in [false, true]) {
        final original = _values(entity, nullOptionals: nullOptionals);
        final before = freshGroupRecoverySnapshotFingerprint(_capture(entity, original));
        expect(before, matches(RegExp(r'^[a-f0-9]{64}$')));
        for (final property in _properties[entity]!) {
          final name = property['name'] as String;
          final old = original[name];
          final changed = Map<String, Object?>.of(original)
            ..[name] = old is int ? old + 1 : '${old ?? 'null'}:changed';
          final after = freshGroupRecoverySnapshotFingerprint(_capture(entity, changed));
          expect(after, isNot(before), reason: '$entity.$name nulls=$nullOptionals');
        }
        expect(freshGroupRecoverySnapshotFingerprint(_capture(entity, original)), before);
      }
    });
  }

  test('full operation roundtrip retains every scalar and explicit null', () {
    final variants = [
      _values(_operationName),
      _values(_operationName, nullOptionals: true),
      for (final key in _nullable[_operationName]!)
        _values(_operationName)..[key] = null,
    ];
    for (final expected in variants) {
      final snapshot = freshGroupRecoveryOperationSnapshot(_operation(expected));
      // Receipt persistence crosses JSON, so roundtrip that representation too.
      final wire = Map<String, Object?>.from(jsonDecode(jsonEncode(snapshot)) as Map);
      final reconstructed = freshGroupRecoveryOperationFromSnapshot(wire);
      expect(freshGroupRecoveryOperationSnapshot(reconstructed), expected);
      expect(freshGroupRecoverySnapshotFingerprint(wire),
          freshGroupRecoverySnapshotFingerprint(snapshot));
    }
  });

  test('fingerprints are independent of map order and stable through JSON', () {
    for (final entity in _nullable.keys) {
      final snapshot = _capture(entity, _values(entity, nullOptionals: true));
      final reversed = Map<String, Object?>.fromEntries(snapshot.entries.toList().reversed);
      final wire = Map<String, Object?>.from(jsonDecode(jsonEncode(reversed)) as Map);
      expect(freshGroupRecoverySnapshotFingerprint(reversed),
          freshGroupRecoverySnapshotFingerprint(snapshot));
      expect(freshGroupRecoverySnapshotFingerprint(wire),
          freshGroupRecoverySnapshotFingerprint(snapshot));
    }
  });

  test('operation reconstruction rejects every missing and unknown field', () {
    // Missing nullable columns must not be silently restored from defaults.
    for (final nullOptionals in [false, true]) {
      final original = _values(_operationName, nullOptionals: nullOptionals);
      for (final key in original.keys) {
        final missing = Map<String, Object?>.of(original)..remove(key);
        expect(() => freshGroupRecoveryOperationFromSnapshot(missing), throwsStateError,
            reason: 'missing $key nulls=$nullOptionals');
      }
      for (final extra in <Object?>[null, 1, 'unknown']) {
        final unknown = Map<String, Object?>.of(original)..['unknownColumn'] = extra;
        expect(() => freshGroupRecoveryOperationFromSnapshot(unknown), throwsStateError);
      }
    }
  });

  test('operation reconstruction rejects wrong types for every persisted field', () {
    final original = _values(_operationName);
    for (final property in _properties[_operationName]!) {
      final name = property['name'] as String;
      final invalid = <Object?>[
        if (property['type'] == 6) '123' else 123,
        1.0, true, <Object?>[], <String, Object?>{},
        if (!_nullable[_operationName]!.contains(name)) null,
      ];
      for (final value in invalid) {
        final changed = Map<String, Object?>.of(original)..[name] = value;
        expect(() => freshGroupRecoveryOperationFromSnapshot(changed), throwsStateError,
            reason: '$name rejects ${value.runtimeType}');
      }
    }
  });

  test('fingerprinting rejects values outside persisted String int null scalars', () {
    for (final value in <Object?>[
      true, false, 1.0, double.nan, double.infinity,
      <Object?>[], <String, Object?>{}, <Object>{}, Object(),
    ]) {
      expect(() => freshGroupRecoverySnapshotFingerprint({'value': value}), throwsStateError);
    }
  });

  test('all returned snapshots are immutable and detached from mutable entities', () {
    final expectedOperation = _values(_operationName);
    final expectedMap = _values(_mapName);
    final expectedSource = _values(_sourceName);
    final operation = _operation(expectedOperation);
    final recordMap = _recordMap(expectedMap);
    final source = _source(expectedSource);
    final operationSnapshot = freshGroupRecoveryOperationSnapshot(operation);
    final mapSnapshot = freshGroupRecoveryMapSnapshot(recordMap);
    final sourceSnapshot = freshGroupRecoverySourceSnapshot(source);
    for (final snapshot in [operationSnapshot, mapSnapshot, sourceSnapshot]) {
      expect(() => snapshot['id'] = -1, throwsUnsupportedError);
      expect(() => snapshot['unknownColumn'] = null, throwsUnsupportedError);
      expect(() => snapshot.remove('id'), throwsUnsupportedError);
      expect(() => snapshot.clear(), throwsUnsupportedError);
    }
    operation..operationId = 'changed'..localChatOrigin = null;
    recordMap..encryptedServerRecordId = 'changed'..etagHash = null;
    source..sourceSha256 = 'changed'..protectedSourceBinding = null;
    expect(operationSnapshot, expectedOperation);
    expect(mapSnapshot, expectedMap);
    expect(sourceSnapshot, expectedSource);
  });
}
