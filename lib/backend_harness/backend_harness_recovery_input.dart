import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_recovery_input.dart';

import 'backend_harness_interactions.dart';
import 'backend_harness_protocol.dart';

final class BackendHarnessRecoveryInput {
  BackendHarnessRecoveryInput(this.interactions);
  final BackendHarnessInteractions interactions;
  List<String>? _deviceNames;
  String? _passwordDevice;

  late final input = CloudSyncRecoveryInput(
    chooseDevice: (names, stillCurrent) async {
      final captured = List<String>.unmodifiable(names);
      _deviceNames = captured;
      try {
        return await interactions.chooseDevice(
          count: captured.length,
          stillCurrent: stillCurrent,
        );
      } finally {
        if (identical(_deviceNames, captured)) _deviceNames = null;
      }
    },
    password: (name, stillCurrent) async {
      _passwordDevice = name;
      try {
        return await interactions.secret(
          BackendHarnessChallengeKind.passcode,
          stillCurrent: stillCurrent,
        );
      } finally {
        _passwordDevice = null;
      }
    },
  );

  static bool validAnswer(Map<String, Object?> args) {
    if (args['challengeId'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(args['challengeId'] as String)) {
      return false;
    }
    final keys = args.keys.toSet();
    if (keys.length == 2 && keys.containsAll({'challengeId', 'cancel'})) {
      return args['cancel'] == true;
    }
    if (keys.length == 2 && keys.containsAll({'challengeId', 'index'})) {
      return args['index'] is int &&
          (args['index'] as int) >= 0 &&
          (args['index'] as int) < 64;
    }
    if (keys.length == 2 && keys.containsAll({'challengeId', 'deviceName'})) {
      return args['deviceName'] is String &&
          (args['deviceName'] as String).isNotEmpty;
    }
    return keys.containsAll({'challengeId', 'secret'}) &&
        keys.length <= 3 &&
        keys.every(const {'challengeId', 'secret', 'deviceName'}.contains) &&
        args['secret'] is String &&
        (args['secret'] as String).isNotEmpty &&
        (args['secret'] as String).length <= 1024 &&
        (!args.containsKey('deviceName') || args['deviceName'] is String);
  }

  void answer(Map<String, Object?> args) {
    if (!validAnswer(args)) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final challenge = interactions.pending;
    if (challenge == null) throw BackendHarnessFailure('backend_not_ready');
    if (challenge.kind == BackendHarnessChallengeKind.verificationCode ||
        challenge.kind == BackendHarnessChallengeKind.smsDestination) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    final id = args['challengeId'] as String;
    if (id != challenge.id) {
      throw BackendHarnessFailure('backend_stale_session');
    }
    if (args['cancel'] == true) {
      interactions.cancel(id);
      return;
    }
    if (challenge.kind == BackendHarnessChallengeKind.trustedDevice) {
      var index = args['index'] as int?;
      if (args['deviceName'] is String && !args.containsKey('secret')) {
        final matches = <int>[];
        final names = _deviceNames ?? const <String>[];
        for (var n = 0; n < names.length; n++) {
          if (names[n] == args['deviceName']) matches.add(n);
        }
        if (matches.length == 1) index = matches.single;
      }
      if (index == null || args.containsKey('secret')) {
        throw BackendHarnessFailure('backend_invalid_arguments');
      }
      interactions.answerChoice(id, index);
    } else {
      if (args['secret'] is! String ||
          (args.containsKey('deviceName') &&
              args['deviceName'] != _passwordDevice)) {
        throw BackendHarnessFailure('backend_invalid_arguments');
      }
      interactions.answerSecret(id, args['secret'] as String);
    }
  }
}
