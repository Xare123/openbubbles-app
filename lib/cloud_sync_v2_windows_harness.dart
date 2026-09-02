import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_download_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_production_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_presentation_repair.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_preflight.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector_health.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_drain_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report_file.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) {
    throw StateError('cloud_sync_windows_dev_profile_windows_required');
  }
  if (!CloudSyncDevGate.manualSemanticPullEnabled) {
    throw StateError('cloud_sync_semantic_pull_disabled');
  }
  final launch = CloudSyncV2WindowsHarnessLaunch.parse(arguments);
  _harnessLaunchId = launch.launchId;
  final operation = launch.operation;

  fs.configureCloudSyncV2WindowsDevProfile();
  if (operation == CloudSyncV2WindowsHarnessOperation.attachmentProbe &&
      !cloudSyncV2WindowsAttachmentProbeProfileIsMarked(fs.appDocDir)) {
    throw StateError('cloud_attachment_probe_disposable_profile_required');
  }
  var stage = 'profile-configured';
  await _writeHarnessStatus(state: 'initializing', stage: stage);
  try {
    await RustLib.init();
    stage = 'rust-ready';
    await _writeHarnessStatus(state: 'initializing', stage: stage);
    await fs.init(headless: true);
    stage = 'filesystem-ready';
    await _writeHarnessStatus(state: 'initializing', stage: stage);
    await Logger.init();
    stage = 'logger-ready';
    await _writeHarnessStatus(state: 'initializing', stage: stage);
    api.doFirstTimeInit(path: fs.appDocDir.path);
    stage = 'protected-keystore-ready';
    await _writeHarnessStatus(state: 'initializing', stage: stage);
    await Database.init(cloudSyncV2Harness: true);
    stage = 'database-ready';
    await _writeHarnessStatus(state: 'initializing', stage: stage);

    runApp(CloudSyncV2WindowsHarness(operation: operation));
    doWhenWindowReady(() {
      appWindow.minSize = const Size(640, 480);
      appWindow.title = 'Cloud Sync V2 Windows Harness';
      appWindow.show();
    });
    await _writeHarnessStatus(state: 'running', stage: 'ui-started');
  } catch (error, stackTrace) {
    await _writeHarnessStatus(
      state: 'failed',
      stage: stage,
      safeCode: cloudSyncV2SafeFailureCode(error),
      errorType: error.runtimeType.toString(),
      detail: _sanitizeHarnessDetail(error.toString()),
      stack: _sanitizeHarnessDetail(stackTrace.toString(), maxLength: 4000),
    );
    rethrow;
  }
}

enum CloudSyncV2WindowsHarnessOperation {
  interactive,
  runOnce,
  drain,
  attachmentProbe,
  projectionViewer,
  projectionDetailViewer;

  static CloudSyncV2WindowsHarnessOperation parse(List<String> arguments) {
    return CloudSyncV2WindowsHarnessLaunch.parse(arguments).operation;
  }
}

enum CloudSyncV2WindowsReadAuthAction {
  activate,
  requestSmsTwoFactor,
  resumePendingSmsTwoFactor,
  reject,
}

CloudSyncV2WindowsReadAuthAction cloudSyncV2WindowsHarnessReadAuthAction(
  api.LoginState state,
) {
  if (state is api.LoginState_LoggedIn) {
    return CloudSyncV2WindowsReadAuthAction.activate;
  }
  if (state is api.LoginState_NeedsSMS2FA ||
      state is api.LoginState_NeedsDevice2FA) {
    return CloudSyncV2WindowsReadAuthAction.requestSmsTwoFactor;
  }
  if (state is api.LoginState_NeedsSMS2FAVerification) {
    return CloudSyncV2WindowsReadAuthAction.resumePendingSmsTwoFactor;
  }
  return CloudSyncV2WindowsReadAuthAction.reject;
}

bool cloudSyncV2WindowsHarnessShouldStartFreshReadAuthentication({
  required String safeCode,
  required bool alreadyAttempted,
}) =>
    safeCode == 'cloud_sync_native_auth_refresh_session_missing' &&
    !alreadyAttempted;

String cloudSyncV2WindowsProjectionChatTitle({
  required String? displayName,
  required String? chatIdentifier,
}) {
  final name = displayName?.trim();
  if (name != null && name.isNotEmpty) return name;
  final identifier = chatIdentifier?.trim();
  if (identifier != null && identifier.isNotEmpty) return identifier;
  return 'Unnamed conversation';
}

String cloudSyncV2WindowsProjectionBody({
  required String? text,
  required String? attributedText,
  required String? subject,
  required bool hasAttachments,
  required bool isAssociated,
  required bool isEvent,
}) {
  for (final candidate in <String?>[text, attributedText, subject]) {
    final normalized = candidate?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized != null && normalized.isNotEmpty) return normalized;
  }
  if (hasAttachments) return '[Attachment]';
  if (isAssociated) return '[Reaction or associated message]';
  if (isEvent) return '[Conversation event]';
  return '[No renderable content]';
}

String _cloudSyncV2WindowsAttributedText(Message message) => message
    .attributedBody
    .map((part) => part.string.trim())
    .where((part) => part.isNotEmpty)
    .join(' ');

bool _cloudSyncV2WindowsIsEvent(Message message) =>
    (message.itemType ?? 0) != 0;

String _cloudSyncV2WindowsTimestamp(DateTime? value) {
  if (value == null) return 'Unknown time';
  final local = value.toLocal();
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

const String cloudSyncV2WindowsAttachmentProbeMarkerFileName =
    '.openbubbles-cloud-sync-v2-attachment-probe-copy';
const String cloudSyncV2WindowsAttachmentProbeMarkerContents =
    'openbubbles-cloud-sync-v2-attachment-probe-copy:v1';
const int cloudSyncV2WindowsAttachmentProbeMaximumBytes = 8 * 1024 * 1024;

bool cloudSyncV2WindowsAttachmentProbeProfileIsMarked(Directory directory) {
  try {
    final marker = File(
      path.join(
        directory.path,
        cloudSyncV2WindowsAttachmentProbeMarkerFileName,
      ),
    );
    return marker.existsSync() &&
        marker.readAsStringSync() ==
            cloudSyncV2WindowsAttachmentProbeMarkerContents;
  } catch (_) {
    return false;
  }
}

@visibleForTesting
Attachment? cloudSyncV2WindowsSelectAttachmentProbeCandidate(
  Iterable<Attachment> attachments, {
  int maximumExpectedBytes = cloudSyncV2WindowsAttachmentProbeMaximumBytes,
  bool Function(Attachment attachment)? existsOnDisk,
}) {
  if (maximumExpectedBytes <= 0 ||
      maximumExpectedBytes >
          CloudAttachmentDownloadCoordinator.maximumExpectedBytes) {
    throw ArgumentError.value(maximumExpectedBytes, 'maximumExpectedBytes');
  }
  final isMaterialized =
      existsOnDisk ?? (attachment) => attachment.existsOnDisk;
  final candidates = <Attachment>[];
  for (final attachment in attachments) {
    final guid = attachment.guid?.trim();
    final transferName = attachment.transferName?.trim();
    final expectedBytes = attachment.totalBytes;
    if (guid == null ||
        guid.isEmpty ||
        transferName == null ||
        transferName.isEmpty ||
        expectedBytes == null ||
        expectedBytes <= 0 ||
        expectedBytes > maximumExpectedBytes ||
        cloudAttachmentBodyCapabilityFor(attachment.metadata) !=
            CloudAttachmentBodyCapability.materializable ||
        cloudAttachmentDownloadLaneFor(attachment.metadata) !=
            CloudAttachmentDownloadLane.cloudSyncV2) {
      continue;
    }
    try {
      if (isMaterialized(attachment)) continue;
    } catch (_) {
      continue;
    }
    candidates.add(attachment);
  }
  candidates.sort((left, right) {
    final bySize = left.totalBytes!.compareTo(right.totalBytes!);
    if (bySize != 0) return bySize;
    final byId = (left.id ?? 0).compareTo(right.id ?? 0);
    if (byId != 0) return byId;
    return left.guid!.compareTo(right.guid!);
  });
  return candidates.isEmpty ? null : candidates.first;
}

final class _CloudSyncProjectionConversation {
  const _CloudSyncProjectionConversation({
    required this.chatId,
    required this.title,
    required this.preview,
    required this.latestDate,
  });

  final int chatId;
  final String title;
  final String preview;
  final DateTime? latestDate;
}

final class _CloudSyncProjectionMessage {
  const _CloudSyncProjectionMessage({
    required this.sender,
    required this.body,
    required this.date,
  });

  final String sender;
  final String body;
  final DateTime? date;
}

Set<int> _cloudSyncV2WindowsAttachmentMessageIds() {
  final ids = <int>{};
  for (final attachment in Database.attachments.getAll()) {
    final messageId = attachment.message.targetId;
    if (messageId != 0) ids.add(messageId);
  }
  return ids;
}

List<_CloudSyncProjectionConversation>
_cloudSyncV2WindowsReadProjectionConversations() {
  return Database.runInTransaction(TxMode.read, () {
    final chatsById = <int, Chat>{};
    for (final chat in Database.chats.getAll()) {
      final id = chat.id;
      if (id != null) chatsById[id] = chat;
    }
    final attachmentMessageIds = _cloudSyncV2WindowsAttachmentMessageIds();
    final query =
        (Database.messages.query(
                Message_.dateDeleted.isNull().and(
                  Message_.dateCreated.notNull(),
                ),
              )
              ..order(Message_.dateCreated, flags: Order.descending)
              ..order(Message_.id, flags: Order.descending))
            .build()
          ..limit = 5000;
    final messages = query.find();
    query.close();

    final conversations = <_CloudSyncProjectionConversation>[];
    final seenChatIds = <int>{};
    for (final message in messages) {
      final chatId = message.chat.targetId;
      final chat = chatsById[chatId];
      if (chatId == 0 || chat == null || !seenChatIds.add(chatId)) continue;
      final messageId = message.id;
      conversations.add(
        _CloudSyncProjectionConversation(
          chatId: chatId,
          title: cloudSyncV2WindowsProjectionChatTitle(
            displayName: chat.displayName,
            chatIdentifier: chat.chatIdentifier,
          ),
          preview: cloudSyncV2WindowsProjectionBody(
            text: message.text,
            attributedText: _cloudSyncV2WindowsAttributedText(message),
            subject: message.subject,
            hasAttachments:
                message.hasAttachments ||
                (messageId != null && attachmentMessageIds.contains(messageId)),
            isAssociated: message.associatedMessageGuid?.isNotEmpty ?? false,
            isEvent: _cloudSyncV2WindowsIsEvent(message),
          ),
          latestDate: message.dateCreated,
        ),
      );
      if (conversations.length == 100) break;
    }
    return conversations;
  });
}

List<_CloudSyncProjectionMessage> _cloudSyncV2WindowsReadProjectionMessages(
  int chatId,
) {
  return Database.runInTransaction(TxMode.read, () {
    final attachmentMessageIds = _cloudSyncV2WindowsAttachmentMessageIds();
    final query =
        (Database.messages.query(
                Message_.dateDeleted
                    .isNull()
                    .and(Message_.dateCreated.notNull())
                    .and(Message_.chat.equals(chatId)),
              )
              ..order(Message_.dateCreated, flags: Order.descending)
              ..order(Message_.id, flags: Order.descending))
            .build()
          ..limit = 500;
    final messages = query.find();
    query.close();
    return messages
        .map((message) {
          final messageId = message.id;
          return _CloudSyncProjectionMessage(
            sender: message.isFromMe ?? false ? 'You' : 'Other person',
            body: cloudSyncV2WindowsProjectionBody(
              text: message.text,
              attributedText: _cloudSyncV2WindowsAttributedText(message),
              subject: message.subject,
              hasAttachments:
                  message.hasAttachments ||
                  (messageId != null &&
                      attachmentMessageIds.contains(messageId)),
              isAssociated: message.associatedMessageGuid?.isNotEmpty ?? false,
              isEvent: _cloudSyncV2WindowsIsEvent(message),
            ),
            date: message.dateCreated,
          );
        })
        .toList(growable: false);
  });
}

final class CloudSyncV2WindowsHarnessLaunch {
  const CloudSyncV2WindowsHarnessLaunch({
    required this.operation,
    required this.launchId,
  });

  static const launchIdArgumentPrefix = '--launch-id=';
  static final RegExp _launchIdPattern = RegExp(r'^[a-f0-9]{32}$');

  final CloudSyncV2WindowsHarnessOperation operation;
  final String launchId;

  static bool isValidLaunchId(String value) => _launchIdPattern.hasMatch(value);

  static CloudSyncV2WindowsHarnessLaunch parse(List<String> arguments) {
    var operation = CloudSyncV2WindowsHarnessOperation.interactive;
    var operationSeen = false;
    String? launchId;
    for (final argument in arguments) {
      switch (argument) {
        case 'run-once':
          if (operationSeen) {
            throw StateError('cloud_sync_windows_dev_launch_mode_invalid');
          }
          operation = CloudSyncV2WindowsHarnessOperation.runOnce;
          operationSeen = true;
        case 'drain':
          if (operationSeen) {
            throw StateError('cloud_sync_windows_dev_launch_mode_invalid');
          }
          operation = CloudSyncV2WindowsHarnessOperation.drain;
          operationSeen = true;
        case 'probe-attachment':
          if (operationSeen) {
            throw StateError('cloud_sync_windows_dev_launch_mode_invalid');
          }
          operation = CloudSyncV2WindowsHarnessOperation.attachmentProbe;
          operationSeen = true;
        case 'view-projection':
          if (operationSeen) {
            throw StateError('cloud_sync_windows_dev_launch_mode_invalid');
          }
          operation = CloudSyncV2WindowsHarnessOperation.projectionViewer;
          operationSeen = true;
        case 'view-projection-detail':
          if (operationSeen) {
            throw StateError('cloud_sync_windows_dev_launch_mode_invalid');
          }
          operation = CloudSyncV2WindowsHarnessOperation.projectionDetailViewer;
          operationSeen = true;
        default:
          if (!argument.startsWith(launchIdArgumentPrefix) ||
              launchId != null) {
            throw StateError('cloud_sync_windows_dev_launch_mode_invalid');
          }
          final candidate = argument.substring(launchIdArgumentPrefix.length);
          if (!isValidLaunchId(candidate)) {
            throw StateError('cloud_sync_windows_dev_launch_id_invalid');
          }
          launchId = candidate;
      }
    }
    if (launchId == null) {
      throw StateError('cloud_sync_windows_dev_launch_id_missing');
    }
    return CloudSyncV2WindowsHarnessLaunch(
      operation: operation,
      launchId: launchId,
    );
  }
}

final class CloudSyncV2WindowsHarnessTerminalStatus {
  const CloudSyncV2WindowsHarnessTerminalStatus({
    required this.state,
    required this.stage,
  });

  final String state;
  final String stage;
}

CloudSyncV2WindowsHarnessTerminalStatus
cloudSyncV2WindowsHarnessDrainTerminalStatus({
  required bool reachedPassLimit,
  required bool projectionComplete,
}) {
  if (reachedPassLimit) {
    return const CloudSyncV2WindowsHarnessTerminalStatus(
      state: 'resumable',
      stage: 'semantic-drain-pass-limit',
    );
  }
  return CloudSyncV2WindowsHarnessTerminalStatus(
    state: 'finished',
    stage: projectionComplete
        ? 'semantic-drain-complete'
        : 'semantic-drain-remote-complete-projection-partial',
  );
}

enum _CloudSyncV2WindowsHarnessResumeOperation {
  initialize,
  semanticPull,
  semanticDrain,
  attachmentProbe,
}

Future<void> _harnessStatusWriteTail = Future<void>.value();
var _harnessStatusTemporarySequence = 0;
late final String _harnessLaunchId;

Map<String, Object?> cloudSyncV2WindowsHarnessStatusPayload({
  required String launchId,
  required int processId,
  required String state,
  required String stage,
  required DateTime updatedUtc,
  String? safeCode,
  String? errorType,
  String? detail,
  String? stack,
}) {
  if (!CloudSyncV2WindowsHarnessLaunch.isValidLaunchId(launchId)) {
    throw StateError('cloud_sync_windows_dev_launch_id_invalid');
  }
  if (processId <= 0 || !updatedUtc.isUtc) {
    throw StateError('cloud_sync_windows_dev_status_identity_invalid');
  }
  return <String, Object?>{
    'version': 'cloud-sync-v2-windows-harness-status-v2',
    'launch_id': launchId,
    'process_id': processId,
    'state': state,
    'stage': stage,
    'updated_utc': updatedUtc.toIso8601String(),
    if (safeCode != null) 'safe_code': safeCode,
    if (errorType != null) 'error_type': errorType,
    if (detail != null) 'detail': detail,
    if (stack != null) 'stack': stack,
  };
}

Future<void> _writeHarnessStatus({
  required String state,
  required String stage,
  String? safeCode,
  String? errorType,
  String? detail,
  String? stack,
}) {
  final previous = _harnessStatusWriteTail.catchError((Object _) {});
  final next = previous.then(
    (_) => _writeHarnessStatusNow(
      state: state,
      stage: stage,
      safeCode: safeCode,
      errorType: errorType,
      detail: detail,
      stack: stack,
    ),
  );
  _harnessStatusWriteTail = next;
  return next;
}

Future<void> _writeHarnessStatusNow({
  required String state,
  required String stage,
  String? safeCode,
  String? errorType,
  String? detail,
  String? stack,
}) async {
  final directory = Directory(path.join(fs.appDocDir.path, 'cloud-sync-v2'));
  await directory.create(recursive: true);
  final target = File(path.join(directory.path, 'windows-harness-status.json'));
  final temporary = File(
    '${target.path}.$pid.${_harnessStatusTemporarySequence++}.tmp',
  );
  final payload = cloudSyncV2WindowsHarnessStatusPayload(
    launchId: _harnessLaunchId,
    processId: pid,
    state: state,
    stage: stage,
    updatedUtc: DateTime.now().toUtc(),
    safeCode: safeCode,
    errorType: errorType,
    detail: detail,
    stack: stack,
  );
  await temporary.writeAsString(jsonEncode(payload), flush: true);
  try {
    await retryCloudSyncV2WindowsHarnessStatusReplace(
      replace: () async {
        if (await target.exists()) await target.delete();
        await temporary.rename(target.path);
      },
    );
  } finally {
    try {
      if (await temporary.exists()) await temporary.delete();
    } catch (_) {
      // A stale status temp is non-authoritative and never blocks the harness.
    }
  }
}

@visibleForTesting
Future<void> retryCloudSyncV2WindowsHarnessStatusReplace({
  required Future<void> Function() replace,
  Future<void> Function(Duration) delay = Future<void>.delayed,
  int maximumAttempts = 20,
}) async {
  if (maximumAttempts <= 0) {
    throw ArgumentError.value(maximumAttempts, 'maximumAttempts');
  }
  for (var attempt = 1; attempt <= maximumAttempts; attempt++) {
    try {
      await replace();
      return;
    } on FileSystemException {
      if (attempt == maximumAttempts) rethrow;
      await delay(const Duration(milliseconds: 25));
    }
  }
}

String _sanitizeHarnessDetail(String value, {int maxLength = 1000}) {
  var sanitized = value
      .replaceAll(
        RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false),
        '[redacted-email]',
      )
      .replaceAll(RegExp(r'(?<!\d)\+?\d[\d .()-]{7,}\d'), '[redacted-number]');
  sanitized = sanitized.replaceAllMapped(
    RegExp(
      r'(serial|dsid|token|password)([:= ]+)[^\s,;]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}${match.group(2)}[redacted]',
  );
  if (sanitized.length > maxLength) {
    sanitized = sanitized.substring(0, maxLength);
  }
  return sanitized;
}

class CloudSyncV2WindowsHarness extends StatefulWidget {
  const CloudSyncV2WindowsHarness({super.key, required this.operation});

  final CloudSyncV2WindowsHarnessOperation operation;

  @override
  State<CloudSyncV2WindowsHarness> createState() =>
      _CloudSyncV2WindowsHarnessState();
}

class _CloudSyncV2WindowsHarnessState extends State<CloudSyncV2WindowsHarness> {
  final List<Object> _sessionHandles = <Object>[];
  final TextEditingController _twoFactorController = TextEditingController();
  Object? _activeClient;
  rustlib.ApsConnection? _connection;
  rustlib.ArcAnisetteClientDefaultAnisetteProvider? _anisette;
  rustlib.ArcMutexAppleAccountDefaultAnisetteProvider? _account;
  api.JoinedOsConfig? _osConfig;
  api.VerifyBody? _smsVerificationBody;
  List<api.TrustedPhoneNumber> _smsPhoneOptions = const [];
  CloudSyncProductionSemanticPullAdapter? _adapter;
  CloudSyncSemanticPullReportFileWriter? _reportWriter;
  CloudSyncSemanticDrainController? _drainController;
  CloudSyncSemanticPullReport? _report;
  String _status = 'Opening the isolated Windows profile...';
  String _runtimeStage = 'initializing';
  bool _needsTwoFactor = false;
  bool _busy = true;
  bool _freshReadAuthenticationAttempted = false;
  _CloudSyncV2WindowsHarnessResumeOperation? _resumeAfterTwoFactor;

  Future<void> _setRuntimeStage(
    String stage, {
    String state = 'initializing',
    String? detail,
  }) {
    _runtimeStage = stage;
    return _writeHarnessStatus(state: state, stage: stage, detail: detail);
  }

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_initialize);
  }

  Future<void> _initialize() async {
    _resumeAfterTwoFactor =
        _CloudSyncV2WindowsHarnessResumeOperation.initialize;
    try {
      if (widget.operation ==
              CloudSyncV2WindowsHarnessOperation.projectionViewer ||
          widget.operation ==
              CloudSyncV2WindowsHarnessOperation.projectionDetailViewer) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _status = 'Viewing the existing local projection read-only.';
        });
        _resumeAfterTwoFactor = null;
        await _setRuntimeStage(
          widget.operation ==
                  CloudSyncV2WindowsHarnessOperation.projectionDetailViewer
              ? 'projection-detail-viewer-ready'
              : 'projection-viewer-ready',
          state: 'ready',
        );
        return;
      }
      // Main has already bound the process-global DPAPI keystore to this exact
      // isolated profile. Keep this composition CloudKit-only: do not invoke
      // SharedPushState.restore, which also restores IDS and FaceTime services.
      await _setRuntimeStage('protected-keystore-ready');

      if (_activeClient == null) {
        final hardware = api.readHardware(path: fs.appDocDir.path);
        if (hardware == null) {
          throw StateError('cloud_sync_windows_dev_hardware_restore_failed');
        }
        late final api.IdsngmIdentity identity;
        try {
          identity = api.decodeIdentity(identity: hardware.identity);
        } catch (_) {
          throw StateError('cloud_sync_windows_dev_identity_restore_failed');
        }
        final config = hardware.osConfig;
        _osConfig = config;
        await _setRuntimeStage('aps-setup');
        final pushSetup = await api.setupPush(
          config: config,
          identity: identity,
          state: hardware.push,
          statePath: fs.appDocDir.path,
        );
        if (pushSetup.$2 != null) {
          throw StateError('cloud_sync_windows_dev_aps_setup_failed');
        }
        final connection = pushSetup.$1;
        _connection = connection;
        await _setRuntimeStage('anisette-setup');
        final anisette = await api.makeAnisette(
          path: fs.appDocDir.path,
          config: config,
          conn: connection,
        );
        _anisette = anisette;
        await _setRuntimeStage('gsa-restore');
        final account = await api.restoreAccount(
          path: fs.appDocDir.path,
          anisette: anisette,
          config: config,
          conn: connection,
        );
        if (account == null) {
          throw StateError('cloud_sync_windows_dev_gsa_restore_failed');
        }
        _sessionHandles.addAll(<Object>[
          hardware,
          identity,
          config,
          connection,
          anisette,
        ]);
        await _activateCloudKitClient(
          account: account,
          anisette: anisette,
          config: config,
        );
      }

      await _rebuildSemanticRuntime();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Ready. The Store app must remain closed while this runs.';
      });
      await _setRuntimeStage('cloudkit-client-ready', state: 'ready');
      _resumeAfterTwoFactor = null;
      await _runRequestedLaunchOperation();
    } catch (error) {
      if (await _handleMissingReadAuthentication(error)) return;
      _showFailure(error);
    }
  }

  Future<void> _activateCloudKitClient({
    required rustlib.ArcMutexAppleAccountDefaultAnisetteProvider account,
    required rustlib.ArcAnisetteClientDefaultAnisetteProvider anisette,
    required api.JoinedOsConfig config,
  }) async {
    final tokenProvider = api.makeTokenProvider(
      account: account,
      config: config,
    );
    await _setRuntimeStage('cloudkit-restore');
    final cloudkit = await api.makeCloudkit(
      path: fs.appDocDir.path,
      anisette: anisette,
      config: config,
      tokenProvider: tokenProvider,
    );
    if (cloudkit == null) {
      throw StateError('cloud_sync_windows_dev_cloudkit_restore_failed');
    }
    await _setRuntimeStage('pcs-keychain');
    final keychain = api.makeKeychain(
      path: fs.appDocDir.path,
      cloudkit: cloudkit,
      anisette: anisette,
      config: config,
      tokenProvider: tokenProvider,
    );
    if (keychain == null) {
      throw StateError('cloud_sync_windows_dev_keychain_restore_failed');
    }
    final cloudMessagesClient = api.makeCloudMessagesClient(
      cloudkit: cloudkit,
      keychain: keychain,
    );
    _sessionHandles.addAll(<Object>[
      account,
      tokenProvider,
      cloudkit,
      keychain,
      cloudMessagesClient,
    ]);
    _account = account;
    _activeClient = cloudMessagesClient;
  }

  Future<void> _rebuildSemanticRuntime() async {
    final previousController = _drainController;
    _drainController = null;
    if (previousController != null) {
      await previousController.dispose();
    }
    final protector = RustCloudSyncProtector(
      storageDirectory: fs.appDocDir.path,
    );
    final preflight = CloudSyncProductionPreflightProbe(
      platformSupported: () => Platform.isWindows,
      uiIsolate: () => true,
      rustPushReady: () => _activeClient != null,
      localState: ObjectBoxCloudSyncPreflightReader.fromDatabase().read,
      privateStorageExists: fs.appDocDir.existsSync,
      logoutActive: () => false,
      legacySyncEnabled: () => false,
      legacySyncActive: () => false,
      protectorSentinelValid: CloudSyncProtectorHealthProbe(
        protector: protector,
      ).read,
    );
    final adapter = CloudSyncProductionSemanticPullAdapter(
      readActiveClient: () => _activeClient,
      readPreflight: preflight.read,
      privateStorageDirectory: fs.appDocDir.path,
      platform: Platform.operatingSystem,
      architecture: ffi.Abi.current().toString(),
      buildCommit: _buildIdentifier(),
    );
    final reportWriter = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: path.join(
        fs.appDocDir.path,
        'cloud-sync-v2',
        'reports',
      ),
      trustedStorageRoot: fs.appDocDir.path,
    );
    _adapter = adapter;
    _reportWriter = reportWriter;
    _drainController = CloudSyncSemanticDrainController.production(
      sampler: adapter.sampler,
      reportWriter: reportWriter,
    );
  }

  Future<bool> _handleMissingReadAuthentication(Object error) async {
    final safeCode = cloudSyncV2SafeFailureCode(error);
    if (!cloudSyncV2WindowsHarnessShouldStartFreshReadAuthentication(
      safeCode: safeCode,
      alreadyAttempted: _freshReadAuthenticationAttempted,
    )) {
      return false;
    }
    _freshReadAuthenticationAttempted = true;
    try {
      await _beginFreshReadAuthentication();
    } catch (recoveryError) {
      _showFailure(recoveryError);
    }
    return true;
  }

  Future<void> _beginFreshReadAuthentication() async {
    final connection = _connection;
    final anisette = _anisette;
    final config = _osConfig;
    if (connection == null || anisette == null || config == null) {
      throw StateError('cloud_sync_windows_dev_auth_session_missing');
    }

    await _setRuntimeStage('read-auth-login', state: 'running');
    final result = await api.tryAuth(
      path: fs.appDocDir.path,
      conf: config,
      conn: connection,
      anisette: anisette,
    );
    final account = result.$1;
    final loginState = result.$2;
    switch (cloudSyncV2WindowsHarnessReadAuthAction(loginState)) {
      case CloudSyncV2WindowsReadAuthAction.activate:
        await _activateCloudKitClient(
          account: account,
          anisette: anisette,
          config: config,
        );
        await _rebuildSemanticRuntime();
        await _resumeAfterAuthenticatedReadSession();
      case CloudSyncV2WindowsReadAuthAction.requestSmsTwoFactor:
        _account = account;
        _sessionHandles.add(account);
        if (!await _prepareSmsTwoFactor()) {
          throw StateError('cloud_sync_windows_dev_2fa_phone_unavailable');
        }
      case CloudSyncV2WindowsReadAuthAction.resumePendingSmsTwoFactor:
        _account = account;
        _sessionHandles.add(account);
        _smsVerificationBody =
            (loginState as api.LoginState_NeedsSMS2FAVerification).field0;
        await _showSmsCodeEntry(
          'Apple is waiting for the SMS verification code.',
        );
      case CloudSyncV2WindowsReadAuthAction.reject:
        throw StateError('cloud_sync_windows_dev_auth_state_unsupported');
    }
  }

  Future<void> _runRequestedLaunchOperation() async {
    switch (widget.operation) {
      case CloudSyncV2WindowsHarnessOperation.interactive:
        return;
      case CloudSyncV2WindowsHarnessOperation.runOnce:
        await _runSemanticPull();
      case CloudSyncV2WindowsHarnessOperation.drain:
        await _runSemanticDrain();
      case CloudSyncV2WindowsHarnessOperation.attachmentProbe:
        await _runAttachmentProbe();
      case CloudSyncV2WindowsHarnessOperation.projectionViewer:
        return;
      case CloudSyncV2WindowsHarnessOperation.projectionDetailViewer:
        return;
    }
  }

  Future<bool> _prepareSmsTwoFactor() async {
    final account = _account;
    if (account == null) return false;

    await _setRuntimeStage('sms-2fa-options', state: 'running');
    final options = await api.get2FaSmsOpts(state: account);
    // An existing verification body can describe an old pending challenge.
    // Always issue a new send request so the notification has a fresh code and
    // timestamp instead of silently replaying stale account state.
    if (options.$1.length == 1) {
      await _sendSmsTwoFactor(options.$1.single);
      return true;
    }
    if (options.$1.isEmpty) return false;

    if (!mounted) return true;
    setState(() {
      _smsPhoneOptions = List<api.TrustedPhoneNumber>.unmodifiable(options.$1);
      _busy = false;
      _status =
          'Choose the trusted phone that should receive Apple’s SMS code.';
    });
    await _setRuntimeStage('sms-2fa-phone-choice', state: 'waiting-user');
    return true;
  }

  Future<void> _sendSmsTwoFactor(api.TrustedPhoneNumber phone) async {
    final account = _account;
    if (account == null) {
      _showFailure(StateError('cloud_sync_windows_dev_2fa_session_missing'));
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Requesting Apple’s SMS verification code...';
    });
    await _setRuntimeStage('sms-2fa-request', state: 'running');
    try {
      final state = await api.send2FaSms(account: account, phoneId: phone.id);
      if (state is! api.LoginState_NeedsSMS2FAVerification) {
        throw StateError('cloud_sync_windows_dev_2fa_request_failed');
      }
      _smsVerificationBody = state.field0;
      _smsPhoneOptions = const [];
      await _showSmsCodeEntry(
        'Apple sent a code to the trusted phone ending in '
        '${phone.lastTwoDigits}.',
      );
    } catch (_) {
      _showFailure(StateError('cloud_sync_windows_dev_2fa_request_failed'));
    }
  }

  Future<void> _showSmsCodeEntry(String status) async {
    if (!mounted) return;
    setState(() {
      _needsTwoFactor = true;
      _busy = false;
      _status = status;
    });
    await _setRuntimeStage('sms-2fa', state: 'waiting-user');
  }

  Future<void> _verifyTwoFactorCode() async {
    final code = _twoFactorController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() {
        _status = 'Enter the complete six-digit Apple verification code.';
      });
      return;
    }
    final body = _smsVerificationBody;
    final anisette = _anisette;
    final config = _osConfig;
    final account = _account;
    if (body == null || anisette == null || config == null || account == null) {
      _showFailure(StateError('cloud_sync_windows_dev_2fa_session_missing'));
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Verifying with Apple...';
    });
    await _setRuntimeStage('sms-2fa-verify', state: 'running');
    try {
      final result = await api.verify2FaSms(
        path: fs.appDocDir.path,
        accountMut: account,
        anisette: anisette,
        config: config,
        body: body,
        code: code,
      );
      if (result.$1 is! api.LoginState_LoggedIn) {
        throw StateError('cloud_sync_windows_dev_2fa_verification_failed');
      }
      await _activateCloudKitClient(
        account: account,
        anisette: anisette,
        config: config,
      );
      await _rebuildSemanticRuntime();
      _twoFactorController.clear();
      if (!mounted) return;
      setState(() {
        _needsTwoFactor = false;
        _smsVerificationBody = null;
        _busy = false;
        _status = 'SMS verification succeeded. Resuming the pull...';
      });
      await _setRuntimeStage('sms-2fa-verified', state: 'running');
      await _resumeAfterAuthenticatedReadSession();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status =
            'Apple did not accept that verification attempt. Request a new '
            'code by restarting the isolated harness.';
      });
      await _writeHarnessStatus(
        state: 'failed',
        stage: 'sms-2fa-verify',
        safeCode: 'cloud_sync_windows_dev_2fa_verification_failed',
      );
    }
  }

  Future<void> _resumeAfterAuthenticatedReadSession() async {
    if (!mounted) return;
    final resumeOperation = _resumeAfterTwoFactor;
    _resumeAfterTwoFactor = null;
    setState(() {
      _busy = false;
      _needsTwoFactor = false;
      _smsPhoneOptions = const [];
    });
    await _setRuntimeStage('cloudkit-client-ready', state: 'ready');
    switch (resumeOperation) {
      case _CloudSyncV2WindowsHarnessResumeOperation.initialize:
        await _runRequestedLaunchOperation();
      case _CloudSyncV2WindowsHarnessResumeOperation.semanticPull:
        await _runSemanticPull();
      case _CloudSyncV2WindowsHarnessResumeOperation.semanticDrain:
        await _runSemanticDrain();
      case _CloudSyncV2WindowsHarnessResumeOperation.attachmentProbe:
        await _runAttachmentProbe();
      case null:
        await _runRequestedLaunchOperation();
    }
  }

  Future<void> _runSemanticPull() async {
    final adapter = _adapter;
    final reportWriter = _reportWriter;
    if (adapter == null || reportWriter == null || _busy) return;
    _resumeAfterTwoFactor =
        _CloudSyncV2WindowsHarnessResumeOperation.semanticPull;
    setState(() {
      _busy = true;
      _status = 'Running one bounded, read-only semantic pull...';
    });
    await _setRuntimeStage('semantic-pull', state: 'running');
    try {
      final report = await adapter.sampler.runConfirmed();
      final repairedChatOrderRows =
          await repairCloudSyncChatLatestMessageDates();
      final reportFile = await reportWriter.write(report);
      final fetched = report.zones.fold<int>(
        0,
        (sum, zone) => sum + zone.fetched,
      );
      final applied = report.zones.fold<int>(
        0,
        (sum, zone) => sum + zone.applied,
      );
      final retained = report.zones.fold<int>(
        0,
        (sum, zone) => sum + zone.retainedUnprojected,
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _busy = false;
        _status =
            'Finished: fetched $fetched, applied $applied, retained $retained. '
            'Report ${path.basename(reportFile.path)}';
      });
      await _setRuntimeStage(
        'semantic-pull',
        state: 'finished',
        detail:
            'fetched=$fetched applied=$applied retained=$retained '
            'chat_order_cache_repaired=$repairedChatOrderRows '
            'report=${path.basename(reportFile.path)}',
      );
      _resumeAfterTwoFactor = null;
    } catch (error) {
      if (await _handleMissingReadAuthentication(error)) return;
      _showFailure(error);
    }
  }

  Future<void> _runSemanticDrain() async {
    final controller = _drainController;
    if (controller == null || _busy) return;
    _resumeAfterTwoFactor =
        _CloudSyncV2WindowsHarnessResumeOperation.semanticDrain;
    setState(() {
      _busy = true;
      _status = 'Draining bounded CloudKit history in one read-only session...';
    });
    await _setRuntimeStage('semantic-drain', state: 'running');
    try {
      final result = await controller.drainConfirmedAndPersist();
      final repairedChatOrderRows =
          await repairCloudSyncChatLatestMessageDates();
      final reportReference = result.persistedReportReference;
      final reportName = reportReference is File
          ? path.basename(reportReference.path)
          : 'persisted';
      final terminalStatus = cloudSyncV2WindowsHarnessDrainTerminalStatus(
        reachedPassLimit: result.reachedPassLimit,
        projectionComplete: result.retainedSaveProjectionComplete,
      );
      if (!mounted) return;
      setState(() {
        _report = result.lastReport;
        _busy = false;
        _status = result.reachedPassLimit
            ? 'Paused safely after ${result.passes} passes. Resume the drain '
                  'to continue. Report $reportName'
            : result.retainedSaveProjectionComplete
            ? 'Remote history is current and every retained iMessage save is '
                  'projected after ${result.passes} passes. Report $reportName'
            : result.projectionSweepAttempted
            ? 'Remote history is current; one exact local sweep examined every '
                  'retained save, but some still need protocol repairs. '
                  'Report $reportName'
            : 'Remote history is current; no retained-save sweep was needed. '
                  'Report $reportName';
      });
      await _setRuntimeStage(
        terminalStatus.stage,
        state: terminalStatus.state,
        detail:
            'passes=${result.passes} remote_drained=${result.remoteDrained} '
            'projection_complete=${result.projectionComplete} '
            'retained_save_projection_complete='
            '${result.retainedSaveProjectionComplete} '
            'projection_sweep_attempted=${result.projectionSweepAttempted} '
            'pass_limit=${result.reachedPassLimit} '
            'chat_order_cache_repaired=$repairedChatOrderRows '
            'report=$reportName',
      );
      _resumeAfterTwoFactor = null;
    } catch (error) {
      if (await _handleMissingReadAuthentication(error)) return;
      _showFailure(error);
    }
  }

  Future<void> _runAttachmentProbe() async {
    if (_activeClient == null || _busy) return;
    _resumeAfterTwoFactor =
        _CloudSyncV2WindowsHarnessResumeOperation.attachmentProbe;
    setState(() {
      _busy = true;
      _status =
          'Verifying one bounded attachment body in the disposable copy...';
    });
    await _setRuntimeStage('attachment-probe', state: 'running');
    try {
      if (!cloudSyncV2WindowsAttachmentProbeProfileIsMarked(fs.appDocDir)) {
        throw StateError('cloud_attachment_probe_disposable_profile_required');
      }
      final candidate = cloudSyncV2WindowsSelectAttachmentProbeCandidate(
        Database.attachments.getAll(),
      );
      if (candidate == null) {
        throw StateError('cloud_attachment_probe_candidate_unavailable');
      }
      final expectedBytes = candidate.totalBytes!;
      final adapter = CloudAttachmentProductionAdapter.fromDatabase(
        readActiveClient: () => _activeClient,
        privateStorageDirectory: fs.appDocDir.path,
        applicationDocumentsDirectory: fs.appDocDir.path,
      );
      final result = await adapter.downloadIfAvailable(
        canonicalGuid: candidate.guid!,
        expectedBytes: expectedBytes,
      );
      if (result is! CloudAttachmentDownloadMaterialized ||
          result.body.verifiedBytes != expectedBytes) {
        throw StateError('cloud_attachment_probe_source_unavailable');
      }
      final finalFile = File(candidate.path);
      if (!await finalFile.exists()) {
        throw StateError('cloud_attachment_final_file_missing');
      }
      final placedBytes = await finalFile.length();
      if (placedBytes != expectedBytes) {
        throw StateError('cloud_attachment_size_mismatch');
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Attachment body verified locally ($placedBytes bytes).';
      });
      await _setRuntimeStage(
        'attachment-probe-complete',
        state: 'finished',
        detail:
            'verified_bytes=$placedBytes '
            'already_referenced=${result.body.alreadyReferenced}',
      );
      _resumeAfterTwoFactor = null;
    } catch (error) {
      if (await _handleMissingReadAuthentication(error)) return;
      _showFailure(error);
    }
  }

  void _showFailure(Object error) {
    if (!mounted) return;
    _resumeAfterTwoFactor = null;
    unawaited(
      _writeHarnessStatus(
        state: 'failed',
        stage: _runtimeStage,
        safeCode: cloudSyncV2SafeFailureCode(error),
        errorType: error.runtimeType.toString(),
        detail: _sanitizeHarnessDetail(error.toString()),
      ),
    );
    setState(() {
      _busy = false;
      _status = 'Stopped safely: ${cloudSyncV2SafeFailureCode(error)}';
    });
  }

  String _buildIdentifier() {
    const supplied = String.fromEnvironment(
      'OPENBUBBLES_BUILD_COMMIT',
      defaultValue: 'windows-dev',
    );
    return RegExp(r'^[A-Za-z0-9._+-]{1,80}$').hasMatch(supplied)
        ? supplied
        : 'windows-dev';
  }

  @override
  void dispose() {
    final controller = _drainController;
    if (controller != null) unawaited(controller.dispose());
    _twoFactorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isProjectionViewer =
        widget.operation ==
            CloudSyncV2WindowsHarnessOperation.projectionViewer ||
        widget.operation ==
            CloudSyncV2WindowsHarnessOperation.projectionDetailViewer;
    final Widget home = isProjectionViewer
        ? _CloudSyncProjectionViewer(
            openFirstConversation:
                widget.operation ==
                CloudSyncV2WindowsHarnessOperation.projectionDetailViewer,
          )
        : Scaffold(
            appBar: AppBar(title: const Text('Cloud Sync V2 Windows Harness')),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _buildHarnessControls(context),
                ),
              ),
            ),
          );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: home,
    );
  }

  Widget _buildHarnessControls(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Card(
          color: Color(0xFF3A2414),
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'PRIVATE DEVELOPMENT PROFILE\n'
              'No remote saves or deletes. Do not run the Microsoft '
              'Store app at the same time.',
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(_status),
        if (_smsPhoneOptions.isNotEmpty) ...[
          const SizedBox(height: 16),
          ..._smsPhoneOptions.map(
            (phone) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _sendSmsTwoFactor(phone),
                icon: const Icon(Icons.sms_outlined),
                label: Text(
                  'Send SMS to trusted phone ending '
                  '${phone.lastTwoDigits}',
                ),
              ),
            ),
          ),
        ],
        if (_needsTwoFactor) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _twoFactorController,
            autofocus: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            maxLength: 6,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Apple SMS verification code',
            ),
            onSubmitted: (_) {
              if (!_busy) unawaited(_verifyTwoFactorCode());
            },
          ),
          FilledButton.icon(
            onPressed: _busy ? null : _verifyTwoFactorCode,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('Verify and resume'),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed:
              _busy ||
                  _adapter == null ||
                  _needsTwoFactor ||
                  _smsPhoneOptions.isNotEmpty
              ? null
              : _runSemanticPull,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_download_outlined),
          label: const Text('Run semantic pull'),
        ),
        const SizedBox(height: 12),
        Builder(
          builder: (navigationContext) => OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => Navigator.of(navigationContext).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const _CloudSyncProjectionViewer(),
                    ),
                  ),
            icon: const Icon(Icons.forum_outlined),
            label: const Text('View projected messages'),
          ),
        ),
        const SizedBox(height: 20),
        if (_report case final report?)
          ...report.zones.map(
            (zone) => ListTile(
              title: Text(zone.zoneLabel),
              subtitle: Text(
                'fetched ${zone.fetched}  applied ${zone.applied}  '
                'retained ${zone.retainedUnprojected}',
              ),
              trailing: Text(zone.status.name),
            ),
          ),
      ],
    );
  }
}

class _CloudSyncProjectionViewer extends StatefulWidget {
  const _CloudSyncProjectionViewer({this.openFirstConversation = false});

  final bool openFirstConversation;

  @override
  State<_CloudSyncProjectionViewer> createState() =>
      _CloudSyncProjectionViewerState();
}

class _CloudSyncProjectionViewerState
    extends State<_CloudSyncProjectionViewer> {
  List<_CloudSyncProjectionConversation> _conversations = const [];
  String? _errorType;
  bool _loading = true;
  bool _didOpenFirstConversation = false;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_reload);
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorType = null;
      });
    }
    await Future<void>.delayed(Duration.zero);
    try {
      final conversations = _cloudSyncV2WindowsReadProjectionConversations();
      if (!mounted) return;
      setState(() {
        _conversations = conversations;
        _loading = false;
      });
      if (widget.openFirstConversation &&
          !_didOpenFirstConversation &&
          conversations.isNotEmpty) {
        _didOpenFirstConversation = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final conversation = conversations.first;
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _CloudSyncProjectionConversationView(
                chatId: conversation.chatId,
                title: conversation.title,
              ),
            ),
          );
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorType = error.runtimeType.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Projected conversations'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _reload,
            tooltip: 'Refresh local projection',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          const _CloudSyncProjectionReadOnlyBanner(),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_errorType case final errorType?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'The local projection could not be opened ($errorType).',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_conversations.isEmpty) {
      return const Center(
        child: Text('No projected messages are available in this profile.'),
      );
    }
    return ListView.separated(
      itemCount: _conversations.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final conversation = _conversations[index];
        return ListTile(
          title: Text(
            conversation.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            conversation.preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            _cloudSyncV2WindowsTimestamp(conversation.latestDate),
            textAlign: TextAlign.end,
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _CloudSyncProjectionConversationView(
                chatId: conversation.chatId,
                title: conversation.title,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CloudSyncProjectionConversationView extends StatefulWidget {
  const _CloudSyncProjectionConversationView({
    required this.chatId,
    required this.title,
  });

  final int chatId;
  final String title;

  @override
  State<_CloudSyncProjectionConversationView> createState() =>
      _CloudSyncProjectionConversationViewState();
}

class _CloudSyncProjectionConversationViewState
    extends State<_CloudSyncProjectionConversationView> {
  List<_CloudSyncProjectionMessage> _messages = const [];
  String? _errorType;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_reload);
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorType = null;
      });
    }
    await Future<void>.delayed(Duration.zero);
    try {
      final messages = _cloudSyncV2WindowsReadProjectionMessages(widget.chatId);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorType = error.runtimeType.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: _loading ? null : _reload,
            tooltip: 'Refresh local conversation',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_errorType case final errorType?) {
      return Center(
        child: Text('The local conversation could not be opened ($errorType).'),
      );
    }
    if (_messages.isEmpty) {
      return const Center(child: Text('No projected messages in this chat.'));
    }
    return Column(
      children: [
        const _CloudSyncProjectionReadOnlyBanner(),
        Expanded(
          child: ListView.separated(
            reverse: true,
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final message = _messages[index];
              return Align(
                alignment: message.sender == 'You'
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${message.sender} - '
                            '${_cloudSyncV2WindowsTimestamp(message.date)}',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(message.body),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CloudSyncProjectionReadOnlyBanner extends StatelessWidget {
  const _CloudSyncProjectionReadOnlyBanner();

  @override
  Widget build(BuildContext context) {
    return const MaterialBanner(
      content: Text(
        'READ-ONLY LOCAL VIEW. This screen cannot send, delete, or change '
        'CloudKit data.',
      ),
      actions: [SizedBox.shrink()],
    );
  }
}
