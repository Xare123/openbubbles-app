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
  writerEpoch: epoch,
);

String _grantFor(int epoch) =>
    jsonEncode([1, 'queued-and-future-local-sends', epoch, 'f' * 32]);

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

  CloudSyncAutomaticArchivePreferences prefs() =>
      CloudSyncAutomaticArchivePreferences(
        captureIdentity: () async =>
            onCapture?.call() ?? _identity(epoch: _epoch),
        currentWriterEpoch: () => _epoch,
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
      );
}

void main() {
  test(
    'native binding requires the exact prepared account store and epoch',
    () {
      final identity = _identity();
      bool matches(CloudSyncAutomaticArchiveIdentity actual) =>
          identity.matchesBinding(
            accountFingerprint: actual.accountFingerprint,
            protectedStoreIdentity: actual.protectedStoreIdentity,
            writerEpoch: actual.writerEpoch,
          );
      expect(matches(_identity()), isTrue);
      expect(matches(_identity(account: 'B')), isFalse);
      expect(matches(_identity(protectedStore: 'T')), isFalse);
      expect(matches(_identity(epoch: 3)), isFalse);
      expect(
        _identity(epoch: 0).matchesBinding(
          accountFingerprint: identity.accountFingerprint,
          protectedStoreIdentity: identity.protectedStoreIdentity,
          writerEpoch: 0,
        ),
        isFalse,
      );
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
  });

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
    expect(saved.identity.writerEpoch, 1);
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
