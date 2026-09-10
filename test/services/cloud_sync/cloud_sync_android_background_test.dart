import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_android_background.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fingerprint = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  test('scope hash binds the complete semantic Messages scope', () {
    final scope = CloudSyncAndroidBackgroundPolicy.semanticMessageScope(
      fingerprint,
    );
    final hash = CloudSyncAndroidBackgroundPolicy.scopeHash(scope);

    expect(scope.container, 'com.apple.messages.cloud');
    expect(scope.database, 'private');
    expect(scope.zone, 'messageManateeZone');
    expect(scope.streamKind, CloudSyncStreamKind.messages);
    expect(scope.persistenceLane, CloudSyncPersistenceLane.semantic);
    expect(hash, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(
      hash,
      isNot(
        CloudSyncAndroidBackgroundPolicy.scopeHash(
          CloudSyncScope(
            accountFingerprint: fingerprint,
            container: scope.container,
            database: scope.database,
            zone: 'chatManateeZone',
            persistenceLane: CloudSyncPersistenceLane.semantic,
          ),
        ),
      ),
    );
  });

  test('only a canonical hash and metadata wake are accepted', () {
    expect(
      CloudSyncAndroidBackgroundPolicy.isCanonicalScopeHash('a' * 64),
      isTrue,
    );
    expect(
      CloudSyncAndroidBackgroundPolicy.isCanonicalScopeHash('A' * 64),
      isFalse,
    );
    expect(
      CloudSyncAndroidBackgroundPolicy.isCanonicalScopeHash(fingerprint),
      isFalse,
    );
    expect(
      CloudSyncAndroidBackgroundPolicy.isSupportedWorkKind('METADATA'),
      isTrue,
    );
    expect(
      CloudSyncAndroidBackgroundPolicy.isSupportedWorkKind('AUTOMATIC_MEDIA'),
      isFalse,
    );
  });

  test('identity replacement is stale and contention remains retryable', () {
    expect(
      CloudSyncAndroidBackgroundPolicy.classifyFailure(
        StateError('cloud_sync_android_background_scope_mismatch'),
      ),
      CloudSyncAndroidBackgroundOutcome.stale,
    );
    expect(
      CloudSyncAndroidBackgroundPolicy.classifyFailure(
        StateError('cloudkit_interlock_busy'),
      ),
      CloudSyncAndroidBackgroundOutcome.retry,
    );
    expect(
      CloudSyncAndroidBackgroundPolicy.classifyFailure(Exception('unknown')),
      CloudSyncAndroidBackgroundOutcome.retry,
    );
  });
}
