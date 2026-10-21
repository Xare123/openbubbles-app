import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure model tests with injected closures only. No database, native,
/// device, account, or cloud work.
CloudSyncAutomaticArchiveIdentity _identity({
  int epoch = 2,
  String account = 'A',
  String protectedStore = 'S',
}) => CloudSyncAutomaticArchiveIdentity(
  accountFingerprint: account * 43,
  protectedStoreIdentity: 'obcs2.store.${protectedStore * 43}',
  ownershipEpoch: epoch,
);

String _grantFor(int epoch) =>
    jsonEncode([1, 'queued-and-future-local-sends', epoch, 'f' * 32]);

String _receivedGrantFor(int epoch, {String? grant}) => jsonEncode([
  2,
  'queued-and-future-local-sends-and-receives',
  epoch,
  grant ?? 'f' * 32,
]);

String _receivedMediaGrantFor(int epoch, {String? grant}) => jsonEncode([
  3,
  'queued-and-future-local-sends-and-received-text-and-media',
  epoch,
  grant ?? 'f' * 32,
]);

final class _Harness {
  _Harness({int epoch = 2, Object? stored}) : _epoch = epoch {
    if (stored != null) {
      _store[_identity(epoch: epoch).preferenceKey] = stored;
    }
  }

  int _epoch;
  bool current = true;
  final Map<String, Object?> _store = {};
  int reloads = 0;
  int writes = 0;
  int prepares = 0;
  bool writeOk = true;
  Object? Function(String key)? onWrite;
  Future<void> Function()? onPrepare;
  Future<CloudSyncAutomaticArchiveIdentity?> Function()? onCapture;

  CloudSyncAutomaticArchivePreferences prefs({String Function()? newGrant}) =>
      CloudSyncAutomaticArchivePreferences(
        captureIdentity: () async =>
            onCapture?.call() ?? _identity(epoch: _epoch),
        currentOwnershipEpoch: () => _epoch,
        stillCurrent: () => current,
        reload: () async {
          reloads++;
        },
        read: (key) => _store[key],
        write: (key, value) async {
          writes++;
          if (writeOk) _store[key] = value;
          onWrite?.call(key);
          return writeOk;
        },
        prepareWriter: () async {
          prepares++;
          await onPrepare?.call();
        },
        newGrant: newGrant,
      );
}

void main() {
  test(
    'received capture grant survives worker absence but not binding or scope changes',
    () {
      final identity = _identity();
      final stored = _receivedGrantFor(2);
      bool permits({
        CloudSyncAutomaticArchiveIdentity? actual,
        Object? currentStoredValue,
        Object? capturedValue,
      }) {
        final binding = actual ?? identity;
        // Reconstructing a saved grant does not require a runtime callback.
        final consent = CloudSyncAutomaticArchivePreference(
          identity: identity,
          storedValue: capturedValue ?? stored,
        );
        return consent.permitsReceivedCapture(
          accountFingerprint: binding.accountFingerprint,
          protectedStoreIdentity: binding.protectedStoreIdentity,
          ownershipEpoch: binding.ownershipEpoch,
          currentStoredValue: currentStoredValue ?? stored,
        );
      }

      expect(permits(), isTrue);
      expect(permits(actual: _identity(account: 'B')), isFalse);
      expect(permits(actual: _identity(protectedStore: 'T')), isFalse);
      expect(permits(actual: _identity(epoch: 3)), isFalse);
      expect(permits(actual: _identity(epoch: 0)), isFalse);
      for (final value in <Object>[
        _grantFor(2),
        jsonEncode([1, 'off']),
        _receivedGrantFor(2, grant: 'a' * 32),
        _receivedGrantFor(3),
        'invalid',
        false,
      ]) {
        expect(permits(currentStoredValue: value), isFalse);
      }
      expect(
        permits(capturedValue: _grantFor(2), currentStoredValue: _grantFor(2)),
        isFalse,
      );
      expect(
        permits(capturedValue: 'invalid', currentStoredValue: 'invalid'),
        isFalse,
      );
    },
  );

  test(
    'native binding requires the exact prepared account store and epoch',
    () {
      final identity = _identity();
      bool matches(CloudSyncAutomaticArchiveIdentity actual) =>
          identity.matchesBinding(
            accountFingerprint: actual.accountFingerprint,
            protectedStoreIdentity: actual.protectedStoreIdentity,
            ownershipEpoch: actual.ownershipEpoch,
          );
      expect(matches(_identity()), isTrue);
      expect(matches(_identity(account: 'B')), isFalse);
      expect(matches(_identity(protectedStore: 'T')), isFalse);
      expect(matches(_identity(epoch: 3)), isFalse);
      expect(
        _identity(epoch: 0).matchesBinding(
          accountFingerprint: identity.accountFingerprint,
          protectedStoreIdentity: identity.protectedStoreIdentity,
          ownershipEpoch: 0,
        ),
        isFalse,
      );
    },
  );

  test('v1 and v2 grants never inherit received media permission', () async {
    for (final stored in [_grantFor(2), _receivedGrantFor(2)]) {
      final harness = _Harness(stored: stored);
      final prefs = harness.prefs();
      final expected = await prefs.load();
      expect(expected.enabled, isTrue);
      expect(expected.includesReceived, stored == _receivedGrantFor(2));
      expect(expected.includesReceivedMedia, isFalse);
      expect(prefs.isGranted(expected), isTrue);
      expect(prefs.isReceivedGranted(expected), expected.includesReceived);
      expect(prefs.isReceivedMediaGranted(expected), isFalse);
      expect(
        expected.permitsReceivedMediaCapture(
          accountFingerprint: expected.identity.accountFingerprint,
          protectedStoreIdentity: expected.identity.protectedStoreIdentity,
          ownershipEpoch: 2,
          currentStoredValue: stored,
        ),
        isFalse,
      );
      expect(harness._store[expected.identity.preferenceKey], stored);
      expect(harness.prepares, 0);
      expect(harness.writes, 0);
    }
  });

  test('received media requires the exact valid v3 scope', () async {
    final valid = _Harness(stored: _receivedMediaGrantFor(2));
    final prefs = valid.prefs();
    final expected = await prefs.load();
    expect(expected.enabled, isTrue);
    expect(expected.includesReceived, isTrue);
    expect(expected.includesReceivedMedia, isTrue);
    expect(prefs.isReceivedGranted(expected), isTrue);
    expect(prefs.isReceivedMediaGranted(expected), isTrue);
    expect(valid.writes, 0);
    for (final stored in <Object?>[
      jsonEncode([
        2,
        'queued-and-future-local-sends-and-received-text-and-media',
        2,
        'f' * 32,
      ]),
      jsonEncode([
        3,
        'queued-and-future-local-sends-and-receives',
        2,
        'f' * 32,
      ]),
      jsonEncode([
        4,
        'queued-and-future-local-sends-and-received-text-and-media',
        2,
        'f' * 32,
      ]),
      jsonEncode([
        3.0,
        'queued-and-future-local-sends-and-received-text-and-media',
        2,
        'f' * 32,
      ]),
      jsonEncode([
        3,
        'queued-and-future-local-sends-and-received-text-and-media',
        2.0,
        'f' * 32,
      ]),
      jsonEncode([
        3,
        'queued-and-future-local-sends-and-received-text-and-media',
        '2',
        'f' * 32,
      ]),
      jsonEncode([
        3,
        'queued-and-future-local-sends-and-received-text-and-media',
        2,
      ]),
      jsonEncode([
        3,
        'queued-and-future-local-sends-and-received-text-and-media',
        2,
        'f' * 32,
        true,
      ]),
      jsonEncode([
        3,
        'future-local-sends-and-received-text-and-media',
        2,
        'f' * 32,
      ]),
      _receivedMediaGrantFor(9),
      _receivedMediaGrantFor(2, grant: 'short'),
      _receivedMediaGrantFor(2, grant: 'F' * 32),
      _receivedMediaGrantFor(2, grant: 'g' * 32),
    ]) {
      final harness = _Harness(stored: stored);
      final preferences = harness.prefs();
      final preference = await preferences.load();
      expect(preference.enabled, isFalse, reason: 'stored=$stored');
      expect(preference.includesReceived, isFalse);
      expect(preference.includesReceivedMedia, isFalse);
      expect(preferences.isReceivedMediaGranted(preference), isFalse);
    }
    final zero = CloudSyncAutomaticArchivePreference(
      identity: _identity(epoch: 0),
      storedValue: _receivedMediaGrantFor(0),
    );
    expect(zero.enabled, isFalse);
    expect(zero.includesReceivedMedia, isFalse);
  });

  test(
    'media capture requires the current exact account store epoch and grant',
    () {
      final expected = CloudSyncAutomaticArchivePreference(
        identity: _identity(),
        storedValue: _receivedMediaGrantFor(2),
      );
      bool permits({
        CloudSyncAutomaticArchiveIdentity? actual,
        Object? current,
      }) {
        final binding = actual ?? _identity();
        return expected.permitsReceivedMediaCapture(
          accountFingerprint: binding.accountFingerprint,
          protectedStoreIdentity: binding.protectedStoreIdentity,
          ownershipEpoch: binding.ownershipEpoch,
          currentStoredValue: current,
        );
      }

      expect(permits(current: expected.storedValue), isTrue);
      expect(
        permits(
          actual: _identity(account: 'B'),
          current: expected.storedValue,
        ),
        isFalse,
      );
      expect(
        permits(
          actual: _identity(protectedStore: 'T'),
          current: expected.storedValue,
        ),
        isFalse,
      );
      expect(
        permits(actual: _identity(epoch: 3), current: expected.storedValue),
        isFalse,
      );
      expect(
        permits(actual: _identity(epoch: 0), current: expected.storedValue),
        isFalse,
      );
      for (final current in <Object?>[
        null,
        false,
        'invalid',
        jsonEncode([1, 'off']),
        _grantFor(2),
        _receivedGrantFor(2),
        _receivedMediaGrantFor(2, grant: 'a' * 32),
        _receivedMediaGrantFor(3),
      ]) {
        expect(permits(current: current), isFalse, reason: 'current=$current');
      }
      expect(
        expected.permitsReceivedCapture(
          accountFingerprint: expected.identity.accountFingerprint,
          protectedStoreIdentity: expected.identity.protectedStoreIdentity,
          ownershipEpoch: 2,
          currentStoredValue: expected.storedValue,
        ),
        isTrue,
        reason: 'V3 still covers received text',
      );
    },
  );

  test(
    'media enable requires acknowledgment and text scope before any I/O',
    () async {
      for (final stored in <Object?>[
        null,
        _receivedGrantFor(2),
        _receivedMediaGrantFor(2),
      ]) {
        for (final acknowledged in [false, true]) {
          final harness = _Harness(stored: stored);
          final prefs = harness.prefs();
          final expected = await prefs.load();
          await expectLater(
            prefs.setEnabled(
              expected,
              true,
              acknowledgeQueuedUploads: acknowledged,
              includeReceived: !acknowledged,
              includeReceivedMedia: true,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                acknowledged
                    ? 'cloud_sync_automatic_archive_received_media_requires_text'
                    : 'cloud_sync_automatic_archive_confirmation_required',
              ),
            ),
          );
          expect(harness.reloads, 1);
          expect(harness.prepares, 0);
          expect(harness.writes, 0);
        }
      }
    },
  );

  test(
    'explicit media opt-in saves v3 in the same preference lineage',
    () async {
      for (final stored in <Object?>[
        null,
        _grantFor(2),
        _receivedGrantFor(2),
      ]) {
        final harness = _Harness(stored: stored);
        final prefs = harness.prefs(newGrant: () => 'a' * 32);
        final expected = await prefs.load();
        final saved = await prefs.setEnabled(
          expected,
          true,
          acknowledgeQueuedUploads: true,
          includeReceived: true,
          includeReceivedMedia: true,
        );
        expect(saved.storedValue, _receivedMediaGrantFor(2, grant: 'a' * 32));
        expect(saved.identity.sameIdentity(expected.identity), isTrue);
        expect(saved.identity.preferenceKey, expected.identity.preferenceKey);
        expect(saved.enabled, isTrue);
        expect(saved.includesReceived, isTrue);
        expect(saved.includesReceivedMedia, isTrue);
        expect(prefs.isGranted(expected), isFalse);
        expect(prefs.isReceivedGranted(saved), isTrue);
        expect(prefs.isReceivedMediaGranted(saved), isTrue);
        expect(harness._store, hasLength(1));
        expect(harness.prepares, 1);
        expect(harness.writes, 1);
      }
    },
  );

  test(
    'narrowing media to text revokes the old grant and preserves v2 text',
    () async {
      final harness = _Harness(stored: _receivedMediaGrantFor(2));
      final prefs = harness.prefs(newGrant: () => 'a' * 32);
      final media = await prefs.load();
      final text = await prefs.setEnabled(
        media,
        true,
        acknowledgeQueuedUploads: true,
        includeReceived: true,
      );
      expect(text.storedValue, _receivedGrantFor(2, grant: 'a' * 32));
      expect(text.includesReceivedMedia, isFalse);
      expect(prefs.isGranted(media), isFalse);
      expect(prefs.isReceivedMediaGranted(media), isFalse);
      expect(prefs.isReceivedGranted(text), isTrue);
      expect(prefs.isReceivedMediaGranted(text), isFalse);
    },
  );

  test(
    'media revocation uses the existing off value without writer setup',
    () async {
      final harness = _Harness(stored: _receivedMediaGrantFor(2));
      final prefs = harness.prefs(newGrant: () => 'a' * 32);
      final media = await prefs.load();
      final off = await prefs.setEnabled(
        media,
        false,
        acknowledgeQueuedUploads: false,
        includeReceived: true,
        includeReceivedMedia: true,
      );
      expect(off.storedValue, '[1,"off"]');
      expect(off.enabled, isFalse);
      expect(off.includesReceived, isFalse);
      expect(off.includesReceivedMedia, isFalse);
      expect(prefs.isReceivedGranted(media), isFalse);
      expect(prefs.isReceivedMediaGranted(media), isFalse);
      expect(harness.prepares, 0);
      expect(harness.writes, 1);
      final text = await prefs.setEnabled(
        off,
        true,
        acknowledgeQueuedUploads: true,
        includeReceived: true,
      );
      expect(
        text.includesReceivedMedia,
        isFalse,
        reason: 'enabling text cannot restore old media consent',
      );
      expect(prefs.isReceivedGranted(text), isTrue);
      expect(prefs.isReceivedMediaGranted(media), isFalse);
    },
  );

  test(
    'media grants reject revocation narrowing epoch token and currency drift',
    () async {
      for (final mutate in <void Function(_Harness)>[
        (harness) =>
            harness._store[_identity().preferenceKey] = jsonEncode([1, 'off']),
        (harness) =>
            harness._store[_identity().preferenceKey] = _receivedGrantFor(2),
        (harness) => harness._epoch = 9,
        (harness) => harness._store[_identity().preferenceKey] =
            _receivedMediaGrantFor(2, grant: 'a' * 32),
        (harness) => harness.current = false,
      ]) {
        final harness = _Harness(stored: _receivedMediaGrantFor(2));
        final prefs = harness.prefs();
        final expected = await prefs.load();
        expect(prefs.isReceivedMediaGranted(expected), isTrue);
        mutate(harness);
        expect(prefs.isGranted(expected), isFalse);
        expect(prefs.isReceivedGranted(expected), isFalse);
        expect(prefs.isReceivedMediaGranted(expected), isFalse);
      }
    },
  );

  test(
    'media saves reject account store epoch and token drift before writing',
    () async {
      for (final duringPrepare in [false, true]) {
        for (final mutate in <void Function(_Harness)>[
          (harness) => harness.onCapture = () async => _identity(account: 'B'),
          (harness) =>
              harness.onCapture = () async => _identity(protectedStore: 'T'),
          (harness) => harness._epoch = 9,
          (harness) =>
              harness._store[_identity().preferenceKey] = _receivedGrantFor(2),
          (harness) => harness._store[_identity().preferenceKey] =
              _receivedMediaGrantFor(2, grant: 'a' * 32),
          (harness) => harness.current = false,
        ]) {
          final harness = _Harness(stored: _receivedMediaGrantFor(2));
          final prefs = harness.prefs();
          final expected = await prefs.load();
          if (duringPrepare) {
            harness.onPrepare = () async {
              mutate(harness);
            };
          } else {
            mutate(harness);
          }
          await expectLater(
            prefs.setEnabled(
              expected,
              true,
              acknowledgeQueuedUploads: true,
              includeReceived: true,
              includeReceivedMedia: true,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'cloud_sync_automatic_archive_identity_changed',
              ),
            ),
          );
          expect(harness.writes, 0);
        }
      }
    },
  );

  test(
    'media save confirms exact stored scope and prepared identity after write',
    () async {
      for (final mutate in <void Function(_Harness, String)>[
        (harness, key) => harness._store[key] = _receivedGrantFor(2),
        (harness, key) => harness._epoch = 9,
        (harness, key) =>
            harness.onCapture = () async => _identity(account: 'B'),
        (harness, key) =>
            harness.onCapture = () async => _identity(protectedStore: 'T'),
      ]) {
        final harness = _Harness();
        harness.onWrite = (key) {
          mutate(harness, key);
          return null;
        };
        final prefs = harness.prefs();
        final expected = await prefs.load();
        await expectLater(
          prefs.setEnabled(
            expected,
            true,
            acknowledgeQueuedUploads: true,
            includeReceived: true,
            includeReceivedMedia: true,
          ),
          throwsA(isA<StateError>()),
        );
        expect(harness.writes, 1);
      }
    },
  );

  test(
    'preference keys stay account and store scoped without epoch inheritance',
    () {
      expect(_identity().preferenceKey, _identity(epoch: 3).preferenceKey);
      expect(
        _identity(account: 'B').preferenceKey,
        isNot(_identity().preferenceKey),
      );
      expect(
        _identity(protectedStore: 'T').preferenceKey,
        isNot(_identity().preferenceKey),
      );
      expect(
        _identity().preferenceKey,
        matches(RegExp(r'^cloudSyncV2AutomaticArchive\.v1\.[a-f0-9]{64}$')),
      );
    },
  );

  test('default off covers missing malformed and legacy values', () {
    final identity = _identity();
    for (final stored in <Object?>[
      null,
      true,
      false,
      'not-json',
      jsonEncode([1, 'off']),
      jsonEncode([1, 'queued-and-future-local-sends', 2]),
      jsonEncode([1, 'queued-and-future-local-sends', 9, 'f' * 32]),
      jsonEncode([1, 'queued-and-future-local-sends', 2, 'short']),
      jsonEncode([2, 'queued-and-future-local-sends', 2, 'f' * 32]),
      42,
    ]) {
      expect(
        CloudSyncAutomaticArchivePreference(
          identity: identity,
          storedValue: stored,
        ).enabled,
        isFalse,
        reason: 'stored=$stored',
      );
    }
    expect(
      CloudSyncAutomaticArchivePreference(
        identity: identity,
        storedValue: _grantFor(2),
      ).enabled,
      isTrue,
    );
    expect(
      CloudSyncAutomaticArchivePreference(
        identity: _identity(epoch: 0),
        storedValue: _grantFor(0),
      ).enabled,
      isFalse,
    );
  });

  test('enable without acknowledgment is rejected before any I/O', () async {
    final harness = _Harness();
    final prefs = harness.prefs();
    final expected = await prefs.load();
    await expectLater(
      prefs.setEnabled(expected, true, acknowledgeQueuedUploads: false),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_automatic_archive_confirmation_required',
        ),
      ),
    );
    expect(harness.reloads, 1);
    expect(harness.prepares, 0);
    expect(harness.writes, 0);
  });

  test('enable binds the current epoch with a fresh grant', () async {
    final harness = _Harness();
    final prefs = harness.prefs();
    final expected = await prefs.load();
    expect(expected.enabled, isFalse);
    final saved = await prefs.setEnabled(
      expected,
      true,
      acknowledgeQueuedUploads: true,
    );
    expect(saved.enabled, isTrue);
    expect(harness.prepares, 1);
    expect(harness.writes, 1);
    final stored = harness._store[expected.identity.preferenceKey] as String;
    final decoded = jsonDecode(stored) as List;
    expect(decoded[0], 1);
    expect(decoded[1], 'queued-and-future-local-sends');
    expect(decoded[2], 2);
    expect(decoded[3], isA<String>());
    expect(prefs.isGranted(saved), isTrue);
    expect(saved.includesReceived, isFalse);
    expect(prefs.isReceivedGranted(saved), isFalse);
  });

  test('v1 sent-only bytes and default scope remain unchanged', () async {
    final original = _grantFor(2);
    final harness = _Harness(stored: original);
    final prefs = harness.prefs(newGrant: () => 'a' * 32);
    final expected = await prefs.load();
    expect(expected.enabled, isTrue);
    expect(expected.includesReceived, isFalse);
    expect(prefs.isGranted(expected), isTrue);
    expect(prefs.isReceivedGranted(expected), isFalse);
    expect(harness._store[expected.identity.preferenceKey], original);
    expect(harness.writes, 0);
    final saved = await prefs.setEnabled(
      expected,
      true,
      acknowledgeQueuedUploads: true,
    );
    expect(
      saved.storedValue,
      '[1,"queued-and-future-local-sends",2,"${'a' * 32}"]',
    );
    expect(saved.includesReceived, isFalse);
    expect(prefs.isGranted(expected), isFalse);
    expect(prefs.isReceivedGranted(saved), isFalse);
  });

  test('received consent requires the exact valid v2 scope', () async {
    final valid = _Harness(stored: _receivedGrantFor(2));
    final prefs = valid.prefs();
    final expected = await prefs.load();
    expect(expected.enabled, isTrue);
    expect(expected.includesReceived, isTrue);
    expect(prefs.isGranted(expected), isTrue);
    expect(prefs.isReceivedGranted(expected), isTrue);
    expect(valid.writes, 0);
    for (final stored in <Object?>[
      null,
      true,
      'not-json',
      jsonEncode({'version': 2}),
      jsonEncode([2, 'off']),
      _grantFor(2),
      jsonEncode([
        1,
        'queued-and-future-local-sends-and-receives',
        2,
        'f' * 32,
      ]),
      jsonEncode([2, 'queued-and-future-local-sends', 2, 'f' * 32]),
      jsonEncode([
        3,
        'queued-and-future-local-sends-and-receives',
        2,
        'f' * 32,
      ]),
      jsonEncode([
        2.0,
        'queued-and-future-local-sends-and-receives',
        2,
        'f' * 32,
      ]),
      jsonEncode([
        2,
        'queued-and-future-local-sends-and-receives',
        2.0,
        'f' * 32,
      ]),
      jsonEncode([
        2,
        'queued-and-future-local-sends-and-receives',
        '2',
        'f' * 32,
      ]),
      jsonEncode([2, 'future-local-sends-and-receives', 2, 'f' * 32]),
      jsonEncode([2, 'queued-and-future-local-sends-and-receives', 2]),
      jsonEncode([
        2,
        'queued-and-future-local-sends-and-receives',
        2,
        'f' * 32,
        true,
      ]),
      _receivedGrantFor(9),
      _receivedGrantFor(2, grant: 'short'),
      _receivedGrantFor(2, grant: 'F' * 32),
      _receivedGrantFor(2, grant: 'g' * 32),
    ]) {
      final harness = _Harness(stored: stored);
      final preferences = harness.prefs();
      final preference = await preferences.load();
      expect(preference.includesReceived, isFalse, reason: 'stored=$stored');
      expect(preferences.isReceivedGranted(preference), isFalse);
      if (stored != _grantFor(2)) {
        expect(preference.enabled, isFalse, reason: 'stored=$stored');
        expect(preferences.isGranted(preference), isFalse);
      }
    }
    final zeroEpoch = _Harness(epoch: 0, stored: _receivedGrantFor(0));
    final zeroPrefs = zeroEpoch.prefs();
    final zero = await zeroPrefs.load();
    expect(zero.enabled, isFalse);
    expect(zero.includesReceived, isFalse);
    expect(zeroPrefs.isReceivedGranted(zero), isFalse);
  });

  test('every enabled save needs acknowledgment before any I/O', () async {
    for (final stored in <Object?>[null, _grantFor(2), _receivedGrantFor(2)]) {
      for (final includeReceived in [false, true]) {
        final harness = _Harness(stored: stored);
        final prefs = harness.prefs();
        final expected = await prefs.load();
        await expectLater(
          prefs.setEnabled(
            expected,
            true,
            acknowledgeQueuedUploads: false,
            includeReceived: includeReceived,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'cloud_sync_automatic_archive_confirmation_required',
            ),
          ),
        );
        expect(harness.reloads, 1);
        expect(harness.prepares, 0);
        expect(harness.writes, 0);
      }
    }
  });

  test(
    'explicit received opt-in saves v2 with the same epoch and key',
    () async {
      final harness = _Harness();
      final prefs = harness.prefs(newGrant: () => 'a' * 32);
      final expected = await prefs.load();
      final saved = await prefs.setEnabled(
        expected,
        true,
        acknowledgeQueuedUploads: true,
        includeReceived: true,
      );
      expect(saved.storedValue, _receivedGrantFor(2, grant: 'a' * 32));
      expect(saved.identity.preferenceKey, expected.identity.preferenceKey);
      expect(saved.includesReceived, isTrue);
      expect(prefs.isReceivedGranted(saved), isTrue);
      expect(harness.prepares, 1);
      expect(harness.writes, 1);
    },
  );

  test(
    'scope upgrades and downgrades replace grants without disabling',
    () async {
      final harness = _Harness(stored: _grantFor(2));
      var grants = 0;
      final prefs = harness.prefs(
        newGrant: () => (++grants).toRadixString(16).padLeft(32, '0'),
      );
      final sentOnly = await prefs.load();
      final broader = await prefs.setEnabled(
        sentOnly,
        true,
        acknowledgeQueuedUploads: true,
        includeReceived: true,
      );
      expect(broader.enabled, isTrue);
      expect(broader.includesReceived, isTrue);
      expect(prefs.isGranted(sentOnly), isFalse);
      expect(prefs.isReceivedGranted(broader), isTrue);
      final narrowed = await prefs.setEnabled(
        broader,
        true,
        acknowledgeQueuedUploads: true,
      );
      expect(narrowed.enabled, isTrue);
      expect(narrowed.includesReceived, isFalse);
      expect(prefs.isGranted(broader), isFalse);
      expect(prefs.isReceivedGranted(broader), isFalse);
      expect(prefs.isGranted(narrowed), isTrue);
      expect(prefs.isReceivedGranted(narrowed), isFalse);
      final values = [sentOnly, broader, narrowed]
          .map(
            (preference) =>
                jsonDecode(preference.storedValue! as String) as List,
          )
          .toList();
      expect(values.map((value) => value[0]), [1, 2, 1]);
      expect(values.map((value) => value[3]).toSet(), hasLength(3));
      expect(harness.writes, 2);
    },
  );

  test(
    'received grants reject revocation epoch token and currency changes',
    () async {
      for (final mutate in <void Function(_Harness)>[
        (harness) =>
            harness._store[_identity().preferenceKey] = jsonEncode([1, 'off']),
        (harness) => harness._epoch = 9,
        (harness) => harness._store[_identity().preferenceKey] =
            _receivedGrantFor(2, grant: 'a' * 32),
        (harness) => harness.current = false,
      ]) {
        final harness = _Harness(stored: _receivedGrantFor(2));
        final prefs = harness.prefs();
        final expected = await prefs.load();
        expect(prefs.isReceivedGranted(expected), isTrue);
        mutate(harness);
        expect(prefs.isGranted(expected), isFalse);
        expect(prefs.isReceivedGranted(expected), isFalse);
      }
    },
  );

  test(
    'received saves reject stale or replaced account store epoch and token',
    () async {
      for (final duringPrepare in [false, true]) {
        for (final mutate in <void Function(_Harness)>[
          (harness) => harness.onCapture = () async => _identity(account: 'B'),
          (harness) =>
              harness.onCapture = () async => _identity(protectedStore: 'T'),
          (harness) => harness._epoch = 9,
          (harness) => harness._store[_identity().preferenceKey] =
              _receivedGrantFor(2, grant: 'a' * 32),
          (harness) => harness._store[_identity().preferenceKey] = jsonEncode([
            1,
            'off',
          ]),
          (harness) => harness.current = false,
        ]) {
          final harness = _Harness(stored: _receivedGrantFor(2));
          final prefs = harness.prefs();
          final expected = await prefs.load();
          if (duringPrepare) {
            harness.onPrepare = () async {
              mutate(harness);
            };
          } else {
            mutate(harness);
          }
          await expectLater(
            prefs.setEnabled(
              expected,
              true,
              acknowledgeQueuedUploads: true,
              includeReceived: true,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'cloud_sync_automatic_archive_identity_changed',
              ),
            ),
          );
          expect(harness.writes, 0);
        }
      }
    },
  );

  test(
    'disabling a received grant keeps the v1 off format and revokes it',
    () async {
      final harness = _Harness(stored: _receivedGrantFor(2));
      final prefs = harness.prefs();
      final expected = await prefs.load();
      final saved = await prefs.setEnabled(
        expected,
        false,
        acknowledgeQueuedUploads: false,
        includeReceived: true,
      );
      expect(saved.storedValue, '[1,"off"]');
      expect(saved.enabled, isFalse);
      expect(saved.includesReceived, isFalse);
      expect(prefs.isReceivedGranted(expected), isFalse);
      expect(prefs.isGranted(expected), isFalse);
      expect(harness.prepares, 0);
      expect(harness.writes, 1);
    },
  );

  test(
    'received opt-in rejects malformed fresh tokens before writing',
    () async {
      final harness = _Harness();
      final prefs = harness.prefs(newGrant: () => 'not-a-grant');
      final expected = await prefs.load();
      await expectLater(
        prefs.setEnabled(
          expected,
          true,
          acknowledgeQueuedUploads: true,
          includeReceived: true,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_automatic_archive_grant_invalid',
          ),
        ),
      );
      expect(harness.writes, 0);
    },
  );

  test('zero epoch provisions initial owner only once', () async {
    final harness = _Harness(epoch: 0);
    final prefs = harness.prefs();
    final expected = await prefs.load();
    expect(expected.enabled, isFalse);
    harness.onPrepare = () async {
      harness._epoch = 1;
    };
    final saved = await prefs.setEnabled(
      expected,
      true,
      acknowledgeQueuedUploads: true,
    );
    expect(saved.enabled, isTrue);
    expect(saved.identity.ownershipEpoch, 1);
    expect(harness.prepares, 1);
  });

  test('replaced epoch never inherits the confirmation', () async {
    final harness = _Harness();
    final prefs = harness.prefs();
    final expected = await prefs.load();
    harness.onPrepare = () async {
      harness._epoch = 9;
    };
    await expectLater(
      prefs.setEnabled(expected, true, acknowledgeQueuedUploads: true),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_automatic_archive_identity_changed',
        ),
      ),
    );
    expect(harness.writes, 0);
  });

  test('stale preview account store epoch and value changes fail', () async {
    Future<void> stale(void Function(_Harness) mutate) async {
      final harness = _Harness();
      final prefs = harness.prefs();
      final expected = await prefs.load();
      mutate(harness);
      await expectLater(
        prefs.setEnabled(expected, false, acknowledgeQueuedUploads: false),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_automatic_archive_identity_changed',
          ),
        ),
      );
      expect(harness.writes, 0);
    }

    await stale((harness) {
      harness.onCapture = () async => _identity(epoch: 9);
    });
    await stale((harness) {
      harness.onCapture = () async => _identity(account: 'B');
    });
    await stale((harness) {
      harness.onCapture = () async => _identity(protectedStore: 'T');
    });
    await stale((harness) {
      harness._store[_identity().preferenceKey] = _grantFor(9);
    });
  });

  test('disable writes off and revokes the grant', () async {
    final harness = _Harness(stored: _grantFor(2));
    final prefs = harness.prefs();
    final expected = await prefs.load();
    expect(expected.enabled, isTrue);
    final saved = await prefs.setEnabled(
      expected,
      false,
      acknowledgeQueuedUploads: false,
    );
    expect(saved.enabled, isFalse);
    expect(harness.prepares, 0);
    expect(
      jsonDecode(harness._store[expected.identity.preferenceKey] as String),
      [1, 'off'],
    );
    final renewed = await prefs.setEnabled(
      saved,
      true,
      acknowledgeQueuedUploads: true,
    );
    expect(renewed.enabled, isTrue);
    expect(
      (jsonDecode(renewed.storedValue! as String) as List)[3],
      isNot((jsonDecode(_grantFor(2)) as List)[3]),
    );
    expect(prefs.isGranted(expected), isFalse);
    expect(prefs.isGranted(renewed), isTrue);
  });

  test('isGranted fences epoch value and currency', () async {
    final harness = _Harness(stored: _grantFor(2));
    final prefs = harness.prefs();
    final expected = await prefs.load();
    expect(prefs.isGranted(expected), isTrue);
    harness._epoch = 9;
    expect(prefs.isGranted(expected), isFalse);
    harness._epoch = 2;
    harness._store[expected.identity.preferenceKey] = _grantFor(9);
    expect(prefs.isGranted(expected), isFalse);
    harness.current = false;
    expect(prefs.isGranted(expected), isFalse);
  });

  test('load races on identity and currency fail with exact codes', () async {
    final gone = _Harness();
    gone.onCapture = () async => null;
    await expectLater(
      gone.prefs().load(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_automatic_archive_unavailable',
        ),
      ),
    );
    final drifting = _Harness();
    var captures = 0;
    drifting.onCapture = () async {
      captures++;
      return _identity(epoch: captures);
    };
    await expectLater(
      drifting.prefs().load(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_automatic_archive_identity_changed',
        ),
      ),
    );
    final stale = _Harness();
    stale.current = false;
    await expectLater(
      stale.prefs().load(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_automatic_archive_identity_changed',
        ),
      ),
    );
  });

  test('prepare write and final read failures keep exact codes', () async {
    final failingPrepare = _Harness();
    failingPrepare.onPrepare = () async {
      throw StateError('synthetic-prepare-down');
    };
    final prefs = failingPrepare.prefs();
    final expected = await prefs.load();
    await expectLater(
      prefs.setEnabled(expected, true, acknowledgeQueuedUploads: true),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'synthetic-prepare-down',
        ),
      ),
    );
    expect(failingPrepare.writes, 0);
    final failingWrite = _Harness();
    failingWrite.writeOk = false;
    final prefs2 = failingWrite.prefs();
    final expected2 = await prefs2.load();
    await expectLater(
      prefs2.setEnabled(expected2, true, acknowledgeQueuedUploads: true),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_automatic_archive_save_failed',
        ),
      ),
    );
    final racingWrite = _Harness();
    racingWrite.onWrite = (key) {
      racingWrite._store[key] = _grantFor(9);
      return null;
    };
    final prefs3 = racingWrite.prefs();
    final expected3 = await prefs3.load();
    await expectLater(
      prefs3.setEnabled(expected3, true, acknowledgeQueuedUploads: true),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'load and disable perform no writer preparation or cloud work',
    () async {
      final harness = _Harness();
      final prefs = harness.prefs();
      await prefs.load();
      expect(harness.prepares, 0);
      expect(harness.writes, 0);
      final expected = await prefs.load();
      await prefs.setEnabled(expected, false, acknowledgeQueuedUploads: false);
      expect(harness.prepares, 0);
      expect(harness.writes, 1);
    },
  );
}
