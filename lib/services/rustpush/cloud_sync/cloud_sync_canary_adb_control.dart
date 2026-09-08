import 'dart:async';
import 'dart:convert';
import 'package:bluebubbles/app/layouts/settings/pages/misc/troubleshoot_panel.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/navigator/navigator_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// Removable Canary-debug-only ADB control dispatcher.
/// Driven by CanaryAdbControlReceiver (src/canaryDebug, explicit broadcast
/// from the on-device shell only). Responses are content-free: route names,
/// aggregate counts, booleans, safe codes. No message text, identifiers,
/// credentials, keys, records, or tokens cross this boundary.
/// Compile gate: --dart-define=OPENBUBBLES_CANARY_ADB_CONTROL=true.
/// Runtime gates: kDebugMode plus canary package check on originPackage.
/// Kill switch: build without the dart-define (default off), or delete this
/// file, the canaryDebug tree, and the CANARY_ADB_HOOK lines in
/// method_channel_service.dart.
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
  static const String prefsPendingKey = 'canary_adb_pending';
  static const String prefsLastNavKey = 'canary_adb_last_nav';
  static bool active({bool? compiledInOverride, bool? debugOverride}) =>
      (compiledInOverride ?? compiledIn) && (debugOverride ?? kDebugMode);
}

/// Parsed ADB command. Throws StateError with a content-free adb_* code.
final class CanaryAdbCommand {
  const CanaryAdbCommand({
    required this.action,
    required this.seq,
    required this.confirm,
    required this.originPackage,
  });
  final String action;
  final String seq;
  final bool confirm;
  final String originPackage;
  static CanaryAdbCommand parse(Map<String, dynamic>? args) {
    final raw = args ?? const {};
    final action = raw['action'];
    if (action is! String ||
        !CanaryAdbControlGate.allowedActions.contains(action))
      throw StateError('adb_action_unknown');
    final seqRaw = raw['seq'];
    final seq = seqRaw == null ? '0' : seqRaw.toString();
    if (seq.isEmpty ||
        seq.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(seq))
      throw StateError('adb_seq_invalid');
    final origin = raw['originPackage'];
    if (origin is! String ||
        origin != CanaryAdbControlGate.expectedOriginPackage)
      throw StateError('adb_origin_refused');
    final confirmRaw = raw['confirm'];
    return CanaryAdbCommand(
      action: action,
      seq: seq,
      confirm: confirmRaw == true || confirmRaw == 'true',
      originPackage: origin,
    );
  }
}

/// Content-free result envelope. Data values are num/bool/short safe strings.
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
  static final RegExp safeString = RegExp(r'^[A-Za-z0-9_.,: +/%+-]*$');
  Map<String, Object> toSafeMap() {
    final safeData = <String, Object>{};
    for (final entry in data.entries) {
      if (!RegExp(r'^[a-z_]+$').hasMatch(entry.key))
        throw StateError('adb_result_key_unsafe');
      final value = entry.value;
      if (value is num || value is bool) {
        safeData[entry.key] = value;
      } else if (value is String &&
          value.length <= 256 &&
          safeString.hasMatch(value)) {
        safeData[entry.key] = value;
      } else {
        throw StateError('adb_result_value_unsafe');
      }
    }
    return {
      'seq': seq,
      'action': action,
      'ok': ok,
      'code': code,
      'data': safeData,
    };
  }

  String toJson() => jsonEncode(toSafeMap());
  static void assertSafeForTest(Map<String, Object> map) {
    const topKeys = {'seq', 'action', 'ok', 'code', 'data'};
    for (final key in map.keys) {
      assert(topKeys.contains(key), 'unexpected top-level key');
    }
    final data = map['data'];
    assert(data is Map, 'data must be a map');
    (data as Map).forEach((key, value) {
      assert(
        key is String && RegExp(r'^[a-z_]+$').hasMatch(key),
        'unsafe data key',
      );
      final valid =
          value is num ||
          value is bool ||
          (value is String &&
              value.length <= 256 &&
              safeString.hasMatch(value));
      assert(valid, 'unsafe data value');
    });
  }
}

/// Entry point from MethodChannelService (CANARY_ADB_HOOK). Never throws.
abstract final class CanaryAdbControl {
  static Future<void> handleCommand(Map<String, dynamic>? args) async {
    String seq = '0';
    String action = 'unknown';
    try {
      if (!CanaryAdbControlGate.active()) {
        final raw = args ?? const {};
        seq = (raw['seq'] ?? '0').toString();
        action = (raw['action'] ?? 'unknown').toString();
        await storeResult(
          CanaryAdbResult(
            seq: seq,
            action: action,
            ok: false,
            code: 'adb_control_disabled',
          ),
        );
        return;
      }
      final command = CanaryAdbCommand.parse(args);
      seq = command.seq;
      action = command.action;
      await storeResult(await _execute(command));
    } on StateError catch (error) {
      final rawCode = error.message.toString();
      final code = RegExp(r'^adb_[a-z_]+$').hasMatch(rawCode)
          ? rawCode
          : 'adb_handler_error';
      await storeResult(
        CanaryAdbResult(seq: seq, action: action, ok: false, code: code),
      );
    } catch (_) {
      await storeResult(
        CanaryAdbResult(
          seq: seq,
          action: action,
          ok: false,
          code: 'adb_handler_error',
        ),
      );
    }
  }

  static void drainPendingAction() {
    if (!CanaryAdbControlGate.active()) return;
    unawaited(
      Future(() async {
        String? pending;
        try {
          pending = ss.prefs.getString(CanaryAdbControlGate.prefsPendingKey);
        } catch (_) {
          return;
        }
        if (pending == null || pending.isEmpty) return;
        final parts = pending.split('|');
        if (parts.length != 2 ||
            !CanaryAdbControlGate.allowedActions.contains(parts[0])) {
          try {
            await ss.prefs.remove(CanaryAdbControlGate.prefsPendingKey);
          } catch (_) {}
          return;
        }
        for (var attempt = 0; attempt < 20; attempt++) {
          if (Get.context != null) {
            try {
              await _openDeveloperPage(parts[0]);
              await storeResult(
                CanaryAdbResult(
                  seq: parts[1],
                  action: parts[0],
                  ok: true,
                  code: 'adb_opened_from_pending',
                ),
              );
            } catch (_) {
              await storeResult(
                CanaryAdbResult(
                  seq: parts[1],
                  action: parts[0],
                  ok: false,
                  code: 'adb_open_failed',
                ),
              );
            }
            try {
              await ss.prefs.remove(CanaryAdbControlGate.prefsPendingKey);
            } catch (_) {}
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }),
    );
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
      default:
        throw StateError('adb_action_unknown');
    }
  }

  static Future<CanaryAdbResult> _status(CanaryAdbCommand command) async {
    return CanaryAdbResult(
      seq: command.seq,
      action: command.action,
      ok: true,
      code: 'adb_status',
      data: {
        'developer_mode': ss.settings.developerEnabled.value,
        'setup_finished': ss.settings.finishedSetup.value,
        'legacy_sync_enabled': ss.settings.cloudSyncingEnabled.value,
        'semantic_pull_compiled': CloudSyncDevGate.manualSemanticPullEnabled,
        'semantic_pull_available': _semanticAvailable(),
        'foreground': Get.context != null,
      },
    );
  }

  static Future<CanaryAdbResult> _queryRoute(CanaryAdbCommand command) async {
    String lastNav = '';
    try {
      lastNav = ss.prefs.getString(CanaryAdbControlGate.prefsLastNavKey) ?? '';
    } catch (_) {}
    return CanaryAdbResult(
      seq: command.seq,
      action: command.action,
      ok: true,
      code: 'adb_route',
      data: {
        'route': _safeRoute(Get.currentRoute),
        'foreground': Get.context != null,
        'last_nav': _safeRoute(lastNav),
      },
    );
  }

  static String _safeRoute(String route) {
    if (route.isEmpty || route.length > 64) return 'unknown';
    if (!RegExp(r'^[A-Za-z0-9_/,.-]*$').hasMatch(route)) return 'unknown';
    return route;
  }

  static Future<CanaryAdbResult> _open(CanaryAdbCommand command) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (Get.context != null) {
        await _openDeveloperPage(command.action);
        return CanaryAdbResult(
          seq: command.seq,
          action: command.action,
          ok: true,
          code: 'adb_opened',
          data: {'developer_mode': ss.settings.developerEnabled.value},
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return CanaryAdbResult(
      seq: command.seq,
      action: command.action,
      ok: false,
      code: 'adb_app_not_foreground',
    );
  }

  static Future<void> _openDeveloperPage(String action) async {
    final context = Get.context;
    if (context == null) throw StateError('adb_app_not_foreground');
    ns.pushSettings(context, TroubleshootPanel());
    try {
      await ss.prefs.setString(CanaryAdbControlGate.prefsLastNavKey, action);
    } catch (_) {}
  }

  static bool _semanticAvailable() {
    try {
      return pushService.cloudSyncV2ManualSemanticPullAvailable;
    } catch (_) {
      return false;
    }
  }

  static Future<CanaryAdbResult> _semanticStatus(
    CanaryAdbCommand command,
  ) async {
    return CanaryAdbResult(
      seq: command.seq,
      action: command.action,
      ok: true,
      code: 'adb_semantic_status',
      data: {
        'semantic_pull_compiled': CloudSyncDevGate.manualSemanticPullEnabled,
        'developer_mode': ss.settings.developerEnabled.value,
        'semantic_pull_available': _semanticAvailable(),
      },
    );
  }

  static Future<CanaryAdbResult> _semanticStart(
    CanaryAdbCommand command,
  ) async {
    final available = _semanticAvailable();
    if (!command.confirm) {
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: false,
        code: 'adb_confirmation_required',
        data: {
          'semantic_pull_available': available,
          'developer_mode': ss.settings.developerEnabled.value,
        },
      );
    }
    if (!available) {
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: false,
        code: 'adb_semantic_unavailable',
      );
    }
    try {
      final result = await pushService
          .runCloudSyncV2AutomaticSemanticCatchUpReadOnly();
      final presentation = cloudSyncV2SemanticCanaryPresentation(
        result.lastReport,
      );
      final outcomeName = presentation.outcome.name;
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: presentation.outcome == CloudSyncV2SemanticCanaryOutcome.complete,
        code: 'adb_semantic_' + outcomeName,
        data: {
          'passes': result.passes,
          'remote_drained': result.remoteDrained,
          'reached_pass_limit': result.reachedPassLimit,
        },
      );
    } catch (error) {
      return CanaryAdbResult(
        seq: command.seq,
        action: command.action,
        ok: false,
        code: 'adb_semantic_' + cloudSyncV2SafeFailureCode(error),
      );
    }
  }

  static Future<void> storeResult(CanaryAdbResult result) async {
    try {
      Logger.info('CanaryAdb result ' + result.toJson());
    } catch (_) {}
    try {
      await ss.prefs.setString(
        CanaryAdbControlGate.prefsResultKey,
        result.toJson(),
      );
    } catch (_) {}
  }
}
