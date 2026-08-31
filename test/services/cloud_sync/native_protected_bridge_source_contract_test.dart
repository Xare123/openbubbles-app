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
    'protected transport is constructed only by compile-gated canary adapters',
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
            'only explicit compile-gated canary adapters may construct the protected transport',
      );

      final adapter = File(allowed).readAsStringSync();
      expect(
        RegExp(
          r'NativeProtectedCloudSyncTransport\(',
        ).allMatches(adapter).length,
        3,
        reason:
            'shadow, semantic pull, and one-text outbound are the only protected transport compositions',
      );
      expect(adapter, contains('NativeProtectedCloudSyncBindings?'));
      expect(adapter, isNot(contains('RustCloudSyncTransport(')));

      final shadowStart = adapter.indexOf(
        'final class CloudSyncProductionSamplerAdapter',
      );
      final semanticStart = adapter.indexOf(
        'final class CloudSyncProductionSemanticPullAdapter',
      );
      final outboundStart = adapter.indexOf(
        'final class CloudSyncProductionOutboundCanaryAdapter',
      );
      expect(shadowStart, greaterThanOrEqualTo(0));
      expect(semanticStart, greaterThan(shadowStart));
      expect(outboundStart, greaterThan(semanticStart));
      final shadowComposition = adapter.substring(shadowStart, semanticStart);
      final semanticComposition = adapter.substring(semanticStart, outboundStart);
      expect(
        shadowComposition,
        isNot(contains('nativeWriterPauseToken: pauseToken')),
        reason: 'the non-projecting shadow diagnostic remains explicitly unbound',
      );
      expect(
        semanticComposition,
        contains('createRawTransport: (snapshot, scope, pauseToken)'),
      );
      expect(
        semanticComposition,
        contains('nativeWriterPauseToken: pauseToken'),
        reason:
            'semantic protected fetch must carry the exact active writer-pause capability',
      );
    },
  );

  test('native semantic fetch acquires and forwards read-authentication permit', () {
    final api = File('rust/src/api/api.rs').readAsStringSync();
    final shadowFetchStart = api.indexOf(
      'pub async fn cloud_sync_fetch_protected_page',
    );
    final semanticFetchStart = api.indexOf(
      'pub async fn cloud_sync_fetch_protected_page_under_writer_pause',
      shadowFetchStart,
    );
    final innerFetchStart = api.indexOf(
      'async fn cloud_sync_fetch_protected_page_inner',
      semanticFetchStart,
    );
    expect(shadowFetchStart, greaterThanOrEqualTo(0));
    expect(semanticFetchStart, greaterThan(shadowFetchStart));
    expect(innerFetchStart, greaterThan(semanticFetchStart));
    final shadowFetch = api.substring(shadowFetchStart, semanticFetchStart);
    final semanticFetch = api.substring(semanticFetchStart, innerFetchStart);
    expect(shadowFetch, isNot(contains('native_writer_pause_token')));
    expect(shadowFetch, isNot(contains('acquire_cloudkit_read_authentication')));
    expect(semanticFetch, contains('native_writer_pause_token: u64'));
    expect(
      semanticFetch,
      contains(
        'acquire_cloudkit_read_authentication(native_writer_pause_token)',
      ),
    );
    expect(semanticFetch, contains('Some(&permit)'));

    final native = File(
      'rust/src/cloud_sync_native_fetch.rs',
    ).readAsStringSync();
    expect(
      native,
      contains('.sync_messages_page_for_read_authentication('),
    );
    expect(
      native,
      contains('.sync_attachments_page_for_read_authentication('),
    );
    expect(native, contains('.sync_chats_page_for_read_authentication('));
  });
}
