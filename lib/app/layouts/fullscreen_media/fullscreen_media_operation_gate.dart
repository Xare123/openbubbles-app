/// Rejects asynchronous fullscreen-media results that no longer belong to the
/// active operation.
class FullscreenMediaOperationGate {
  int _generation = 0;
  bool _disposed = false;

  int begin() => ++_generation;

  bool isCurrent(int generation) => !_disposed && generation == _generation;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
  }
}
