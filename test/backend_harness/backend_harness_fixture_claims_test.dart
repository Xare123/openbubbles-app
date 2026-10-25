import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_fixture_claims.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:flutter_test/flutter_test.dart';

const fixture = '01234567-89AB-4DEF-8123-456789ABCDEF';
const messageGuid = '11234567-89AB-4DEF-8123-456789ABCDEF';
const owner = '21234567-89ab-4def-8123-456789abcdef';
const source = '0123456789012345678901234567890123456789';

void main() {
  late Directory root;
  late BackendHarnessFixtureClaims claims;
  CloudSyncNativeAuthSnapshot auth({String? account, String? store}) =>
      CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'synthetic',
        accountFingerprint: account ?? 'A' * 43,
        protectedStoreIdentity: store ?? 'obcs2.store.${'B' * 43}',
        cloudMessagesClient: Object(),
      );
  BackendHarnessFixtureClaims reopened({
    CloudSyncNativeAuthSnapshot? identity,
    String? build,
  }) => BackendHarnessFixtureClaims(
    storageDirectory: root.path,
    source: build ?? source,
    auth: identity ?? auth(),
  );
  File file() =>
      File('${root.path}/cloud-sync-v2/backend-fixtures/$fixture.jsonl');
  final refused = throwsA(isA<BackendHarnessFailure>());
  setUp(() async {
    root = await Directory(
      '${Directory.current.path}/test/backend_harness',
    ).createTemp('fixture-claims-');
    claims = reopened();
  });
  tearDown(() async => root.delete(recursive: true));

  test('flushed claim consumes fixture before any reflected message', () {
    final claim = claims.consume(fixture, owner: owner);
    expect(claim.messageGuid, isNull);
    expect(reopened().read(fixture, owner: owner)!.messageGuid, isNull);
    expect(() => reopened().consume(fixture, owner: owner), refused);
    expect(
      () => reopened().consume(fixture.toLowerCase(), owner: owner),
      refused,
    );
    final value = jsonDecode(file().readAsLinesSync().single) as Map;
    expect(value.keys.toSet(), {
      'version',
      'fixtureId',
      'source',
      'owner',
      'account',
      'store',
    });
    expect(file().readAsStringSync().endsWith('\n'), true);
  });

  test(
    'actual result is distinct from fixture and commits once across restart',
    () {
      final claim = claims.consume(fixture, owner: owner);
      claims.commit(claim, messageGuid);
      final result = reopened().read(fixture, owner: owner)!;
      expect(result.messageGuid, messageGuid);
      expect(result.fixtureId, isNot(messageGuid));
      expect(result.partialResult, false);
      expect(() => claims.commit(claim, messageGuid), refused);
      expect(() => claims.consume(fixture, owner: owner), refused);
    },
  );

  test('partial result is consumed and retained without repair', () {
    final claim = claims.consume(fixture, owner: owner);
    file().writeAsStringSync(
      '{"messageGuid":"1123',
      mode: FileMode.append,
      flush: true,
    );
    final before = file().readAsBytesSync();
    final recovered = reopened().read(fixture, owner: owner)!;
    expect(recovered.messageGuid, isNull);
    expect(recovered.partialResult, true);
    expect(() => claims.commit(claim, messageGuid), refused);
    expect(() => claims.consume(fixture, owner: owner), refused);
    expect(file().readAsBytesSync(), before);
  });

  test('empty or torn initial claim cannot be overwritten or adopted', () {
    claims.consume(fixture, owner: owner);
    file().writeAsStringSync('{"version":', flush: true);
    final before = file().readAsStringSync();
    expect(() => reopened().read(fixture), refused);
    expect(() => reopened().consume(fixture, owner: owner), refused);
    expect(file().readAsStringSync(), before);
  });

  test('account store owner and source mismatches refuse retained claim', () {
    claims.consume(fixture, owner: owner);
    final before = file().readAsBytesSync();
    expect(
      () => reopened(identity: auth(account: 'C' * 43)).read(fixture),
      refused,
    );
    expect(
      () => reopened(
        identity: auth(store: 'obcs2.store.${'D' * 43}'),
      ).read(fixture),
      refused,
    );
    expect(() => reopened(build: 'a' * 40).read(fixture), refused);
    expect(
      () => claims.read(fixture, owner: '31234567-89AB-4DEF-8123-456789ABCDEF'),
      refused,
    );
    expect(
      () => reopened(
        identity: auth(account: 'C' * 43),
      ).consume(fixture, owner: owner),
      refused,
    );
    expect(file().readAsBytesSync(), before);
  });

  test('malformed result never overrides binding or permits replacement', () {
    claims.consume(fixture, owner: owner);
    file().writeAsStringSync(
      '${jsonEncode({'messageGuid': messageGuid, 'claimSha256': '0' * 64})}\n',
      mode: FileMode.append,
      flush: true,
    );
    expect(claims.read(fixture)!.messageGuid, isNull);
    expect(claims.read(fixture)!.partialResult, true);
    expect(() => claims.consume(fixture, owner: owner), refused);
  });

  test('fixed UUID paths and plain directories are required', () {
    expect(claims.read(fixture), isNull);
    expect(() => claims.consume('../claim', owner: owner), refused);
    expect(() => claims.consume(fixture, owner: 'caller-owner'), refused);
    File('${root.path}/cloud-sync-v2').writeAsStringSync('not a directory');
    expect(() => claims.consume(fixture, owner: owner), refused);
  });
}
