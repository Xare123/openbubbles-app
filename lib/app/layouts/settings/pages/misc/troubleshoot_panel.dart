import 'package:bluebubbles/app/layouts/settings/pages/misc/logging_panel.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/log_level_selector.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/next_button.dart';
import 'package:bluebubbles/helpers/backend/settings_helpers.dart';
import 'package:bluebubbles/main.dart';
import 'package:bluebubbles/services/backend/sync/chat_sync_manager.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_presentation_repair.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:disable_battery_optimization/disable_battery_optimization.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;




enum CloudSyncV2SemanticCanaryOutcome { complete, partial, stoppedSafely }

@immutable
final class CloudSyncV2SemanticCanaryPresentation {
  const CloudSyncV2SemanticCanaryPresentation({
    required this.outcome,
    required this.title,
    required this.message,
  });

  final CloudSyncV2SemanticCanaryOutcome outcome;
  final String title;
  final String message;
}

CloudSyncV2SemanticCanaryPresentation cloudSyncV2SemanticCanaryPresentation(
  CloudSyncSemanticPullReport report,
) {
  final fetched = report.zones.fold<int>(
    0,
    (total, zone) => total + zone.fetched,
  );
  final applied = report.zones.fold<int>(
    0,
    (total, zone) => total + zone.applied,
  );
  final retainedUnprojected = report.zones.fold<int>(
    0,
    (total, zone) => total + zone.retainedUnprojected,
  );
  final deferred = report.zones.fold<int>(
    0,
    (total, zone) => total + zone.deferred,
  );
  final quarantined = report.zones.fold<int>(
    0,
    (total, zone) => total + zone.quarantined,
  );
  final unsupportedServiceQuarantined = report.zones.fold<int>(
    0,
    (total, zone) => total + zone.semanticUnsupportedServiceQuarantined,
  );
  final tombstoneQuarantined = report.zones.fold<int>(
    0,
    (total, zone) => total + zone.tombstoneQuarantined,
  );
  final tombstoneReadOnlyAcknowledged = report.zones.fold<int>(
    0,
    (total, zone) => total + zone.tombstoneReadOnlyAcknowledged,
  );
  final retried = report.zones.fold<int>(
    0,
    (total, zone) => total + zone.retried,
  );
  const expectedZones = <String>{"chats", "messages", "attachments"};
  final reportedZones = report.zones.map((zone) => zone.zoneLabel).toSet();
  final zoneStructureIntact =
      report.zones.length == expectedZones.length &&
      reportedZones.length == expectedZones.length &&
      reportedZones.containsAll(expectedZones);
  final allZonesCompleted = report.zones.every(
    (zone) => zone.status == CloudSyncRunStatus.completed,
  );
  final allZonesReadWithoutBlockingFailure = report.zones.every(
    (zone) =>
        zone.status == CloudSyncRunStatus.completed ||
        (zone.status == CloudSyncRunStatus.degraded &&
            zone.failureSafeCode == 'retained_projection_incomplete'),
  );
  final readCompletionGatesPassed =
      zoneStructureIntact &&
      allZonesReadWithoutBlockingFailure &&
      deferred == 0 &&
      quarantined == 0 &&
      unsupportedServiceQuarantined == 0 &&
      tombstoneQuarantined == 0 &&
      retried == 0 &&
      report.remoteWriteTripwiresIntact;
  final totals =
      "Fetched $fetched, applied $applied, retained-unprojected $retainedUnprojected, read-only tombstones acknowledged $tombstoneReadOnlyAcknowledged, deferred $deferred, quarantined $quarantined (unsupported service $unsupportedServiceQuarantined, tombstone failures $tombstoneQuarantined), retried $retried.";

  if (readCompletionGatesPassed &&
      allZonesCompleted &&
      retainedUnprojected == 0) {
    return CloudSyncV2SemanticCanaryPresentation(
      outcome: CloudSyncV2SemanticCanaryOutcome.complete,
      title: "Cloud Sync V2 Complete",
      message: "$totals No CloudKit uploads or deletes occurred.",
    );
  }
  if (readCompletionGatesPassed && retainedUnprojected > 0) {
    final retainedLabel = retainedUnprojected == 1
        ? "record remains retained and has not"
        : "records remain retained and have not";
    return CloudSyncV2SemanticCanaryPresentation(
      outcome: CloudSyncV2SemanticCanaryOutcome.partial,
      title: "Cloud Sync V2 Partial",
      message:
          "$totals The read completed, but $retainedUnprojected $retainedLabel been projected into local messages. No CloudKit uploads or deletes occurred.",
    );
  }
  return CloudSyncV2SemanticCanaryPresentation(
    outcome: CloudSyncV2SemanticCanaryOutcome.stoppedSafely,
    title: "Cloud Sync V2 Stopped Safely",
    message:
        "$totals Incomplete records/zone or a write tripwire was detected. No further work was allowed.",
  );
}

String? cloudSyncV2InterlockBusyMessage(
  Object error, {
  DateTime? now,
}) {
  if (error is! CloudKitOperationInterlockException ||
      error.safeCode != 'cloudkit_interlock_busy') {
    return null;
  }

  final current = (now ?? DateTime.now()).toUtc();
  final retryAt = error.retryAt?.toUtc();
  if (retryAt == null || !retryAt.isAfter(current)) {
    return "Another CloudKit operation is active. Wait for it to finish and retry. If OpenBubbles was just force-stopped, its data-protection lease can take up to five minutes to expire.";
  }

  final secondsRemaining = retryAt.difference(current).inSeconds;
  final minutesRemaining = (secondsRemaining + 59) ~/ 60;
  final unit = minutesRemaining == 1 ? "minute" : "minutes";
  return "Another CloudKit operation is active, or a recently interrupted operation still holds its data-protection lease. Retry in about $minutesRemaining $unit; it may become available sooner if the active operation finishes.";
}

enum CloudSyncV2OutboundCanaryOutcome {
  writeConfirmed,
  replayVerified,
  recoveryCompleted,
  quarantined,
  unresolved,
}

@immutable
final class CloudSyncV2OutboundCanaryPresentation {
  const CloudSyncV2OutboundCanaryPresentation({
    required this.outcome,
    required this.title,
    required this.message,
  });

  final CloudSyncV2OutboundCanaryOutcome outcome;
  final String title;
  final String message;
}

CloudSyncV2OutboundCanaryPresentation cloudSyncV2OutboundCanaryPresentation(
  CloudSyncOutboundCanaryReport report,
) {
  final cleanTerminalConfirmation =
      report.status == CloudSyncRunStatus.completed &&
      report.outboxStatus == CloudOutboxStatus.confirmed &&
      report.quarantined == 0 &&
      report.retried == 0;

  if (!report.recovery &&
      !report.replayVerification &&
      cleanTerminalConfirmation &&
      report.confirmed == 1) {
    return const CloudSyncV2OutboundCanaryPresentation(
      outcome: CloudSyncV2OutboundCanaryOutcome.writeConfirmed,
      title: "Cloud Sync V2 Upload Confirmed",
      message:
          "One create-only message record was confirmed. No deletes were enabled. Run the no-save replay verification next.",
    );
  }
  if (report.recovery &&
      report.replayVerification &&
      cleanTerminalConfirmation &&
      report.confirmed == 0) {
    return const CloudSyncV2OutboundCanaryPresentation(
      outcome: CloudSyncV2OutboundCanaryOutcome.replayVerified,
      title: "Cloud Sync V2 Replay Verified",
      message:
          "The existing terminal operation was reconciled. No new message was admitted and no additional save was reported.",
    );
  }
  if (report.recovery &&
      !report.replayVerification &&
      cleanTerminalConfirmation &&
      report.confirmed >= 0 &&
      report.confirmed <= 1) {
    return const CloudSyncV2OutboundCanaryPresentation(
      outcome: CloudSyncV2OutboundCanaryOutcome.recoveryCompleted,
      title: "Cloud Sync V2 Recovery Completed",
      message:
          "The existing create operation reached confirmed state. Recovery may have completed one remote create, but no new message was admitted and no delete was enabled.",
    );
  }
  if (report.outboxStatus == CloudOutboxStatus.quarantined ||
      report.quarantined > 0) {
    return const CloudSyncV2OutboundCanaryPresentation(
      outcome: CloudSyncV2OutboundCanaryOutcome.quarantined,
      title: "Cloud Sync V2 Upload Quarantined",
      message:
          "The one operation was quarantined. Do not retry automatically. Review the redacted diagnostic code before using recovery.",
    );
  }
  return const CloudSyncV2OutboundCanaryPresentation(
    outcome: CloudSyncV2OutboundCanaryOutcome.unresolved,
    title: "Cloud Sync V2 Outcome Unresolved",
    message:
        "CloudKit did not return a safely confirmed terminal outcome. Do not retry automatically or admit another message. Use only the recovery action.",
  );
}

class TroubleshootPanel extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _TroubleshootPanelState();
}

class _TroubleshootPanelState extends OptimizedState<TroubleshootPanel> {
  final RxnBool resyncingHandles = RxnBool();
  final RxnBool resyncingChats = RxnBool();
  final RxInt logFileCount = 1.obs;
  final RxInt logFileSize = 0.obs;
  final RxBool optimizationsDisabled = false.obs;
  final RxBool cloudSyncV2Running = false.obs;
  final TextEditingController participantController = TextEditingController();

  bool isExportingLogs = false;
  final RxnBool reregisteringIds = RxnBool();

  bool _showCloudSyncV2Busy(Object error) {
    final message = cloudSyncV2InterlockBusyMessage(error);
    if (message == null) return false;
    final retryTimeAvailable =
        error is CloudKitOperationInterlockException && error.retryAt != null;
    Logger.warn(
      "Cloud Sync V2 operation blocked code=cloudkit_interlock_busy retry_time_available=$retryTimeAvailable",
    );
    showSnackbar("Cloud Sync V2 Busy", message);
    return true;
  }

  @override
  void initState() {
    super.initState();

    // Count how many .log files are in the log directory
    final Directory logDir = Directory(Logger.logDir);
    if (logDir.existsSync()) {
      final List<FileSystemEntity> files = logDir.listSync();
      final logFiles =
          files.where((file) => file.path.endsWith(".log")).toList();
      logFileCount.value = logFiles.length;

      // Size in KB
      for (final file in logFiles) {
        logFileSize.value += file.statSync().size ~/ 1024;
      }
    }

    // Check if battery optimizations are disabled
    if (Platform.isAndroid) {
      DisableBatteryOptimization.isAllBatteryOptimizationDisabled.then((value) {
        optimizationsDisabled.value = value ?? false;
      });
    }
  }

  Future<void> _runCloudSyncV2PcsPreparation() async {
    if (cloudSyncV2Running.value) return;
    if (!pushService.cloudSyncV2PcsPreparationAvailable) {
      showSnackbar(
        "CloudKit Encryption Setup Blocked",
        "Finish OpenBubbles setup, enable Developer Mode, turn off legacy Messages in iCloud sync, and wait for active sync or logout work to finish.",
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.theme.colorScheme.properSurface,
        title: Text(
          "Prepare iCloud encryption?",
          style: context.theme.textTheme.titleLarge,
        ),
        content: Text(
          "This checks whether this Canary can decrypt Messages in iCloud. If needed, you can enter the passcode or password of one trusted Apple device. It will not enable legacy sync, reset encrypted data, upload or delete CloudKit records, or delete local messages.",
          style: context.theme.textTheme.bodyLarge,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Continue"),
          ),
        ],
      ),
    );
    if (confirmed != true || cloudSyncV2Running.value) return;

    cloudSyncV2Running.value = true;
    try {
      final outcome = await pushService.prepareCloudSyncV2PcsConfirmed();
      switch (outcome) {
        case CloudSyncV2PcsPreparationOutcome.alreadyReady:
          showSnackbar(
            "CloudKit Encryption Ready",
            "This Canary already has the iCloud encryption access needed for a bounded catch-up.",
          );
        case CloudSyncV2PcsPreparationOutcome.joined:
          showSnackbar(
            "CloudKit Encryption Ready",
            "Encrypted iCloud access was prepared without enabling legacy sync. You can run Messages in iCloud catch-up now.",
          );
        case CloudSyncV2PcsPreparationOutcome.cancelled:
          showSnackbar(
            "CloudKit Encryption Setup Cancelled",
            "Nothing was reset, uploaded, deleted, or enabled.",
          );
      }
    } catch (error) {
      if (_showCloudSyncV2Busy(error)) return;
      final safeCode = cloudSyncV2SafeFailureCode(error);
      Logger.warn(
        "Cloud Sync V2 PCS preparation stopped safely code=$safeCode",
      );
      showSnackbar(
        "CloudKit Encryption Setup Stopped",
        "Diagnostic code: $safeCode. No encrypted data was reset and legacy sync stayed off.",
      );
    } finally {
      cloudSyncV2Running.value = false;
    }
  }

  Future<bool> _confirmCloudSyncV2Outbound({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: context.theme.colorScheme.properSurface,
            title: Text(title, style: context.theme.textTheme.titleLarge),
            content: Text(message, style: context.theme.textTheme.bodyLarge),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<String?> _requestCloudSyncV2OutboundRecipient() async {
    if (!mounted) return null;
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: context.theme.colorScheme.properSurface,
          title: Text(
            "Enter the exact test recipient",
            style: context.theme.textTheme.titleLarge,
          ),
          content: TextField(
            controller: controller,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              hintText: "Apple email or phone number",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                final recipient = controller.text.trim();
                if (recipient.isNotEmpty) {
                  Navigator.of(dialogContext).pop(recipient);
                }
              },
              child: const Text("Use Exact Recipient"),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<CloudSyncV2OutboundCanaryPresentation?>
      _runCloudSyncV2OutboundRecoveryFlow({
    required bool prepareWriter,
    required bool immediateReplay,
  }) async {
    CloudSyncOutboundCanaryConfirmation? armed;
    try {
      final firstConfirmed = await _confirmCloudSyncV2Outbound(
        title: immediateReplay
            ? "Verify the confirmed upload without another save?"
            : "Recover one interrupted CloudKit upload?",
        message: immediateReplay
            ? "This performs an exact protected remote digest readback for the already-confirmed operation. It never prepares, consumes, or submits a save, selects or admits a new message, and must report zero additional saves."
            : "This resumes the one exact durable operation. If it is pending or outcome-unknown, the first step may provision local V2 writer ownership before the final confirmation. If it is already confirmed, recovery automatically switches to a no-save protected digest readback. It never selects or admits a new message.",
        confirmLabel: immediateReplay ? "Verify Existing" : "Prepare Recovery",
      );
      if (!firstConfirmed) return null;

      armed = immediateReplay
          ? await pushService.armCloudSyncV2OutboundReplayConfirmed()
          : await pushService.armCloudSyncV2OutboundRecoveryConfirmed();
      final replayVerification = armed.replayVerification;
      if (prepareWriter && !replayVerification) {
        await pushService.prepareCloudSyncV2OutboundWriter();
      }

      final secondConfirmed = await _confirmCloudSyncV2Outbound(
        title: replayVerification
            ? "Final no-save replay confirmation"
            : "Final recovery confirmation",
        message: replayVerification
            ? "Only the exact already-confirmed operation may receive a protected remote digest readback. This never prepares, consumes, or submits a save. The run must report zero saves. No new message or delete is enabled, and an unresolved result must not be retried automatically."
            : "Only the exact existing create operation may be reconciled. The first step may have provisioned local V2 writer ownership and quarantined local legacy queues; after this second confirmation, it may complete one durable remote create. No new message or delete is enabled, and an unresolved result must not be retried automatically.",
        confirmLabel: replayVerification ? "Verify Once" : "Recover Once",
      );
      if (!secondConfirmed) return null;

      final report = await pushService.runCloudSyncV2OutboundDoubleConfirmed(
        armed,
      );
      return cloudSyncV2OutboundCanaryPresentation(report);
    } finally {
      if (armed != null) {
        pushService.disarmCloudSyncV2Outbound(armed);
      }
    }
  }

  Future<void> _runCloudSyncV2OutboundCanary() async {
    if (cloudSyncV2Running.value) return;
    if (!pushService.cloudSyncV2ManualOutboundAvailable) {
      showSnackbar(
        "Cloud Sync V2 Writer Blocked",
        "Use the isolated Android Canary writer build, finish setup, enable Developer Mode, turn off legacy Messages in iCloud sync, and wait for active sync or logout work to finish.",
      );
      return;
    }

    cloudSyncV2Running.value = true;
    CloudSyncOutboundCanaryConfirmation? armed;
    try {
      final expectedRecipient = await _requestCloudSyncV2OutboundRecipient();
      if (expectedRecipient == null) return;
      final candidate = await pushService
          .selectCloudSyncV2OutboundCanaryCandidate(
            expectedRecipient: expectedRecipient,
          );
      if (candidate == null) {
        showSnackbar(
          "No Eligible Canary Message",
          "The newest outgoing row is not a fresh, ordinary one-to-one iMessage text. No older message was selected and nothing was written.",
        );
        return;
      }

      final firstConfirmed = await _confirmCloudSyncV2Outbound(
        title: "Prepare one create-only CloudKit upload?",
        message:
            "Expected recipient: $expectedRecipient. Candidate hash ${candidate.guidHash}, created ${candidate.createdAtUtc.toIso8601String()}, ${candidate.characterCount} characters. This first confirmation performs local safety checks only. Provisioning may change local V2 writer ownership and quarantine local legacy queues, but it cannot contact CloudKit or admit a message before the final confirmation. Message text is not shown or logged.",
        confirmLabel: "Prepare One",
      );
      if (!firstConfirmed) return;

      armed = await pushService.armCloudSyncV2OutboundConfirmed(
        candidate: candidate,
        expectedRecipient: expectedRecipient,
      );
      await pushService.prepareCloudSyncV2OutboundWriter();

      final secondConfirmed = await _confirmCloudSyncV2Outbound(
        title: "Final confirmation: create one record?",
        message:
            "This may create exactly one message record for $expectedRecipient after a final in-run check of the newest local message and the current IDS sending handle. Deletes are disabled. If the outcome is unknown, do not retry; use recovery to reconcile the exact durable operation.",
        confirmLabel: "Create Once",
      );
      if (!secondConfirmed) return;

      final report = await pushService.runCloudSyncV2OutboundDoubleConfirmed(
        armed,
      );
      final presentation = cloudSyncV2OutboundCanaryPresentation(report);
      showSnackbar(presentation.title, presentation.message);

      if (presentation.outcome !=
          CloudSyncV2OutboundCanaryOutcome.writeConfirmed) {
        return;
      }

      final replayPresentation = await _runCloudSyncV2OutboundRecoveryFlow(
        prepareWriter: false,
        immediateReplay: true,
      );
      if (replayPresentation != null) {
        showSnackbar(replayPresentation.title, replayPresentation.message);
      }
    } catch (error) {
      if (_showCloudSyncV2Busy(error)) return;
      final safeCode = cloudSyncV2SafeFailureCode(error);
      Logger.warn(
        "Cloud Sync V2 outbound canary stopped safely code=$safeCode",
      );
      showSnackbar(
        "Cloud Sync V2 Writer Stopped Safely",
        "Diagnostic code: $safeCode. Do not retry automatically. No deletes were enabled.",
      );
    } finally {
      if (armed != null) {
        pushService.disarmCloudSyncV2Outbound(armed);
      }
      cloudSyncV2Running.value = false;
    }
  }

  Future<void> _recoverCloudSyncV2OutboundCanary() async {
    if (cloudSyncV2Running.value) return;
    if (!pushService.cloudSyncV2ManualOutboundAvailable) {
      showSnackbar(
        "Cloud Sync V2 Recovery Blocked",
        "Use the isolated Android Canary writer build, finish setup, enable Developer Mode, turn off legacy Messages in iCloud sync, and wait for active sync or logout work to finish.",
      );
      return;
    }

    cloudSyncV2Running.value = true;
    try {
      final presentation = await _runCloudSyncV2OutboundRecoveryFlow(
        prepareWriter: true,
        immediateReplay: false,
      );
      if (presentation != null) {
        showSnackbar(presentation.title, presentation.message);
      }
    } catch (error) {
      if (_showCloudSyncV2Busy(error)) return;
      final safeCode = cloudSyncV2SafeFailureCode(error);
      Logger.warn(
        "Cloud Sync V2 outbound recovery stopped safely code=$safeCode",
      );
      showSnackbar(
        "Cloud Sync V2 Recovery Stopped Safely",
        "Diagnostic code: $safeCode. Do not retry automatically and do not admit another message.",
      );
    } finally {
      cloudSyncV2Running.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isWebOrDesktop = kIsWeb || kIsDesktop;
    return SettingsScaffold(
        title: "Developer Tools",
        initialHeader: (isWebOrDesktop) ? "Contacts" : "Logging",
        iosSubtitle: iosSubtitle,
        materialSubtitle: materialSubtitle,
        tileColor: tileColor,
        headerColor: headerColor,
        bodySlivers: [
          SliverList(
            delegate: SliverChildListDelegate(
              <Widget>[
                if (isWebOrDesktop)
                  SettingsSection(
                    backgroundColor: tileColor,
                    children: [
                      SettingsTile(
                        onTap: () async {
                          final RxList<String> log = <String>[].obs;
                          showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                    backgroundColor:
                                        context.theme.colorScheme.surface,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 20),
                                    titlePadding:
                                        const EdgeInsets.only(top: 15),
                                    title: Text("Fetching contacts...",
                                        style:
                                            context.theme.textTheme.titleLarge),
                                    content: Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: SizedBox(
                                        width: ns.width(context) * 4 / 5,
                                        height: context.height * 1 / 3,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(25),
                                            color: context
                                                .theme.colorScheme.background,
                                          ),
                                          padding: const EdgeInsets.all(10),
                                          child: Obx(() => ListView.builder(
                                                physics:
                                                    const AlwaysScrollableScrollPhysics(
                                                        parent:
                                                            BouncingScrollPhysics()),
                                                itemBuilder: (context, index) {
                                                  return Text(
                                                    log[index],
                                                    style: TextStyle(
                                                      color: context
                                                          .theme
                                                          .colorScheme
                                                          .onBackground,
                                                      fontSize: 10,
                                                    ),
                                                  );
                                                },
                                                itemCount: log.length,
                                              )),
                                        ),
                                      ),
                                    ),
                                  ));
                          await cs.fetchNetworkContacts(logger: (newLog) {
                            log.add(newLog);
                          });
                        },
                        leading: const SettingsLeadingIcon(
                          iosIcon: CupertinoIcons.group,
                          materialIcon: Icons.contacts,
                        ),
                        title: "Fetch Contacts With Verbose Logging",
                        subtitle:
                            "This will fetch contacts from the server with extra info to help devs debug contacts issues",
                      ),
                    ],
                  ),
                if (isWebOrDesktop)
                  SettingsHeader(
                      iosSubtitle: iosSubtitle,
                      materialSubtitle: materialSubtitle,
                      text: "Logging"),
                SettingsSection(backgroundColor: tileColor, children: [
                  const LogLevelSelector(),
                  SettingsTile(
                    title: "View Latest Log",
                    subtitle: "View the latest log file. Useful for debugging issues, in app.",
                    leading: const SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.doc_append,
                      materialIcon: Icons.document_scanner_rounded,
                      containerColor: Colors.blueAccent,
                    ),
                    onTap: () {
                      ns.pushSettings(
                        context,
                        LoggingPanel(),
                      );
                    },
                    trailing: const NextButton(),
                  ),
                  if (Platform.isAndroid)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (Platform.isAndroid)
                    SettingsTile(
                        leading: const SettingsLeadingIcon(
                          iosIcon: CupertinoIcons.share_up,
                          materialIcon: Icons.share,
                          containerColor: Colors.green,
                        ),
                        title: "Download / Share Logs",
                        subtitle:
                            "${logFileCount.value} log file(s) | ${logFileSize.value} KB",
                        onTap: () async {
                          if (logFileCount.value == 0) {
                            showSnackbar("No Logs", "There are no logs to download!");
                            return;
                          }

                          if (isExportingLogs) return;
                          isExportingLogs = true;

                          try {
                            showSnackbar("Please Wait", "Compressing ${logFileCount.value} log file(s)...");
                            String filePath = Logger.compressLogs();
                            final File zippedLogFile = File(filePath);

                            // Copy the file to downloads
                            String newPath = await fs.saveToDownloads(zippedLogFile);

                            // Delete the original file
                            zippedLogFile.deleteSync();

                            // Let the user know what happened
                            showSnackbar(
                              "Logs Exported",
                              "Logs have been exported to your downloads folder. Tap here to share it.",
                              durationMs: 5000,
                              onTap: (snackbar) async {
                                Share.file("BlueBubbles Logs", newPath);
                              },
                            );
                          } catch (ex, stacktrace) {
                            Logger.error("Failed to export logs!", error: ex, trace: stacktrace);
                            showSnackbar("Failed to export logs!", "Error: ${ex.toString()}");
                          } finally {
                            isExportingLogs = false;
                          }
                        }),
                  if (kIsDesktop)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (kIsDesktop)
                    SettingsTile(
                        leading: const SettingsLeadingIcon(
                          iosIcon: CupertinoIcons.doc,
                          materialIcon: Icons.file_open,
                        ),
                        title: "Open Logs",
                        subtitle: Logger.logDir,
                        onTap: () async {
                          final File logFile = File(Logger.logDir);
                          if (logFile.existsSync()) {
                            logFile.createSync(recursive: true);
                          }
                          await launchUrl(Uri.file(logFile.path));
                        }),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  SettingsTile(
                      leading: const SettingsLeadingIcon(
                        iosIcon: CupertinoIcons.trash,
                        materialIcon: Icons.delete,
                        containerColor: Colors.redAccent,
                      ),
                      title: "Clear Logs",
                      subtitle: "Deletes all stored log files.",
                      onTap: () async {
                        Logger.clearLogs();
                        showSnackbar(
                            "Logs Cleared", "All logs have been deleted.");
                        logFileCount.value = 0;
                        logFileSize.value = 0;
                      }),
                  if (kIsDesktop) const SettingsDivider(),
                  if (kIsDesktop)
                    SettingsTile(
                      leading: const SettingsLeadingIcon(
                        iosIcon: CupertinoIcons.folder,
                        materialIcon: Icons.folder,
                      ),
                      title: "Open App Data Location",
                      subtitle: fs.appDocDir.path,
                      onTap: () async =>
                          await launchUrl(Uri.file(fs.appDocDir.path)),
                    ),
                ]),
                if (Platform.isAndroid)
                  SettingsHeader(
                      iosSubtitle: iosSubtitle,
                      materialSubtitle: materialSubtitle,
                      text: "Optimizations"),
                if (Platform.isAndroid)
                  SettingsSection(backgroundColor: tileColor, children: [
                    SettingsTile(
                        onTap: () async {
                          if (optimizationsDisabled.value) {
                            showSnackbar("Already Disabled",
                                "Battery optimizations are already disabled for BlueBubbles");
                            return;
                          }

                          final optsDisabled =
                              await disableBatteryOptimizations();
                          if (!optsDisabled) {
                            showSnackbar("Error",
                                "Battery optimizations were not disabled. Please try again.");
                          }
                        },
                        leading: Obx(() => SettingsLeadingIcon(
                          iosIcon: CupertinoIcons.battery_25,
                          materialIcon: Icons.battery_5_bar,
                          containerColor: optimizationsDisabled.value ? Colors.green : Colors.redAccent,
                        )),
                        title: "Disable Battery Optimizations",
                        subtitle: "Allow app to run in the background via the OS. This may not do anything on some devices.",
                        trailing: Obx(() => !optimizationsDisabled.value
                            ? const NextButton()
                            : Icon(Icons.check,
                                color: context.theme.colorScheme.outline))),
                  ]),

                if ((CloudSyncDevGate.manualShadowSamplerEnabled ||
                        CloudSyncDevGate.manualSemanticPullEnabled ||
                        CloudSyncDevGate.manualOutboundCanaryEnabled ||
                        CloudSyncDevGate.protocolEvidenceAvailable) &&
                    ss.settings.developerEnabled.value &&
                    (Platform.isAndroid || Platform.isWindows))
                  SettingsHeader(
                    iosSubtitle: iosSubtitle,
                    materialSubtitle: materialSubtitle,
                    text: "Cloud Sync V2",
                  ),
                if ((CloudSyncDevGate.manualShadowSamplerEnabled ||
                        CloudSyncDevGate.manualSemanticPullEnabled ||
                        CloudSyncDevGate.manualOutboundCanaryEnabled ||
                        CloudSyncDevGate.protocolEvidenceAvailable) &&
                    ss.settings.developerEnabled.value &&
                    (Platform.isAndroid || Platform.isWindows))
                  SettingsSection(
                    backgroundColor: tileColor,
                    children: [
                      if (CloudSyncDevGate.protocolEvidenceAvailable)
                        Obx(() => SettingsSwitch(
                          initialVal: ss.settings.cloudSyncV2EvidenceEnabled.value,
                          onChanged: (bool val) async {
                            ss.settings.cloudSyncV2EvidenceEnabled.value = val;
                            await ss.settings.saveOne('cloudSyncV2EvidenceEnabled');
                          },
                          title: "Record CloudKit protocol evidence",
                          subtitle: "Local-only, bounded structural diagnostics for the CloudKit canary. Never records message text, contacts, credentials, keys, raw records, or change tokens.",
                          isThreeLine: true,
                          backgroundColor: tileColor,
                        )),
                      if (CloudSyncDevGate.manualShadowSamplerEnabled)
                        Obx(() => SettingsTile(
                        leading: const SettingsLeadingIcon(
                          iosIcon: CupertinoIcons.cloud_download,
                          materialIcon: Icons.cloud_download_outlined,
                          containerColor: Colors.indigo,
                        ),
                        title: "Run Read-only Shadow Sample",
                        subtitle: "Developer-only diagnostic. Fetches one bounded page per Messages in iCloud zone without CloudKit writes, semantic applies, or background scheduling. A protected local journal, checkpoint, and redacted report are saved in private app storage.",
                        trailing: cloudSyncV2Running.value
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: context.theme.colorScheme.primary,
                                ),
                              )
                            : const NextButton(),
                        onTap: () async {
                          if (cloudSyncV2Running.value) return;
                          if (!pushService.cloudSyncV2ManualShadowAvailable) {
                            showSnackbar(
                              "Cloud Sync V2 Blocked",
                              "Finish OpenBubbles setup, enable Developer Mode on Android, turn off legacy Messages in iCloud sync, and wait for active sync or logout work to finish.",
                            );
                            return;
                          }
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (dialogContext) => AlertDialog(
                              backgroundColor: context.theme.colorScheme.properSurface,
                              title: Text(
                                "Run read-only Cloud Sync sample?",
                                style: context.theme.textTheme.titleLarge,
                              ),
                              content: Text(
                                "This performs one manual, bounded CloudKit read for diagnostics. It will not apply messages, upload or delete records, enable background sync, or replace live IDS delivery.",
                                style: context.theme.textTheme.bodyLarge,
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(dialogContext).pop(false),
                                  child: const Text("Cancel"),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(dialogContext).pop(true),
                                  child: const Text("Run Once"),
                                ),
                              ],
                            ),
                          );
                          if (confirmed != true) return;
                          if (cloudSyncV2Running.value) return;
                          cloudSyncV2Running.value = true;
                          try {
                            final report = await pushService.runCloudSyncV2ManualShadowConfirmed();
                            final fetched = report.zones.fold<int>(
                              0,
                              (total, zone) => total + zone.fetched,
                            );
                            final journaled = report.zones.fold<int>(
                              0,
                              (total, zone) => total + zone.journaled,
                            );
                            if (report.isValidReadOnlySuccess) {
                              showSnackbar(
                                "Cloud Sync V2 Complete",
                                "Read-only checks passed. Fetched $fetched and journaled $journaled protected change(s). A redacted report was saved in private app storage.",
                              );
                            } else {
                              showSnackbar(
                                "Cloud Sync V2 Stopped Safely",
                                "One or more zones did not pass the read-only checks. No CloudKit writes or semantic applies were enabled.",
                              );
                            }
                          } catch (error) {
                            if (_showCloudSyncV2Busy(error)) return;
                            final safeCode =
                                cloudSyncV2SafeFailureCode(error);
                            Logger.warn(
                              "Cloud Sync V2 shadow sample stopped safely code=$safeCode",
                            );
                            showSnackbar(
                              "Cloud Sync V2 Stopped Safely",
                              "Diagnostic code: $safeCode. No CloudKit writes or semantic applies were enabled.",
                            );
                          } finally {
                            cloudSyncV2Running.value = false;
                          }
                        },
                        )),
                      if (CloudSyncDevGate.manualSemanticPullEnabled)
                        Obx(() => SettingsTile(
                          leading: const SettingsLeadingIcon(
                            iosIcon: CupertinoIcons.lock_shield,
                            materialIcon: Icons.lock_open_outlined,
                            containerColor: Colors.indigo,
                          ),
                          title: "Prepare iCloud Encryption (Canary)",
                          subtitle: "Checks and, if needed, joins this app to your existing iCloud Keychain trust so Messages in iCloud can be decrypted. Never resets encrypted data or enables legacy sync.",
                          trailing: cloudSyncV2Running.value
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: context.theme.colorScheme.primary,
                                  ),
                                )
                              : const NextButton(),
                          onTap: _runCloudSyncV2PcsPreparation,
                        )),
                      if (CloudSyncDevGate.manualSemanticPullEnabled)
                        Obx(() => SettingsTile(
                          leading: const SettingsLeadingIcon(
                            iosIcon: CupertinoIcons.cloud_download,
                            materialIcon: Icons.cloud_sync,
                            containerColor: Colors.teal,
                          ),
                          title: "Catch Up Messages in iCloud (Canary)",
                          subtitle: "Choose a bounded, resumable history batch. Local canonical chats, messages, reactions, and attachment metadata may be added or updated. No CloudKit uploads or deletes, no local message deletes, and tombstones are retained as read-only acknowledgements.",
                          trailing: cloudSyncV2Running.value
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: context.theme.colorScheme.primary,
                                  ),
                                )
                              : const NextButton(),
                          onTap: () async {
                            if (cloudSyncV2Running.value) return;
                            if (!pushService.cloudSyncV2ManualSemanticPullAvailable) {
                              showSnackbar(
                                "Cloud Sync V2 Blocked",
                                "Finish OpenBubbles setup, enable Developer Mode, turn off legacy Messages in iCloud sync, and wait for active sync or logout work to finish.",
                              );
                              return;
                            }
                            final maximumPasses = await showDialog<int>(
                              context: context,
                              builder: (dialogContext) => SimpleDialog(
                                backgroundColor: context.theme.colorScheme.properSurface,
                                title: Text(
                                  "Choose catch-up size",
                                  style: context.theme.textTheme.titleLarge,
                                ),
                                children: [
                                  SimpleDialogOption(
                                    onPressed: () => Navigator.of(dialogContext).pop(1),
                                    child: const ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text("Small"),
                                      subtitle: Text("Up to 200 changes per CloudKit zone."),
                                    ),
                                  ),
                                  SimpleDialogOption(
                                    onPressed: () => Navigator.of(dialogContext).pop(4),
                                    child: const ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text("Standard"),
                                      subtitle: Text("Up to 800 changes per zone, then pause safely."),
                                    ),
                                  ),
                                  SimpleDialogOption(
                                    onPressed: () => Navigator.of(dialogContext).pop(16),
                                    child: const ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text("Deep catch-up"),
                                      subtitle: Text("Up to 3,200 changes per zone. This can take several minutes."),
                                    ),
                                  ),
                                ],
                              ),
                            );
                            if (maximumPasses == null) return;
                            final maximumChangesPerZone = maximumPasses * 200;
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                backgroundColor: context.theme.colorScheme.properSurface,
                                title: Text(
                                  "Run bounded CloudKit catch-up?",
                                  style: context.theme.textTheme.titleLarge,
                                ),
                                content: Text(
                                  "This reads up to $maximumChangesPerZone changes per CloudKit zone and pauses at a durable checkpoint. CloudKit change history is checkpoint-ordered rather than safely date-seekable, so each later run resumes without skipping earlier changes. Local canonical chats, messages, reactions, and attachment metadata may be added or updated. It will not upload or delete CloudKit records, delete local messages, or apply tombstones.",
                                  style: context.theme.textTheme.bodyLarge,
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(dialogContext).pop(false),
                                    child: const Text("Cancel"),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.of(dialogContext).pop(true),
                                    child: const Text("Run Once"),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed != true) return;
                            if (cloudSyncV2Running.value) return;
                            cloudSyncV2Running.value = true;
                            try {
                              final result = await pushService.runCloudSyncV2ManualSemanticPullConfirmed(
                                maximumPasses: maximumPasses,
                              );
                              var chatListRefreshMessage =
                                  "Chat list refreshed.";
                              try {
                                final repairedChatOrderRows =
                                    await repairCloudSyncChatLatestMessageDates();
                                Logger.info(
                                  "Cloud Sync V2 local chat ordering cache repaired rows=$repairedChatOrderRows",
                                );
                                // The ObjectBox count watcher intentionally ignores its
                                // first zero-to-nonzero transition and only adds one chat
                                // for a multi-chat transaction. A semantic pull can make
                                // exactly that transition, so refresh the presentation
                                // once after the durable pull has completed.
                                await chats.init(force: true);
                              } catch (error) {
                                final safeCode = cloudSyncV2SafeFailureCode(error);
                                Logger.warn(
                                  "Cloud Sync V2 local chat refresh failed code=$safeCode",
                                );
                                chatListRefreshMessage =
                                    "CloudKit catch-up completed, but the chat list could not refresh. Restart OpenBubbles to display any newly available history.";
                              }
                              final presentation =
                                  cloudSyncV2SemanticCanaryPresentation(result.lastReport);
                              final progress = result.reachedPassLimit
                                  ? "Paused safely after ${result.passes} pass(es). Run catch-up again to resume from the saved checkpoint."
                                  : result.remoteDrained
                                      ? "Remote CloudKit change history reached its current head after ${result.passes} pass(es)."
                                      : "Stopped safely after ${result.passes} pass(es).";
                              showSnackbar(
                                presentation.title,
                                "${presentation.message} $progress $chatListRefreshMessage",
                              );
                            } catch (error) {
                              if (_showCloudSyncV2Busy(error)) return;
                              final safeCode = cloudSyncV2SafeFailureCode(error);
                              Logger.warn(
                                "Cloud Sync V2 semantic pull stopped safely code=$safeCode",
                              );
                              showSnackbar(
                                "Cloud Sync V2 Stopped Safely",
                                "Diagnostic code: $safeCode. No CloudKit uploads or deletes were enabled.",
                              );
                            } finally {
                              cloudSyncV2Running.value = false;
                            }
                          },
                        )),
                      if (CloudSyncDevGate.manualOutboundCanaryEnabled &&
                          Platform.isAndroid)
                        Obx(
                          () => SettingsTile(
                            leading: const SettingsLeadingIcon(
                              iosIcon: CupertinoIcons.cloud_upload,
                              materialIcon: Icons.cloud_upload_outlined,
                              containerColor: Colors.deepOrange,
                            ),
                            title: "Upload One Existing Text Canary",
                            subtitle:
                                "Developer-only, two-confirmation, create-only CloudKit V2 writer. Selects only the newest fresh ordinary one-to-one iMessage text. Never falls back to an older row. No deletes or automatic retry.",
                            trailing: cloudSyncV2Running.value
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      color: context.theme.colorScheme.primary,
                                    ),
                                  )
                                : const NextButton(),
                            onTap: _runCloudSyncV2OutboundCanary,
                          ),
                        ),
                      if (CloudSyncDevGate.manualOutboundCanaryEnabled &&
                          Platform.isAndroid)
                        Obx(
                          () => SettingsTile(
                            leading: const SettingsLeadingIcon(
                              iosIcon: CupertinoIcons.refresh,
                              materialIcon: Icons.settings_backup_restore,
                              containerColor: Colors.amber,
                            ),
                            title: "Recover One Interrupted Upload",
                            subtitle:
                                "May complete only the one exact durable CloudKit create after interruption or an unknown outcome. It does not select or admit a new message. Never retry automatically.",
                            trailing: cloudSyncV2Running.value
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      color: context.theme.colorScheme.primary,
                                    ),
                                  )
                                : const NextButton(),
                            onTap: _recoverCloudSyncV2OutboundCanary,
                          ),
                        ),
                    ],
                  ),

                
                SettingsHeader(
                  iosSubtitle: iosSubtitle,
                  materialSubtitle: materialSubtitle,
                  text: "Troubleshooting"),
                SettingsSection(
                  backgroundColor: tileColor,
                  children: [
                    SettingsTile(
                      leading: const SettingsLeadingIcon(
                        iosIcon: CupertinoIcons.share,
                        materialIcon: Icons.share,
                      ),
                      title: "Export OB logs",
                      subtitle: "Last 24-48 hours saved. Contains sensitive information (such as messages and identifiers); do not share publicly.",
                      onTap: () async {
                        var file = Directory(Platform.isAndroid ? "${fs.appDocDir.path}/../files/logs" : "${fs.appDocDir.path}/logs");
                        final List<FileSystemEntity> entities = await file.list().toList();
                        var current = entities.indexWhere((element) => element.path.endsWith("CURRENT.log"));
                        var item = entities.removeAt(current);
                        var end = await File(item.path).readAsBytes();
                        var b = BytesBuilder();
                        if (entities.isNotEmpty) {
                          var next = await File(entities.first.path).readAsBytes();
                          b.add(next);
                        }
                        b.add(end);
                        var total = b.toBytes();
                        // Copy the file to downloads

                        final date = DateTime.now().toIso8601String().split('T').first;
                        final File logFile =
                            File("${fs.appDocDir.path}/openbubbles-logs-$date.log");
                        if (logFile.existsSync()) logFile.deleteSync();

                        await logFile.writeAsBytes(total);

                        String newPath = await fs.saveToDownloads(logFile);

                        // Delete the original file
                        logFile.deleteSync();

                        // Let the user know what happened
                        showSnackbar(
                          "Logs Exported",
                          "Logs have been exported to your downloads folder. Tap here to share it.",
                          durationMs: 5000,
                          onTap: (snackbar) async {
                            Share.file("OpenBubbles Logs", newPath);
                          },
                        );
                        // Logger.writeLogToFile(total);
                      },
                    ),
                    SettingsTile(
                        onTap: () async {
                          await ss.prefs.remove("lastOpenedChat");
                          showSnackbar("Success", "Successfully cleared the last opened chat!");
                        },
                        leading: const SettingsLeadingIcon(
                          iosIcon: CupertinoIcons.rectangle_badge_xmark,
                          materialIcon: Icons.folder_delete_outlined,
                          containerColor: Colors.orange,
                        ),
                        title: "Clear Last Opened Chat",
                        subtitle: "Use this if you are experiencing the app opening an incorrect chat"
                    )
                  ]),
                if (!kIsWeb && backend.getRemoteService() != null)
                  SettingsHeader(
                      iosSubtitle: iosSubtitle,
                      materialSubtitle: materialSubtitle,
                      text: "Database Re-syncing"),
                if (!kIsWeb && backend.getRemoteService() != null)
                  SettingsSection(backgroundColor: tileColor, children: [
                    SettingsTile(
                        title: "Sync Handles & Contacts",
                        subtitle:
                            "Run this troubleshooter if you are experiencing issues with missing or incorrect contact names and photos",
                        onTap: () async {
                          resyncingHandles.value = true;
                          try {
                            final handleSyncer = HandleSyncManager();
                            await handleSyncer.start();
                            eventDispatcher.emit("refresh-all", null);

                            showSnackbar("Success",
                                "Successfully re-synced handles! You may need to close and re-open the app for changes to take effect.");
                          } catch (ex, stacktrace) {
                            Logger.error("Failed to reset contacts!", error: ex, trace: stacktrace);

                            showSnackbar("Failed to re-sync handles!",
                                "Error: ${ex.toString()}");
                          } finally {
                            resyncingHandles.value = false;
                          }
                        },
                        trailing: Obx(() => resyncingHandles.value == null
                            ? const SizedBox.shrink()
                            : resyncingHandles.value == true
                                ? Container(
                                    constraints: const BoxConstraints(
                                      maxHeight: 20,
                                      maxWidth: 20,
                                    ),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          context.theme.colorScheme.primary),
                                    ))
                                : Icon(Icons.check,
                                    color: context.theme.colorScheme.outline))),
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                    SettingsTile(
                        title: "Sync Chat Info",
                        subtitle: "This will re-sync all chat data & icons from the server to ensure that you have the most up-to-date information.\n\nNote: This will overwrite any group chat icons that are not locked!",
                        onTap: () async {
                          resyncingChats.value = true;
                          try {
                            showSnackbar("Please Wait...", "This may take a few minutes.");

                            final chatSyncer = ChatSyncManager();
                            await chatSyncer.start();
                            eventDispatcher.emit("refresh-all", null);

                            showSnackbar("Success",
                                "Successfully synced your chat info! You may need to close and re-open the app for changes to take effect.");
                          } catch (ex, stacktrace) {
                            Logger.error("Failed to sync chat info!", error: ex, trace: stacktrace);
                            showSnackbar("Failed to sync chat info!",
                                "Error: ${ex.toString()}");
                          } finally {
                            resyncingChats.value = false;
                          }
                        },
                        trailing: Obx(() => resyncingChats.value == null
                            ? const SizedBox.shrink()
                            : resyncingChats.value == true
                                ? Container(
                                    constraints: const BoxConstraints(
                                      maxHeight: 20,
                                      maxWidth: 20,
                                    ),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          context.theme.colorScheme.primary),
                                    ))
                                : Icon(Icons.check,
                                    color: context.theme.colorScheme.outline)))
                  ]),
              if (usingRustPush)
                SettingsHeader(
                  iosSubtitle: iosSubtitle,
                  materialSubtitle: materialSubtitle,
                  text: "iMessage"
                ),
              if (usingRustPush)
                SettingsSection(
                  backgroundColor: tileColor,
                  children: [
                    SettingsTile(
                      title: "Clear identity cache",
                      subtitle: "Run this troubleshooter if you're having trouble sending messages.",
                      onTap: () async {
                        await api.invalidateIdCache(client: pushService.state!.client);
                        showSnackbar("Success", "Identity cache cleared! Try re-sending any messages.");
                      }),
                    SettingsTile(
                      title: "Clear peer caches",
                      subtitle: "Run this troubleshooter if you are told to do so.",
                      onTap: () async {
                        if (reregisteringIds.value ?? false) return;
                        try {
                          reregisteringIds.value = true;
                          await pushService.invalidatePeerCaches();
                          showSnackbar("Success", "Cleared peer caches");
                        } catch (e) {
                          showSnackbar("Failure", e.toString());
                          rethrow;
                        } finally {
                          reregisteringIds.value = false;
                        }
                      },
                      trailing: Obx(() => reregisteringIds.value == null
                          ? const SizedBox.shrink()
                          : reregisteringIds.value == true ? Container(
                          constraints: const BoxConstraints(
                            maxHeight: 20,
                            maxWidth: 20,
                          ),
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                          )) : Icon(Icons.check, color: context.theme.colorScheme.outline))
                      ),
                    SettingsTile(
                      title: "Reregister",
                      subtitle: "Run this troubleshooter if you are told to do so.",
                      onTap: () async {
                        if (reregisteringIds.value ?? false) return;
                        try {
                          reregisteringIds.value = true;
                          await api.doReregister(state: pushService.state!.client);
                          showSnackbar("Success", "Registered");
                        } catch (e) {
                          showSnackbar("Failure", e.toString());
                          rethrow;
                        } finally {
                          reregisteringIds.value = false;
                        }
                      },
                      trailing: Obx(() => reregisteringIds.value == null
                          ? const SizedBox.shrink()
                          : reregisteringIds.value == true ? Container(
                          constraints: const BoxConstraints(
                            maxHeight: 20,
                            maxWidth: 20,
                          ),
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                          )) : Icon(Icons.check, color: context.theme.colorScheme.outline))
                      ),
                    SettingsTile(
                      title: "Clear FaceTime Handles",
                      subtitle: "Run this troubleshooter if you cannot use FaceTime. This will delete all links asscoiated with your account.",
                      onTap: () async {
                        if (reregisteringIds.value ?? false) return;
                        try {
                          reregisteringIds.value = true;
                          await api.clearLinks(facetime: pushService.state!.ftClient);
                          showSnackbar("Success", "Cleared Links!");
                        } catch (e) {
                          showSnackbar("Failure", e.toString());
                          rethrow;
                        } finally {
                          reregisteringIds.value = false;
                        }
                      },
                      trailing: Obx(() => reregisteringIds.value == null
                          ? const SizedBox.shrink()
                          : reregisteringIds.value == true ? Container(
                          constraints: const BoxConstraints(
                            maxHeight: 20,
                            maxWidth: 20,
                          ),
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                          )) : Icon(Icons.check, color: context.theme.colorScheme.outline))
                      )
                  ]),
                if (usingRustPush && Platform.isAndroid)
                  Obx(() => ss.settings.developerEnabled.value
                      ? SettingsHeader(
                          iosSubtitle: iosSubtitle,
                          materialSubtitle: materialSubtitle,
                          text: "FaceTime Diagnostics",
                        )
                      : const SizedBox.shrink()),
                if (usingRustPush && Platform.isAndroid)
                  Obx(() => ss.settings.developerEnabled.value
                      ? SettingsSection(
                          backgroundColor: tileColor,
                          children: [
                            SettingsSwitch(
                              initialVal: ss.settings.faceTimeDiagnosticsEnabled.value,
                              onChanged: (bool val) async {
                                ss.settings.faceTimeDiagnosticsEnabled.value = val;
                                await ss.settings.saveOne('faceTimeDiagnosticsEnabled');
                              },
                              title: "Enable FaceTime diagnostics",
                              subtitle: "Logs FaceTime WebView, join, permission, and media state for debugging. Join recovery and End Call remain enabled when this is off.",
                              isThreeLine: true,
                              backgroundColor: tileColor,
                            ),
                          ],
                        )
                      : const SizedBox.shrink()),
                if(!kIsDesktop)
                SettingsHeader(
                  iosSubtitle: iosSubtitle,
                  materialSubtitle: materialSubtitle,
                  text: "Extensions"
                ),
                if(!kIsDesktop)
                SettingsSection(
                  backgroundColor: tileColor,
                  children: [
                    Obx(() => SettingsSwitch(
                      onChanged: (bool val) async {
                        if (val) {
                          showDialog(
                            context: context,
                            builder: (BuildContext context) {
                              return AlertDialog(
                                  backgroundColor: context.theme.colorScheme.properSurface,
                                  title: Text("Enable development mode?", style: context.theme.textTheme.titleLarge),
                                  content: Text(
                                    'This mode is intended for developer use only. Extensions added through this mode have not been reviewed or approved by neither OpenBubbles or Google. You are responsible for ensuring the safety of your data and any extensions you add.',
                                    style: context.theme.textTheme.bodyLarge,
                                  ),
                                  actions: <Widget>[
                                    TextButton(
                                      child: Text("Cancel",
                                          style: context.theme.textTheme.bodyLarge!
                                              .copyWith(color: context.theme.colorScheme.primary)),
                                      onPressed: () {
                                        Navigator.of(context).pop();
                                      },
                                    ),
                                    TextButton(
                                      child: Text("Enable",
                                          style: context.theme.textTheme.bodyLarge!
                                              .copyWith(color: context.theme.colorScheme.primary)),
                                      onPressed: () async {
                                        Navigator.of(context).pop();
                                        ss.settings.developerEnabled.value = true;
                                        ss.settings.save();
                                        if (mounted) setState(() {});
                                      },
                                    ),
                                  ]);
                            },
                          );
                          return;
                        }
                        ss.settings.developerEnabled.value = val;
                        if (!val) {
                          ss.settings.faceTimeDiagnosticsEnabled.value = false;
                          ss.settings.cloudSyncV2EvidenceEnabled.value = false;
                          await ss.settings.saveMany([
                            'developerEnabled',
                            'faceTimeDiagnosticsEnabled',
                            'cloudSyncV2EvidenceEnabled',
                          ]);
                        } else {
                          await ss.settings.saveOne('developerEnabled');
                        }
                        if (mounted) setState(() {});
                        showSnackbar("Success", "Restart device or force quit OpenBubbles to unload extensions");
                      },
                      initialVal: ss.settings.developerEnabled.value,
                      title: "Enable Developer Mode",
                      backgroundColor: tileColor,
                    )),
                  ],
                ),
                if (kIsDesktop) const SizedBox(height: 100),
              ],
            ),
          ),
          if(!kIsDesktop)
          Obx(() => SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final addMember = ListTile(
                mouseCursor: MouseCursor.defer,
                title: Text("Add Service Name", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                leading: Container(
                  width: 40 * ss.settings.avatarScale.value,
                  height: 40 * ss.settings.avatarScale.value,
                  decoration: BoxDecoration(
                    color: !iOS ? null : context.theme.colorScheme.properSurface,
                    shape: BoxShape.circle,
                    border: iOS ? null : Border.all(color: context.theme.colorScheme.primary, width: 3)
                  ),
                  child: Icon(
                    Icons.add,
                    color: context.theme.colorScheme.primary,
                    size: 20
                  ),
                ),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (_) {
                      return AlertDialog(
                        actions: [
                          TextButton(
                            child: Text("Cancel", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                            onPressed: () => Get.back(),
                          ),
                          TextButton(
                            child: Text("OK", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                            onPressed: () async {
                              ss.settings.developerMode.add(participantController.text);
                              ss.saveSettings();
                              await es.refreshCache();
                              Get.back();
                            },
                          ),
                        ],
                        content: TextField(
                          controller: participantController,
                          decoration: const InputDecoration(
                            labelText: "Service Name",
                            border: OutlineInputBorder(),
                          ),
                          autofillHints: [AutofillHints.telephoneNumber, AutofillHints.email],
                        ),
                        title: Text("Add", style: context.theme.textTheme.titleLarge),
                        backgroundColor: context.theme.colorScheme.properSurface,
                      );
                    }
                  );
                },
              );

              final refreshCache = ListTile(
                mouseCursor: MouseCursor.defer,
                title: Text("Reload extensions", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                leading: Container(
                  width: 40 * ss.settings.avatarScale.value,
                  height: 40 * ss.settings.avatarScale.value,
                  decoration: BoxDecoration(
                    color: !iOS ? null : context.theme.colorScheme.properSurface,
                    shape: BoxShape.circle,
                    border: iOS ? null : Border.all(color: context.theme.colorScheme.primary, width: 3)
                  ),
                  child: Icon(
                    Icons.refresh,
                    color: context.theme.colorScheme.primary,
                    size: 20
                  ),
                ),
                onTap: () async {
                  await es.refreshCache();
                  showSnackbar("Success", "Extensions reloaded!");
                },
              );

              final clear = ListTile(
                mouseCursor: MouseCursor.defer,
                title: Text("Clear services", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.error)),
                leading: Container(
                  width: 40 * ss.settings.avatarScale.value,
                  height: 40 * ss.settings.avatarScale.value,
                  decoration: BoxDecoration(
                    color: !iOS ? null : context.theme.colorScheme.properSurface,
                    shape: BoxShape.circle,
                    border: iOS ? null : Border.all(color: context.theme.colorScheme.primary, width: 3)
                  ),
                  child: Icon(
                    Icons.clear_all,
                    color: context.theme.colorScheme.error,
                    size: 20
                  ),
                ),
                onTap: () async {
                  ss.settings.developerMode.clear();
                  ss.saveSettings();
                  showSnackbar("Success", "Restart device or force quit OpenBubbles to unload extensions");
                },
              );

              if (index == ss.settings.developerMode.length) {
                return addMember;
              }
              if (index == ss.settings.developerMode.length + 1) {
                return refreshCache;
              }
              if (index == ss.settings.developerMode.length + 2) {
                return clear;
              }

              return ListTile(
                mouseCursor: MouseCursor.defer,
                title: Text(ss.settings.developerMode[index]),
              );
            }, childCount: ss.settings.developerEnabled.value ? ss.settings.developerMode.length + 3 : 0),
          ),)
        ]);
  }
}
