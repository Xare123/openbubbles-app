// Offline regression: fixed literal failure and diagnostic vocabulary emitted
// by the semantic store gateway and the canonical entity adapter must stay
// preserved by the failure sanitizer and reviewed by the diagnostic gate.
// Pure source, contract, and synthetic checks only. No device, profile,
// snapshots, network, native DLL, credential reads, or builds.
import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

const _gatewayPath =
    'lib/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart';
const _adapterPath =
    'lib/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';

// Only fixed literal call-site arguments match these. Dynamic expressions
// (variables, interpolation, concatenation, switch arms) never match because
// the opening quote must immediately follow the call-site punctuation.
final _safeCodeLiteral = RegExp(r"safeCode\s*:\s*'([^']+)'");
final _failureLiteral = RegExp(r"_failure\s*\(\s*'([^']+)'");
final _malformedLiteral = RegExp(r"_malformed\s*\(\s*'([^']+)'");
final _diagnosticLiteral =
    RegExp(r"_diagnosticRecorder\?\s*\.call\s*\(\s*'([^']+)'");

Set<String> _fixedLiterals(String source, List<RegExp> patterns) {
  final codes = <String>{};
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(source)) {
      final code = match.group(1)!;
      if (code.contains(r'$')) continue; // dynamic interpolation, ignore
      codes.add(code);
    }
  }
  return codes;
}

void main() {
  test('semantic store failure codes stay preserved and reviewed', () {
    final gateway = File(_gatewayPath).readAsStringSync();
    final adapter = File(_adapterPath).readAsStringSync();

    final gatewayFailures = _fixedLiterals(gateway, [
      _safeCodeLiteral,
      _failureLiteral,
      _malformedLiteral,
    ]);
    final adapterFailures = _fixedLiterals(adapter, [
      _safeCodeLiteral,
      _failureLiteral,
      _malformedLiteral,
    ]);
    expect(gatewayFailures, isNotEmpty,
        reason: 'gateway extraction must not be vacuous');
    expect(adapterFailures, isNotEmpty,
        reason: 'adapter extraction must not be vacuous');

    final failures = {...gatewayFailures, ...adapterFailures};
    final collector = CloudSyncSemanticDiagnosticCollector();
    for (final code in failures) {
      expect(cloudSyncV2SafeFailureCodeForCandidate(code), code,
          reason: 'sanitizer must preserve fixed failure $code');
      expect(CloudSyncSemanticDiagnosticCodes.isReviewed(code), isTrue,
          reason: 'diagnostics must review fixed failure $code');
      collector.record(code);
    }
    final counts = collector.snapshot();
    for (final code in failures) {
      expect(counts[code], 1, reason: 'collector must admit $code');
    }
  });

  test('diagnostic recorder labels stay reviewed', () {
    final gateway = File(_gatewayPath).readAsStringSync();
    final adapter = File(_adapterPath).readAsStringSync();
    final labels = {
      ..._fixedLiterals(adapter, [_diagnosticLiteral]),
      ..._fixedLiterals(gateway, [_diagnosticLiteral]),
    };
    expect(labels, isNotEmpty,
        reason: 'diagnostic label extraction must not be vacuous');
    expect(labels.any((label) => label.contains(r'$')), isFalse,
        reason: 'dynamic recorder expressions must be excluded');
    final collector = CloudSyncSemanticDiagnosticCollector();
    for (final label in labels) {
      // Informational only: reviewed by the diagnostic gate, never routed
      // through the failure sanitizer.
      expect(CloudSyncSemanticDiagnosticCodes.isReviewed(label), isTrue,
          reason: 'diagnostics must review recorder label $label');
      collector.record(label);
    }
    final counts = collector.snapshot();
    for (final label in labels) {
      expect(counts[label], 1, reason: 'collector must admit $label');
    }
  });

  test('tidy unknowns and sample identity text never admitted', () {
    const probes = [
      'semantic_conflict_unreviewed_probe',
      'unreviewed_probe_semantic_conflict',
      'semantic_',
      'canonical_',
      'decoder_',
      'retained_projection_',
      // Synthetic samples only, never real account, GUID, or reference values.
      '123e4567-e89b-12d3-a456-426614174000',
      'sample_account_fingerprint_0001_probe',
      'sample.account.0001@example.invalid',
      'obcs2.ref.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    ];
    for (final probe in probes) {
      expect(cloudSyncV2SafeFailureCodeForCandidate(probe),
          'cloud_sync_unknown_failure',
          reason: 'sanitizer must stay exact for $probe');
      expect(CloudSyncSemanticDiagnosticCodes.isReviewed(probe), isFalse,
          reason: 'diagnostics must reject $probe');
    }
    final collector = CloudSyncSemanticDiagnosticCollector();
    for (final probe in probes) {
      collector.record(probe);
    }
    final counts = collector.snapshot();
    for (final probe in probes) {
      expect(counts.containsKey(probe), isFalse,
          reason: 'collector must not admit $probe');
    }
    expect(counts['diagnostic_code_invalid'], probes.length,
        reason: 'collector must collapse every probe to one bounded code');
  });
}
