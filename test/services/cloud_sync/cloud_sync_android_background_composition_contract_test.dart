import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android registration is Canary-only and persists no account or message data',
    () {
      final source = File(
        'android/app/src/main/kotlin/com/bluebubbles/messaging/services/'
        'rustpush/CloudSyncV2WorkRegistration.kt',
      ).readAsStringSync();

      expect(source, contains('com.bluebubbles.messaging.cloudkitcanary'));
      expect(source, contains('scope_hash'));
      final coordinator = File(
        'android/app/src/main/kotlin/com/bluebubbles/messaging/services/'
        'rustpush/CloudSyncV2WakeCoordinator.kt',
      ).readAsStringSync();
      expect(source, contains('CloudSyncV2WakeRecord.isCanonicalScopeHash'));
      expect(coordinator, contains(r'^[a-f0-9]{64}$'));
      expect(source, contains('registration_epoch'));
      expect(source, contains('requested_generation'));
      expect(source, contains('active_work_id'));
      expect(source, isNot(contains('accountFingerprint')));
      expect(source, isNot(contains('messageGuid')));
      expect(source, isNot(contains('chatGuid')));
    },
  );

  test('registration results use the tested account and operation fence', () {
    final service = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    expect(service, contains('CloudSyncBackgroundRegistration()'));
    expect(
      service,
      contains('_cloudSyncV2AndroidBackgroundRegistration.registered'),
    );
    expect(
      service,
      contains('_cloudSyncV2AndroidBackgroundRegistration.configure('),
    );
    expect(
      service,
      contains('_cloudSyncV2AndroidBackgroundRegistration.disable('),
    );
    expect(
      service,
      isNot(
        matches(RegExp(r'_cloudSyncV2AndroidBackgroundRegistered\s*=(?!>)')),
      ),
    );
  });

  test(
    'durable hints are epoch fenced and enqueue acknowledgments are awaited',
    () {
      const native =
          'android/app/src/main/kotlin/com/bluebubbles/messaging/'
          'services/rustpush/';
      final handler = File(
        '${native}CloudSyncV2WorkControlHandler.kt',
      ).readAsStringSync();
      final scheduler = File(
        '${native}CloudSyncV2WorkScheduler.kt',
      ).readAsStringSync();
      final worker = File('${native}CloudSyncV2Worker.kt').readAsStringSync();
      expect(handler, contains('expected?.scopeHash != scopeHash'));
      expect(handler, contains('CoroutineStart.UNDISPATCHED'));
      expect(scheduler, contains('.result.await()'));
      expect(scheduler, contains('.getWorkInfoById(workId).await()'));
      expect(scheduler, contains('INPUT_REGISTRATION_EPOCH'));
      expect(scheduler, isNot(contains('ExistingWorkPolicy.APPEND')));
      expect(scheduler, isNot(contains('ExistingWorkPolicy.REPLACE')));
      expect(worker, contains('CloudSyncV2WorkRegistration.begin('));
      expect(worker, contains('CloudSyncV2WorkRegistration.seal('));
      expect(worker, contains('scopeHash!!, epoch'));
    },
  );

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

  test('worker separates bounded timeouts from external cancellation', () {
    final worker = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/'
      'rustpush/CloudSyncV2Worker.kt',
    ).readAsStringSync();
    expect(worker, contains('import kotlinx.coroutines.CancellationException'));
    // The three suspension boundaries are begin, Dart handoff and terminal
    // seal. Timeout is a bounded retry; a stopped WorkManager future is not.
    expect(
      RegExp(
        r'catch \(error: CancellationException\) \{\s*throw error',
      ).allMatches(worker),
      hasLength(3),
    );
    expect(
      RegExp(r'catch \(_: TimeoutCancellationException\)').allMatches(worker),
      hasLength(3),
    );
  });

  test('result-bearing Flutter startup is cancellable and time-bounded', () {
    final source = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/'
      'backend_ui_interop/DartWorker.kt',
    ).readAsStringSync();

    expect(source, contains('suspendCancellableCoroutine<Unit>'));
    expect(source, contains('RESULT_ENGINE_READY_TIMEOUT_MILLIS'));
    expect(source, contains('withTimeout(RESULT_ENGINE_READY_TIMEOUT_MILLIS)'));
  });

  test('Dart wake revalidates scope and never queues outbound work', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('runCloudSyncV2AndroidBackgroundReadOnly');
    final end = source.indexOf(
      '_runCloudSyncV2AutomaticSemanticCatchUp',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final wake = source.substring(start, end);

    expect(
      wake,
      contains('final preferences = _cloudSyncV2BackgroundReadPreferences();'),
    );
    expect(wake, contains('final preference = await preferences.load();'));
    expect(wake, contains('!preference.enabled'));
    expect(wake, contains('preference.identity.scopeHash != scopeHash'));
    expect(wake, isNot(contains('_cloudSyncV2DeveloperRuntimeAllowed')));
    expect(wake, contains('cloud_sync_android_background_scope_mismatch'));
    expect(wake, contains('allowAndroidBackgroundIsolate: true'));
    expect(
      wake,
      contains('CloudSyncAndroidBackgroundPolicy.classifyReadResult('),
    );
    expect(wake, isNot(contains('result.projectionComplete')));
    expect(wake, isNot(contains('_queueCloudSyncV2LocalSends(')));
    expect(wake, isNot(contains('runCloudSyncV2Outbound')));
  });

  test(
    'internal reader wakes omit exhaustive repair while user catch-up keeps it',
    () {
      final service = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final controller = File(
        'lib/services/rustpush/cloud_sync/cloud_sync_semantic_drain_controller.dart',
      ).readAsStringSync();
      expect(
        service,
        contains(
          'sweepRetainedAtHead: sweepRetainedAtHead && !allowAndroidBackgroundIsolate',
        ),
      );
      expect(controller, contains('bool sweepRetainedAtHead = true'));
      expect(controller, contains('sweepRetainedAtHead: sweepRetainedAtHead'));
      expect(
        controller,
        contains('cancelCatchUp: sampler.cancelActiveCatchUp'),
      );
    },
  );

  test('bounded internal reads share one background budget and one pass', () {
    final service = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final progress = File(
      'lib/services/rustpush/cloud_sync/cloud_sync_progress.dart',
    ).readAsStringSync();
    final budget = File(
      'lib/services/rustpush/cloud_sync/cloud_sync_read_budget.dart',
    ).readAsStringSync();
    // One shared fallback owns the automatic/internal budget: Profile Regular
    // and Turbo speeds resolve through their existing per-speed budgets, and
    // only the progress-absent path falls back to the background budget.
    expect(
      service,
      contains(
        'final readBudget = progress?.speed.readBudget ?? CloudSyncReadBudget.background;',
      ),
    );
    expect(service, contains('readBudget: readBudget,'));
    final adapterStart = service.indexOf(
      'final adapter = CloudSyncProductionSemanticPullAdapter(',
    );
    expect(adapterStart, greaterThanOrEqualTo(0));
    final adapterWindow = service.substring(adapterStart, adapterStart + 300);
    expect(adapterWindow, contains('readBudget: readBudget,'));
    final writerStart = service.indexOf(
      'final reportWriter = CloudSyncSemanticPullReportFileWriter(',
    );
    expect(writerStart, greaterThanOrEqualTo(0));
    final writerWindow = service.substring(writerStart, writerStart + 400);
    expect(writerWindow, contains('readBudget: readBudget,'));
    expect(budget, contains('static const background = CloudSyncReadBudget('));
    expect(budget, contains('retainedReplayEntries: 4,'));
    expect(progress, contains('CloudSyncReadBudget.regular'));
    expect(progress, contains('CloudSyncReadBudget.standard'));
    // Automatic catch-up without Profile progress skips the exhaustive
    // retained sweep; explicit Profile requests still pass progress through.
    expect(service, contains('sweepRetainedAtHead: progress != null,'));
    // Internal readers hold exactly one pass under one lock: the Android
    // metadata wake and the progress-absent automatic default.
    final wakeStart = service.indexOf(
      'runCloudSyncV2AndroidBackgroundReadOnly({',
    );
    expect(wakeStart, greaterThanOrEqualTo(0));
    final wakeEnd = service.indexOf(
      '_runCloudSyncV2AutomaticSemanticCatchUp({',
      wakeStart,
    );
    expect(wakeEnd, greaterThan(wakeStart));
    final wake = service.substring(wakeStart, wakeEnd);
    expect(wake, contains('maximumPasses: 1,'));
    expect(
      service,
      contains('maximumPasses: progress?.speed.passesPerBatch ?? 1,'),
    );
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

  test(
    'headless APNs completion may enqueue only the registered metadata wake',
    () {
      final source = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final start = source.indexOf(
        'Future<void> enqueueCloudSyncV2AndroidBackgroundReadHint',
      );
      final end = source.indexOf('_queueCloudSyncV2LocalSends', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final hint = source.substring(start, end);

      expect(hint, contains('!ls.isUiThread && mcs.background'));
      expect(hint, contains("'kind': 'METADATA'"));
      expect(hint, contains("'scopeHash': preference.identity.scopeHash"));
      final load = hint.indexOf('await preferences.load()');
      final current = hint.indexOf('!preferences.stillCurrent()');
      final dispatch = hint.indexOf('await mcs.invokeMethod(');
      expect(load, greaterThanOrEqualTo(0));
      expect(current, greaterThan(load));
      expect(dispatch, greaterThan(current));
      expect(hint, isNot(contains('_queueCloudSyncV2LocalSends(')));
    },
  );

  test(
    'received iMessage wakes are post-processing, nonblocking and account-fenced',
    () {
      final source = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future handleMsg(api.PushMessage push)');
      final end = source.indexOf('bool authing = false;', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final handler = source.substring(start, end);
      final capture = handler.indexOf('final expectedState = state;');
      final apply = handler.indexOf('await handleMsgInner(push).timeout(');
      final certify = handler.indexOf('markCertified(push);');
      final hint = handler.indexOf(
        'unawaited(enqueueCloudSyncV2AndroidBackgroundReadHint());',
      );
      expect(capture, greaterThanOrEqualTo(0));
      expect(apply, greaterThan(capture));
      expect(certify, greaterThan(apply));
      expect(hint, greaterThan(certify));
      expect(handler, contains('push is api.PushMessage_IMessage'));
      expect(handler, contains('expectedState != null'));
      expect(handler, contains('identical(expectedState, state)'));
      expect(
        handler,
        isNot(contains('await enqueueCloudSyncV2AndroidBackgroundReadHint')),
      );
      expect(handler, isNot(contains('_queueCloudSyncV2LocalSends(')));
      expect(handler, isNot(contains('runCloudSyncV2Outbound')));
      expect(handler, isNot(contains('finally')));
    },
  );

  test(
    'CloudKit invalidation is content-free and avoids receive-loop network work',
    () {
      final api = File('rust/src/api/api.rs').readAsStringSync();
      final start = api.indexOf('pub async fn recv_wait(');
      final end = api.indexOf('if let Some(fmfd)', start);
      final route = api.substring(start, end);
      expect(
        route,
        contains('client.change_notification_nonce(&state.conn, &msg)'),
      );
      expect(
        route,
        contains('PushMessage::CloudKitChangeHint { registration_nonce }'),
      );
      expect(route, isNot(contains('configure_change_notifications')));
      expect(route, isNot(contains('create_sync_subscription')));
      final service = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final handlerStart = service.indexOf('Future handleMsgInner(');
      final handlerEnd = service.indexOf(
        'api.PushMessage_CircleFinishEvent',
        handlerStart,
      );
      final handler = service.substring(handlerStart, handlerEnd);
      expect(handler, contains('api.PushMessage_CloudKitChangeHint'));
      expect(
        handler,
        contains('unawaited(enqueueCloudSyncV2AndroidBackgroundReadHint('),
      );
      expect(handler, contains('notificationNonce: push.registrationNonce'));
      expect(handler, isNot(contains('await api.')));
    },
  );

  test(
    'notification setup owns bounded native lifetime and cached identity fences',
    () {
      final api = File('rust/src/api/api.rs').readAsStringSync();
      final start = api.indexOf(
        'pub async fn cloud_sync_configure_messages_change_notifications(',
      );
      final end = api.indexOf(
        'fn cloud_sync_password_writer_resume_error(',
        start,
      );
      final setup = api.substring(start, end);
      expect(setup, contains('tokio::time::timeout(Duration::from_secs(30)'));
      expect(
        setup,
        contains(
          'cloudkit_read_authentication_lifecycle_gate(std::path::Path::new(&state.conf_dir))',
        ),
      );
      expect(setup, contains('with_cloudkit_writer_operation('));
      expect(
        setup,
        contains(
          'current.native_session_id != expected_auth.native_session_id',
        ),
      );
      expect(
        setup,
        contains(
          'after.protected_store_identity != expected_auth.protected_store_identity',
        ),
      );
      expect(
        setup,
        contains('disable_change_notifications(Some(&registration_nonce))'),
      );
      final service = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final prepareStart = service.indexOf(
        'Future<bool> _prepareCloudSyncV2MessagesChangeNotifications(',
      );
      final prepareEnd = service.indexOf(
        'Future<void> _disableCloudSyncV2AndroidBackgroundRead',
        prepareStart,
      );
      final prepare = service.substring(prepareStart, prepareEnd);
      expect(prepare, contains('!preference.explicitlyEnabled'));
      expect(prepare, contains('_cloudSyncV2LocalSourceOperations.run('));
      expect(prepare, contains('_runCloudKitIdentityMaintenance('));
      expect(prepare, contains('reloaded.explicitlyEnabled'));
      expect(prepare, isNot(contains('.timeout(')));
    },
  );

  test(
    'headless restart reattaches notifications without losing a usable read',
    () {
      final service = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final start = service.indexOf(
        'runCloudSyncV2AndroidBackgroundReadOnly({',
      );
      final end = service.indexOf(
        '_runCloudSyncV2AutomaticSemanticCatchUp({',
        start,
      );
      final wake = service.substring(start, end);
      expect(
        wake.indexOf('if (preference.explicitlyEnabled)'),
        greaterThan(wake.indexOf('preference.identity.scopeHash != scopeHash')),
      );
      expect(
        wake.indexOf('_prepareCloudSyncV2MessagesChangeNotifications('),
        lessThan(wake.indexOf('_runCloudSyncV2ManualSemanticPull(')),
      );
      expect(wake, contains('var notificationsReady = true;'));
      expect(wake, contains('notificationsReady = false;'));
      expect(wake, contains('CloudSyncAndroidBackgroundOutcome.retry'));
      expect(
        service,
        contains('_cloudSyncV2AndroidBackgroundRegistration.locallyRegistered'),
      );
      expect(
        service,
        contains('closingState != null && ls.isUiThread && !mcs.background'),
      );
      final native = File(
        'android/app/src/main/kotlin/com/bluebubbles/messaging/services/rustpush/APNService.kt',
      ).readAsStringSync();
      expect(
        native,
        contains('CloudSyncV2WorkRegistration.current(this)?.let'),
      );
      expect(native, contains('CloudSyncV2WorkKind.METADATA, registration'));
      expect(native, contains('catch (error: CancellationException)'));
    },
  );
}
