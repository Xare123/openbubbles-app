/// Independent from CloudKit and global log levels. Enable only for a qualified
/// diagnostic iteration with --dart-define=OPENBUBBLES_FINDMY_VERBOSE_DIAGNOSTICS=true.
const findMyVerboseDiagnostics = bool.fromEnvironment(
  'OPENBUBBLES_FINDMY_VERBOSE_DIAGNOSTICS',
);

enum FindMyDiagnosticPhase { init, refresh, selected, cached }

enum FindMyDiagnosticStage { fetch, projection }

enum FindMyItemsStage { beacons, publish }

enum FindMyItemsOutcome { succeeded, failed }

/// At most 12 records per page instance; at most 256 rows per sampled list.
/// Callbacks never run while disabled or after the budget is exhausted.
class FindMyDiagnostics {
  FindMyDiagnostics({this.enabled = findMyVerboseDiagnostics});

  final bool enabled;
  int _remaining = 12;
  static const rowLimit = 256;

  bool _admit() {
    if (!enabled || _remaining == 0) return false;
    _remaining--;
    return true;
  }

  void people<R, T>({
    required FindMyDiagnosticPhase phase,
    required Iterable<R> rows,
    required Iterable<T> projected,
    required bool Function(R) hasNativeLocation,
    required bool Function(R) isLocating,
    required bool Function(T) hasProjectedLocation,
    bool Function(R)? isSelected,
    required void Function(String) emit,
  }) {
    if (!_admit()) return;
    // One look-ahead row establishes truncation without walking the full input.
    final nativeSample = rows.take(rowLimit + 1).toList();
    final projectedSample = projected.take(rowLimit + 1).toList();
    var nativeLocations = 0;
    var locating = 0;
    var selectedPresent = false;
    var selectedHasLocation = false;
    for (final row in nativeSample.take(rowLimit)) {
      final hasLocation = hasNativeLocation(row);
      if (hasLocation) nativeLocations++;
      if (isLocating(row)) locating++;
      if (isSelected?.call(row) == true) {
        selectedPresent = true;
        selectedHasLocation = selectedHasLocation || hasLocation;
      }
    }
    final projectedLocations = projectedSample
        .take(rowLimit)
        .where(hasProjectedLocation)
        .length;
    emit(
      'Find My diagnostic phase=${phase.name} outcome=projected '
      'limit=$rowLimit roster_sample=${nativeSample.take(rowLimit).length} '
      'native_locations=$nativeLocations '
      'projected_rows_sample=${projectedSample.take(rowLimit).length} '
      'projected_valid_locations=$projectedLocations locating=$locating '
      'native_truncated=${nativeSample.length > rowLimit} '
      'projected_truncated=${projectedSample.length > rowLimit}'
      '${isSelected == null ? '' : ' selected_sample_present=$selectedPresent selected_sample_has_location=$selectedHasLocation'}',
    );
  }

  void failure({
    required FindMyDiagnosticPhase phase,
    required FindMyDiagnosticStage stage,
    required void Function(String) emit,
  }) {
    if (!_admit()) return;
    // No error object or runtimeType reaches this diagnostic interface.
    emit(
      'Find My diagnostic phase=${phase.name} outcome=failed stage=${stage.name}',
    );
  }

  void items({
    required FindMyItemsStage stage,
    required FindMyItemsOutcome outcome,
    int Function()? beacons,
    int Function()? uiItems,
    int Function()? uiTotal,
    required void Function(String) emit,
  }) {
    if (!_admit()) return;
    // O(1) collection lengths only, evaluated after the same gate and budget.
    // Unobserved counts are not zero; UI Items excludes the FMIP base rows.
    String count(String label, int Function()? read) {
      if (read == null) return '$label=unobserved';
      final value = read();
      return '$label=${value.clamp(0, rowLimit)} ${label}_truncated=${value > rowLimit}';
    }
    emit(
      'Find My diagnostic service=items stage=${stage.name} outcome=${outcome.name} '
      'limit=$rowLimit ${count('beacons', beacons)} '
      '${count('ui_items', uiItems)} ${count('ui_total', uiTotal)}',
    );
  }
}
