import 'dart:io';

import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/setup_interaction_port.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;

import 'backend_harness_interactions.dart';
import 'backend_harness_protocol.dart';

/// Presentation adapter over the real setup controller. No hidden widgets,
/// review login, imported account DB, reset, send or synthetic completion.
final class BackendHarnessAccount implements SetupInteractionPort {
  BackendHarnessAccount(this.interactions) {
    setupController = SetupViewController(interactionPort: this);
    setupController.updateObx = (operation) => operation();
  }
  final BackendHarnessInteractions interactions;
  late final SetupViewController setupController;
  BackendHarnessPhase phase = BackendHarnessPhase.needs_credentials;
  int? _attempt;
  List<String>? _smsDestinations;

  static bool validRelay(Map<String, Object?> args) =>
      args.length == 3 &&
      args.keys.every(const {'host', 'code', 'token'}.contains) &&
      args['host'] == 'https://registration-relay.beeper.com' &&
      args['code'] is String &&
      RegExp(
        r'^[A-Z0-9]{4}(?:-[A-Z0-9]{4}){3}$',
      ).hasMatch(args['code'] as String) &&
      args['token'] is String &&
      RegExp(r'^[\x21-\x7e]{1,8192}$').hasMatch(args['token'] as String);

  static bool validLogin(Map<String, Object?> args) =>
      args.length == 2 &&
      args.keys.every(const {'appleId', 'password'}.contains) &&
      args['appleId'] is String &&
      (args['appleId'] as String).length <= 320 &&
      RegExp(r'^[^\s@]+@[^\s@]+$').hasMatch(args['appleId'] as String) &&
      args['password'] is String &&
      (args['password'] as String).isNotEmpty &&
      (args['password'] as String).length <= 1024 &&
      !(args['password'] as String).contains('\u0000');

  static bool validCode(Map<String, Object?> args) {
    if (args.length != 2 ||
        args['challengeId'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(args['challengeId'] as String)) {
      return false;
    }
    if (args['cancel'] == true) return true;
    if (args['secret'] is String) {
      return RegExp(r'^[0-9]{6}$').hasMatch(args['secret'] as String);
    }
    if (args['index'] is int) {
      return (args['index'] as int) >= 0 && (args['index'] as int) < 64;
    }
    return args['destination'] is String &&
        (args['destination'] as String).isNotEmpty &&
        (args['destination'] as String).length <= 128;
  }

  void answer(Map<String, Object?> args) {
    if (!validCode(args)) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final challenge = interactions.pending;
    if (challenge == null ||
        !const {
          BackendHarnessChallengeKind.verificationCode,
          BackendHarnessChallengeKind.smsDestination,
        }.contains(challenge.kind)) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    final id = args['challengeId'] as String;
    if (id != challenge.id) {
      throw BackendHarnessFailure('backend_stale_session');
    }
    if (args['cancel'] == true) {
      interactions.cancel(id);
    } else if (challenge.kind == BackendHarnessChallengeKind.verificationCode) {
      if (args['secret'] is! String) {
        throw BackendHarnessFailure('backend_invalid_arguments');
      }
      interactions.answerSecret(id, args['secret'] as String);
    } else {
      var index = args['index'] as int?;
      if (args['destination'] is String) {
        final names = _smsDestinations ?? const <String>[];
        final matches = <int>[
          for (var n = 0; n < names.length; n++)
            if (names[n] == args['destination']) n,
        ];
        if (matches.length == 1) index = matches.single;
      }
      if (index == null) {
        throw BackendHarnessFailure('backend_invalid_arguments');
      }
      interactions.answerChoice(id, index);
    }
  }

  Future<BackendHarnessPayload> restore(Map<String, Object?> _) async {
    phase = BackendHarnessPhase.configuring;
    await pushService.initFuture;
    if (pushService.state != null) return inspect(const {});
    final c = setupController;
    if (c.config == null) {
      final saved = api.readHardware(path: pushService.statePath);
      if (saved != null) {
        await c.restoreSavedHardware(saved);
        if (c.restoredConfigNeedsFreshIdentity || c.connection == null) {
          phase = BackendHarnessPhase.blocked;
          throw BackendHarnessFailure('backend_not_ready');
        }
        await c.restoreCachedPhoneUsers();
      }
    }
    final config = c.config;
    if (config != null) {
      final info = await api.getDeviceInfo(config: config);
      if (!identical(config, c.config) || pushService.state != null) {
        throw BackendHarnessFailure('backend_identity_changed');
      }
      c.supportsPhoneReg.value = const [
        'iPhone',
        'iPod',
        'iPad',
      ].any(info.name.contains);
    }
    phase = BackendHarnessPhase.needs_credentials;
    return snapshot();
  }

  Future<BackendHarnessPayload> configure(Map<String, Object?> args) async {
    await restore(const {});
    final c = setupController;
    if (pushService.state != null ||
        c.currentAppleAccount != null ||
        c.currentAppleUser != null ||
        c.restoredConfigNeedsFreshIdentity) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    phase = BackendHarnessPhase.configuring;
    final candidate = await api.configFromRelay(
      host: args['host'] as String,
      code: args['code'] as String,
      token: args['token'] as String,
    );
    var adopted = false;
    try {
      final info = await api.getDeviceInfo(config: candidate);
      if (!const ['iPhone', 'iPod', 'iPad'].any(info.name.contains)) {
        throw BackendHarnessFailure('backend_not_supported');
      }
      if (c.config != null) {
        // Matching retained identity is required. A failed match never falls
        // through to fresh identity, cached-phone removal or reactivation.
        if (!await c.reuseNativeRelaySetup(candidate)) {
          throw BackendHarnessFailure('backend_identity_changed');
        }
      } else {
        if (c.connection != null ||
            c.identity != null ||
            c.cachedState != null ||
            c.anisette != null ||
            c.currentPhoneUsers.isNotEmpty) {
          throw BackendHarnessFailure('backend_not_ready');
        }
        c.identity = api.newNgmIdentity();
        c.config = candidate;
        adopted = true;
        await c.setupConnection();
      }
      c.supportsPhoneReg.value = true;
      ss.settings.macIsMine.value = true;
      ss.settings.deviceIsHosted.value = false;
      await ss.saveSettings();
      phase = BackendHarnessPhase.needs_credentials;
      return snapshot();
    } finally {
      if (!adopted &&
          !identical(c.config, candidate) &&
          !candidate.isDisposed) {
        candidate.dispose();
      }
    }
  }

  Future<BackendHarnessPayload> login(Map<String, Object?> args) async {
    await restore(const {});
    final c = setupController;
    if (pushService.state != null ||
        ss.settings.finishedSetup.value ||
        c.currentAppleAccount != null ||
        c.currentAppleUser != null ||
        c.config == null ||
        c.connection == null ||
        c.anisette == null) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    phase = BackendHarnessPhase.configuring;
    final attempt = c.beginLoginAttempt();
    _attempt = attempt;
    final appleId = (args['appleId'] as String).toLowerCase();
    final password = args['password'] as String;
    try {
      final (account, initial) = await c.withLoginAttemptResources(
        attempt,
        [c.config, c.connection, c.anisette],
        () => api.tryAuth(
          path: pushService.statePath,
          conf: c.config!,
          conn: c.connection!,
          anisette: c.anisette!,
          creds: (appleId, password),
        ),
      );
      c.replaceCurrentAppleAccount(account, attempt: attempt);
      _requireCurrent(attempt);
      await c.completeAuthenticatedAppleLogin(
        initial,
        account,
        attempt: attempt,
      );
      _requireCurrent(attempt);
      var state = await c.updateLoginState(initial, attempt: attempt);
      _requireCurrent(attempt);
      ss.settings.iCloudAccount.value = appleId;
      c.twoFaCreds = (appleId, password);
      // A bad code may yield another server-issued verification state. No
      // implicit retry: each iteration requires a new opaque input challenge.
      while (state is api.LoginState_Needs2FAVerification ||
          state is api.LoginState_NeedsSMS2FAVerification) {
        phase = state is api.LoginState_NeedsSMS2FAVerification
            ? BackendHarnessPhase.needs_sms_2fa
            : BackendHarnessPhase.needs_2fa;
        final code = await interactions.secret(
          BackendHarnessChallengeKind.verificationCode,
          stillCurrent: () =>
              c.isLoginAttemptCurrent(attempt) &&
              identical(c.currentAppleAccount, account),
        );
        if (code == null) {
          phase = BackendHarnessPhase.blocked;
          throw BackendHarnessFailure('backend_not_ready');
        }
        _requireCurrent(attempt);
        phase = BackendHarnessPhase.registering;
        state = await c.submitCode(code, attempt: attempt);
        _requireCurrent(attempt);
      }
      if (state is! api.LoginState_LoggedIn || !c.success) {
        phase = BackendHarnessPhase.blocked;
        throw BackendHarnessFailure('backend_not_ready');
      }
      await ss.saveSettings();
      return inspect(const {});
    } catch (_) {
      phase = BackendHarnessPhase.blocked;
      rethrow;
    } finally {
      // Clear credentials in the presentation layer, preserving every native
      // operation/account handle and outcome for observation or recovery.
      c.twoFaCreds = null;
      if (_attempt == attempt) _attempt = null;
    }
  }

  void _requireCurrent(int attempt) {
    if (!setupController.isLoginAttemptCurrent(attempt)) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
  }

  /// Authenticate only this retained host's read session. A successful fresh
  /// account is followed by independent verification on the original client.
  Future<BackendHarnessPayload> readAuthenticate(Map<String, Object?> args) async {
    if (args.isNotEmpty || !Platform.isWindows) {
      throw BackendHarnessFailure('backend_invalid_arguments', effectNotEntered: true);
    }
    rustlib.ArcMutexAppleAccountDefaultAnisetteProvider? heldAccount;
    phase = BackendHarnessPhase.configuring;
    try {
      await pushService.authenticateWindowsBackendRead((current) async {
        final storage = pushService.statePath;
        bool stillCurrent() => identical(current, pushService.state) &&
            storage == pushService.statePath && ss.settings.finishedSetup.value;
        void validate() {
          if (!stillCurrent()) throw BackendHarnessFailure('backend_identity_changed');
        }
        validate();
        // Omitted credentials use the saved encrypted digest. Native Windows
        // profile admission avoids onboarding and retained-state replacement.
        final result = await api.tryAuth(
          path: storage, conf: current.osConfig,
          conn: current.conn, anisette: current.anisette,
        );
        final account = result.$1;
        heldAccount = account;
        validate();
        var login = result.$2;
        if (login is api.LoginState_NeedsDevice2FA || login is api.LoginState_NeedsSMS2FA) {
          // Match the existing Windows read harness's normal SMS choice path.
          final options = await api.get2FaSmsOpts(state: account);
          validate();
          final pending = options.$2;
          if (pending != null) {
            login = pending;
          } else {
            final phones = options.$1;
            if (phones.isEmpty || phones.length > 64) {
              throw BackendHarnessFailure('backend_read_auth_rejected');
            }
            phase = BackendHarnessPhase.needs_sms_2fa;
            final index = phones.length == 1 ? 0 : await interactions.chooseDevice(
              count: phones.length, kind: BackendHarnessChallengeKind.smsDestination,
              stillCurrent: stillCurrent,
            );
            validate();
            if (index == null) throw BackendHarnessFailure('backend_not_ready');
            login = await api.send2FaSms(account: account, phoneId: phones[index].id);
            validate();
          }
        }
        (api.LoginState, api.IdsUser?)? verified;
        if (login is api.LoginState_Needs2FAVerification ||
            login is api.LoginState_NeedsSMS2FAVerification) {
          phase = login is api.LoginState_NeedsSMS2FAVerification
              ? BackendHarnessPhase.needs_sms_2fa : BackendHarnessPhase.needs_2fa;
          final code = await interactions.secret(
            BackendHarnessChallengeKind.verificationCode, stillCurrent: stillCurrent,
          );
          validate();
          if (code == null) throw BackendHarnessFailure('backend_not_ready');
          phase = BackendHarnessPhase.configuring;
          if (login is api.LoginState_NeedsSMS2FAVerification) {
            verified = await api.verify2FaSms(
              path: storage, accountMut: account, anisette: current.anisette,
              config: current.osConfig, body: login.field0, code: code,
            );
          } else {
            verified = await api.verify2FaDirect(
              path: storage, account: account, osConfig: current.osConfig, code: code,
            );
          }
          validate();
          login = verified.$1;
          if (verified.$2 != null) {
            verified.$2!.dispose();
            throw BackendHarnessFailure('backend_identity_changed');
          }
        }
        if (login is! api.LoginState_LoggedIn) {
          throw BackendHarnessFailure('backend_read_auth_rejected');
        }
      });
      phase = BackendHarnessPhase.idle;
      return readAuthenticationReady();
    } catch (error) {
      phase = BackendHarnessPhase.blocked;
      if (error is BackendHarnessFailure) rethrow;
      final changed = error is StateError &&
          error.message == 'cloud_sync_retained_read_auth_changed';
      throw BackendHarnessFailure(changed ? 'backend_identity_changed' : 'backend_read_auth_failed');
    } finally {
      // Keep the fresh account alive through the original client's proof;
      // do not replace or dispose any of the retained service's handles.
      heldAccount?.dispose();
    }
  }

  static BackendHarnessPayload readAuthenticationReady() =>
      const BackendHarnessPayload(flags: {
        'read_auth_ready': true,
        'existing_native_client_retained': true,
      });

  Future<BackendHarnessPayload> repair(Map<String, Object?> args) async {
    if (args.isNotEmpty) {
      throw BackendHarnessFailure('backend_invalid_arguments', effectNotEntered: true);
    }
    await pushService.initFuture;
    final current = pushService.state;
    final client = current?.icloudServices?.cloudMessagesClient;
    final storage = pushService.statePath;
    bool stillCurrent() => current != null && client != null &&
        identical(current, pushService.state) &&
        identical(client, pushService.state?.icloudServices?.cloudMessagesClient) &&
        storage == pushService.statePath && ss.settings.finishedSetup.value;
    phase = BackendHarnessPhase.registering;
    try {
      final result = await repairRetainedRegistration(
        stillCurrent: stillCurrent,
        captureIdentity: () async => client == null ? null :
            await api.cloudSyncCaptureReceivedIdentity(
              cloudMessagesClient: client, storageDirectory: storage),
        // Windows terminal rejection needs fresh credentials and a restart.
        // Other clients retain the ordinary Profile action and its interlock.
        refresh: Platform.isWindows
            ? pushService.refreshWindowsBackendRegistrationCredentials
            : pushService.reregisterIdentity,
        restartAfterRefresh: Platform.isWindows,
        credentialsEffectEntered: Platform.isWindows
            ? () => pushService.backendRegistrationRestartRequired : null,
        isRegistered: () async => current != null &&
            await api.getRegstate(state: current.client) is api.RegisterState_Registered,
      );
      phase = result.phase;
      return result;
    } catch (error) {
      phase = BackendHarnessPhase.blocked;
      final classified = classifyRegistrationFailure(error);
      if (classified != null) throw classified;
      rethrow;
    }
  }

  /// Fixed diagnostics only. A recognized native registration rejection remains
  /// uncertain and never authorizes retry, message delivery or a new identity.
  static BackendHarnessFailure? classifyRegistrationFailure(Object error) {
    if (error is BackendHarnessFailure) return null;
    if (error is CloudKitOperationInterlockException) {
      return BackendHarnessFailure(
        error.safeCode == 'cloudkit_interlock_busy' ? 'backend_busy' : 'backend_not_ready',
        effectNotEntered: const {
          'cloudkit_interlock_busy', 'cloudkit_interlock_unavailable',
          'cloudkit_interlock_profile_mismatch', 'cloudkit_interlock_mode_violation',
        }.contains(error.safeCode),
      );
    }
    if (RegExp(r'Registration Error[^\r\n]{0,220}\(6005\)').hasMatch(error.toString())) {
      return BackendHarnessFailure('backend_registration_rejected');
    }
    return null;
  }

  /// Fresh registration is separate from a cached Registered observation.
  /// The callbacks let the ordinary native operation keep its lifetime while
  /// offline regressions cover stale identity and failed/unfinished refreshes.
  static Future<BackendHarnessPayload> repairRetainedRegistration({
    required bool Function() stillCurrent,
    required Future<api.CloudSyncNativeAuthMetadata?> Function() captureIdentity,
    required Future<void> Function() refresh,
    required Future<bool> Function() isRegistered,
    bool restartAfterRefresh = false,
    bool Function()? credentialsEffectEntered,
  }) async {
    var entered = false;
    void requireCurrent() {
      if (!stillCurrent()) {
        throw BackendHarnessFailure('backend_identity_changed', effectNotEntered: !entered);
      }
    }
    requireCurrent();
    final before = await captureIdentity();
    requireCurrent();
    if (before == null || !validCachedIdentity(before)) {
      throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
    }
    entered = true;
    try {
      await refresh();
    } catch (_) {
      if (restartAfterRefresh && credentialsEffectEntered?.call() == false) {
        throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
      }
      rethrow;
    }
    requireCurrent();
    final registered = restartAfterRefresh ? false : await isRegistered();
    requireCurrent();
    final after = await captureIdentity();
    requireCurrent();
    if (after == null || !validCachedIdentity(after) ||
        before.accountFingerprint != after.accountFingerprint ||
        before.protectedStoreIdentity != after.protectedStoreIdentity ||
        before.nativeSessionId != after.nativeSessionId) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    if (restartAfterRefresh) {
      return const BackendHarnessPayload(
        phase: BackendHarnessPhase.blocked,
        flags: {
          'native_client_present': true,
          'native_identity_available': true,
          'registration_ready': false,
          'credentials_refreshed': true,
          'restart_required': true,
        },
      );
    }
    if (!registered) throw BackendHarnessFailure('backend_not_ready');
    return const BackendHarnessPayload(flags: {
      'native_client_present': true,
      'native_identity_available': true,
      'registration_ready': true,
      'registration_refreshed': true,
    });
  }

  Future<BackendHarnessPayload> inspect(Map<String, Object?> _) async {
    await pushService.initFuture;
    final current = pushService.state;
    if (current == null) return snapshot();
    final registration = await api.getRegstate(state: current.client);
    if (!identical(current, pushService.state)) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    final client = current.icloudServices?.cloudMessagesClient;
    final storage = pushService.statePath;
    // This observation needs persisted composition identity. The writer
    // snapshot requires refreshed GSA SPD and is unavailable on a cold boot.
    // External operations still establish their normal fresh read/write permit.
    final identity = client == null
        ? null
        : await api.cloudSyncCaptureReceivedIdentity(
            cloudMessagesClient: client,
            storageDirectory: storage,
          );
    if (!identical(current, pushService.state) ||
        !identical(
          client,
          pushService.state?.icloudServices?.cloudMessagesClient,
        ) ||
        storage != pushService.statePath) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    final validIdentity = identity != null && validCachedIdentity(identity);
    final restartRequired = pushService.backendAuthenticationRestartRequired;
    final registered = registration is api.RegisterState_Registered &&
        !pushService.backendRegistrationRestartRequired;
    // Native metadata binds identity; it does not prove fresh network auth.
    // The normal semantic read still owns read-auth refresh under its interlock.
    phase = registered && validIdentity
        ? BackendHarnessPhase.idle
        : BackendHarnessPhase.blocked;
    return BackendHarnessPayload(
      phase: phase,
      flags: {
        'native_client_present': true,
        ...registrationObservation(registration),
        'registration_ready': registered,
        'restart_required': restartRequired,
        'native_identity_available': validIdentity,
        'setup_finished': ss.settings.finishedSetup.value,
      },
    );
  }

  static Map<String, bool> registrationObservation(api.RegisterState state) => {
    'registration_ready': state is api.RegisterState_Registered,
    'registration_resource_failed': state is api.RegisterState_Failed,
    'registration_rejected': state is api.RegisterState_Failed &&
        classifyRegistrationFailure(state.error)?.code == 'backend_registration_rejected',
    'registration_retry_available': state is api.RegisterState_Failed && state.retryWait != null,
  };

  static bool validCachedIdentity(api.CloudSyncNativeAuthMetadata identity) =>
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(identity.nativeSessionId) &&
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(identity.accountFingerprint) &&
      RegExp(
        r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
      ).hasMatch(identity.protectedStoreIdentity);

  BackendHarnessPayload snapshot({bool retainedRelayResources = false}) {
    final c = setupController;
    return BackendHarnessPayload(
      phase: phase,
      flags: {
        'relay_ready':
            (c.config != null && c.connection != null && c.anisette != null) ||
            retainedRelayResources,
      },
      challenge: interactions.pending,
    );
  }

  @override
  Future<T> wait<T>(Future<T> operation) => operation;

  @override
  Future<int?> chooseSmsDestination(
    List<String> privateLabels, {
    required bool Function() stillCurrent,
  }) async {
    final captured = List<String>.unmodifiable(privateLabels);
    _smsDestinations = captured;
    try {
      return await interactions.chooseDevice(
        count: captured.length,
        kind: BackendHarnessChallengeKind.smsDestination,
        stillCurrent: stillCurrent,
      );
    } finally {
      if (identical(_smsDestinations, captured)) _smsDestinations = null;
    }
  }

  @override
  Future<void> registrationSupportRequired() async {
    phase = BackendHarnessPhase.blocked;
    throw BackendHarnessFailure('backend_not_supported');
  }
}
