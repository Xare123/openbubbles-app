import 'dart:async';
import 'dart:math';

import 'backend_harness_protocol.dart';

/// Replaces a test app's dialog interaction with a bounded, identity-bound
/// challenge. It supplies input to the existing backend; it never marks an
/// account authenticated or encryption ready.
final class BackendHarnessInteractions {
  BackendHarnessInteractions({Random? random})
    : _random = random ?? Random.secure();
  final Random _random;
  _PendingInteraction? _pending;
  BackendHarnessChallenge? get pending => _pending?.challenge;

  String _token() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<int?> chooseDevice({
    required int count,
    required bool Function() stillCurrent,
    Duration deadline = const Duration(minutes: 2),
    BackendHarnessChallengeKind kind =
        BackendHarnessChallengeKind.trustedDevice,
  }) async {
    if (!kind.isChoice || count < 1 || count > 64) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final answer = await _request(kind, count, stillCurrent, deadline);
    return answer as int?;
  }

  Future<String?> secret(
    BackendHarnessChallengeKind kind, {
    required bool Function() stillCurrent,
    Duration deadline = const Duration(minutes: 2),
  }) async {
    if (kind.isChoice) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final answer = await _request(kind, 0, stillCurrent, deadline);
    return answer as String?;
  }

  Future<Object?> _request(
    BackendHarnessChallengeKind kind,
    int options,
    bool Function() stillCurrent,
    Duration deadline,
  ) {
    if (_pending != null) throw BackendHarnessFailure('backend_busy');
    if (deadline <= Duration.zero || deadline > const Duration(minutes: 5)) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    if (!stillCurrent()) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    final pending = _PendingInteraction(
      BackendHarnessChallenge(_token(), kind, options: options),
      stillCurrent,
    );
    _pending = pending;
    pending.expiry = Timer(deadline, () => _finish(pending, null));
    return pending.answer.future;
  }

  void answerChoice(String id, int index) {
    final pending = _requireCurrent(id);
    if (!pending.challenge.kind.isChoice ||
        index < 0 ||
        index >= pending.challenge.options) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    _finish(pending, index);
  }

  void answerSecret(String id, String value) {
    final pending = _requireCurrent(id);
    if (pending.challenge.kind.isChoice ||
        value.isEmpty ||
        value.length > 1024 ||
        value.contains('\u0000')) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    _finish(pending, value);
  }

  void cancel(String id) => _finish(_requireCurrent(id), null);

  _PendingInteraction _requireCurrent(String id) {
    final pending = _pending;
    if (pending == null || pending.challenge.id != id) {
      throw BackendHarnessFailure('backend_stale_session');
    }
    if (!pending.stillCurrent()) {
      _finish(pending, null);
      throw BackendHarnessFailure('backend_identity_changed');
    }
    return pending;
  }

  void _finish(_PendingInteraction pending, Object? answer) {
    if (!identical(_pending, pending)) return;
    _pending = null;
    pending.expiry?.cancel();
    if (!pending.answer.isCompleted) pending.answer.complete(answer);
  }

  /// App-owned teardown resolves an outstanding prompt as canceled. It does
  /// not cancel a native operation or remove any lease, receipt or message.
  void close() {
    final pending = _pending;
    if (pending != null) _finish(pending, null);
  }
}

final class _PendingInteraction {
  _PendingInteraction(this.challenge, this.stillCurrent);
  final BackendHarnessChallenge challenge;
  final bool Function() stillCurrent;
  final answer = Completer<Object?>();
  Timer? expiry;
}
