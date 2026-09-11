import 'dart:async';

enum _FindMyRefreshLane { people, devices, items }

/// One operation per lane, including projection/geocoding. Polls while a lane
/// is busy coalesce into that work without queuing or waiting on it again.
/// Explicit People selections keep their existing separate FIFO.
class FindMyRefreshScheduler {
  final _busy = <_FindMyRefreshLane>{};
  bool _disposed = false;

  bool get allBusy => _busy.length == _FindMyRefreshLane.values.length;

  Future<void> refresh({
    required Future<void> Function() people,
    required Future<void> Function() devices,
    required Future<void> Function() items,
  }) async {
    await Future.wait([
      _run(_FindMyRefreshLane.people, people),
      _run(_FindMyRefreshLane.devices, devices),
      refreshItems(items),
    ]);
  }

  /// The Items-only retry button must share the same slot as periodic polls.
  Future<void> refreshItems(Future<void> Function() items) =>
      _run(_FindMyRefreshLane.items, items);

  Future<void> _run(
    _FindMyRefreshLane lane,
    Future<void> Function() operation,
  ) async {
    if (_disposed || !_busy.add(lane)) return;
    try {
      await operation();
    } finally {
      _busy.remove(lane);
    }
  }

  // Do not release busy slots or pretend to cancel an outstanding native call.
  // Page/state liveness checks suppress its late publication and follow-up work.
  void dispose() => _disposed = true;
}

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
    bool Function()? isActive,
  }) async {
    final now = clock ?? DateTime.now;
    if (loading || isActive?.call() == false) return false;
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
      if (isActive?.call() == false) return false;
      value = next;
      lastSuccessAt = now();
      retryAfter = null;
      error = null;
      return true;
    } catch (failure) {
      if (isActive?.call() == false) return false;
      error = failure;
      retryAfter = now().add(const Duration(minutes: 1));
      return false;
    } finally {
      loading = false;
    }
  }
}

/// People polls and selections share a FIFO through projection and publication.
/// Follow-up selection must be awaited by the caller after this method returns,
/// never from [publish], so it cannot wait on its own queue slot.
class FindMyPeopleRefreshState<R, T> extends FindMyRefreshState<List<T>> {
  FindMyPeopleRefreshState(super.value);

  Future<void> _tail = Future<void>.value();

  Future<bool> refreshAndPublish({
    required Future<Iterable<R>> Function() fetch,
    required List<T> Function(Iterable<R>) project,
    required void Function() publish,
    bool force = false,
    bool Function()? isActive,
    void Function(Iterable<R>, List<T>)? onSuccess,
    void Function(String stage, Object error)? onFailure,
  }) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      if (isActive?.call() == false) return false;
      final succeeded = await refresh(
        () async {
          var stage = 'fetch';
          try {
            final rows = await fetch();
            if (isActive?.call() == false) return value;
            stage = 'projection';
            final projected = project(rows);
            onSuccess?.call(rows, projected);
            return projected;
          } catch (error) {
            onFailure?.call(stage, error);
            rethrow;
          }
        },
        force: force,
        isActive: isActive,
      );
      if (isActive?.call() != false) publish();
      return succeeded;
    } finally {
      done.complete();
    }
  }
}

/// Popup events echo explicit selections. Remember intent before awaiting the
/// request so repeated events cannot enqueue the same selection recursively.
class FindMySelectionIntent {
  String? selected;

  bool acceptPopup(String? next) {
    if (selected == next) return false;
    selected = next;
    return true;
  }
}

String findMyPeopleSummary({
  required bool selection,
  required int roster,
  required int nativeLocations,
  required int projectedLocations,
  required int locating,
  bool? selectedPresent,
  bool? selectedHasLocation,
}) =>
    'Find My People source=${selection ? 'selection' : 'poll'} '
    'roster=$roster native_locations=$nativeLocations '
    'projected_valid_locations=$projectedLocations locating=$locating'
    '${selectedPresent == null ? '' : ' selected_present=$selectedPresent selected_has_location=$selectedHasLocation'}';

/// Keep the existing (0, 0) unknown-location sentinel, but allow either zero
/// axis individually. Invalid/missing coordinates belong in the other bucket.
bool hasFindMyLocation(double? latitude, double? longitude) {
  return latitude != null &&
      longitude != null &&
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      (latitude != 0 || longitude != 0);
}

List<T> projectFindMyPeople<R, T>(
  Iterable<R> records, {
  required Iterable<String> Function(R) handles,
  required T Function(R, String) project,
  required String? Function(R) lastKnownHandle,
}) {
  final result = <T>[];
  for (final record in records) {
    // Reuse identity only. Reusing the entire old projection discards a fresh
    // location (or an explicit missing location) when a response omits handles.
    final address = findMyAcceptedHandle(handles(record)) ??
        findMyAcceptedHandle([lastKnownHandle(record) ?? '']);
    if (address != null) result.add(project(record, address));
  }
  return result;
}

String? findMyAcceptedHandle(Iterable<String> handles) {
  for (final handle in handles) {
    if (handle.trim().isNotEmpty) return handle.trim();
  }
  return null;
}

/// An absent reverse-geocoded address is not an absent location. Never use
/// address availability to infer coordinates or sharing permission.
String findMyLocationLabel({
  required double? latitude,
  required double? longitude,
  String? address,
}) {
  if (!hasFindMyLocation(latitude, longitude)) return 'No location found';
  return address?.trim().isNotEmpty == true
      ? address!.trim()
      : 'Location available';
}
