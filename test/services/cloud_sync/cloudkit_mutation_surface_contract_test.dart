import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const legacyMutationMethods = <String>{
    'saveChats',
    'deleteChats',
    'saveMessages',
    'deleteMessages',
    'saveAttachments',
    'deleteAttachments',
    'uploadCloudAttachments',
    'uploadGroupPhoto',
    'resetClique',
  };

  test('legacy CloudKit mutation wrappers have one reviewed Dart caller', () {
    final unexpected = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final normalized = entity.path.replaceAll('\\', '/');
      if (normalized.endsWith('/src/rust/api/api.dart') ||
          normalized.endsWith('/src/rust/frb_generated.dart') ||
          normalized.endsWith('/services/rustpush/rustpush_service.dart')) {
        continue;
      }
      final source = entity.readAsStringSync();
      for (final method in legacyMutationMethods) {
        if (source.contains('api.$method(')) {
          unexpected.add('$normalized:$method');
        }
      }
    }
    expect(unexpected, isEmpty);
  });

  test('reviewed legacy mutators are owner-gated and interlocked', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('CloudKitWriterOwnership.legacyMutationsEnabled'),
    );
    expect(source, contains('_runLegacyCloudKitOperation('));
    expect(source, contains('CloudKitOperationKind.legacyReadWrite'));
    expect(source, contains('_runCloudKitDestructiveReset('));
    expect(source, contains('CloudKitOperationKind.destructiveReset'));
    expect(source, isNot(contains('OPENBUBBLES_LEGACY_CLOUDKIT_MUTATIONS')));
  });
}
