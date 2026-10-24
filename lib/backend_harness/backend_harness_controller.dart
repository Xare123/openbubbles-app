import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector_health.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';

import 'backend_harness_account.dart';
import 'backend_harness_archive.dart';
import 'backend_harness_evidence.dart';
import 'backend_harness_fixtures.dart';
import 'backend_harness_interactions.dart';
import 'backend_harness_protocol.dart';
import 'backend_harness_recovery_input.dart';
import 'backend_harness_reports.dart';

/// A loaded client and a saved setup marker are availability facts. Neither
/// establishes fresh account authentication; the auth adapter must do that.
BackendHarnessPayload backendHarnessAccountAvailability({
  required bool setupFinished,
  required bool nativeClientPresent,
}) => BackendHarnessPayload(
  phase: setupFinished
      ? nativeClientPresent
            ? BackendHarnessPhase.idle
            : BackendHarnessPhase.configuring
      : nativeClientPresent
      ? BackendHarnessPhase.registering
      : BackendHarnessPhase.needs_credentials,
  flags: {
    'setup_finished': setupFinished,
    'native_client_present': nativeClientPresent,
  },
);

/// Compiled adapters call the same service methods as Profile. Capabilities
/// include only implemented operations; account/archive adapters are separate.
final class BackendHarnessController {
  BackendHarnessController() {
    engine = BackendHarnessEngine(
      enabled: true,
      source: BackendHarnessGate.source,
      package: fs.packageInfo.packageName,
      platform: Platform.isAndroid ? 'android' : 'windows',
      operations: {
        'status': BackendHarnessOperation(
          validate: (args) => args.isEmpty,
          handler: (_) async => snapshot(),
        ),
        'relay.configure': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: BackendHarnessAccount.validRelay,
          handler: account.configure,
          snapshot: snapshot,
        ),
        'auth.restore': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: (args) => args.isEmpty,
          handler: account.restore,
          snapshot: snapshot,
        ),
        'auth.status': BackendHarnessOperation(
          background: true,
          validate: (args) => args.isEmpty,
          handler: account.inspect,
          snapshot: snapshot,
        ),
        'auth.login': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: BackendHarnessAccount.validLogin,
          handler: account.login,
          snapshot: snapshot,
        ),
        'auth.code': BackendHarnessOperation(
          validate: BackendHarnessAccount.validCode,
          handler: (args) async {
            account.answer(args);
            return snapshot();
          },
        ),
        'archive.prepare': BackendHarnessOperation(
          background: true,
          validate: (args) => args.isEmpty,
          handler: (_) => archive.prepare(),
        ),
        'archive.scope': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: BackendHarnessArchive.validScope,
          handler: archive.setScope,
        ),
        'archive.status': BackendHarnessOperation(
          background: true,
          validate: (args) => args.isEmpty,
          handler: (_) => archive.status(),
        ),
        'fixture.inspect': BackendHarnessOperation(
          background: true,
          validate: BackendHarnessEvidence.validInspect,
          handler: evidence.inspect,
        ),
        'fixture.materialize': BackendHarnessOperation(
          background: true,
          validate: BackendHarnessEvidence.validMaterialize,
          handler: evidence.materialize,
        ),
        'report.snapshot': BackendHarnessOperation(
          validate: (args) => args.isEmpty,
          handler: (_) async => backendHarnessReportSnapshot(
            pushService.cloudSyncV2Progress,
            BackendHarnessGate.source,
          ),
        ),
        'fixture.send': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: BackendHarnessFixtures.validSend,
          handler: fixtures.send,
        ),
        'fixture.edit': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: BackendHarnessFixtures.validMutation,
          handler: fixtures.edit,
        ),
        'fixture.unsend': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: BackendHarnessFixtures.validMutation,
          handler: fixtures.unsend,
        ),
        'fixture.status': BackendHarnessOperation(
          validate: BackendHarnessFixtures.validStatus,
          handler: fixtures.status,
        ),
        'protector.check': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: (args) => args.isEmpty,
          handler: (_) async {
            await pushService.initFuture;
            final healthy = await CloudSyncProtectorHealthProbe(
              protector: RustCloudSyncProtector(
                storageDirectory: pushService.statePath,
              ),
            ).read();
            return BackendHarnessPayload(
              phase: healthy
                  ? BackendHarnessPhase.idle
                  : BackendHarnessPhase.blocked,
              flags: {'protector_ready': healthy},
            );
          },
        ),
        'pcs.devices': BackendHarnessOperation(
          validate: (args) => args.isEmpty,
          handler: (_) async => snapshot(),
        ),
        'pcs.unlock': BackendHarnessOperation(
          validate: BackendHarnessRecoveryInput.validAnswer,
          handler: (args) async {
            recovery.answer(args);
            return snapshot();
          },
        ),
        'sync.pause': BackendHarnessOperation(
          validate: (args) => args.isEmpty,
          handler: (_) async {
            pushService.cloudSyncV2Progress.pause();
            if (const {
              BackendHarnessChallengeKind.trustedDevice,
              BackendHarnessChallengeKind.passcode,
              BackendHarnessChallengeKind.pin,
            }.contains(interactions.pending?.kind)) {
              interactions.close();
            }
            return snapshot();
          },
        ),
        'sync.start': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: _readArguments,
          handler: _read,
          snapshot: snapshot,
        ),
      },
    );
  }
  late final BackendHarnessEngine engine;
  final interactions = BackendHarnessInteractions();
  late final account = BackendHarnessAccount(interactions);
  late final archive = BackendHarnessArchive(
    read: () => pushService.readCloudSyncV2AutomaticArchivePreference(),
    write: (expected, enabled, acknowledged, received, media) =>
        pushService.setCloudSyncV2AutomaticArchivePreference(
          expected,
          enabled,
          acknowledgeQueuedUploads: acknowledged,
          includeReceived: received,
          includeReceivedMedia: media,
        ),
  );
  late final recovery = BackendHarnessRecoveryInput(interactions);
  final fixtures = BackendHarnessFixtures();
  late final evidence = BackendHarnessEvidence(
    readStore: () => Database.store,
    captureAuth: () async {
      await pushService.initFuture;
      return CloudSyncProductionAuthSnapshotProvider(
        readActiveClient: () =>
            pushService.state?.icloudServices?.cloudMessagesClient,
        nativeAuthBinding: FrbCloudSyncNativeAuthBinding(),
        privateStorageDirectory: pushService.statePath,
      ).capture();
    },
    download: (attachment) => backend.downloadAttachment(attachment),
  );

  static bool _readArguments(Map<String, Object?> args) =>
      args.keys.every(const {'speed', 'budgetSeconds'}.contains) &&
      (!args.containsKey('speed') ||
          const {'regular', 'turbo'}.contains(args['speed'])) &&
      (!args.containsKey('budgetSeconds') ||
          (args['budgetSeconds'] is int &&
              (args['budgetSeconds'] as int) >= 1 &&
              (args['budgetSeconds'] as int) <= 300));

  Future<BackendHarnessPayload> _read(Map<String, Object?> args) async {
    final service = pushService;
    if (!ss.settings.finishedSetup.value ||
        service.state?.icloudServices?.cloudMessagesClient == null ||
        service.cloudSyncV2Progress.restartRequired) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    if (service.cloudSyncV2HistoryReadActive ||
        service.cloudSyncV2Progress.active) {
      throw BackendHarnessFailure('backend_busy');
    }
    final speed = args['speed'] == 'turbo'
        ? CloudSyncSpeed.turbo
        : CloudSyncSpeed.regular;
    // Cooperative pause preserves the in-flight native operation and its
    // receipts. A Future.timeout must never discard a live backend owner.
    final pause = Timer(
      Duration(seconds: args['budgetSeconds'] as int? ?? 60),
      () {
        service.cloudSyncV2Progress.pause();
        interactions.close();
      },
    );
    try {
      await service.startCloudSyncV2Progress(
        speed,
        recoveryInput: recovery.input,
      );
      if (service.cloudSyncV2Progress.safeFailure != null) {
        throw BackendHarnessFailure('backend_job_failed');
      }
      return snapshot();
    } finally {
      pause.cancel();
    }
  }

  BackendHarnessPayload snapshot() {
    final service = pushService;
    final progress = service.cloudSyncV2Progress;
    final availability = backendHarnessAccountAvailability(
      setupFinished: ss.settings.finishedSetup.value,
      nativeClientPresent:
          service.state?.icloudServices?.cloudMessagesClient != null,
    );
    final challenge = interactions.pending;
    final phase = challenge != null
        ? switch (challenge.kind) {
            BackendHarnessChallengeKind.trustedDevice =>
              BackendHarnessPhase.needs_trusted_device,
            BackendHarnessChallengeKind.smsDestination =>
              BackendHarnessPhase.needs_sms_2fa,
            BackendHarnessChallengeKind.verificationCode =>
              BackendHarnessPhase.needs_2fa,
            BackendHarnessChallengeKind.archiveConsent =>
              BackendHarnessPhase.blocked,
            BackendHarnessChallengeKind.passcode ||
            BackendHarnessChallengeKind.pin =>
              BackendHarnessPhase.needs_passcode,
          }
        : switch (progress.phase) {
            CloudSyncProgressPhase.idle => availability.phase,
            CloudSyncProgressPhase.waiting ||
            CloudSyncProgressPhase.authentication ||
            CloudSyncProgressPhase.pcs => BackendHarnessPhase.configuring,
            CloudSyncProgressPhase.fetching ||
            CloudSyncProgressPhase.replaying => BackendHarnessPhase.syncing,
            CloudSyncProgressPhase.pausing => BackendHarnessPhase.pausing,
            CloudSyncProgressPhase.paused => BackendHarnessPhase.paused,
            CloudSyncProgressPhase.remoteHead =>
              BackendHarnessPhase.remote_head,
            CloudSyncProgressPhase.error => BackendHarnessPhase.error,
          };
    return BackendHarnessPayload(
      phase: phase,
      challenge: challenge,
      flags: {
        ...availability.flags,
        ...account.snapshot().flags,
        'sync_active': service.cloudSyncV2HistoryReadActive,
        'sync_quiescing': service.cloudSyncV2CanaryAdbSemanticPullQuiescing,
        'projection_complete': progress.projectionComplete,
        'has_report': progress.hasReport,
        'failure_present': progress.safeFailure != null,
      },
      counts: {
        'pages': progress.pages,
        'fetched': progress.fetched,
        'reprojected': progress.reprojected,
        'retained': progress.retained,
      },
    );
  }
}
