import 'dart:async';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart'
    show CloudKitOperationInterlockException;

/// One drain per engine, shared by lifecycle and queue completion. The callbacks
/// are the real production admission barrier and native release, not timers.
class EngineExitCoordinator {
  EngineExitCoordinator({
    required this.canExit,
    required this.drain,
    required this.resumeAdmission,
    required this.releaseEngine,
    required this.onError,
    this.onStalled,
    this.stallAfter = const Duration(seconds: 30),
  });

  final bool Function() canExit;
  final Future<void> Function() drain;
  final void Function() resumeAdmission;
  final Future<void> Function() releaseEngine;
  final void Function(Object) onError;
  final void Function()? onStalled;
  final Duration stallAfter;
  Future<void>? _pending;
  Completer<void>? _workDrained;
  int _ownedWork = 0;
  bool _closing = false;
  int _generation = 0;

  void cancel() {
    _generation++;
    _closing = false;
    resumeAdmission();
  }

  /// Retain the complete direct UI operation, including any receipt handling
  /// after its protected preparation lock has been released.
  Future<T> retain<T>(Future<T> Function() operation) async {
    if (_closing) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_busy',
      );
    }
    _ownedWork++;
    try {
      return await operation();
    } finally {
      if (--_ownedWork == 0) {
        final drained = _workDrained;
        _workDrained = null;
        drained?.complete();
      }
    }
  }

  Future<void> request() {
    if (!canExit()) return Future<void>.value();
    final pending = _pending;
    if (pending != null) return pending;
    final generation = _generation;
    _closing = true;
    final completion = Completer<void>();
    _pending = completion.future;
    unawaited(_run(generation, completion));
    return completion.future;
  }

  Future<void> _run(int generation, Completer<void> completion) async {
    // Diagnostic only: expiry cannot release, cancel, or complete owned work.
    final watchdog = onStalled == null
        ? null
        : Timer(stallAfter, () {
            if (generation == _generation && canExit()) onStalled!();
          });
    try {
      if (_ownedWork > 0) {
        await (_workDrained ??= Completer<void>()).future;
      }
      if (generation != _generation || !canExit()) return;
      await drain();
      if (generation == _generation && canExit()) await releaseEngine();
    } catch (error) {
      onError(error);
    } finally {
      _pending = null;
      watchdog?.cancel();
      completion.complete();
      // A resume/queue arrival superseded the old request. If that work has
      // since finished and the host is detached again, take a fresh barrier.
      if (generation != _generation && canExit()) unawaited(request());
    }
  }
}
