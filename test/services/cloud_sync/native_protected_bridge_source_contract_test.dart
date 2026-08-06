import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated protected DTOs expose no raw CloudKit material', () {
    final source = File('lib/src/rust/api/api.dart').readAsStringSync();
    final start = source.indexOf('class CloudSyncProtectedChange {');
    final end = source.indexOf('enum CloudSyncProtectedSafeCode {');
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final protectedSurface = source.substring(start, end);
    final forbidden = <RegExp>[
      RegExp(r'\brecordName\b'),
      RegExp(r'\betag\b'),
      RegExp(r'\bcontinuationToken\b'),
      RegExp(r'\bencryptedRecord\b'),
      RegExp(r'\btombstonePayload\b'),
      RegExp(r'\bcredentials\b'),
      RegExp(r'\bplaintext\b'),
      RegExp(r'\bstorageDirectory\b'),
      RegExp(r'\bfilePath\b'),
    ];

    for (final pattern in forbidden) {
      expect(
        pattern.hasMatch(protectedSurface),
        isFalse,
        reason: 'generated protected DTO boundary exposed ${pattern.pattern}',
      );
    }
  });

  test(
    'protected transport is constructed only by the compile-gated sampler adapter',
    () {
      final constructors = <String>[];
      const allowed =
          'lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final normalizedPath = entity.path.replaceAll(r'\', '/');
        if (normalizedPath.endsWith(
          '/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart',
        )) {
          continue;
        }
        if (entity.readAsStringSync().contains(
          'NativeProtectedCloudSyncTransport(',
        )) {
          constructors.add(entity.path);
        }
      }

      final normalized = constructors
          .map((path) => path.replaceAll(r'\', '/'))
          .toList(growable: false);
      expect(
        normalized,
        [allowed],
        reason:
            'only the explicit compile-gated manual adapter may construct the protected transport',
      );

      final adapter = File(allowed).readAsStringSync();
      expect(
        RegExp(
          r'NativeProtectedCloudSyncTransport\(',
        ).allMatches(adapter).length,
        1,
      );
      expect(adapter, contains('NativeProtectedCloudSyncBindings?'));
      expect(adapter, isNot(contains('RustCloudSyncTransport(')));
    },
  );
}
