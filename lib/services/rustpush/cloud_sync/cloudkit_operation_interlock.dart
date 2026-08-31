import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' show IsolateNameServer;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_store.dart';

enum CloudKitOperationKind {
  legacyReadWrite,
  v2ReadWrite,
  v2ShadowRead,
  v2SemanticRead,
  writerTransition,
  destructiveReset,
}

typedef CloudKitOperationBody<T> = Future<T> Function();

abstract interface class CloudKitOperationExclusion {
  Future<T> runExclusive<T>({
    required CloudKitOperationKind kind,
    required CloudKitOperationBody<T> action,
  });

  /// Retains the process-wide exclusion lock until process restart.
  ///
  /// Call only from inside [runExclusive] after an in-process bridge leaves
  /// native writer state uncertain.
  void poisonUntilProcessRestart();
}

/// A process- and isolate-wide exclusion boundary for private CloudKit work.
///
/// Android may run the legacy CloudKit path in a second Dart isolate, while
/// Windows may have more than one app process touching the same profile. A
/// static mutex cannot cover either case, so every operation also holds a
/// process-wide isolate reservation and an operating-system file lock in the
/// existing private support directory.
///
/// Re-entry is permitted only for the same operation kind. This lets the
/// legacy sync call smaller legacy upload helpers without deadlocking, while
/// ensuring a write helper accidentally reached from the V2 shadow sampler
/// fails closed.
final class CloudKitOperationInterlock implements CloudKitOperationExclusion {
  CloudKitOperationInterlock({
    required String privateStorageDirectory,
    required this._fenceStore,
    Duration leaseDuration = const Duration(minutes: 5),
    Duration heartbeatInterval = const Duration(seconds: 30),
  }) : _privateStorageDirectory = _validateStorageDirectory(
         privateStorageDirectory,
       ),
       _leaseDuration = leaseDuration,
       _heartbeatInterval = heartbeatInterval {
    if (leaseDuration.inMicroseconds <= 0 ||
        heartbeatInterval.inMicroseconds <= 0 ||
        heartbeatInterval.inMicroseconds >= leaseDuration.inMicroseconds) {
      throw ArgumentError(
        'The heartbeat interval must be positive and shorter than the lease',
      );
    }
  }

  static const _lockFileName = '.openbubbles-cloudkit-operation.lock';
  static const _fenceAccountFingerprint =
      '-8hryNWhXHChrtLXXv9CZEP9PRsA_fGw2ltOR79b3yQ';
  static final _fenceScope = CloudSyncScope(
    accountFingerprint: _fenceAccountFingerprint,
    container: 'openbubbles.local',
    database: 'private',
    zone: 'cloudkit-operation-fence',
  );

  /// Storage key of the mutual-exclusion fence lease.
  ///
  /// This interlock holds a lease on a sentinel scope for the duration of the
  /// work it guards, including while that work runs its own preflight. A
  /// coordinator-lease probe must exclude this key, because a mutual-exclusion
  /// fence is not another sync coordinator and an operation must not observe
  /// itself as one.
  static String get fenceScopeKey => cloudSyncPersistentScopeKey(_fenceScope);

  static final Object _zoneLeaseKey = Object();
  static final Set<String> _locallyReservedPaths = <String>{};
  static final Set<String> _poisonedPaths = <String>{};
  static final List<RandomAccessFile> _poisonedHandles = <RandomAccessFile>[];
  static final List<_ProcessIsolateReservation> _poisonedIsolateReservations =
      <_ProcessIsolateReservation>[];

  final String _privateStorageDirectory;
  final CloudSyncStore _fenceStore;
  final Duration _leaseDuration;
  final Duration _heartbeatInterval;

  String get lockPath => path.join(_privateStorageDirectory, _lockFileName);

  static void throwIfActiveFenceLost() {
    final active = Zone.current[_zoneLeaseKey];
    if (active is _ActiveCloudKitOperation && active.fenceLost) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_fence_lost',
      );
    }
  }

  /// Proves that a mutation guard is executing inside the expected exclusion
  /// boundary. This prevents future callers from treating the interlock as a
  /// documentation-only precondition.
  static void requireActive(CloudKitOperationKind kind) {
    final active = Zone.current[_zoneLeaseKey];
    if (active is! _ActiveCloudKitOperation) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_required',
      );
    }
    if (active.kind != kind) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_mode_violation',
      );
    }
    throwIfActiveFenceLost();
  }

  static void requireActiveAny(Set<CloudKitOperationKind> kinds) {
    final active = Zone.current[_zoneLeaseKey];
    if (active is! _ActiveCloudKitOperation) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_required',
      );
    }
    if (!kinds.contains(active.kind)) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_mode_violation',
      );
    }
    throwIfActiveFenceLost();
  }

  @override
  void poisonUntilProcessRestart() {
    final active = Zone.current[_zoneLeaseKey];
    if (active is! _ActiveCloudKitOperation || active.lockPath != lockPath) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_required',
      );
    }
    active.poisoned = true;
  }

  /// Releases retained poison locks only in assertion-enabled test builds.
  static Future<void> debugResetPoisonedLocksForTesting() async {
    var reset = false;
    assert(() {
      reset = true;
      return true;
    }());
    if (!reset) {
      throw UnsupportedError('cloudkit_interlock_poison_reset_disabled');
    }
    final handles = List<RandomAccessFile>.of(_poisonedHandles);
    _poisonedHandles.clear();
    for (final handle in handles) {
      await _releaseQuietly(handle);
    }
    final isolateReservations = List<_ProcessIsolateReservation>.of(
      _poisonedIsolateReservations,
    );
    _poisonedIsolateReservations.clear();
    for (final reservation in isolateReservations) {
      reservation.release();
    }
    _locallyReservedPaths.removeAll(_poisonedPaths);
    _poisonedPaths.clear();
  }

  @override
  Future<T> runExclusive<T>({
    required CloudKitOperationKind kind,
    required CloudKitOperationBody<T> action,
  }) async {
    final inherited = Zone.current[_zoneLeaseKey];
    if (inherited is _ActiveCloudKitOperation) {
      if (inherited.lockPath != lockPath) {
        throw const CloudKitOperationInterlockException(
          'cloudkit_interlock_profile_mismatch',
        );
      }
      if (inherited.kind != kind) {
        throw const CloudKitOperationInterlockException(
          'cloudkit_interlock_mode_violation',
        );
      }
      if (inherited.fenceLost) {
        throw const CloudKitOperationInterlockException(
          'cloudkit_interlock_fence_lost',
        );
      }
      return action();
    }

    if (!_locallyReservedPaths.add(lockPath)) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_busy',
      );
    }

    RandomAccessFile? handle;
    _ProcessIsolateReservation? isolateReservation;
    Timer? heartbeat;
    Future<void>? renewalInFlight;
    final ownerId = _newOwnerId();
    CloudCoordinatorLeaseFence? databaseFence;
    _ActiveCloudKitOperation? active;
    var retainedUntilRestart = false;
    try {
      isolateReservation = _ProcessIsolateReservation.acquire(lockPath);
      final fence = await _fenceStore.tryAcquireCoordinatorLease(
        _fenceScope,
        ownerId: ownerId,
        now: DateTime.now(),
        leaseDuration: _leaseDuration,
      );
      if (fence == null) {
        throw const CloudKitOperationInterlockException(
          'cloudkit_interlock_busy',
        );
      }
      databaseFence = fence;

      try {
        handle = await File(lockPath).open(mode: FileMode.append);
      } on FileSystemException {
        throw const CloudKitOperationInterlockException(
          'cloudkit_interlock_unavailable',
        );
      }

      try {
        await handle.lock(FileLock.exclusive);
      } on FileSystemException {
        await _closeQuietly(handle);
        handle = null;
        throw const CloudKitOperationInterlockException(
          'cloudkit_interlock_busy',
        );
      }

      final operation = _ActiveCloudKitOperation(
        lockPath: lockPath,
        kind: kind,
      );
      active = operation;
      heartbeat = Timer.periodic(_heartbeatInterval, (_) {
        if (renewalInFlight != null || operation.fenceLost) return;
        final renewal = _renewFence(fence, operation);
        renewalInFlight = renewal;
        renewal.whenComplete(() {
          if (identical(renewalInFlight, renewal)) {
            renewalInFlight = null;
          }
        });
      });
      final result = await runZoned(
        action,
        zoneValues: <Object, Object>{_zoneLeaseKey: operation},
      );
      // Stop new renewals and settle any renewal already in flight before the
      // final ownership check. Otherwise a late rejected renewal could mark
      // the fence lost only after this method had committed to returning a
      // successful result.
      heartbeat.cancel();
      heartbeat = null;
      await renewalInFlight;
      renewalInFlight = null;
      isolateReservation.requireOwned();
      if (operation.fenceLost) {
        throw const CloudKitOperationInterlockException(
          'cloudkit_interlock_fence_lost',
        );
      }
      return result;
    } finally {
      heartbeat?.cancel();
      await renewalInFlight;
      if (handle != null) {
        if (active?.poisoned ?? false) {
          _poisonedHandles.add(handle);
          _poisonedPaths.add(lockPath);
          retainedUntilRestart = true;
        } else {
          await _releaseQuietly(handle);
        }
      }
      final fence = databaseFence;
      if (fence != null) {
        try {
          await _fenceStore.releaseCoordinatorLease(
            _fenceScope,
            leaseFence: fence,
          );
        } catch (_) {
          // Lease expiry is the final recovery boundary after process death or
          // an unavailable local store. The operation itself has already
          // stopped before this best-effort release.
        }
      }
      if (isolateReservation != null) {
        if (active?.poisoned ?? false) {
          _poisonedIsolateReservations.add(isolateReservation);
        } else {
          isolateReservation.release();
        }
      }
      if (!retainedUntilRestart) {
        _locallyReservedPaths.remove(lockPath);
      }
    }
  }

  Future<void> _renewFence(
    CloudCoordinatorLeaseFence leaseFence,
    _ActiveCloudKitOperation active,
  ) async {
    try {
      final renewed = await _fenceStore.renewCoordinatorLease(
        _fenceScope,
        leaseFence: leaseFence,
        now: DateTime.now(),
        leaseDuration: _leaseDuration,
      );
      if (!renewed) active.fenceLost = true;
    } catch (_) {
      active.fenceLost = true;
    }
  }

  static String _newOwnerId() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String _validateStorageDirectory(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(value, 'privateStorageDirectory');
    }
    final directory = Directory(trimmed).absolute;
    if (!directory.existsSync()) {
      throw ArgumentError.value(
        value,
        'privateStorageDirectory',
        'The existing private storage directory is required',
      );
    }
    try {
      return path.normalize(directory.resolveSymbolicLinksSync());
    } on FileSystemException {
      throw ArgumentError.value(
        value,
        'privateStorageDirectory',
        'The storage directory must resolve to one canonical path',
      );
    }
  }

  static Future<void> _releaseQuietly(RandomAccessFile handle) async {
    try {
      await handle.unlock();
    } on FileSystemException {
      // Closing the handle releases the operating-system lock even if an
      // explicit unlock fails during shutdown or profile teardown.
    }
    await _closeQuietly(handle);
  }

  static Future<void> _closeQuietly(RandomAccessFile handle) async {
    try {
      await handle.close();
    } on FileSystemException {
      // The operation has already ended. Never mask its result with cleanup
      // noise; the operating system will reclaim the handle with the process.
    }
  }
}

/// Same-process, cross-isolate reservation complementing the operating-system
/// lock. POSIX advisory file locks can be process-scoped, so another Dart
/// isolate may otherwise enter through a separately opened handle.
final class _ProcessIsolateReservation {
  _ProcessIsolateReservation._(this.name, this.port);

  final String name;
  final ReceivePort port;

  static _ProcessIsolateReservation acquire(String lockPath) {
    final name =
        'openbubbles.cloudkit-operation.v1:${sha256.convert(utf8.encode(lockPath))}';
    final port = ReceivePort();
    if (!IsolateNameServer.registerPortWithName(port.sendPort, name)) {
      port.close();
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_busy',
      );
    }
    return _ProcessIsolateReservation._(name, port);
  }

  bool get isOwned => IsolateNameServer.lookupPortByName(name) == port.sendPort;

  void requireOwned() {
    if (!isOwned) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_reservation_lost',
      );
    }
  }

  void release() {
    if (isOwned) {
      IsolateNameServer.removePortNameMapping(name);
    }
    port.close();
  }
}

final class _ActiveCloudKitOperation {
  _ActiveCloudKitOperation({required this.lockPath, required this.kind});

  final String lockPath;
  final CloudKitOperationKind kind;
  bool fenceLost = false;
  bool poisoned = false;
}

final class CloudKitOperationInterlockException implements Exception {
  const CloudKitOperationInterlockException(this.safeCode);

  final String safeCode;

  @override
  String toString() => 'CloudKitOperationInterlockException($safeCode)';
}
