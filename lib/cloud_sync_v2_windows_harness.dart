import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_preflight.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector_health.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
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

  fs.configureCloudSyncV2WindowsDevProfile();
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

    runApp(CloudSyncV2WindowsHarness(runOnce: arguments.contains('run-once')));
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

Future<void> _harnessStatusWriteTail = Future<void>.value();
var _harnessStatusTemporarySequence = 0;

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
  final payload = <String, Object?>{
    'version': 'cloud-sync-v2-windows-harness-status-v1',
    'state': state,
    'stage': stage,
    'updated_utc': DateTime.now().toUtc().toIso8601String(),
    if (safeCode != null) 'safe_code': safeCode,
    if (errorType != null) 'error_type': errorType,
    if (detail != null) 'detail': detail,
    if (stack != null) 'stack': stack,
  };
  await temporary.writeAsString(jsonEncode(payload), flush: true);
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);
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
  const CloudSyncV2WindowsHarness({super.key, required this.runOnce});

  final bool runOnce;

  @override
  State<CloudSyncV2WindowsHarness> createState() =>
      _CloudSyncV2WindowsHarnessState();
}

class _CloudSyncV2WindowsHarnessState extends State<CloudSyncV2WindowsHarness> {
  final List<Object> _sessionHandles = <Object>[];
  final TextEditingController _twoFactorController = TextEditingController();
  Object? _activeClient;
  rustlib.ArcAnisetteClientDefaultAnisetteProvider? _anisette;
  rustlib.ArcMutexAppleAccountDefaultAnisetteProvider? _account;
  api.JoinedOsConfig? _osConfig;
  api.VerifyBody? _smsVerificationBody;
  List<api.TrustedPhoneNumber> _smsPhoneOptions = const [];
  CloudSyncProductionSemanticPullAdapter? _adapter;
  CloudSyncSemanticPullReport? _report;
  String _status = 'Opening the isolated Windows profile...';
  String _runtimeStage = 'initializing';
  bool _needsTwoFactor = false;
  bool _busy = true;

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
    try {
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
        _account = account;
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
          hardware,
          identity,
          config,
          connection,
          anisette,
          account,
          tokenProvider,
          cloudkit,
          keychain,
          cloudMessagesClient,
        ]);
        _activeClient = cloudMessagesClient;
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
      _adapter = CloudSyncProductionSemanticPullAdapter(
        readActiveClient: () => _activeClient,
        readPreflight: preflight.read,
        privateStorageDirectory: fs.appDocDir.path,
        platform: Platform.operatingSystem,
        architecture: ffi.Abi.current().toString(),
        buildCommit: _buildIdentifier(),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Ready. The Store app must remain closed while this runs.';
      });
      await _setRuntimeStage('cloudkit-client-ready', state: 'ready');
      if (widget.runOnce) await _runSemanticPull();
    } catch (error) {
      if (cloudSyncV2SafeFailureCode(error) ==
          'cloud_sync_native_auth_refresh_session_missing') {
        try {
          if (await _prepareSmsTwoFactor()) return;
        } catch (_) {
          _showFailure(StateError('cloud_sync_windows_dev_2fa_request_failed'));
          return;
        }
      }
      _showFailure(error);
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
      _twoFactorController.clear();
      if (!mounted) return;
      setState(() {
        _needsTwoFactor = false;
        _smsVerificationBody = null;
        _busy = false;
        _status = 'SMS verification succeeded. Resuming the pull...';
      });
      await _setRuntimeStage('sms-2fa-verified', state: 'running');
      await _runSemanticPull();
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

  Future<void> _runSemanticPull() async {
    final adapter = _adapter;
    if (adapter == null || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Running one bounded, read-only semantic pull...';
    });
    await _setRuntimeStage('semantic-pull', state: 'running');
    try {
      final report = await adapter.sampler.runConfirmed();
      final reportFile = await CloudSyncSemanticPullReportFileWriter(
        privateReportDirectory: path.join(
          fs.appDocDir.path,
          'cloud-sync-v2',
          'reports',
        ),
        trustedStorageRoot: fs.appDocDir.path,
      ).write(report);
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
            'report=${path.basename(reportFile.path)}',
      );
    } catch (error) {
      if (cloudSyncV2SafeFailureCode(error) ==
          'cloud_sync_native_auth_refresh_session_missing') {
        try {
          if (await _prepareSmsTwoFactor()) return;
        } catch (_) {
          _showFailure(StateError('cloud_sync_windows_dev_2fa_request_failed'));
          return;
        }
      }
      _showFailure(error);
    }
  }

  void _showFailure(Object error) {
    if (!mounted) return;
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
    _twoFactorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Cloud Sync V2 Windows Harness')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
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
                          onPressed: _busy
                              ? null
                              : () => _sendSmsTwoFactor(phone),
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
