import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;
import 'package:path/path.dart' as path;

import 'cloud_sync_v2_windows_historical_source.dart';
import 'services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'services/rustpush/cloud_sync/cloud_sync_historical_import_controller.dart';
import 'services/rustpush/cloud_sync/cloud_sync_historical_import_source.dart';
import 'services/rustpush/cloud_sync/cloud_sync_historical_received_trial.dart';
import 'services/rustpush/cloud_sync/cloud_sync_historical_import_runtime.dart';

/// Private operator request for one finite import, never an IDS send request.
/// A preview grants no consent. Archival requires the exact previewed snapshot,
/// explicit destination binding and a fresh manual invocation of the writer host.
final class CloudSyncWindowsHistoricalRequest {
  CloudSyncWindowsHistoricalRequest._(Map<String, dynamic> value)
    : sourceDirectory = value['sourceDirectory'] as String,
      databaseSha256 = value['databaseSha256'] as String,
      sourceLabel = value['sourceLabel'] as String,
      accountLabel = value['accountLabel'] as String,
      account = CloudSyncHistoricalAccountBinding(
        accountFingerprint: value['accountFingerprint'] as String,
        protectedStoreIdentity: value['protectedStoreIdentity'] as String,
      ),
      accountHandles = List<String>.unmodifiable(
        value['accountHandles'] as List,
      ),
      capturedAtMs = value['capturedAtMs'] as int,
      execute = value['action'] == 'archive',
      receivedEndpointTrialGuid = value['receivedEndpointTrialGuid'] as String?,
      snapshotSha256 = value['snapshotSha256'] as String?,
      maximumAssessed = value['maximumAssessed'] as int,
      maximumCreates = value['maximumCreates'] as int;

  static const fileName = 'windows-historical-import-request.json';
  static const _invalid = 'cloud_sync_windows_historical_request_invalid';
  static final _hex = RegExp(r'^[a-f0-9]{64}$');
  static final _fingerprint = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _store = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
  static const _keys = {
    'version',
    'action',
    'sourceDirectory',
    'databaseSha256',
    'sourceLabel',
    'accountLabel',
    'accountFingerprint',
    'protectedStoreIdentity',
    'accountHandles',
    'capturedAtMs',
    'snapshotSha256',
    'maximumAssessed',
    'maximumCreates',
    'receivedEndpointTrialGuid',
  };

  final String sourceDirectory;
  final String databaseSha256;
  final String sourceLabel;
  final String accountLabel;
  final CloudSyncHistoricalAccountBinding account;
  final List<String> accountHandles;
  final int capturedAtMs;
  final bool execute;
  final String? receivedEndpointTrialGuid;
  final String? snapshotSha256;
  final int maximumAssessed;
  final int maximumCreates;

  static bool _text(Object? value, int maximum) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.length <= maximum &&
      !value.contains(RegExp(r'[\r\n\x00]'));

  static CloudSyncWindowsHistoricalRequest parse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.keys.toSet().difference(_keys).isNotEmpty ||
        value['version'] != 1 ||
        !{'preview', 'archive'}.contains(value['action']) ||
        !_text(value['sourceDirectory'], 4096) ||
        !path.isAbsolute(value['sourceDirectory'] as String) ||
        !_text(value['databaseSha256'], 64) ||
        !_hex.hasMatch(value['databaseSha256'] as String) ||
        !_text(value['sourceLabel'], 120) ||
        !_text(value['accountLabel'], 512) ||
        value['accountFingerprint'] is! String ||
        !_fingerprint.hasMatch(value['accountFingerprint'] as String) ||
        value['protectedStoreIdentity'] is! String ||
        !_store.hasMatch(value['protectedStoreIdentity'] as String) ||
        value['capturedAtMs'] is! int ||
        (value['capturedAtMs'] as int) <= 0 ||
        (value['capturedAtMs'] as int) > 8640000000000000 ||
        value['accountHandles'] is! List ||
        (value['accountHandles'] as List).isEmpty ||
        (value['accountHandles'] as List).length > 64 ||
        !(value['accountHandles'] as List).every(
          (v) =>
              _text(v, 1024) &&
              (v as String).trim() == v &&
              !v.startsWith('mailto:') &&
              !v.startsWith('tel:'),
        ) ||
        (value['accountHandles'] as List).toSet().length !=
            (value['accountHandles'] as List).length ||
        value['maximumAssessed'] is! int ||
        (value['maximumAssessed'] as int) < 1 ||
        (value['maximumAssessed'] as int) > 200 ||
        value['maximumCreates'] is! int ||
        (value['maximumCreates'] as int) < 1 ||
        (value['maximumCreates'] as int) > 20 ||
        (value['receivedEndpointTrialGuid'] != null &&
            (!_text(value['receivedEndpointTrialGuid'], 512) ||
                (value['receivedEndpointTrialGuid'] as String).trim() !=
                    value['receivedEndpointTrialGuid'] ||
                value['maximumCreates'] != 1 ||
                value['maximumAssessed'] != 1)) ||
        (value['action'] == 'archive'
            ? value['snapshotSha256'] is! String ||
                  !_hex.hasMatch(value['snapshotSha256'] as String)
            : value['snapshotSha256'] != null)) {
      throw StateError(_invalid);
    }
    return CloudSyncWindowsHistoricalRequest._(value);
  }

  static Future<CloudSyncWindowsHistoricalRequest> read(
    Directory profile,
  ) async {
    try {
      final file = File(path.join(profile.path, fileName));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError(_invalid);
      }
      final bytes = await file
          .openRead(0, 16385)
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      if (bytes.isEmpty || bytes.length > 16384) throw StateError(_invalid);
      return parse(jsonDecode(utf8.decode(bytes)));
    } catch (_) {
      throw StateError(_invalid);
    }
  }

  @override
  String toString() => 'CloudSyncWindowsHistoricalRequest(redacted)';
}

/// The same controller used by Profile, with a small explicit Windows test
/// budget. Budgets stop admission, not an in-flight save or its readback.
Future<Map<String, Object?>> runCloudSyncWindowsHistoricalPlan({
  required CloudSyncWindowsHistoricalRequest request,
  required Future<CloudSyncHistoricalImportPlan> Function() prepare,
}) async {
  // A small create/assessment budget can end midway through a normal page.
  // Checkpoint every settled row here, or repeated bounded invocations could
  // re-confirm the first row forever without advancing the durable cursor.
  final controller = CloudSyncHistoricalImportController(pageSize: 1);
  var budgetPause = false;
  void onProgress() {
    if (!budgetPause &&
        controller.phase == CloudSyncHistoricalImportPhase.running &&
        (controller.assessed >= request.maximumAssessed ||
            controller.confirmedCreates >= request.maximumCreates)) {
      budgetPause = true;
      controller.pause();
    }
  }

  controller.addListener(onProgress);
  try {
    late CloudSyncHistoricalImportPlan plan;
    final confirmation = await controller.prepare(() async {
      plan = await prepare();
      final snapshot = plan.snapshot;
      if (request.receivedEndpointTrialGuid case final guid?) {
        final trial = await CloudSyncHistoricalReceivedEndpointTrial.select(
          source: CloudSyncHistoricalImportSource(
            snapshot: snapshot,
            label: plan.sourceLabel,
          ),
          guid: guid,
        );
        trial.requireSource(
          CloudSyncHistoricalImportSource(
            snapshot: snapshot,
            label: plan.sourceLabel,
          ),
        );
      }
      final handles = List<String>.of(request.accountHandles)..sort();
      if (snapshot.account.accountFingerprint !=
              request.account.accountFingerprint ||
          snapshot.account.protectedStoreIdentity !=
              request.account.protectedStoreIdentity ||
          snapshot.manifest.capturedAtMs != request.capturedAtMs ||
          jsonEncode(snapshot.manifest.accountHandles) != jsonEncode(handles) ||
          plan.sourceLabel != request.sourceLabel ||
          plan.accountLabel != request.accountLabel ||
          (request.execute &&
              snapshot.manifest.snapshotSha256 != request.snapshotSha256)) {
        throw StateError('cloud_sync_historical_import_source_changed');
      }
      return plan;
    });
    final snapshot = plan.snapshot;
    if (request.execute) {
      await controller.confirm(confirmation);
    } else {
      controller.cancel(confirmation);
    }
    return {
      'action': request.execute ? 'archive' : 'preview',
      'snapshot_sha256': snapshot.manifest.snapshotSha256,
      'source_rows': snapshot.manifest.messageCount,
      'captured_at_ms': snapshot.manifest.capturedAtMs,
      'phase': controller.phase.name,
      'budget_paused': budgetPause,
      'scan_complete': controller.scanComplete,
      'assessed_this_session': controller.assessed,
      'confirmed_creates_this_session': controller.confirmedCreates,
      'reader_handoffs_this_session': controller.readerHandoffs,
      'deferred_metadata_this_session': controller.deferredMissingMetadata,
      'deferred_missing_attachments_this_session':
          controller.deferredMissingAttachments,
      'retained_conflicts_this_session': controller.retainedConflicts,
      'skipped_owned_this_session': controller.skippedOwned,
      'ineligible_this_session': controller.ineligibleByReason,
    };
  } finally {
    controller.removeListener(onProgress);
    await controller.drain();
    controller.dispose();
  }
}

/// CloudKit-only host composition: no IDS client, fresh send, automatic upload,
/// writer takeover, legacy reset or credential replacement is performed here.
Future<Map<String, Object?>> runCloudSyncWindowsHistoricalImport({
  required Directory profile,
  required Store store,
  required rustlib.ArcCloudMessagesClientDefaultAnisetteProvider client,
  required bool Function() stillCurrent,
  required Future<void> Function() settleReader,
}) async {
  if (!CloudSyncDevGate.manualOutboundCanaryEnabled ||
      const String.fromEnvironment('OPENBUBBLES_CLOUDKIT_WRITER_OWNER') !=
          'v2') {
    throw StateError('cloud_sync_windows_historical_disabled');
  }
  final request = await CloudSyncWindowsHistoricalRequest.read(profile);
  final auth = await api.cloudSyncCaptureAuthSnapshot(
    cloudMessagesClient: client,
    storageDirectory: profile.path,
  );
  Future<void> validate() async {
    if (!stillCurrent() || store.isClosed()) {
      throw StateError('cloud_sync_historical_import_identity_changed');
    }
    final current = await api.cloudSyncCaptureAuthSnapshot(
      cloudMessagesClient: client,
      storageDirectory: profile.path,
    );
    if (!stillCurrent() ||
        store.isClosed() ||
        current.nativeSessionId != auth.nativeSessionId ||
        current.accountFingerprint != request.account.accountFingerprint ||
        current.protectedStoreIdentity !=
            request.account.protectedStoreIdentity ||
        current.accountFingerprint != auth.accountFingerprint ||
        current.protectedStoreIdentity != auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_historical_import_identity_changed');
    }
  }

  await validate();
  final scratch = Directory(
    path.join(profile.path, 'historical-capture-scratch'),
  );
  if (await FileSystemEntity.type(scratch.path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    await scratch.create();
  }
  final source = await captureCloudSyncWindowsHistoricalSource(
    sourceDirectory: Directory(request.sourceDirectory),
    scratchRoot: scratch,
    expectedDatabaseSha256: request.databaseSha256,
    account: request.account,
    accountHandles: request.accountHandles,
    label: request.sourceLabel,
    capturedAtMs: request.capturedAtMs,
    validateIdentity: validate,
    stillCurrent: stillCurrent,
  );
  await validate();
  final trial = request.receivedEndpointTrialGuid == null
      ? null
      : await CloudSyncHistoricalReceivedEndpointTrial.select(
          source: source,
          guid: request.receivedEndpointTrialGuid!,
        );
  await validate();
  return runCloudSyncWindowsHistoricalPlan(
    request: request,
    prepare: () => prepareCloudSyncHistoricalImportPlanForClient(
      client: client,
      store: store,
      storageDirectory: profile.path,
      accountLabel: request.accountLabel,
      source: trial?.source ?? source,
      receivedEndpointTrial: trial,
      stillCurrent: stillCurrent,
      settleReader: settleReader,
    ),
  );
}
