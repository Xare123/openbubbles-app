import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_canary_adb_control.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:flutter_test/flutter_test.dart';

// Narrow public/release surface contract: Developer Settings are preserved
// for diagnostics, while the temporary shell-only Canary ADB automation stays
// fenced to canaryDebug and the V2 rollout read/write gates default off in
// ordinary builds. This test only inspects source sets, manifests, and
// compile-time gates; it changes no workflows and disables no Canary controls.
void main() {
  test('canary ADB receiver is absent from every public source set', () {
    for (final manifest in [
      'android/app/src/main/AndroidManifest.xml',
      'android/app/src/debug/AndroidManifest.xml',
      'android/app/src/profile/AndroidManifest.xml',
    ]) {
      final source = File(manifest).readAsStringSync();
      expect(source, isNot(contains('CanaryAdb')));
      expect(source, isNot(contains('CANARY_ADB')));
    }
    expect(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      contains('android:debuggable="false"'),
    );

    // Alpha, Beta, and release are Gradle flavors without dedicated src
    // directories, so they inherit main; still, assert no flavor source-set
    // copy of the receiver exists under either language root.
    for (final set in ['main', 'alpha', 'beta', 'release']) {
      for (final lang in ['java', 'kotlin']) {
        expect(
          File(
            'android/app/src/$set/$lang/com/bluebubbles/messaging/CanaryAdbControlReceiver.kt',
          ).existsSync(),
          isFalse,
        );
      }
    }

    final strays = Directory('android/app/src/main')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.contains('CanaryAdb'))
        .toList();
    expect(strays, isEmpty);
  });

  test('canary ADB receiver stays shell-only under canaryDebug', () {
    // Verified with rg --files: the receiver currently lives under the java
    // language root. Resolve it by filename instead of assuming the root so
    // a future java/kotlin move fails loudly here rather than silently.
    final matches = Directory('android/app/src/canaryDebug')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('CanaryAdbControlReceiver.kt'))
        .toList();
    expect(matches.length, 1);

    final overlay = File(
      'android/app/src/canaryDebug/AndroidManifest.xml',
    ).readAsStringSync();
    expect(overlay, contains('CanaryAdbControlReceiver'));
    expect(overlay, contains('android:exported="true"'));
    expect(overlay, contains('android.permission.DUMP'));
    expect(overlay, isNot(contains('intent-filter')));

    final receiver = matches.single.readAsStringSync();
    expect(receiver, contains('com.bluebubbles.messaging.cloudkitcanary'));
    expect(receiver, contains('ApplicationInfo.FLAG_DEBUGGABLE'));
    expect(receiver, isNot(contains('startActivity')));
  });

  test('V2 rollout read/write gates default off', () {
    expect(CloudSyncDevGate.manualShadowSamplerEnabled, isFalse);
    expect(CloudSyncDevGate.manualSemanticPullEnabled, isFalse);
    expect(CloudSyncDevGate.manualOutboundCanaryEnabled, isFalse);
    expect(CloudSyncDevGate.localSendRuntimeEnabled, isFalse);
    expect(CloudSyncDevGate.androidBackgroundReadEnabled, isFalse);
    expect(CloudSyncDevGate.protocolEvidenceAvailable, isFalse);
    expect(CanaryAdbControlGate.compiledIn, isFalse);
  });

  test('developer settings surface is preserved for diagnostics', () {
    final panel = File(
      'lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart',
    ).readAsStringSync();
    expect(panel, contains('developerEnabled'));
  });

  test(
    'profile card exposes an ordinary start callback without a developer gate',
    () {
      final card = File(
        'lib/app/layouts/settings/pages/profile/cloud_sync_progress_card.dart',
      ).readAsStringSync();
      expect(card, contains('required this.onStart'));
      expect(card, contains('widget.onStart(speed)'));
      expect(card, isNot(contains('developerEnabled')));
    },
  );
}
