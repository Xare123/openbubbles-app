import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Attachment initial create shares the native fixed identity vector', () {
    final scope = CloudSyncScope(
      accountFingerprint: 'A' * 43,
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'attachmentManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    const expected =
        'op1:7b2b89e41a267f080a5bdc0e27e83abbbfaa0cd14d1c7e0cbadccbd52ff5a04c';
    expect(
      CloudOperationIdentity.forInitialCreate(
        scope: scope,
        logicalEntityKeyHash: 'L' * 43,
        payloadVersion: 1,
      ),
      expected,
    );
    // Native CI executes the matching vector; this asserts fixture parity only.
    final native = File(
      'rust/src/cloud_sync_outbound_attachment.rs',
    ).readAsStringSync();
    expect(native, contains('"$expected"'));
    for (final zone in ['messageManateeZone', 'chatManateeZone']) {
      final other = CloudSyncScope(
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: zone,
        persistenceLane: scope.persistenceLane,
      );
      expect(
        CloudOperationIdentity.forInitialCreate(
          scope: other,
          logicalEntityKeyHash: 'L' * 43,
          payloadVersion: 1,
        ),
        isNot(expected),
      );
    }
  });
}
