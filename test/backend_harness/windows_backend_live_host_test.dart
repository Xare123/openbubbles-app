import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_controller.dart';
import 'package:bluebubbles/backend_harness/backend_harness_fixtures.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/backend_harness/backend_harness_vm_service.dart';
import 'package:bluebubbles/backend_harness/backend_harness_windows_writer.dart';
import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart' as harness;
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/services/backend/filesystem/cloud_sync_windows_dev_profile.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'windows_backend_harness_storage.dart';
import 'windows_chat_source_inspection.dart';

/// Only the test entry below supplies the fixed marked-profile validator.
/// Offline control-file checks can inject an owned synthetic directory.
final class WindowsBackendHostFiles {
  WindowsBackendHostFiles(
    this.requireProfile,
    this.launchId, {
    int Function()? elapsedMilliseconds,
  }) : _elapsedMilliseconds = elapsedMilliseconds ?? _monotonicClock() {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(launchId)) {
      throw StateError('backend_windows_launch_invalid');
    }
    expectedRoot = path.normalize(requireProfile().absolute.path);
    expectedResolved = path.normalize(
      requireProfile().resolveSymbolicLinksSync(),
    );
    _root();
  }

  final Directory Function() requireProfile;
  final String launchId;
  final int Function() _elapsedMilliseconds;
  int? _stopPublicationStarted;
  late final String expectedRoot;
  late final String expectedResolved;
  String? _recoveryText;
  bool _chatSourceInspectionConsumed = false;

  static int Function() _monotonicClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  String _root() {
    final root = requireProfile();
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        path.normalize(root.absolute.path) != expectedRoot ||
        path.normalize(root.resolveSymbolicLinksSync()) != expectedResolved) {
      throw StateError('backend_windows_control_root_changed');
    }
    return expectedRoot;
  }

  File _file(String suffix) =>
      File(path.join(_root(), 'backend-host-$launchId.$suffix'));

  void requireFreshLaunch() {
    for (final suffix in ['json', 'stop', 'closed.json', 'recovery.json',
      'chat-source.json', 'chat-source-started.json', 'chat-source-result.json',
      for (final stage in windowsChatSourceInspectionStages) 'chat-source-$stage.json']) {
      if (FileSystemEntity.typeSync(_file(suffix).path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('backend_windows_launch_consumed');
      }
    }
  }

  void _requirePlainFile(File file) {
    _root();
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        path.normalize(file.resolveSymbolicLinksSync()) !=
            path.normalize(file.absolute.path)) {
      throw StateError('backend_windows_control_file_changed');
    }
  }

  void _writeNew(String suffix, Map<String, Object?> value) {
    final file = _file(suffix)..createSync(exclusive: true);
    _requirePlainFile(file);
    final handle = file.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.exclusive);
      if (handle.lengthSync() != 0) {
        throw StateError('backend_windows_control_file_changed');
      }
      handle.writeStringSync(jsonEncode(value));
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    _requirePlainFile(file);
  }

  void publishReady(Uri uri, String source, int ownerPid) {
    if (uri.scheme != 'ws' ||
        !const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host) ||
        !uri.hasPort ||
        uri.port == 0 ||
        uri.userInfo.isNotEmpty ||
        uri.pathSegments.where((part) => part.isNotEmpty).length < 2 ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw StateError('backend_windows_private_endpoint_required');
    }
    _writeNew('json', {
      'schema': 1,
      'launchId': launchId,
      'source': source,
      'package': 'com.bluebubbles.cloudsync.testhost',
      'pid': ownerPid,
      'uri': uri.toString(),
    });
  }

  bool stopRequested() {
    final file = _file('stop');
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return false;
    }
    _requirePlainFile(file);
    final length = file.lengthSync();
    final started = _stopPublicationStarted;
    final now = _elapsedMilliseconds();
    if (length > 32 || (started != null && now - started >= 2000)) {
      throw StateError('backend_windows_stop_owner_mismatch');
    }
    if (length < 32) {
      _stopPublicationStarted ??= now;
      return false;
    }
    if (file.readAsStringSync() != launchId) {
      throw StateError('backend_windows_stop_owner_mismatch');
    }
    return true;
  }

  Map<String, Object?>? takeChatSourceInspection(String source, int ownerPid, {
    bool allowMessagePreparationRecovery = false,
  }) {
    if (_chatSourceInspectionConsumed) return null;
    final file = _file('chat-source.json');
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    _requireReadyOwner(source, ownerPid);
    _requirePlainFile(file);
    if (file.lengthSync() > 4096) {
      throw StateError('backend_windows_chat_source_request_invalid');
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw StateError('backend_windows_chat_source_request_invalid');
    }
    final request = decoded.cast<String, Object?>();
    if (!validWindowsChatSourceRequest(request) ||
        request['schema'] == 4 && !allowMessagePreparationRecovery || request['launchId'] != launchId ||
        request['source'] != source || request['pid'] != ownerPid) {
      throw StateError('backend_windows_chat_source_request_invalid');
    }
    // Consume before entering native work. A timeout or failed observation is
    // retained under this launch, never retried by the polling loop.
    _chatSourceInspectionConsumed = true;
    _writeNew('chat-source-started.json', {
      'schema': 1, 'launchId': launchId, 'source': source, 'pid': ownerPid,
      'rowId': request['rowId'], 'generation': request['generation'],
      'sequence': request['sequence'],
    });
    return request;
  }

  void publishChatSourceInspection(String source, int ownerPid,
      Map<String, Object?> result) {
    _requireReadyOwner(source, ownerPid);
    if (!_chatSourceInspectionConsumed) {
      throw StateError('backend_windows_chat_source_not_started');
    }
    _writeNew('chat-source-result.json', {
      'launchId': launchId, 'source': source, 'pid': ownerPid, ...result,
    });
  }

  void publishChatSourceStage(String source, int ownerPid, String stage) {
    _requireReadyOwner(source, ownerPid);
    if (!_chatSourceInspectionConsumed ||
        !windowsChatSourceInspectionStages.contains(stage)) {
      throw StateError('backend_windows_chat_source_stage_invalid');
    }
    _writeNew('chat-source-$stage.json', {
      'schema': 1, 'launchId': launchId, 'source': source, 'pid': ownerPid,
      'stage': stage, 'rawContentExposed': false,
    });
  }

  void preserveRecovery(
    BackendHarnessEngine engine,
    String source,
    int ownerPid,
    String recoveryOwner,
  ) {
    if (!backendHarnessRecoveryOwnerValid(recoveryOwner)) {
      throw StateError('backend_windows_recovery_owner_invalid');
    }
    final snapshot = engine.drainedRecoverySnapshot();
    if (snapshot['source'] != source ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(source) ||
        snapshot['package'] != 'com.bluebubbles.cloudsync.testhost' ||
        snapshot['platform'] != 'windows' ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(snapshot['sessionId'] as String)) {
      throw StateError('backend_windows_recovery_identity_changed');
    }
    final jobs = snapshot['jobs'] as List;
    if (jobs.isEmpty || !engine.hasUncertainJobs) {
      throw StateError('backend_windows_recovery_empty');
    }
    for (final job in jobs.cast<Map>()) {
      final correlation = job['correlation'];
      if (correlation is Map &&
          correlation['retainedRecoveryOwner'] != recoveryOwner) {
        throw StateError('backend_windows_recovery_owner_mismatch');
      }
    }
    _requireReadyOwner(source, ownerPid);
    final value = <String, Object>{
      'schema': 1,
      'launchId': launchId,
      'source': source,
      'pid': ownerPid,
      'sessionId': engine.sessionId,
      'recoveryOwner': recoveryOwner,
      'outcome_uncertain': true,
      'recovery': snapshot,
    };
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > 1048576) {
      throw StateError('backend_windows_recovery_too_large');
    }
    _writeNew('recovery.json', value);
    _recoveryText = encoded;
    verifyRecovery();
  }

  void verifyRecovery() {
    final expected = _recoveryText;
    if (expected == null) return;
    final file = _file('recovery.json');
    _requirePlainFile(file);
    if (file.lengthSync() != utf8.encode(expected).length ||
        file.readAsStringSync() != expected) {
      throw StateError('backend_windows_recovery_changed');
    }
  }

  void _requireReadyOwner(String source, int ownerPid) {
    final ready = _file('json');
    _requirePlainFile(ready);
    if (ready.lengthSync() > 8192) {
      throw StateError('backend_windows_ready_owner_mismatch');
    }
    final value = jsonDecode(ready.readAsStringSync()) as Map;
    if (ownerPid <= 0 ||
        value['launchId'] != launchId ||
        value['source'] != source ||
        value['pid'] != ownerPid) {
      throw StateError('backend_windows_ready_owner_mismatch');
    }
  }

  void publishClosed(String source, int ownerPid) {
    verifyRecovery();
    final ready = _file('json');
    _requirePlainFile(ready);
    final value = jsonDecode(ready.readAsStringSync()) as Map;
    if (value['launchId'] != launchId ||
        value['source'] != source ||
        value['pid'] != ownerPid) {
      throw StateError('backend_windows_ready_owner_mismatch');
    }
    ready.deleteSync();
    _writeNew('closed.json', {
      'schema': 1,
      'launchId': launchId,
      'source': source,
      'pid': ownerPid,
      'protectedWorkDrained': true,
      'nativeHandlesReleased': true,
      'storeClosed': true,
      'rustDisposed': true,
    });
  }
}

/// A persisted terminal uncertainty is distinct from active work. Failure of
/// either preservation or the ordinary close sequence propagates to host hold.
Future<void> shutdownWindowsBackendHost({
  required BackendHarnessEngine engine,
  required WindowsBackendHostFiles files,
  required String source,
  required int ownerPid,
  required String recoveryOwner,
  required void Function() pause,
  required Future<void> Function() closeNative,
}) async {
  final drain = engine.closeAdmissionAndDrain();
  pause();
  await drain;
  if (engine.hasUncertainJobs) {
    files.preserveRecovery(engine, source, ownerPid, recoveryOwner);
  }
  await closeNative();
}

/// The native send bridge can return while its completion task still owns the
/// send. A handoff is not a substitute for joining it. Keep the existing hold
/// when the current process still marks a pending send, or a terminal fixture
/// result cannot establish completion of a background mutation/send.
Future<void> requireWindowsBackendNativeSendCompletion(
  BackendHarnessEngine engine,
  Store store,
  String serviceId, {
  Future<BackendHarnessPayload> Function(Map<String, Object?> job)?
      observeCurrentFixture,
}) async {
  _requireNoPendingNativeSend(store, serviceId);
  for (final job
      in (engine.drainedRecoverySnapshot()['jobs'] as List).cast<Map>()) {
    if ((const {'fixture.edit', 'fixture.unsend'}.contains(job['action']) ||
            job['action'] == 'fixture.send' && job['state'] == 'completed') &&
        (job['flags'] as Map)['ids_evidence_present'] != true) {
      final observe = observeCurrentFixture;
      if (observe == null) {
        throw StateError('backend_windows_native_completion_unconfirmed');
      }
      final original = Map<String, Object?>.from(job);
      final current = await observe(original);
      _requireNoPendingNativeSend(store, serviceId);
      if (!BackendHarnessFixtures.nativeCompletionMatches(original, current)) {
        throw StateError('backend_windows_native_completion_unconfirmed');
      }
    }
  }
  _requireNoPendingNativeSend(store, serviceId);
}

void _requireNoPendingNativeSend(Store store, String serviceId) {
  if (store.isClosed()) throw StateError('backend_windows_store_closed');
  final pending =
      store
          .box<Message>()
          .query(Message_.sendingServiceId.equals(serviceId))
          .build()
        ..limit = 1;
  try {
    if (pending.count() != 0) {
      throw StateError('backend_windows_native_send_pending');
    }
  } finally {
    pending.close();
  }
}

void main() {
  const compiledHost = bool.fromEnvironment('BACKEND_HARNESS_WINDOWS_HOST');
  final enabled =
      Platform.isWindows &&
      compiledHost &&
      Platform.environment['OPENBUBBLES_RUN_WINDOWS_BACKEND_HOST'] == '1';
  test(
    'isolated Windows backend exposes compiled commands',
    () async {
      final launchId =
          Platform.environment['OPENBUBBLES_BACKEND_LAUNCH_ID'] ?? '';
      final library =
          Platform.environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'] ?? '';
      const build = String.fromEnvironment('OPENBUBBLES_BUILD_COMMIT');
      const writerCompiled = bool.fromEnvironment('BACKEND_HARNESS_WINDOWS_WRITER');
      final recoveryOwner =
          Platform.environment['OPENBUBBLES_BACKEND_RECOVERY_OWNER'] ?? '';
      if (!kDebugMode ||
          !BackendHarnessGate.compiledIn ||
          !backendHarnessWindowsWriterModeAllowed(
            writerCompiled: writerCompiled,
            writerEnvironment: Platform.environment[
                'OPENBUBBLES_RUN_WINDOWS_BACKEND_WRITER'] == '1',
            recoveryOwner: recoveryOwner,
            legacyWriter: CloudKitWriterOwnership.legacyMutationsEnabled,
            v2Writer: CloudKitWriterOwnership.v2MutationsEnabled,
            outbound: CloudSyncDevGate.manualOutboundCanaryEnabled,
            automaticUploads: CloudSyncDevGate.localSendRuntimeEnabled,
          ) ||
          !RegExp(r'^[a-f0-9]{40}$').hasMatch(BackendHarnessGate.source) ||
          build != BackendHarnessGate.source ||
          library.isEmpty ||
          Platform.environment['OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST'] != '1' ||
          Platform.environment['OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS'] !=
              '1') {
        throw StateError('backend_windows_host_disabled');
      }
      final files = WindowsBackendHostFiles(
        CloudSyncWindowsDevProfile.requireBootstrapped,
        launchId,
      );
      files.requireFreshLaunch();
      final profile = CloudSyncWindowsDevProfile.requireBootstrapped();
      if (FileSystemEntity.typeSync(
            path.join(profile.path, 'incident_affected'),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw StateError('backend_windows_incident_requires_review');
      }
      // The parent retains the existing supported profile mutex. This additional
      // owned file lock survives a parent transport failure until this host exits.
      final leaseFile = File(
        path.join(profile.path, '.backend-command-host.lock'),
      );
      if (FileSystemEntity.typeSync(leaseFile.path, followLinks: false) !=
              FileSystemEntityType.notFound &&
          FileSystemEntity.typeSync(leaseFile.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw StateError('backend_windows_owner_lock_changed');
      }
      final lease = leaseFile.openSync(mode: FileMode.append);
      lease.lockSync(FileLock.exclusive);
      var nativeEntered = false;
      BackendHarnessController? activeController;
      try {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          (_) async => <String, Object?>{
            'appName': 'OpenBubbles Backend Test Host',
            'packageName': 'com.bluebubbles.cloudsync.testhost',
            'version': '0.0.0',
            'buildNumber': '0',
            'buildSignature': '',
            'installerStore': null,
          },
        );
        harness.configureCloudSyncV2WindowsHarnessTestLaunch(launchId);
        BackendHarnessWindowsStorage.installMarkedProfile();
        await fs.init(headless: true);
        Logger.currentOutput = Logger.fileOutput;
        await Logger.init();
        await ss.init(headless: true);
        if (ss.settings.cloudSyncingEnabled.value) {
          throw StateError('backend_windows_legacy_sync_enabled');
        }
        nativeEntered = true;
        await RustLib.init(externalLibrary: ExternalLibrary.open(library));
        await Database.init(cloudSyncV2Harness: true);
        ss.getFcmData();
        await mcs.init();
        // This is the retained service owner, so use the real foreground-owner
        // lifecycle. Headless lifecycle deliberately skips receipt recovery.
        await ls.init();
        final service = pushService;
        await service.startupFuture;
        // This lane restores the retained owner. A missing session requires
        // separate recovery, rather than acquiring unowned setup resources.
        if (service.state == null) {
          throw StateError('backend_windows_retained_session_required');
        }
        final controller = BackendHarnessController(
          retainedRecoveryOwner: writerCompiled ? recoveryOwner : null,
        );
        activeController = controller;
        if (!registerBackendHarnessExtension(
          controller.engine,
          isolatedWindowsProfile: fs.cloudSyncV2WindowsDevProfileActive,
        )) {
          throw StateError('backend_windows_registration_refused');
        }
        if (!StartupTasks.uiReady.isCompleted) StartupTasks.uiReady.complete();
        final endpoint = (await developer.Service.getInfo()).serverWebSocketUri;
        if (endpoint == null) {
          throw StateError('backend_windows_private_endpoint_required');
        }
        files.publishReady(endpoint, BackendHarnessGate.source, pid);
        final deadline = DateTime.now().add(const Duration(minutes: 20));
        while (!files.stopRequested() && DateTime.now().isBefore(deadline)) {
          final sourceRequest = files.takeChatSourceInspection(
            BackendHarnessGate.source, pid, allowMessagePreparationRecovery: writerCompiled);
          if (sourceRequest != null) {
            // This one-shot observation is terminal for command admission.
            // Finish any entered command before taking its native read window.
            await controller.engine.closeAdmissionAndDrain();
            Future<void> requireIdle() async {
              final preference = await service.readCloudSyncV2AutomaticArchivePreference();
              if (preference.enabled || service.cloudSyncV2HistoryReadActive ||
                  service.cloudSyncV2CanaryAdbSemanticPullQuiescing ||
                  service.backendRegistrationRestartRequired ||
                  !identical(controller, activeController)) {
                throw StateError('backend_windows_chat_source_requires_idle');
              }
            }
            var stage = 'requested';
            try {
              final result = await inspectWindowsChatSource(
                store: Database.store, profile: profile.path, request: sourceRequest,
                readActiveClient: () => service.state?.icloudServices?.cloudMessagesClient,
                requireIdle: requireIdle,
                onStage: (next) {
                  files.publishChatSourceStage(BackendHarnessGate.source, pid, next);
                  stage = next;
                });
              files.publishChatSourceInspection(BackendHarnessGate.source, pid, result);
            } catch (error) {
              files.publishChatSourceInspection(BackendHarnessGate.source, pid, {
                'schema': 1, 'completed': false, 'rowId': sourceRequest['rowId'],
                'generation': sourceRequest['generation'], 'sequence': sourceRequest['sequence'],
                'lastStage': stage, 'failure': safeWindowsChatSourceFailure(error),
                if (sourceRequest['schema'] == 4) ...windowsMessagePreparationFailureDetails(error),
                'rawContentExposed': false,
              });
              rethrow; // Preserve native ownership; failure is not a close grant.
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        await shutdownWindowsBackendHost(
          engine: controller.engine,
          files: files,
          source: BackendHarnessGate.source,
          ownerPid: pid,
          recoveryOwner: recoveryOwner,
          pause: () {
            service.cloudSyncV2Progress.pause();
            controller.interactions.close();
          },
          closeNative: () async {
            await requireWindowsBackendNativeSendCompletion(
              controller.engine,
              Database.store,
              service.serviceId,
              observeCurrentFixture:
                  controller.fixtures.observeNativeCompletionForShutdown,
            );
            final hadState = service.state != null;
            service.onClose();
            await service.nativeCloseFuture;
            if (service.state != null ||
                (hadState && !service.nativeCloseCompleted)) {
              throw StateError('backend_windows_native_release_unconfirmed');
            }
            await CloudKitOperationInterlock.drainForEngineExit();
            ls.onClose();
            Database.store.close();
            RustLib.dispose();
            files.publishClosed(BackendHarnessGate.source, pid);
            nativeEntered = false;
            lease.unlockSync();
            lease.closeSync();
          },
        );
      } catch (_) {
        if (nativeEntered) {
          final controller = activeController;
          if (controller != null) {
            unawaited(controller.engine.closeAdmissionAndDrain());
            pushService.cloudSyncV2Progress.pause();
            controller.interactions.close();
          }
          // Neither an exception nor a timeout cancels entered native work.
          // Keep ownership and private observations for explicit recovery.
          print(
            'WINDOWS_BACKEND_HOST_HELD=backend_windows_shutdown_unconfirmed',
          );
          await Completer<void>().future;
        }
        lease.closeSync();
        throw StateError('backend_windows_bootstrap_refused');
      }
    },
    skip: !enabled,
    timeout: Timeout.none,
  );
}
