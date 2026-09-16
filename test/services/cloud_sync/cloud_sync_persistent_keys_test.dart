import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CloudSyncScope scope({String account = 'A', String zone = 'messageManateeZone'}) =>
      CloudSyncScope(accountFingerprint: account * 43,
        container: 'com.apple.messages.cloud', database: 'private', zone: zone,
        persistenceLane: CloudSyncPersistenceLane.semantic);

  // Frozen independently from the existing journal's SHA256 framing. Neither
  // a rebootstrap nor this shared helper is a migration of stored keys.
  const vectors = {
    1: 'change:2bf471c87a568f0a3e1db83577df092663ff7b078fa18daf58a1ae1bbea3eb3d',
    2: 'change-generation-2:f34e0614bac046492751cb7409b3ca320956bbd6c90505640b568d79b3e2e8e7',
    7: 'change-generation-7:450c0b808fef9e0ea67ad18b5ec0bca059f3acaa744fb0d10f6e25880dec574b',
  };
  for (final entry in vectors.entries) {
    test('keeps the existing durable change key at generation ${entry.key}', () {
      expect(cloudSyncPersistentChangeKey(scope(), entry.key, 'C' * 43), entry.value);
    });
  }
  test('scope and generation cannot alias another account or reset', () {
    final keys = <String>{
      for (final generation in [1, 2, 7])
        for (final account in ['A', 'B'])
          for (final zone in ['messageManateeZone', 'chatManateeZone'])
            cloudSyncPersistentChangeKey(scope(account: account, zone: zone), generation, 'C' * 43),
    };
    expect(keys, hasLength(12));
    expect(() => cloudSyncPersistentChangeKey(scope(), 0, 'C' * 43), throwsArgumentError);
  });
}
