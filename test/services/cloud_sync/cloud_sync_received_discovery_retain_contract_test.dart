import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_discovery_retain_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'discovery retain path stays disabled while dev gates are off',
    () async {
      await expectLater(
        retainCloudSyncDiscoveredReceivedFound(
          intentId: 1,
          privateStorageDirectory: 'test-only-directory',
          readActiveClient: () => null,
          stillCurrent: () => true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'disabled discovery never reaches native lookup',
    () async {
      var clientsRead = 0;
      await expectLater(
        retainCloudSyncDiscoveredReceivedFound(
          intentId: 7,
          privateStorageDirectory: 'test-only-directory',
          readActiveClient: () {
            clientsRead++;
            return null;
          },
          stillCurrent: () => false,
        ),
        throwsStateError,
      );
      expect(clientsRead, 0, reason: 'gates must throw before any client use');
    },
  );
}
