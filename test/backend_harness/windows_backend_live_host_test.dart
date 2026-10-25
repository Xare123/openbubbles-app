import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_controller.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/backend_harness/backend_harness_vm_service.dart';
import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart' as harness;
import 'package:bluebubbles/database/database.dart';
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
    for (final suffix in ['json', 'stop', 'closed.json']) {
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
    file.writeAsStringSync(jsonEncode(value), flush: true);
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

  void publishClosed(String source, int ownerPid) {
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
      if (!kDebugMode ||
          !BackendHarnessGate.compiledIn ||
          CloudKitWriterOwnership.legacyMutationsEnabled ||
          CloudKitWriterOwnership.v2MutationsEnabled ||
          CloudSyncDevGate.manualOutboundCanaryEnabled ||
          CloudSyncDevGate.localSendRuntimeEnabled ||
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
        final controller = BackendHarnessController();
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
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        final drain = controller.engine.closeAdmissionAndDrain();
        service.cloudSyncV2Progress.pause();
        controller.interactions.close();
        await drain;
        if (controller.engine.hasUncertainJobs) {
          throw StateError('backend_windows_outcome_uncertain');
        }
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
