import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

const backendHarnessProtocol = 1;
const backendHarnessExtension = 'ext.openbubbles.backend';
const backendHarnessActions = <String>{
  'hello',
  'status',
  'job.status',
  'sync.start',
  'sync.pause',
  'relay.configure',
  'auth.login',
  'auth.code',
  'auth.restore',
  'auth.status',
  'auth.repair',
  'auth.read',
  'protector.check',
  'pcs.devices',
  'pcs.unlock',
  'archive.scope',
  'archive.prepare',
  'archive.status',
  'archive.recover-group',
  'archive.recover-message',
  'fixture.inspect',
  'fixture.fetch',
  'fixture.materialize',
  'report.snapshot',
  'fixture.send',
  'fixture.edit',
  'fixture.unsend',
  'fixture.status',
  'fixture.route',
};
const backendHarnessCodes = <String>{
  'backend_ready',
  'backend_disabled',
  'backend_not_ready',
  'backend_group_context_not_ready',
  'backend_group_parent_not_ready',
  'backend_group_sender_not_ready',
  'backend_group_route_not_ready',
  'backend_group_dependency_not_ready',
  'backend_group_route_ambiguous',
  'backend_group_targets_not_ready',
  'backend_invalid_request',
  'backend_invalid_action',
  'backend_invalid_arguments',
  'backend_busy',
  'backend_job_accepted',
  'backend_job_running',
  'backend_job_completed',
  'backend_job_failed',
  'backend_group_recovery_receipt_missing',
  'backend_group_recovery_binding_changed',
  'backend_group_recovery_auth_unavailable',
  'backend_group_recovery_ineligible',
  'backend_group_recovery_not_ready',
  'backend_group_recovery_protected_storage_failed',
  'backend_message_recovery_receipt_missing',
  'backend_message_recovery_binding_changed',
  'backend_message_recovery_auth_unavailable',
  'backend_message_recovery_ineligible',
  'backend_message_recovery_protected_storage_failed',
  'backend_registration_rejected',
  'backend_read_auth_failed',
  'backend_read_auth_rejected',
  'backend_restart_required',
  'backend_job_unknown',
  'backend_request_reused',
  'backend_internal_error',
  'backend_job_limit',
  'backend_stale_session',
  'backend_source_mismatch',
  'backend_identity_changed',
  'backend_not_supported',
  'backend_auth_challenge',
};

abstract final class BackendHarnessGate {
  static const compiledIn = bool.fromEnvironment('OPENBUBBLES_AGENT_BACKEND');
  static const source = String.fromEnvironment('OPENBUBBLES_BACKEND_SOURCE');
  static bool allowed({
    required bool compiled,
    required bool debug,
    required String platform,
    required String package,
    bool isolatedWindowsProfile = false,
  }) =>
      compiled &&
      debug &&
      ((platform == 'android' &&
              package == 'com.bluebubbles.messaging.backendtest') ||
          (platform == 'windows' && isolatedWindowsProfile));
}

enum BackendHarnessPhase {
  idle,
  configuring,
  needs_credentials,
  needs_2fa,
  needs_sms_2fa,
  authenticated,
  registering,
  needs_trusted_device,
  needs_passcode,
  ready,
  syncing,
  pausing,
  paused,
  remote_head,
  blocked,
  error,
}

enum BackendHarnessChallengeKind {
  trustedDevice,
  smsDestination,
  verificationCode,
  archiveConsent,
  passcode,
  pin;

  bool get isChoice => this == trustedDevice || this == smsDestination;
}

/// Opaque interaction metadata. Device names, passwords and account labels
/// remain in the adapter; only this short-lived handle crosses public status.
final class BackendHarnessChallenge {
  const BackendHarnessChallenge(this.id, this.kind, {this.options = 0});
  final String id;
  final BackendHarnessChallengeKind kind;
  final int options;
  Map<String, Object> toJson() {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        (kind.isChoice ? options < 1 || options > 64 : options != 0)) {
      throw const FormatException('backend_invalid_challenge');
    }
    return {'id': id, 'kind': kind.name, 'options': options};
  }
}

/// Private fixture correlation for the batch controller. Contains fixed
/// identifiers/digests only; the CLI must omit this object from public output.
final class BackendHarnessFixtureReceipt {
  const BackendHarnessFixtureReceipt({
    required this.fixtureId,
    required this.messageGuid,
    required this.visibleTextSha256,
    this.participantsSha256,
    this.editHistorySha256,
    this.chatGuidSha256,
  });
  final String fixtureId;
  final String messageGuid;
  final String visibleTextSha256;
  final String? participantsSha256;
  final String? editHistorySha256;
  final String? chatGuidSha256;
  static final uuid = RegExp(
    r'^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$',
  );
  static bool validJson(Object? raw) =>
      raw is Map &&
      (raw.length == 3 || raw.length == 5 || raw.length == 6) &&
      raw.keys.every(
        const {'fixtureId', 'messageGuid', 'visibleTextSha256',
          'participantsSha256', 'editHistorySha256', 'chatGuidSha256'}.contains,
      ) &&
      raw['fixtureId'] is String &&
      uuid.hasMatch(raw['fixtureId'] as String) &&
      raw['messageGuid'] is String &&
      uuid.hasMatch(raw['messageGuid'] as String) &&
      raw['visibleTextSha256'] is String &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['visibleTextSha256'] as String) &&
      (raw.length == 3 ||
          raw['participantsSha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['participantsSha256'] as String) &&
          raw['editHistorySha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['editHistorySha256'] as String)) &&
      (raw.length != 6 || raw['chatGuidSha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['chatGuidSha256'] as String));
  Map<String, Object> toJson() {
    final value = <String, Object>{
      'fixtureId': fixtureId,
      'messageGuid': messageGuid,
      'visibleTextSha256': visibleTextSha256,
      if (participantsSha256 != null) 'participantsSha256': participantsSha256!,
      if (editHistorySha256 != null) 'editHistorySha256': editHistorySha256!,
      if (chatGuidSha256 != null) 'chatGuidSha256': chatGuidSha256!,
    };
    if (!validJson(value)) {
      throw const FormatException('backend_invalid_fixture');
    }
    return value;
  }
}

/// Public command results contain typed facts, never arbitrary native strings.
final class BackendHarnessPayload {
  const BackendHarnessPayload({
    this.phase = BackendHarnessPhase.idle,
    this.flags = const {},
    this.counts = const {},
    this.challenge,
    this.fixture,
  });
  static const flagNames = {
    'setup_finished',
    'auth_ready',
    'read_auth_ready',
    'existing_native_client_retained',
    'native_client_present',
    'native_identity_available',
    'registration_ready',
    'registration_refreshed',
    'credentials_refreshed',
    'restart_required',
    'registration_resource_failed',
    'registration_rejected',
    'registration_retry_available',
    'send_resources_ready',
    'protector_ready',
    'account_matches',
    'relay_ready',
    'encryption_ready',
    'sync_active',
    'sync_quiescing',
    'projection_complete',
    'has_report',
    'failure_present',
    'outbox_settled',
    'group_recovery_ready',
    'group_recovery_record_retained',
    'message_recovery_ready',
    'message_recovery_record_retained',
    'archive_enabled',
    'received_text_enabled',
    'received_media_enabled',
    'readback_verified',
    'exact_read_found',
    'exact_read_projected',
    'exact_read_absent',
    'exact_read_unresolved',
    'exact_read_tripwires_intact',
    'outcome_uncertain',
    'fixture_content_matches',
    'fixture_edit_matches',
    'fixture_retraction_matches',
    'fixture_matches',
    'fixture_parent_matches',
    'fixture_participants_match',
    'fixture_history_matches',
    'cloud_projection_present',
    'attachment_bytes_match',
    'report_source_matches',
    'report_tripwires_intact',
    'report_safe',
    'remote_head',
    'ids_evidence_present',
    'fixture_create_present',
    'fixture_create_pending',
    'fixture_create_settled',
    'fixture_edit_present',
    'fixture_edit_pending',
    'fixture_edit_settled',
    'fixture_undo_present',
    'fixture_undo_pending',
    'fixture_undo_settled',
    'fixture_attachment_archive_settled',
    'fixture_route_available',
  };
  static const countNames = {
    'pages',
    'fetched',
    'reprojected',
    'retained',
    'unavailable',
    'messages',
    'attachments',
    'devices',
    'ready_intents',
    'held_intents',
    'unresolved_operations',
    'edits',
    'retracted_parts',
    'bytes',
    'deferred',
    'quarantined',
    'outbox_before',
    'outbox_after',
  };
  final BackendHarnessPhase phase;
  final Map<String, bool> flags;
  final Map<String, int> counts;
  final BackendHarnessChallenge? challenge;
  final BackendHarnessFixtureReceipt? fixture;
  Map<String, Object> toJson() {
    if (!flagNames.containsAll(flags.keys) ||
        !countNames.containsAll(counts.keys) ||
        counts.values.any((count) => count < 0 || count > 1000000000)) {
      throw const FormatException('backend_invalid_payload');
    }
    return {
      'phase': phase.name,
      'flags': Map<String, bool>.of(flags),
      'counts': Map<String, int>.of(counts),
      if (challenge != null) 'challenge': challenge!.toJson(),
      if (fixture != null) 'fixture': fixture!.toJson(),
    };
  }
}

typedef BackendHarnessHandler =
    Future<BackendHarnessPayload> Function(Map<String, Object?> arguments);

final class BackendHarnessOperation {
  const BackendHarnessOperation({
    required this.handler,
    required this.validate,
    this.background = false,
    this.uncertainOnFailure = false,
    this.snapshot,
  });
  final BackendHarnessHandler handler;
  final bool Function(Map<String, Object?>) validate;
  final bool background;
  // A command fault cannot prove that an entered external operation did not
  // happen. Its durable owner must inspect/reconcile rather than resubmit.
  final bool uncertainOnFailure;
  final BackendHarnessPayload Function()? snapshot;
}

final class BackendHarnessFailure implements Exception {
  BackendHarnessFailure(this.code, {this.effectNotEntered = false}) {
    if (!backendHarnessCodes.contains(code)) {
      throw const FormatException('backend_invalid_failure');
    }
  }
  final String code;
  /// Trusted adapter preflight only. Never set after entering an external
  /// effect; request consumption and durable fixture claims remain retained.
  final bool effectNotEntered;
}

/// One engine per app boot. Repeated submissions return the SAME operation;
/// neither a host timeout nor polling creates another backend invocation.
final class BackendHarnessEngine {
  BackendHarnessEngine({
    required this.enabled,
    required this.source,
    required this.package,
    required this.platform,
    required Map<String, BackendHarnessOperation> operations,
    this.maximumJobs = 128,
    Random? random,
  }) : _operations = Map.unmodifiable(operations),
       _random = random ?? Random.secure() {
    if (maximumJobs < 1 ||
        maximumJobs > 1024 ||
        !backendHarnessActions.containsAll(operations.keys) ||
        operations.keys.any((key) => key == 'hello' || key == 'job.status')) {
      throw const FormatException('backend_invalid_registry');
    }
    sessionId = _token();
  }
  final bool enabled;
  final String source;
  final String package;
  final String platform;
  final int maximumJobs;
  final Map<String, BackendHarnessOperation> _operations;
  final Random _random;
  late final String sessionId;
  final _jobs = <String, _BackendHarnessJob>{};
  final _requests = <String, _BackendHarnessJob>{};
  _BackendHarnessJob? _active;
  bool _accepting = true;
  int _enteredCalls = 0;
  Completer<void>? _drained;
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// Stop new backend invocations without canceling an entered operation.
  /// Hello and cached job observations remain available for the original owner.
  Future<void> closeAdmissionAndDrain() {
    _accepting = false;
    final completion = _drained ??= Completer<void>();
    _notifyDrained();
    return completion.future;
  }

  bool get hasUncertainJobs => _jobs.values.any((job) {
    final flags = job.payload['flags'];
    return flags is Map && flags['outcome_uncertain'] == true;
  });

  /// Terminal recovery evidence only. No admission, resubmission, receipt or
  /// reconciliation authority is transferred, and the original jobs stay put.
  Map<String, Object> drainedRecoverySnapshot() {
    if (_accepting ||
        _active != null ||
        _enteredCalls != 0 ||
        _drained?.isCompleted != true) {
      throw StateError('backend_recovery_not_drained');
    }
    final jobs = <Map<String, Object>>[];
    for (final job in _jobs.values) {
      final flags = job.payload['flags'];
      if (flags is! Map || flags['outcome_uncertain'] != true) continue;
      if (!const {'completed', 'failed', 'blocked'}.contains(job.state) ||
          !backendHarnessCodes.contains(job.code)) {
        throw StateError('backend_recovery_not_terminal');
      }
      final correlation = job.recoveryCorrelation;
      if (const {
            'fixture.send',
            'fixture.edit',
            'fixture.unsend',
          }.contains(job.action) &&
          correlation == null) {
        throw StateError('backend_recovery_fixture_invalid');
      }
      final fixture = job.payload['fixture'];
      if (fixture != null &&
          (!BackendHarnessFixtureReceipt.validJson(fixture) ||
              correlation == null ||
              fixture is! Map ||
              (fixture['fixtureId'] as String).toUpperCase() !=
                  correlation['fixtureId']!.toUpperCase() ||
              (correlation.containsKey('messageGuid') &&
                  (fixture['messageGuid'] as String).toUpperCase() !=
                      correlation['messageGuid']!.toUpperCase()))) {
        throw StateError('backend_recovery_fixture_invalid');
      }
      jobs.add({
        'jobId': job.id,
        'requestId': job.requestId,
        'action': job.action,
        'requestSha256': job.digest,
        'state': job.state,
        'code': job.code,
        'flags': Map<String, bool>.from(flags),
        if (correlation != null)
          'correlation': Map<String, String>.from(correlation),
        if (fixture != null)
          'fixture': Map<String, Object>.from(fixture as Map),
      });
    }
    return {
      'schema': 1,
      'source': source,
      'package': package,
      'platform': platform,
      'sessionId': sessionId,
      'jobs': jobs,
    };
  }

  static Map<String, String>? _recoveryCorrelation(
    String action,
    Map<String, Object?> arguments,
  ) {
    if (!const {
      'fixture.send',
      'fixture.edit',
      'fixture.unsend',
    }.contains(action)) {
      return null;
    }
    final value = <String, String>{};
    for (final key in [
      'fixtureId',
      'retainedRecoveryOwner',
      if (action != 'fixture.send') 'messageGuid',
    ]) {
      final id = arguments[key];
      if (id is! String || !BackendHarnessFixtureReceipt.uuid.hasMatch(id)) {
        return null;
      }
      value[key] = id;
    }
    return Map.unmodifiable(value);
  }

  void _notifyDrained() {
    final completion = _drained;
    if (_active == null && _enteredCalls == 0 &&
        completion != null && !completion.isCompleted) {
      completion.complete();
    }
  }

  String _token() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Map<String, Object?> _reply(
    String id,
    String action,
    String code, {
    String state = 'completed',
    String? jobId,
    Map<String, Object> data = const {},
  }) => {
    'protocol': backendHarnessProtocol,
    'requestId': id,
    'action': action,
    'ok': !const {'failed', 'blocked'}.contains(state),
    'code': code,
    'state': state,
    'jobId': jobId,
    'data': data,
  };

  Future<Map<String, Object?>> execute(
    Object? raw, {
    String? expectedSessionId,
  }) async {
    _enteredCalls++;
    var id = 'invalid';
    var action = 'hello';
    try {
      if (raw is! Map ||
          raw.length != 4 ||
          !raw.keys.toSet().containsAll({
            'protocol',
            'requestId',
            'action',
            'arguments',
          }) ||
          raw['protocol'] is! int ||
          raw['protocol'] != backendHarnessProtocol ||
          raw['requestId'] is! String ||
          !_tokenPattern.hasMatch(raw['requestId'] as String) ||
          raw['action'] is! String ||
          raw['arguments'] is! Map) {
        return _reply(id, action, 'backend_invalid_request', state: 'blocked');
      }
      id = raw['requestId'] as String;
      final candidateAction = raw['action'] as String;
      if (!backendHarnessActions.contains(candidateAction)) {
        return _reply(id, action, 'backend_invalid_action', state: 'blocked');
      }
      action = candidateAction;
      final arguments = Map<String, Object?>.from(raw['arguments'] as Map);
      if (!_boundedJson(arguments) || jsonEncode(raw).length > 65536) {
        return _reply(
          id,
          action,
          'backend_invalid_arguments',
          state: 'blocked',
        );
      }
      if (!enabled) {
        return _reply(id, action, 'backend_disabled', state: 'blocked');
      }
      if (expectedSessionId != null && expectedSessionId != sessionId) {
        return _reply(id, action, 'backend_stale_session', state: 'blocked');
      }
      if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(source)) {
        return _reply(id, action, 'backend_source_mismatch', state: 'blocked');
      }
      if (action == 'hello') {
        if (arguments.isNotEmpty) {
          return _reply(
            id,
            action,
            'backend_invalid_arguments',
            state: 'blocked',
          );
        }
        return _reply(
          id,
          action,
          'backend_ready',
          data: {
            'source': source,
            'package': package,
            'platform': platform,
            'sessionId': sessionId,
            'mode': 'backend',
            'actions': <String>['hello', 'job.status', ..._operations.keys]
              ..sort(),
          },
        );
      }
      if (action == 'job.status') {
        if (arguments.length != 1 ||
            arguments['jobId'] is! String ||
            !_tokenPattern.hasMatch(arguments['jobId'] as String)) {
          return _reply(
            id,
            action,
            'backend_invalid_arguments',
            state: 'blocked',
          );
        }
        final job = _jobs[arguments['jobId']];
        return job == null
            ? _reply(id, action, 'backend_job_unknown', state: 'blocked')
            : _jobReply(id, action, job);
      }
      if (!_accepting) {
        return _reply(id, action, 'backend_busy', state: 'blocked');
      }
      final operation = _operations[action];
      if (operation == null) {
        return _reply(id, action, 'backend_not_supported', state: 'blocked');
      }
      if (!operation.validate(arguments)) {
        return _reply(
          id,
          action,
          'backend_invalid_arguments',
          state: 'blocked',
        );
      }
      if (!operation.background) {
        final payload = await operation.handler(arguments);
        return _reply(id, action, 'backend_ready', data: payload.toJson());
      }
      final digest = sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'action': action,
                'arguments': _canonical(arguments),
              }),
            ),
          )
          .toString();
      final previous = _requests[id];
      if (previous != null) {
        return previous.digest == digest
            ? _jobReply(id, action, previous)
            : _reply(id, action, 'backend_request_reused', state: 'blocked');
      }
      if (_active != null) {
        return _reply(id, action, 'backend_busy', state: 'blocked');
      }
      if (_jobs.length >= maximumJobs) {
        return _reply(id, action, 'backend_job_limit', state: 'blocked');
      }
      final job = _BackendHarnessJob(_token(), digest, operation.snapshot,
        id, action, _recoveryCorrelation(action, arguments));
      _jobs[job.id] = job;
      _requests[id] = job;
      _active = job;
      unawaited(
        Future<void>(() async {
          job.state = 'running';
          try {
            job.payload = (await operation.handler(arguments)).toJson();
            job.state = 'completed';
            job.code = 'backend_job_completed';
          } on BackendHarnessFailure catch (error) {
            job.state = 'blocked';
            job.code = error.code;
            job.payload = BackendHarnessPayload(
              phase: BackendHarnessPhase.error,
              flags: {'outcome_uncertain': operation.uncertainOnFailure && !error.effectNotEntered},
            ).toJson();
          } catch (_) {
            job.state = 'failed';
            job.code = 'backend_job_failed';
            job.payload = BackendHarnessPayload(
              phase: BackendHarnessPhase.error,
              flags: {'outcome_uncertain': operation.uncertainOnFailure},
            ).toJson();
          } finally {
            if (identical(_active, job)) _active = null;
            _notifyDrained();
          }
        }),
      );
      return _jobReply(id, action, job);
    } on BackendHarnessFailure catch (error) {
      return _reply(id, action, error.code, state: 'blocked');
    } catch (_) {
      return _reply(id, action, 'backend_internal_error', state: 'failed');
    } finally {
      _enteredCalls--;
      _notifyDrained();
    }
  }

  Map<String, Object?> _jobReply(
    String id,
    String action,
    _BackendHarnessJob job,
  ) {
    var payload = job.payload;
    if (const {'accepted', 'running'}.contains(job.state) &&
        job.snapshot != null) {
      try {
        payload = job.snapshot!.call().toJson();
      } catch (_) {
        // Observation failure cannot erase an accepted operation's handle or
        // make the host believe that its backend invocation never happened.
      }
    }
    return _reply(
      id,
      action,
      const {'accepted', 'running'}.contains(job.state) && payload.containsKey('challenge')
          ? 'backend_auth_challenge' : job.code,
      state: job.state,
      jobId: job.id,
      data: payload,
    );
  }

  static bool _boundedJson(Object? value, [int depth = 0]) {
    if (depth > 8) return false;
    if (value == null || value is bool || value is String || value is int) {
      return true;
    }
    if (value is List) {
      return value.length <= 128 &&
          value.every((entry) => _boundedJson(entry, depth + 1));
    }
    if (value is Map) {
      return value.length <= 32 &&
          value.entries.every(
            (entry) =>
                entry.key is String && _boundedJson(entry.value, depth + 1),
          );
    }
    return false;
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}

final class _BackendHarnessJob {
  _BackendHarnessJob(
    this.id,
    this.digest,
    this.snapshot,
    this.requestId,
    this.action,
    this.recoveryCorrelation,
  );
  final String id;
  final String digest;
  final BackendHarnessPayload Function()? snapshot;
  final String requestId;
  final String action;
  final Map<String, String>? recoveryCorrelation;
  String state = 'accepted';
  String code = 'backend_job_accepted';
  Map<String, Object> payload = const {};
}
