import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';

enum CloudKitOperationKind {
  legacyReadWrite,
  v2ShadowRead,
  v2SemanticRead,
  destructiveReset,
}

typedef CloudKitOperationBody<T> = Future<T> Function();

/// A process- and isolate-wide exclusion boundary for private CloudKit work.
///
/// Android may run the legacy CloudKit path in a second Dart isolate, while
/// Windows may have more than one app process touching the same profile. A
/// static mutex cannot cover either case, so every operation also holds an
/// operating-system file lock in the existing private support directory.
///
/// Re-entry is permitted only for the same operation kind. This lets the
/// legacy sync call smaller legacy upload helpers without deadlocking, while
/// ensuring a write helper accidentally reached from the V2 shadow sampler
/// fails closed.
final class CloudKitOperationInterlock {
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
  static String get fenceScopeKey => _fenceScope.storageKey;

  static final Object _zoneLeaseKey = Object();
  static final Set<String> _locallyReservedPaths = <String>{};

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
      return action();
    }

    if (!_locallyReservedPaths.add(lockPath)) {
      throw const CloudKitOperationInterlockException(
        'cloudkit_interlock_busy',
      );
    }

    RandomAccessFile? handle;
    Timer? heartbeat;
    Future<void>? renewalInFlight;
    final ownerId = _newOwnerId();
    CloudCoordinatorLeaseFence? databaseFence;
    try {
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

      final active = _ActiveCloudKitOperation(lockPath: lockPath, kind: kind);
      heartbeat = Timer.periodic(_heartbeatInterval, (_) {
        if (renewalInFlight != null || active.fenceLost) return;
        final renewal = _renewFence(fence, active);
        renewalInFlight = renewal;
        renewal.whenComplete(() {
          if (identical(renewalInFlight, renewal)) {
            renewalInFlight = null;
          }
        });
      });
      final result = await runZoned(
        action,
        zoneValues: <Object, Object>{_zoneLeaseKey: active},
      );
      throwIfActiveFenceLost();
      return result;
    } finally {
      heartbeat?.cancel();
      await renewalInFlight;
      if (handle != null) {
        await _releaseQuietly(handle);
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
      _locallyReservedPaths.remove(lockPath);
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
    return path.normalize(directory.path);
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

final class _ActiveCloudKitOperation {
  _ActiveCloudKitOperation({required this.lockPath, required this.kind});

  final String lockPath;
  final CloudKitOperationKind kind;
  bool fenceLost = false;
}

final class CloudKitOperationInterlockException implements Exception {
  const CloudKitOperationInterlockException(this.safeCode);

  final String safeCode;

  @override
  String toString() => 'CloudKitOperationInterlockException($safeCode)';
}
