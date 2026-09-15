import 'package:bluebubbles/app/layouts/settings/pages/profile/cloud_sync_profile_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudSyncProfileEntry placement policy', () {
    test('V2 card follows the existing capability gate', () {
      expect(CloudSyncProfileEntry.showV2Card(v2Visible: false), isFalse);
      expect(CloudSyncProfileEntry.showV2Card(v2Visible: true), isTrue);
    });

    test('legacy section stays except for fresh accounts under V2', () {
      // Non-V2 builds keep the original legacy UI either way.
      expect(
        CloudSyncProfileEntry.showLegacySection(
          v2Visible: false,
          legacyEnabled: false,
        ),
        isTrue,
      );
      expect(
        CloudSyncProfileEntry.showLegacySection(
          v2Visible: false,
          legacyEnabled: true,
        ),
        isTrue,
      );
      // Enabled legacy keeps its section (and off switch) under V2.
      expect(
        CloudSyncProfileEntry.showLegacySection(
          v2Visible: true,
          legacyEnabled: true,
        ),
        isTrue,
      );
      // Fresh legacy opt-in is hidden while V2 is the normal entry.
      expect(
        CloudSyncProfileEntry.showLegacySection(
          v2Visible: true,
          legacyEnabled: false,
        ),
        isFalse,
      );
    });
  });
}
