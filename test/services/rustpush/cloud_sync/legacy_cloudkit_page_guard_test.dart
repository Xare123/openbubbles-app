import 'package:bluebubbles/services/rustpush/cloud_sync/legacy_cloudkit_page_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LegacyCloudKitPageGuard', () {
    test('returns the next token after a fully applied page', () {
      expect(
        LegacyCloudKitPageGuard.validate(
          zone: 'messages',
          previousToken: null,
          nextToken: <int>[1, 2, 3],
          state: 1,
          hadItemFailure: false,
          page: 1,
        ),
        'AQID',
      );
    });

    test('refuses to advance after any item failure', () {
      expect(
        () => LegacyCloudKitPageGuard.validate(
          zone: 'messages',
          previousToken: null,
          nextToken: <int>[1],
          state: 1,
          hadItemFailure: true,
          page: 1,
        ),
        throwsStateError,
      );
    });

    test('detects a nonterminal page that makes no token progress', () {
      expect(
        () => LegacyCloudKitPageGuard.validate(
          zone: 'messages',
          previousToken: 'AQID',
          nextToken: <int>[1, 2, 3],
          state: 1,
          hadItemFailure: false,
          page: 2,
        ),
        throwsStateError,
      );
    });

    test('permits a terminal page to repeat its token', () {
      expect(
        LegacyCloudKitPageGuard.validate(
          zone: 'messages',
          previousToken: 'AQID',
          nextToken: <int>[1, 2, 3],
          state: 3,
          hadItemFailure: false,
          page: 2,
        ),
        'AQID',
      );
    });

    test('caps a pathological zone traversal', () {
      expect(
        () => LegacyCloudKitPageGuard.validate(
          zone: 'messages',
          previousToken: null,
          nextToken: <int>[1],
          state: 1,
          hadItemFailure: false,
          page: LegacyCloudKitPageGuard.maxPagesPerZone + 1,
        ),
        throwsStateError,
      );
    });
  });
}
