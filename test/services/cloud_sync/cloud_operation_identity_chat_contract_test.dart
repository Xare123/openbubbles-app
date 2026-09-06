import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Chat initial create shares the native fixed identity vector', () {
    final scope = CloudSyncScope(
      accountFingerprint: 'A' * 43,
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'chatManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    const expected =
        'op1:a78f1b167797724168f9233a56838cfef90e17e3dd90d2328de23c33658945db';
    expect(
      CloudOperationIdentity.forInitialCreate(
        scope: scope,
        logicalEntityKeyHash: 'L' * 43,
        payloadVersion: cloudSyncOutboundChatPayloadVersion,
      ),
      expected,
    );
    // This checks fixture parity, not execution of Rust. Native CI must also
    // run chat_initial_operation_matches_fixed_dart_domain_vector.
    final native = File('rust/src/cloud_sync_outbound_chat.rs').readAsStringSync();
    expect(native, contains('"$expected"'));
  });
}
