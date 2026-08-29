typedef CloudSyncSemanticDiagnosticRecorder = void Function(String safeCode);

/// Content-free counters for semantic decode and local projection stages.
///
/// Values are bounded safe codes only. Record identifiers, account data,
/// message contents, and protected references must never be passed here.
final class CloudSyncSemanticDiagnosticCollector {
  static final RegExp _safeCodePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$');

  final Map<String, int> _counts = <String, int>{};

  void record(String safeCode) {
    // Diagnostics must never change projection behavior. Collapse malformed or
    // unexpectedly sensitive-looking values into one bounded code instead of
    // throwing from an error-reporting path.
    final boundedCode = _safeCodePattern.hasMatch(safeCode)
        ? safeCode
        : 'diagnostic_code_invalid';
    _counts.update(boundedCode, (count) => count + 1, ifAbsent: () => 1);
  }

  Map<String, int> snapshot() => validatedSnapshot(_counts);

  static Map<String, int> validatedSnapshot(Map<String, int> source) {
    final keys = source.keys.toList(growable: false)..sort();
    final result = <String, int>{};
    for (final key in keys) {
      final count = source[key];
      if (!_safeCodePattern.hasMatch(key) || count == null || count <= 0) {
        throw ArgumentError('cloud_sync_semantic_diagnostics_invalid');
      }
      result[key] = count;
    }
    return Map<String, int>.unmodifiable(result);
  }
}
