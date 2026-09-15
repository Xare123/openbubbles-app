import 'dart:convert';

import 'package:bluebubbles/cloud_sync_v2_windows_findmy_probe.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Focused tests for the redacted per-person binding in the Windows Find My
// probe's selected section. All vectors are synthetic; no Apple, network, or
// device interaction. The full probe run (runWindowsFindMyProbe) is covered by
// the CI lane; these pin the digest contract the offline qualifier scores:
// digest present only on a bound selection, absent (fail closed) otherwise,
// and reproducible offline by an operator holding the expected handle.
void main() {
  const launchId = '0123456789abcdef0123456789abcdef';
  const otherLaunchId = 'ffffffffffffffffffffffffffffffff';

  String expectedDigest(String canonical) {
    final mac = Hmac(sha256, utf8.encode(launchId));
    return mac
        .convert(
          utf8.encode('$findMyProbeSelectedIdentityDomain:$canonical'),
        )
        .toString();
  }

  test('report key name is stable for the qualifier allowlist', () {
    expect(
      findMyProbeSelectedIdentityDigestKey,
      'selected_identity_digest',
    );
  });

  test('handle request binds to the normalized requested handle', () {
    final canonical = findMySelectedIdentityCanonical(
      acceptedHandles: const ['Shared@Example.test'],
      fromHandles: const [],
      rowId: 'native-row-1',
      requestedHandle: 'shared@example.test',
      requestedId: null,
    );
    expect(canonical, 'handle:shared@example.test');
    final digest = findMySelectedIdentityDigest(
      launchId: launchId,
      canonical: canonical!,
    );
    expect(digest, expectedDigest('handle:shared@example.test'));
    expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(digest), isTrue);
  });

  test('digest is launch-keyed (no cross-launch linkability)', () {
    final first = findMySelectedIdentityDigest(
      launchId: launchId,
      canonical: 'handle:shared@example.test',
    );
    final second = findMySelectedIdentityDigest(
      launchId: otherLaunchId,
      canonical: 'handle:shared@example.test',
    );
    expect(first, isNot(second));
  });

  test('digest separates people and schemes', () {
    final handle = findMySelectedIdentityDigest(
      launchId: launchId,
      canonical: 'handle:shared@example.test',
    );
    final otherHandle = findMySelectedIdentityDigest(
      launchId: launchId,
      canonical: 'handle:other@example.test',
    );
    final idScheme = findMySelectedIdentityDigest(
      launchId: launchId,
      canonical: 'id:shared@example.test',
    );
    expect(handle, isNot(otherHandle));
    expect(handle, isNot(idScheme));
  });

  test('person-ID request binds to the exact row ID on equality', () {
    final canonical = findMySelectedIdentityCanonical(
      acceptedHandles: const ['shared@example.test'],
      fromHandles: const [],
      rowId: 'native-row-1',
      requestedHandle: null,
      requestedId: 'native-row-1',
    );
    expect(canonical, 'id:native-row-1');
  });

  test('person-ID mismatch falls back to row handle material', () {
    final canonical = findMySelectedIdentityCanonical(
      acceptedHandles: const [],
      fromHandles: const ['From@Example.test'],
      rowId: 'native-row-1',
      requestedHandle: null,
      requestedId: 'different-row',
    );
    expect(canonical, 'handle:from@example.test');
  });

  test('empty identity material returns null (fail closed)', () {
    expect(
      findMySelectedIdentityCanonical(
        acceptedHandles: const ['  '],
        fromHandles: const [],
        rowId: 'native-row-1',
        requestedHandle: null,
        requestedId: 'different-row',
      ),
      isNull,
    );
    expect(
      findMySelectedIdentityCanonical(
        acceptedHandles: const [],
        fromHandles: const [],
        rowId: 'native-row-1',
        requestedHandle: '   ',
        requestedId: null,
      ),
      isNull,
    );
  });

  test('digest is keyed (differs from unkeyed SHA-256 of the message)', () {
    const canonical = 'handle:shared@example.test';
    final keyed = findMySelectedIdentityDigest(
      launchId: launchId,
      canonical: canonical,
    );
    final unkeyed = sha256
        .convert(
          utf8.encode('$findMyProbeSelectedIdentityDomain:$canonical'),
        )
        .toString();
    expect(keyed, isNot(unkeyed));
  });

  test('no raw identifier leaks through the digest shape', () {
    const raw = 'shared@example.test';
    final digest = findMySelectedIdentityDigest(
      launchId: launchId,
      canonical: 'handle:$raw',
    );
    expect(digest.contains(raw), isFalse);
    expect(digest.contains('native-row-1'), isFalse);
  });
}
