import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:objectbox/internal.dart' as obx;

void main() {
  test(
    'archive ownership column preserves old authority rows on upgrade',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ob-writer-consent-upgrade-',
      );
      final current = getObjectBoxModel();
    // Pin the hand-maintained bindings to the committed UID manifest as well
    // as exercising their actual serialization and upgrade below.
    final committed = obx.ModelInfo.fromMap(
      jsonDecode(File('lib/objectbox-model.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    expect(current.model.toMap(), committed.toMap());
      final beforeMap = current.model.toMap();
      final entity =
          (beforeMap['entities'] as List).singleWhere(
                (e) => e['name'] == 'CloudKitWriterAuthorityEntity',
              )
              as Map;
      final properties = entity['properties'] as List;
      final addition =
          properties.singleWhere((p) => p['name'] == 'ownershipEpoch') as Map;
      expect(addition['id'], '16:2024932844516293885');
      expect(addition['type'], 6);
      properties.remove(addition);
      expect(properties.length, 15);
      expect(properties.last['id'], '15:8451174932715279609');
      entity['lastPropertyId'] = '15:8451174932715279609';
      final before = obx.ModelDefinition(
        obx.ModelInfo.fromMap(beforeMap),
        current.bindings,
      );
      Store? store;
      try {
        store = Store(before, directory: directory.path);
        final originals = <CloudKitWriterAuthorityEntity>[
          for (final state in [0, 4, 2])
            CloudKitWriterAuthorityEntity(
              authorityKey: 'synthetic-authority-$state',
              accountFingerprint: 'A' * 43,
              container: 'com.apple.messages.cloud',
              database: 'private',
              owner: 2,
              state: state,
              epoch: 6 + state,
              transitionIdHash: state == 2 ? 'a' * 64 : null,
              resetScopeKeyHash: state == 2 ? 'b' * 64 : null,
              resetProofReferenceHash: state == 2 ? 'c' * 64 : null,
              resetProofReference: state == 2 ? 'obcs2.ref.${'P' * 43}' : null,
              resetGeneration: state == 2 ? 7 : 0,
              updatedAtMs: 1000 + state,
            ),
        ];
        for (final original in originals) {
          store.box<CloudKitWriterAuthorityEntity>().put(original);
        }
        store.close();
        for (var restart = 0; restart < 2; restart++) {
          store = await openStore(directory: directory.path);
          for (final original in originals) {
            final row = store.box<CloudKitWriterAuthorityEntity>().get(
              original.id,
            )!;
            expect(row.id, original.id);
            expect(row.authorityKey, original.authorityKey);
            expect(row.accountFingerprint, original.accountFingerprint);
            expect(row.container, original.container);
            expect(row.database, original.database);
            expect(row.owner, original.owner);
            expect(row.state, original.state);
            expect(row.targetOwner, original.targetOwner);
            expect(row.epoch, original.epoch);
            expect(row.ownershipEpoch, restart == 0 ? 0 : 6);
            expect(row.transitionIdHash, original.transitionIdHash);
            expect(row.resetScopeKeyHash, original.resetScopeKeyHash);
            expect(
              row.resetProofReferenceHash,
              original.resetProofReferenceHash,
            );
            expect(row.resetProofReference, original.resetProofReference);
            expect(row.resetGeneration, original.resetGeneration);
            expect(row.updatedAtMs, original.updatedAtMs);
            if (restart == 0) {
              row.ownershipEpoch = 6;
              store.box<CloudKitWriterAuthorityEntity>().put(row);
            }
          }
          expect(store.box<CloudKitWriterAuthorityEntity>().count(), 3);
          final query = store
              .box<CloudKitWriterAuthorityEntity>()
              .query(CloudKitWriterAuthorityEntity_.ownershipEpoch.equals(6))
              .build();
          try {
            expect(query.count(), 3);
          } finally {
            query.close();
          }
          store.close();
        }
      } finally {
        if (store != null && !store.isClosed()) store.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      }
    },
  );
}
