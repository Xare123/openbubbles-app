import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android registration is Canary-only and persists only a scope hash', () {
    final source = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/'
      'rustpush/CloudSyncV2WorkRegistration.kt',
    ).readAsStringSync();

    expect(source, contains('com.bluebubbles.messaging.cloudkitcanary'));
    expect(source, contains('scope_hash'));
    expect(source, contains(r'^[a-f0-9]{64}$'));
    expect(source, isNot(contains('accountFingerprint')));
    expect(source, isNot(contains('messageGuid')));
    expect(source, isNot(contains('chatGuid')));
  });

  test('worker accepts one metadata wake and has a bounded retry budget', () {
    final worker = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/'
      'rustpush/CloudSyncV2Worker.kt',
    ).readAsStringSync();
    final policy = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/'
      'rustpush/CloudSyncV2WorkPolicy.kt',
    ).readAsStringSync();

    expect(worker, contains('cloud-sync-v2-background-wake'));
    expect(worker, contains('kind != CloudSyncV2WorkKind.METADATA'));
    expect(worker, contains('withTimeout(EXECUTION_TIMEOUT_MILLIS)'));
    expect(policy, contains('const val MAX_ATTEMPTS = 5'));
    expect(worker, isNot(contains('AUTOMATIC_MEDIA')));
  });

  test('result-bearing Flutter startup is cancellable and time-bounded', () {
    final source = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/'
      'backend_ui_interop/DartWorker.kt',
    ).readAsStringSync();

    expect(source, contains('suspendCancellableCoroutine<Unit>'));
    expect(source, contains('RESULT_ENGINE_READY_TIMEOUT_MILLIS'));
    expect(
      source,
      contains('withTimeout(RESULT_ENGINE_READY_TIMEOUT_MILLIS)'),
    );
  });

  test('Dart wake revalidates scope and never queues outbound work', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'runCloudSyncV2AndroidBackgroundReadOnly',
    );
    final end = source.indexOf(
      '_runCloudSyncV2AutomaticSemanticCatchUp',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final wake = source.substring(start, end);

    expect(wake, contains('_cloudSyncV2AndroidBackgroundScopeHash'));
    expect(wake, contains('cloud_sync_android_background_scope_mismatch'));
    expect(wake, contains('allowAndroidBackgroundIsolate: true'));
    expect(wake, isNot(contains('_queueCloudSyncV2LocalSends(')));
    expect(wake, isNot(contains('runCloudSyncV2Outbound')));
  });

  test('headless dispatch waits for the complete service graph', () {
    final methodChannel = File(
      'lib/services/backend/java_dart_interop/method_channel_service.dart',
    ).readAsStringSync();
    final startup = File(
      'lib/helpers/backend/startup_tasks.dart',
    ).readAsStringSync();

    expect(methodChannel, contains('StartupTasks.waitForIsolateServices()'));
    expect(methodChannel, contains('await pushService.initFuture'));
    expect(startup, contains('_isolateServicesReady.complete()'));
  });

  test('headless APNs completion may enqueue only the registered metadata wake',
      () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'Future<void> enqueueCloudSyncV2AndroidBackgroundReadHint',
    );
    final end = source.indexOf(
      '_queueCloudSyncV2LocalSends',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final hint = source.substring(start, end);

    expect(hint, contains('!ls.isUiThread && mcs.background'));
    expect(hint, contains("'kind': 'METADATA'"));
    expect(hint, isNot(contains('_queueCloudSyncV2LocalSends(')));
  });
}
