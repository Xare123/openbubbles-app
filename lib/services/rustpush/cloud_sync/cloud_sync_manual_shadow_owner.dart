import 'cloud_sync_manual_shadow_controller.dart';
import 'cloud_sync_shadow_report.dart';

typedef CloudSyncShadowControllerBuilder =
    Future<CloudSyncManualShadowController> Function();

/// Lazily owns the developer-only sampler across account lifecycle changes.
///
/// Account teardown closes admission before waiting for construction or an
/// active run. The owning Rust credentials can therefore be disposed only
/// after [quiesceForAccountTransition] completes. A later account may call
/// [resumeAfterAccountTransition], which forces a fresh controller.
final class CloudSyncManualShadowOwner {
  CloudSyncManualShadowOwner({required this.buildController});

  final CloudSyncShadowControllerBuilder buildController;
  CloudSyncManualShadowController? _controller;
  Future<CloudSyncManualShadowController>? _buildFuture;
  Future<void>? _quiesceFuture;
  int _generation = 0;
  bool _admissionOpen = true;
  bool _disposed = false;

  bool get isActive => _controller?.isActive ?? false;
  bool get isQuiescing => !_admissionOpen && !_disposed;
  bool get isDisposed => _disposed;

  Future<CloudSyncShadowReport> runConfirmedAndPersist() async {
    if (_disposed) throw StateError('cloud_sync_shadow_owner_disposed');
    if (!_admissionOpen) {
      throw StateError('cloud_sync_shadow_owner_quiescing');
    }
    final generation = _generation;
    final controller = await _controllerFor(generation);
    if (_disposed ||
        !_admissionOpen ||
        generation != _generation ||
        !identical(controller, _controller)) {
      throw StateError('cloud_sync_shadow_owner_superseded');
    }
    return controller.runConfirmedAndPersist();
  }

  Future<CloudSyncManualShadowController> _controllerFor(int generation) {
    final existing = _controller;
    if (existing != null) return Future.value(existing);
    final building = _buildFuture;
    if (building != null) return building;

    late final Future<CloudSyncManualShadowController> operation;
    operation = Future.sync(buildController)
        .then((candidate) async {
          if (_disposed || !_admissionOpen || generation != _generation) {
            await candidate.dispose();
            throw StateError('cloud_sync_shadow_owner_superseded');
          }
          _controller = candidate;
          return candidate;
        })
        .whenComplete(() {
          if (identical(_buildFuture, operation)) _buildFuture = null;
        });
    _buildFuture = operation;
    return operation;
  }

  /// Closes admission immediately and waits for all credential users to stop.
  Future<void> quiesceForAccountTransition() {
    if (_disposed) return Future.value();
    _admissionOpen = false;
    _generation++;
    return _quiesceFuture ??= _quiesce();
  }

  Future<void> _quiesce() async {
    final building = _buildFuture;
    if (building != null) {
      try {
        await building;
      } catch (_) {
        // A superseded build disposes its own candidate.
      }
    }
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
  }

  /// Reopens admission only after the previous account is fully quiescent.
  Future<void> resumeAfterAccountTransition() async {
    if (_disposed) throw StateError('cloud_sync_shadow_owner_disposed');
    await _quiesceFuture;
    _quiesceFuture = null;
    _admissionOpen = true;
  }

  Future<void> dispose() async {
    if (_disposed) return _quiesceFuture;
    _disposed = true;
    _admissionOpen = false;
    _generation++;
    _quiesceFuture ??= _quiesce();
    await _quiesceFuture;
  }
}
