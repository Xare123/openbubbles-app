import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _workflowPath = '.github/workflows/bridge-bindings.yml';
const _normalizerPath = 'tooling/frb/normalize_generated_diagnostics.ps1';

const _diagnostics = <String>[
  '// These functions are ignored because they are not marked as `pub`: `alpha`',
  '// These functions are ignored because they have generic arguments: `beta`, `gamma`',
  '// These types are ignored because they are not used by any `pub` functions: `FixtureType`',
  '// These function are ignored because they are on traits that is not defined in current crate (put an empty `#[frb]` on it to unignore): `delta`',
  '// These functions are ignored (category: IgnoreBecauseOwnerTyShouldIgnore): `epsilon`',
];

String _fixture([List<String>? diagnostics]) {
  return <String>[
    '// generated fixture',
    "part 'api.freezed.dart';",
    '',
    ...(diagnostics ?? _diagnostics),
    '',
    'class Fixture {}',
  ].join('\n');
}

ProcessResult _runNormalizer(File file, String mode) {
  final powershell = Platform.isWindows ? 'pwsh.exe' : 'pwsh';
  return Process.runSync(powershell, <String>[
    '-NoProfile',
    '-File',
    _normalizerPath,
    '-Mode',
    mode,
    '-GeneratedDart',
    file.path,
  ]);
}

String _resultOutput(ProcessResult result) =>
    '${result.stdout}\n${result.stderr}';

void main() {
  test('FRB workflow triggers cover the normalizer tooling', () {
    final workflow = File(_workflowPath).readAsStringSync();
    final pushStart = workflow.indexOf('  push:');
    final pullRequestStart = workflow.indexOf('  pull_request:');
    final jobsStart = workflow.indexOf('jobs:');
    expect(pushStart, greaterThanOrEqualTo(0));
    expect(pullRequestStart, greaterThan(pushStart));
    expect(jobsStart, greaterThan(pullRequestStart));

    final push = workflow.substring(pushStart, pullRequestStart);
    final pullRequest = workflow.substring(pullRequestStart, jobsStart);
    expect(push, contains('      - "tooling/frb/**"'));
    expect(pullRequest, contains('      - "tooling/frb/**"'));
  });

  test('normalizer accepts only the exact five diagnostic classes', () {
    final script = File(_normalizerPath).readAsStringSync();
    expect(
      RegExp(r'^        Name = ', multiLine: true).allMatches(script).length,
      5,
    );
    expect(script, contains('Expected exactly one allowlisted FRB diagnostic'));
    expect(script, contains('Test-ByteArrayEqual'));
    expect(script, contains('Final normalized Dart bytes do not match'));
    expect(script, isNot(contains('ExpectedMinimumCount')));
    expect(script, isNot(contains('ExpectedMaximumCount')));
    expect(script, isNot(contains('Expected between')));
  });

  test(
    'normalizer normalizes and verifies a complete allowlisted prologue',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'frb-generated-diagnostics-contract-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}api.dart')
        ..writeAsStringSync(_fixture());

      final normalize = _runNormalizer(file, 'Normalize');
      expect(normalize.exitCode, 0, reason: _resultOutput(normalize));
      final verify = _runNormalizer(file, 'Verify');
      expect(verify.exitCode, 0, reason: _resultOutput(verify));
      expect(
        file.readAsStringSync(),
        isNot(contains('These functions are ignored')),
      );
    },
  );

  test(
    'normalizer fails closed on missing, duplicate, and unexpected variants',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'frb-generated-diagnostics-fail-closed-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));

      final fixtures = <String, List<String>>{
        'missing': _diagnostics.sublist(0, _diagnostics.length - 1),
        'duplicate': <String>[..._diagnostics, _diagnostics.first],
        'unexpected': <String>[
          ..._diagnostics,
          '// These functions are ignored because they are not marked as `pub`: `zeta` unexpected',
        ],
      };

      for (final entry in fixtures.entries) {
        final file = File(
          '${directory.path}${Platform.pathSeparator}${entry.key}.dart',
        )..writeAsStringSync(_fixture(entry.value));
        final before = file.readAsBytesSync();
        final result = _runNormalizer(file, 'Normalize');
        expect(
          result.exitCode,
          isNot(0),
          reason: '${entry.key}: ${_resultOutput(result)}',
        );
        expect(
          file.readAsBytesSync(),
          orderedEquals(before),
          reason: entry.key,
        );
      }

      final misplaced =
          File('${directory.path}${Platform.pathSeparator}misplaced.dart')
            ..writeAsStringSync(
              <String>[
                '// generated fixture',
                "part 'api.freezed.dart';",
                '',
                'class Fixture {}',
                _diagnostics.first,
              ].join('\n'),
            );
      final beforeMisplaced = misplaced.readAsBytesSync();
      final misplacedResult = _runNormalizer(misplaced, 'Normalize');
      expect(misplacedResult.exitCode, isNot(0));
      expect(misplaced.readAsBytesSync(), orderedEquals(beforeMisplaced));
    },
  );
}
