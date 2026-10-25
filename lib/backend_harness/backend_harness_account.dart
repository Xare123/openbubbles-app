import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/rustpush/setup_interaction_port.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

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
    final registered = registration is api.RegisterState_Registered;
    // Native metadata binds identity; it does not prove fresh network auth.
    // The normal semantic read still owns read-auth refresh under its interlock.
    phase = registered && validIdentity
        ? BackendHarnessPhase.idle
        : BackendHarnessPhase.blocked;
    return BackendHarnessPayload(
      phase: phase,
      flags: {
        'native_client_present': true,
        'registration_ready': registered,
        'native_identity_available': validIdentity,
        'setup_finished': ss.settings.finishedSetup.value,
      },
    );
  }

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
