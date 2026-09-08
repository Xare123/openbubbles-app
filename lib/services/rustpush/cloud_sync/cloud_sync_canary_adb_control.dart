import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bluebubbles/app/layouts/settings/pages/misc/troubleshoot_panel.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report_file.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// Removable Canary-debug-only ADB control dispatcher.
abstract final class CanaryAdbControlGate {
  static const bool compiledIn = bool.fromEnvironment(
    'OPENBUBBLES_CANARY_ADB_CONTROL',
    defaultValue: false,
  );
  static const Set<String> allowedActions = {
    'ping',
    'status',
    'query_route',
    'open_developer_settings',
    'open_cloud_sync_v2',
    'semantic_pull_status',
    'semantic_pull_start',
  };
  static const String expectedOriginPackage =
      CloudSyncDevGate.androidCanaryPackageName;
  static const String prefsResultKey = 'canary_adb_last_result';
  static bool active({bool? compiledInOverride, bool? debugOverride}) =>
      (compiledInOverride ?? compiledIn) && (debugOverride ?? kDebugMode);
}

final class CanaryAdbCommand {
  const CanaryAdbCommand({
    required this.action,
    required this.seq,
    required this.confirm,
    required this.challenge,
    required this.originPackage,
  });
  final String action;
  final String seq;
  final bool confirm;
  final String? challenge;
  final String originPackage;

  static CanaryAdbCommand parse(Map<String, dynamic>? args) {
    final raw = args ?? const {};
    final action = raw['action'];
    if (action is! String ||
        !CanaryAdbControlGate.allowedActions.contains(action)) {
      throw StateError('adb_action_unknown');
    }
    final seq = (raw['seq'] ?? '0').toString();
    if (!CanaryAdbResultSchema.validToken(seq)) {
      throw StateError('adb_seq_invalid');
    }
    final origin = raw['originPackage'];
    if (origin is! String ||
        origin != CanaryAdbControlGate.expectedOriginPackage) {
      throw StateError('adb_origin_refused');
    }
    final challenge = raw['challenge'];
    if (challenge != null &&
        (challenge is! String ||
            !CanaryAdbResultSchema.validChallenge(challenge))) {
      throw StateError('adb_challenge_invalid');
    }
    final confirm = raw['confirm'];
    return CanaryAdbCommand(
      action: action,
      seq: seq,
      confirm: confirm == true || confirm == 'true',
      challenge: challenge as String?,
      originPackage: origin,
    );
  }
}

final class CanaryAdbResult {
  const CanaryAdbResult({
    required this.seq,
    required this.action,
    required this.ok,
    required this.code,
    this.data = const {},
  });
  final String seq;
  final String action;
  final bool ok;
  final String code;
  final Map<String, Object> data;

  Map<String, Object> toSafeMap() {
    CanaryAdbResultSchema.validate(this);
    return {
      'seq': seq,
      'action': action,
      'ok': ok,
      'code': code,
      'data': Map<String, Object>.unmodifiable(data),
    };
  }

  String toJson() => jsonEncode(toSafeMap());
}

/// Closed action-specific result schemas. Free-form safe-looking strings are
/// rejected rather than merely filtered by character set.
abstract final class CanaryAdbResultSchema {
  static final _token = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static final _challenge = RegExp(r'^c_[A-Za-z0-9_-]{27}$');
  static const preflightKeys = {
    'setup_finished',
    'developer_mode',
    'legacy_sync_enabled',
    'legacy_sync_active',
    'logout_active',
    'semantic_pull_compiled',
    'semantic_pull_active',
    'semantic_pull_quiescing',
    'auth_ready',
    'ui_ready',
    'coordinator_active',
    'outbox_state',
    'semantic_pull_available',
  };
  static const diagnosticCodes = {
    'none',
    'semantic_report_zone_label_invalid',
    'semantic_report_zone_counter_invalid',
    'semantic_report_terminal_read_invalid',
    'semantic_report_elapsed_invalid',
    'semantic_report_projection_counter_invalid',
    'semantic_report_projection_mode_invalid',
    'semantic_report_projection_accounting_invalid',
    'semantic_report_diagnostic_count_invalid',
  };
  static const diagnosticZones = {'none', 'chats', 'messages', 'attachments'};
  static const _outboxStates = {'empty', 'settled', 'blocked', 'unavailable'};
  static const _runStates = {'idle', 'running', 'complete', 'failed'};
  static const _outcomes = {'none', 'complete', 'partial', 'stopped_safely'};
  static const _failures = {
    'none',
    'disabled',
    'wrong_package',
    'developer_required',
    'setup_required',
    'legacy_active',
    'already_running',
    'quiescing',
    'auth_unavailable',
    'outbox_blocked',
    'report_invalid',
    'internal',
  };
  static const _successfulCodes = {
    'adb_pong',
    'adb_status',
    'adb_route',
    'adb_opened',
    'adb_semantic_accepted',
    'adb_semantic_status',
  };

  static bool validToken(String value) => _token.hasMatch(value);
  static bool validChallenge(String value) => _challenge.hasMatch(value);

  static void validate(CanaryAdbResult result) {
    if (!validToken(result.seq)) throw StateError('adb_result_seq_unsafe');
    if (!(CanaryAdbControlGate.allowedActions.contains(result.action) ||
        result.action == 'invalid')) {
      throw StateError('adb_result_action_unsafe');
    }
    if (result.ok != _successfulCodes.contains(result.code)) {
      throw StateError('adb_result_ok_code_mismatch');
    }
    final data = result.data;
    switch (result.code) {
      case 'adb_pong':
        _action(result, {'ping'});
        _exact(data, {'semantic_pull_compiled'});
        _bool(data, 'semantic_pull_compiled');
        return;
      case 'adb_status':
        _action(result, {'status'});
        _preflight(data);
        return;
      case 'adb_route':
        _action(result, {'query_route'});
        _exact(data, {'route', 'foreground', 'last_nav'});
        _enum(data, 'route', {'developer_tools', 'other', 'unknown'});
        _bool(data, 'foreground');
        _enum(data, 'last_nav', {'none', 'developer_tools', 'cloud_sync_v2'});
        return;
      case 'adb_opened':
        _action(result, {'open_developer_settings', 'open_cloud_sync_v2'});
        _exact(data, {'developer_mode'});
        _bool(data, 'developer_mode');
        return;
      case 'adb_semantic_preflight':
        _action(result, {'semantic_pull_start'});
        _preflight(data, additional: {'challenge'});
        final challenge = data['challenge'];
        if (challenge is! String || !validChallenge(challenge)) {
          throw StateError('adb_result_challenge_unsafe');
        }
        return;
      case 'adb_semantic_accepted':
        _action(result, {'semantic_pull_start'});
        _exact(data, {'pull_state'});
        _enum(data, 'pull_state', {'running'});
        return;
      case 'adb_semantic_status':
        _action(result, {'semantic_pull_status'});
        const extra = {
          'pull_state',
          'outcome',
          'failure',
          'passes',
          'remote_drained',
          'reached_pass_limit',
          'diagnostic_code',
          'diagnostic_zone',
        };
        _preflight(data, additional: extra);
        _enum(data, 'pull_state', _runStates);
        _enum(data, 'outcome', _outcomes);
        _enum(data, 'failure', _failures);
        final passes = data['passes'];
        if (passes is! int || passes < 0 || passes > 65535) {
          throw StateError('adb_result_passes_unsafe');
        }
        _bool(data, 'remote_drained');
        _bool(data, 'reached_pass_limit');
        _enum(data, 'diagnostic_code', diagnosticCodes);
        _enum(data, 'diagnostic_zone', diagnosticZones);
        return;
      case 'adb_control_disabled':
      case 'adb_action_unknown':
      case 'adb_seq_invalid':
      case 'adb_origin_refused':
      case 'adb_challenge_invalid':
      case 'adb_handler_error':
        _action(result, {'invalid'});
        _exact(data, const {});
        return;
      case 'adb_app_not_foreground':
      case 'adb_open_failed':
        _action(result, {'open_developer_settings', 'open_cloud_sync_v2'});
        _exact(data, const {});
        return;
      case 'adb_semantic_challenge_invalid':
      case 'adb_semantic_challenge_expired':
        _action(result, {'semantic_pull_start'});
        _exact(data, const {});
        return;
      case 'adb_semantic_unavailable':
        _action(result, {'semantic_pull_start'});
        _preflight(data);
        return;
      default:
        throw StateError('adb_result_code_unsafe');
    }
  }

  static void _preflight(
    Map<String, Object> data, {
    Set<String> additional = const {},
  }) {
    _exact(data, {...preflightKeys, ...additional});
    for (final key in preflightKeys.difference({'outbox_state'})) {
      _bool(data, key);
    }
    _enum(data, 'outbox_state', _outboxStates);
  }

  static void _action(CanaryAdbResult result, Set<String> allowed) {
    if (!allowed.contains(result.action)) {
      throw StateError('adb_result_action_code_mismatch');
    }
  }

  static void _exact(Map<String, Object> data, Set<String> keys) {
    if (data.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(data.keys.toSet()).isNotEmpty) {
      throw StateError('adb_result_schema_mismatch');
    }
  }

  static void _bool(Map<String, Object> data, String key) {
    if (data[key] is! bool) throw StateError('adb_result_type_mismatch');
  }

  static void _enum(Map<String, Object> data, String key, Set<String> allowed) {
    final value = data[key];
    if (value is! String || !allowed.contains(value)) {
      throw StateError('adb_result_enum_mismatch');
    }
  }
}

enum CanaryAdbChallengeConsumption { accepted, invalid, expired }

final class CanaryAdbChallengeStore {
  _CanaryAdbChallenge? _active;

  String issue({
    required String action,
    required String seq,
    required DateTime now,
    required String token,
  }) {
    if (!CanaryAdbResultSchema.validChallenge(token)) {
      throw StateError('adb_challenge_invalid');
    }
    _active = _CanaryAdbChallenge(
      action,
      seq,
      token,
      now.toUtc().add(const Duration(seconds: 20)),
    );
    return token;
  }

  CanaryAdbChallengeConsumption consume({
    required String action,
    required String seq,
    required String? token,
    required DateTime now,
  }) {
    final active = _active;
    _active = null;
    if (active == null ||
        active.action != action ||
        active.seq != seq ||
        active.token != token) {
      return CanaryAdbChallengeConsumption.invalid;
    }
    if (!now.toUtc().isBefore(active.expiresAt)) {
      return CanaryAdbChallengeConsumption.expired;
    }
    return CanaryAdbChallengeConsumption.accepted;
  }
}

final class _CanaryAdbChallenge {
  const _CanaryAdbChallenge(this.action, this.seq, this.token, this.expiresAt);
  final String action;
  final String seq;
  final String token;
  final DateTime expiresAt;
}

final class _CanaryAdbPreflight {
  const _CanaryAdbPreflight(this.data);
  final Map<String, Object> data;
  bool get available => data['semantic_pull_available'] == true;
}

abstract final class CanaryAdbControl {
  static final _challenges = CanaryAdbChallengeStore();
  static String _pullState = 'idle';
  static String _outcome = 'none';
  static String _failure = 'none';
  static int _passes = 0;
  static bool _remoteDrained = false;
  static bool _reachedPassLimit = false;
  static String _diagnosticCode = 'none';
  static String _diagnosticZone = 'none';

  static Future<void> handleCommand(Map<String, dynamic>? args) async {
    var seq = '0';
    try {
      if (!CanaryAdbControlGate.active()) {
        await storeResult(
          const CanaryAdbResult(
            seq: '0',
            action: 'invalid',
            ok: false,
            code: 'adb_control_disabled',
          ),
        );
        return;
      }
      final command = CanaryAdbCommand.parse(args);
      seq = command.seq;
      await storeResult(await _execute(command));
    } on StateError catch (error) {
      final rawCode = error.message.toString();
      final code =
          const {
            'adb_action_unknown',
            'adb_seq_invalid',
            'adb_origin_refused',
            'adb_challenge_invalid',
          }.contains(rawCode)
          ? rawCode
          : 'adb_handler_error';
      await storeResult(
        CanaryAdbResult(
          seq: CanaryAdbResultSchema.validToken(seq) ? seq : '0',
          action: 'invalid',
          ok: false,
          code: code,
        ),
      );
    } catch (_) {
      await storeResult(
        CanaryAdbResult(
          seq: CanaryAdbResultSchema.validToken(seq) ? seq : '0',
          action: 'invalid',
          ok: false,
          code: 'adb_handler_error',
        ),
      );
    }
  }

  static Future<CanaryAdbResult> _execute(CanaryAdbCommand command) async {
    switch (command.action) {
      case 'ping':
        return CanaryAdbResult(
          seq: command.seq,
          action: command.action,
          ok: true,
          code: 'adb_pong',
          data: {
            'semantic_pull_compiled':
                CloudSyncDevGate.manualSemanticPullEnabled,
          },
        );
      case 'status':
        return _status(command);
      case 'query_route':
        return _queryRoute(command);
      case 'open_developer_settings':
      case 'open_cloud_sync_v2':
        return _open(command);
      case 'semantic_pull_status':
        return _semanticStatus(command);
      case 'semantic_pull_start':
        return _semanticStart(command);
    }
    throw StateError('adb_action_unknown');
  }

  static Future<_CanaryAdbPreflight> _readPreflight() async {
    var outboxState = 'unavailable';
    var coordinatorActive = true;
    try {
      final local = ObjectBoxCloudSyncPreflightReader.fromDatabase().read();
      coordinatorActive = local.coordinatorLeaseActive;
      if (local.outboxCount == 0) {
        outboxState = 'empty';
      } else if (local.outboxCount > 0 &&
          local.settledOutboxFingerprint != null) {
        outboxState = 'settled';
      } else {
        outboxState = 'blocked';
      }
    } catch (_) {}
    final setupFinished = ss.settings.finishedSetup.value;
    final developerMode = ss.settings.developerEnabled.value;
    final legacyEnabled = ss.settings.cloudSyncingEnabled.value;
    final legacyActive = pushService.isSyncing.value != null;
    final logoutActive = pushService.loggingOut;
    const semanticCompiled = CloudSyncDevGate.manualSemanticPullEnabled;
    final semanticActive = pushService.cloudSyncV2CanaryAdbSemanticPullActive;
    final semanticQuiescing =
        pushService.cloudSyncV2CanaryAdbSemanticPullQuiescing;
    final authReady =
        pushService.statePath.isNotEmpty &&
        pushService.state?.icloudServices?.cloudMessagesClient != null;
    final uiReady = Get.context != null;
    final outboxSafe = outboxState == 'empty' || outboxState == 'settled';
    final data = <String, Object>{
      'setup_finished': setupFinished,
      'developer_mode': developerMode,
      'legacy_sync_enabled': legacyEnabled,
      'legacy_sync_active': legacyActive,
      'logout_active': logoutActive,
      'semantic_pull_compiled': semanticCompiled,
      'semantic_pull_active': semanticActive,
      'semantic_pull_quiescing': semanticQuiescing,
      'auth_ready': authReady,
      'ui_ready': uiReady,
      'coordinator_active': coordinatorActive,
      'outbox_state': outboxState,
      'semantic_pull_available':
          pushService.cloudSyncV2ManualSemanticPullAvailable &&
          setupFinished &&
          developerMode &&
          !legacyEnabled &&
          !legacyActive &&
          !logoutActive &&
          semanticCompiled &&
          !semanticActive &&
          !semanticQuiescing &&
          authReady &&
          uiReady &&
          !coordinatorActive &&
          outboxSafe,
    };
    return _CanaryAdbPreflight(data);
  }

  static Future<CanaryAdbResult> _status(CanaryAdbCommand command) async {
    final preflight = await _readPreflight();
    return CanaryAdbResult(
      seq: command.seq,
      action: command.action,
      ok: true,
      code: 'adb_status',
      data: preflight.data,
    );
  }

  static Future<CanaryAdbResult> _queryRoute(CanaryAdbCommand command) async {
    var lastNav = 'none';
    try {
      final raw = ss.prefs.getString('canary_adb_last_nav');
      if (raw == 'open_developer_settings') lastNav = 'developer_tools';
      if (raw == 'open_cloud_sync_v2') lastNav = 'cloud_sync_v2';
    } catch (_) {}
    return CanaryAdbResult(
      seq: command.seq,
      action: command.action,
      ok: true,
      code: 'adb_route',
      data: {
        'route': _routeClass(Get.currentRoute),
        'foreground': Get.context != null,
        'last_nav': lastNav,
      },
    );
  }

  static String _routeClass(String route) {
    if (route.isEmpty) return 'unknown';
    final normalized = route.toLowerCase();
    if (normalized.contains('troubleshoot') ||
        normalized.contains('developer')) {
      return 'developer_tools';
    }
    return 'other';
  }

  static Future<CanaryAdbResult> _open(CanaryAdbCommand command) async {
    final context = Get.context;
    if (context == null) {
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: false,
        code: 'adb_app_not_foreground',
      );
    }
    try {
      ns.pushSettings(context, TroubleshootPanel());
      await ss.prefs.setString('canary_adb_last_nav', command.action);
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: true,
        code: 'adb_opened',
        data: {'developer_mode': ss.settings.developerEnabled.value},
      );
    } catch (_) {
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: false,
        code: 'adb_open_failed',
      );
    }
  }

  static Future<CanaryAdbResult> _semanticStatus(
    CanaryAdbCommand command,
  ) async {
    final preflight = await _readPreflight();
    return CanaryAdbResult(
      seq: command.seq,
      action: command.action,
      ok: true,
      code: 'adb_semantic_status',
      data: {
        ...preflight.data,
        'pull_state': _pullState,
        'outcome': _outcome,
        'failure': _failure,
        'passes': _passes,
        'remote_drained': _remoteDrained,
        'reached_pass_limit': _reachedPassLimit,
        'diagnostic_code': _diagnosticCode,
        'diagnostic_zone': _diagnosticZone,
      },
    );
  }

  static Future<CanaryAdbResult> _semanticStart(
    CanaryAdbCommand command,
  ) async {
    if (!command.confirm) {
      final preflight = await _readPreflight();
      if (!preflight.available) {
        return CanaryAdbResult(
          seq: command.seq,
          action: command.action,
          ok: false,
          code: 'adb_semantic_unavailable',
          data: preflight.data,
        );
      }
      final challenge = _challenges.issue(
        action: command.action,
        seq: command.seq,
        now: DateTime.now().toUtc(),
        token: _newChallenge(),
      );
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: false,
        code: 'adb_semantic_preflight',
        data: {...preflight.data, 'challenge': challenge},
      );
    }

    final consumed = _challenges.consume(
      action: command.action,
      seq: command.seq,
      token: command.challenge,
      now: DateTime.now().toUtc(),
    );
    if (consumed != CanaryAdbChallengeConsumption.accepted) {
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: false,
        code: consumed == CanaryAdbChallengeConsumption.expired
            ? 'adb_semantic_challenge_expired'
            : 'adb_semantic_challenge_invalid',
      );
    }
    final preflight = await _readPreflight();
    if (!preflight.available) {
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: false,
        code: 'adb_semantic_unavailable',
        data: preflight.data,
      );
    }

    _pullState = 'running';
    _outcome = 'none';
    _failure = 'none';
    _passes = 0;
    _remoteDrained = false;
    _reachedPassLimit = false;
    _diagnosticCode = 'none';
    _diagnosticZone = 'none';
    unawaited(_runSemanticPull());
    return CanaryAdbResult(
      seq: command.seq,
      action: command.action,
      ok: true,
      code: 'adb_semantic_accepted',
      data: const {'pull_state': 'running'},
    );
  }

  static Future<void> _runSemanticPull() async {
    try {
      final result = await pushService
          .runCloudSyncV2AutomaticSemanticCatchUpReadOnly();
      final presentation = cloudSyncV2SemanticCanaryPresentation(
        result.lastReport,
      );
      _pullState = 'complete';
      _outcome = switch (presentation.outcome) {
        CloudSyncV2SemanticCanaryOutcome.complete => 'complete',
        CloudSyncV2SemanticCanaryOutcome.partial => 'partial',
        CloudSyncV2SemanticCanaryOutcome.stoppedSafely => 'stopped_safely',
      };
      _passes = min(max(result.passes, 0), 65535);
      _remoteDrained = result.remoteDrained;
      _reachedPassLimit = result.reachedPassLimit;
    } catch (error) {
      _pullState = 'failed';
      _failure = _classifyFailure(error);
      _captureClosedReportDiagnostics(error);
    }
  }

  static String _classifyFailure(Object error) {
    final code = cloudSyncV2SafeFailureCode(error);
    if (code.contains('disabled')) return 'disabled';
    if (code.contains('canary_package')) return 'wrong_package';
    if (code.contains('developer_mode')) return 'developer_required';
    if (code.contains('setup')) return 'setup_required';
    if (code.contains('legacy') || code.contains('sync_active')) {
      return 'legacy_active';
    }
    if (code.contains('active') || code.contains('in_flight')) {
      return 'already_running';
    }
    if (code.contains('quiesc') || code.contains('logout')) return 'quiescing';
    if (code.contains('auth') || code.contains('account')) {
      return 'auth_unavailable';
    }
    if (code.contains('outbox')) return 'outbox_blocked';
    if (code.contains('report')) return 'report_invalid';
    return 'internal';
  }

  /// Dynamic access keeps this branch compatible with the older exception.
  /// After commit 98ebe6ba4 is integrated, only its closed diagnostic fields
  /// are exposed through the strict allowlists above.
  static void _captureClosedReportDiagnostics(Object error) {
    if (error is! CloudSyncSemanticPullReportFileException) return;
    try {
      final dynamic reportError = error;
      final Object? code = reportError.diagnosticCode;
      final Object? zone = reportError.diagnosticZone;
      if (code is String && diagnosticCodes.contains(code)) {
        _diagnosticCode = code;
      }
      if (zone is String && diagnosticZones.contains(zone)) {
        _diagnosticZone = zone;
      }
    } catch (_) {}
  }

  static Set<String> get diagnosticCodes =>
      CanaryAdbResultSchema.diagnosticCodes;
  static Set<String> get diagnosticZones =>
      CanaryAdbResultSchema.diagnosticZones;

  static String _newChallenge() {
    final random = Random.secure();
    final bytes = List<int>.generate(20, (_) => random.nextInt(256));
    return 'c_${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  static Future<void> storeResult(CanaryAdbResult result) async {
    try {
      final encoded = result.toJson();
      await ss.prefs.setString(CanaryAdbControlGate.prefsResultKey, encoded);
      Logger.info(
        'CanaryAdb result action=${result.action} code=${result.code}',
      );
    } catch (_) {
      Logger.warn('CanaryAdb result rejected');
    }
  }
}
