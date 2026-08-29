import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('records sorted bounded content-free diagnostic counts', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    diagnostics.record('native_ready');
    diagnostics.record('apply_dependency');
    diagnostics.record('native_ready');

    expect(diagnostics.snapshot(), <String, int>{
      'apply_dependency': 1,
      'native_ready': 2,
    });
  });

  test('invalid diagnostic input cannot interrupt semantic projection', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    diagnostics.record('message body or identifier');

    expect(diagnostics.snapshot(), <String, int>{'diagnostic_code_invalid': 1});
  });
}
