import 'dart:async';

class CloudSyncCancellationToken {
  bool _cancelled = false;
  Completer<void>? _cancelledCompleter;

  bool get isCancelled => _cancelled;

  Future<void> get whenCancelled {
    if (_cancelled) return Future<void>.value();
    return (_cancelledCompleter ??= Completer<void>()).future;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final completer = _cancelledCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}
