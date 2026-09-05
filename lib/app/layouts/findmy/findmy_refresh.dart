/// Per-section last-good data and retry state. A failed service cannot invalidate
/// another section or make a failed refresh look fresh.
class FindMyRefreshState<T> {
  FindMyRefreshState(this.value);

  T value;
  Object? error;
  bool loading = false;
  DateTime? lastSuccessAt;
  DateTime? retryAfter;

  Future<bool> refresh(
    Future<T> Function() fetch, {
    bool force = false,
    Duration? maxAge,
    DateTime Function()? clock,
  }) async {
    final now = clock ?? DateTime.now;
    if (loading) return false;
    final started = now();
    if (!force) {
      if (retryAfter?.isAfter(started) == true) return false;
      if (error == null &&
          maxAge != null &&
          lastSuccessAt != null &&
          started.difference(lastSuccessAt!) < maxAge) {
        return false;
      }
    }
    loading = true;
    try {
      final next = await fetch();
      value = next;
      lastSuccessAt = now();
      retryAfter = null;
      error = null;
      return true;
    } catch (failure) {
      error = failure;
      retryAfter = now().add(const Duration(minutes: 1));
      return false;
    } finally {
      loading = false;
    }
  }
}

List<T> projectFindMyPeople<R, T>(
  Iterable<R> records, {
  required Iterable<String> Function(R) handles,
  required T Function(R, String) project,
  required T? Function(R) lastGood,
}) {
  final result = <T>[];
  for (final record in records) {
    final address = findMyAcceptedHandle(handles(record));
    final person = address == null
        ? lastGood(record)
        : project(record, address);
    if (person != null) result.add(person);
  }
  return result;
}

String? findMyAcceptedHandle(Iterable<String> handles) {
  for (final handle in handles) {
    if (handle.trim().isNotEmpty) return handle;
  }
  return null;
}
