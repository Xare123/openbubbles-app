import 'dart:async';

enum ICloudCliqueRefresh { unknown, pending, trusted, notTrusted }

/// A deadline limits follow-on work, not ownership of an uncancellable native
/// future. Startup and recurring maintenance must share this instance.
final class ICloudMaintenance {
  ICloudMaintenance({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;
  _MaintenanceRun? _active;
  _MaintenanceRun? _pending;
  ICloudCliqueRefresh cliqueRefresh = ICloudCliqueRefresh.unknown;

  Future<void> run({
    required Object stateIdentity,
    required bool Function() stillCurrent,
    Future<void> Function()? syncPasswords,
    Future<bool> Function()? readClique,
    required void Function(bool) publishClique,
    required bool Function() syncEnabled,
    required Future<void> Function() syncCloudKit,
    required void Function(String, Object, StackTrace) report,
  }) {
    // Stale triggers must not replace the latest current-state request.
    if (!stillCurrent()) return Future<void>.value();
    if (identical(_active?.stateIdentity, stateIdentity)) {
      return _active!.completion.future;
    }
    if (identical(_pending?.stateIdentity, stateIdentity)) {
      return _pending!.completion.future;
    }
    cliqueRefresh = ICloudCliqueRefresh.unknown;
    final request = _MaintenanceRun(stateIdentity, () async {
      if (!stillCurrent()) return;
      cliqueRefresh = ICloudCliqueRefresh.unknown;
      if (syncPasswords != null) {
        final result = await _step('passwords', syncPasswords, report);
        if (!result.completed || !stillCurrent()) return;
      }
      if (readClique != null) {
        cliqueRefresh = ICloudCliqueRefresh.pending;
        final result = await _step(
          'clique',
          readClique,
          report,
          onTimeout: () => cliqueRefresh = ICloudCliqueRefresh.unknown,
        );
        if (!result.completed || !stillCurrent()) {
          cliqueRefresh = ICloudCliqueRefresh.unknown;
          return;
        }
        final trusted = result.value!;
        cliqueRefresh = trusted
            ? ICloudCliqueRefresh.trusted
            : ICloudCliqueRefresh.notTrusted;
        publishClique(trusted);
      }
      if (stillCurrent() && syncEnabled()) {
        await _step('cloudkit', syncCloudKit, report);
      }
    });
    if (_active != null) {
      // Only one replacement is retained. Superseded waiters finish without
      // running their stale callbacks; no retry loop or native overlap.
      _pending?.completion.complete();
      _pending = request;
    } else {
      _start(request);
    }
    return request.completion.future;
  }

  void _start(_MaintenanceRun request) {
    _active = request;
    unawaited(() async {
      try {
        await request.execute();
        request.completion.complete();
      } catch (error, stack) {
        request.completion.completeError(error, stack);
      } finally {
        _active = null;
        final next = _pending;
        _pending = null;
        if (next != null) _start(next);
      }
    }());
  }

  void _reportSafely(
    void Function(String, Object, StackTrace) report,
    String phase,
    Object error,
    StackTrace stack,
  ) {
    try {
      report(phase, error, stack);
    } catch (_) {
      // Diagnostics must not throw from a timer or release native ownership.
    }
  }

  Future<({bool completed, T? value})> _step<T>(
    String phase,
    Future<T> Function() action,
    void Function(String, Object, StackTrace) report, {
    void Function()? onTimeout,
  }) async {
    var expired = false;
    final timer = Timer(timeout, () {
      expired = true;
      onTimeout?.call();
      _reportSafely(
        report,
        phase,
        TimeoutException('Native maintenance still pending', timeout),
        StackTrace.current,
      );
    });
    try {
      final value = await action();
      return (completed: !expired, value: value);
    } catch (error, stack) {
      // Observe late failures too; they must never become unhandled errors.
      _reportSafely(report, phase, error, stack);
      return (completed: false, value: null);
    } finally {
      timer.cancel();
    }
  }
}

final class _MaintenanceRun {
  _MaintenanceRun(this.stateIdentity, this.execute);

  final Object stateIdentity;
  final Future<void> Function() execute;
  final completion = Completer<void>();
}
