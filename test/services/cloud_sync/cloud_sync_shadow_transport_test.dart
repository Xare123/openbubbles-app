import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  test(
    'account change after fetch rejects page before caller can journal it',
    () async {
      final scope = testScope();
      var activeFingerprint = scope.accountFingerprint;
      final delegate = FakeCloudSyncTransport()
        ..fetchHandler = (scope, token, generation, limit) async {
          activeFingerprint = 'replacement-account';
          return CloudFetchBatch(
            scope: scope,
            changes: [testChange(1)],
            batchId: 'batch',
            generation: generation,
            nextToken: 'token',
            hasMore: false,
          );
        };
      final transport = AccountBoundShadowTransport(
        delegate: delegate,
        readActiveFingerprint: () async => activeFingerprint,
        expectedFingerprint: scope.accountFingerprint,
      );

      await expectLater(
        transport.fetchChanges(
          scope,
          previousToken: null,
          generation: 1,
          limit: 50,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'account_changed',
          ),
        ),
      );
    },
  );

  test('all mutation and refresh routes fail through the tripwire', () async {
    final scope = testScope();
    final transport = AccountBoundShadowTransport(
      delegate: FakeCloudSyncTransport(),
      readActiveFingerprint: () async => scope.accountFingerprint,
      expectedFingerprint: scope.accountFingerprint,
    );

    await expectLater(
      transport.pushOperations(scope, operations: const []),
      throwsA(isA<CloudSyncFailure>()),
    );
    await expectLater(
      transport.allocateServerRecordMapping(
        scope,
        logicalEntityKeyHash: 'logical',
      ),
      throwsA(isA<CloudSyncFailure>()),
    );
    await expectLater(
      transport.refreshAuthentication(scope),
      throwsA(isA<CloudSyncFailure>()),
    );
    await expectLater(
      transport.refreshPcsAccess(scope),
      throwsA(isA<CloudSyncFailure>()),
    );
  });
}
