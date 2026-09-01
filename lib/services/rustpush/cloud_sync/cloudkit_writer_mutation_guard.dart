// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:objectbox/objectbox.dart';
import 'package:path/path.dart' as path;

import 'cloud_sync_production_sampler_adapter.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

typedef ActiveCloudKitClientReader = Object? Function();

final RegExp _cloudKitWriterSha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// Narrow capability used by the protected V2 transport at the exact native
/// mutation boundary.
abstract interface class CloudKitWriterMutationRunner {
  void requireClear();

  void markActiveMutationUnknown();

  Future<T> runAuthorized<T>({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    required String? preparedHandleBindingSha256,
    required void Function() requireAdmission,
    required Future<T> Function(CloudKitWriterMutationCapability capability)
    action,
  });
}

/// Non-constructible, single-use native mutation capability.
///
/// The raw random token exists only for the lifetime of one guarded action.
/// Durable state and diagnostics retain only its SHA-256 digest.
final class CloudKitWriterMutationCapability {
  CloudKitWriterMutationCapability._(String token) : _token = token;

  String? _token;

  bool get consumed => _token == null;

  String consumeForNative() {
    final token = _token;
    if (token == null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_capability_consumed',
      );
    }
    _token = null;
    return token;
  }

  @override
  String toString() => 'CloudKitWriterMutationCapability(redacted)';
}

final class _ActiveCloudKitMutation {
  _ActiveCloudKitMutation({required this.permit});

  final CloudKitWriterPermit permit;
  bool forcedUnknown = false;
}

/// Binds one remote mutation to the active native identity and a durable
/// single-writer permit.
///
/// This guard must run inside [CloudKitOperationInterlock]. Authority
/// transitions use the same interlock, so a transition cannot overtake a
/// mutation after its permit is issued. The post-action checks turn any
/// impossible identity/epoch race into an unknown outcome instead of allowing
/// the caller to record an unverified success.
final class CloudKitWriterMutationGuard
    implements CloudKitWriterMutationRunner {
  CloudKitWriterMutationGuard({
    required Store store,
    required ActiveCloudKitClientReader readActiveClient,
    required String privateStorageDirectory,
    CloudSyncNativeAuthBinding? nativeAuthBinding,
    DateTime Function()? clock,
  }) : _readActiveClient = readActiveClient,
       _privateStorageDirectory = privateStorageDirectory,
       _clock = clock ?? DateTime.now,
       _nativeAuthBinding =
           nativeAuthBinding ?? FrbCloudSyncNativeAuthBinding(),
       _authority = ObjectBoxCloudKitWriterAuthority(store: store) {
    if (privateStorageDirectory.isEmpty) {
      throw ArgumentError.value(
        privateStorageDirectory,
        'privateStorageDirectory',
        'must not be empty',
      );
    }
  }

  CloudKitWriterMutationGuard.forTest({
    required Store store,
    required ActiveCloudKitClientReader readActiveClient,
    required String privateStorageDirectory,
    required CloudKitWriterOwnershipDecision buildDecision,
    CloudSyncNativeAuthBinding? nativeAuthBinding,
    DateTime Function()? clock,
  }) : _readActiveClient = readActiveClient,
       _privateStorageDirectory = privateStorageDirectory,
       _clock = clock ?? DateTime.now,
       _nativeAuthBinding =
           nativeAuthBinding ?? FrbCloudSyncNativeAuthBinding(),
       _authority = ObjectBoxCloudKitWriterAuthority.forTest(
         store: store,
         buildDecision: buildDecision,
       ) {
    if (privateStorageDirectory.isEmpty) {
      throw ArgumentError.value(
        privateStorageDirectory,
        'privateStorageDirectory',
        'must not be empty',
      );
    }
  }

  final ActiveCloudKitClientReader _readActiveClient;
  final String _privateStorageDirectory;
  final CloudSyncNativeAuthBinding _nativeAuthBinding;
  final ObjectBoxCloudKitWriterAuthority _authority;
  final DateTime Function() _clock;

  @override
  void requireClear() => _PersistentCloudKitMutationFence(
    privateStorageDirectory: _privateStorageDirectory,
  ).requireClear();

  Future<T> run<T>({
    required CloudKitWriterOwner owner,
    required Future<T> Function() action,
  }) async {
    final expectedClient = _readActiveClient();
    if (expectedClient == null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_active_client_missing',
      );
    }
    return runAuthorized(
      owner: owner,
      expectedClient: expectedClient,
      preparedHandleBindingSha256: null,
      requireAdmission: () {},
      action: (_) => action(),
    );
  }

  @override
  void markActiveMutationUnknown() {
    final active = _activeMutation;
    if (active == null) return;
    active.forcedUnknown = true;
    _markMutationUnknownFailClosed(active.permit);
  }

  _ActiveCloudKitMutation? _activeMutation;

  @override
  Future<T> runAuthorized<T>({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    required String? preparedHandleBindingSha256,
    required void Function() requireAdmission,
    required Future<T> Function(CloudKitWriterMutationCapability capability)
    action,
  }) async {
    final operationKind = switch (owner) {
      CloudKitWriterOwner.legacy => CloudKitOperationKind.legacyReadWrite,
      CloudKitWriterOwner.v2 => CloudKitOperationKind.v2ReadWrite,
      CloudKitWriterOwner.none => throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_owner_invalid',
      ),
    };
    CloudKitOperationInterlock.requireActive(operationKind);
    requireAdmission();
    requireClear();
    final client = _readActiveClient();
    if (client == null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_active_client_missing',
      );
    }
    if (!identical(client, expectedClient)) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_transport_client_mismatch',
      );
    }
    if (owner == CloudKitWriterOwner.v2 &&
        (preparedHandleBindingSha256 == null ||
            !_cloudKitWriterSha256Pattern.hasMatch(
              preparedHandleBindingSha256,
            ))) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_prepared_handle_binding_invalid',
      );
    }
    final before = await _capture(client);
    // A timeout can poison admission while native identity capture is pending.
    // Recheck before arming the fence; after this point no await occurs until
    // [_activeMutation] is installed, so late timeout poisoning is observable.
    requireAdmission();
    if (!identical(client, _readActiveClient())) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_identity_changed_before_mutation',
      );
    }
    final scope = CloudKitWriterScope(
      accountFingerprint: before.accountFingerprint,
    );
    final permit = _authority.issuePermit(scope, expectedOwner: owner);
    if (_activeMutation != null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_already_active',
      );
    }
    final capabilityToken = _newCapabilityToken();
    final capabilityDigest = sha256
        .convert(utf8.encode(capabilityToken))
        .toString();
    final capability = CloudKitWriterMutationCapability._(capabilityToken);
    final persistentFence = _PersistentCloudKitMutationFence(
      privateStorageDirectory: _privateStorageDirectory,
    );
    persistentFence.arm(
      permit,
      protectedStoreIdentity: before.protectedStoreIdentity,
      capabilityDigest: capabilityDigest,
      preparedHandleBindingSha256:
          preparedHandleBindingSha256 ?? capabilityDigest,
    );
    final active = _ActiveCloudKitMutation(permit: permit);
    _activeMutation = active;
    try {
      late final T value;
      try {
        CloudKitOperationInterlock.requireActive(operationKind);
        value = await action(capability);
        CloudKitOperationInterlock.requireActive(operationKind);
        if (active.forcedUnknown ||
            (owner == CloudKitWriterOwner.v2 && !capability.consumed)) {
          throw const CloudKitWriterAuthorityFailure(
            'cloudkit_writer_mutation_outcome_unknown',
          );
        }
      } catch (_) {
        // Once the remote action starts, an exception cannot prove that Apple
        // rejected the request. Revoke the durable writer epoch and require
        // explicit reconciliation instead of allowing any automatic retry.
        active.forcedUnknown = true;
        _markMutationUnknownFailClosed(permit);
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_outcome_unknown',
        );
      }

      try {
        if (!identical(client, _readActiveClient())) {
          throw const CloudKitWriterAuthorityFailure(
            'cloudkit_writer_active_client_replaced',
          );
        }
        final after = await _capture(client);
        if (after.accountFingerprint != before.accountFingerprint ||
            after.protectedStoreIdentity != before.protectedStoreIdentity) {
          throw const CloudKitWriterAuthorityFailure(
            'cloudkit_writer_active_identity_changed',
          );
        }
        _authority.verifyPermit(permit);
        if (active.forcedUnknown) {
          throw const CloudKitWriterAuthorityFailure(
            'cloudkit_writer_mutation_outcome_unknown',
          );
        }
      } catch (_) {
        // The network action already returned. A failed postcondition cannot
        // prove whether CloudKit committed it, so never expose it as a normal
        // retryable failure.
        active.forcedUnknown = true;
        _markMutationUnknownFailClosed(permit);
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_outcome_unknown',
        );
      }
      try {
        persistentFence.disarm(
          permit,
          protectedStoreIdentity: before.protectedStoreIdentity,
          capabilityDigest: capabilityDigest,
          preparedHandleBindingSha256:
              preparedHandleBindingSha256 ?? capabilityDigest,
        );
      } catch (_) {
        active.forcedUnknown = true;
        _markMutationUnknownFailClosed(permit);
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_release_failed',
        );
      }
      return value;
    } finally {
      if (identical(_activeMutation, active)) {
        _activeMutation = null;
      }
    }
  }

  String _newCapabilityToken() {
    final random = Random.secure();
    return List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<CloudSyncNativeAuthMetadata> _capture(Object client) =>
      _nativeAuthBinding.capture(
        cloudMessagesClient: client,
        privateStorageDirectory: _privateStorageDirectory,
      );

  void _markMutationUnknownFailClosed(CloudKitWriterPermit permit) {
    try {
      _authority.markMutationUnknown(permit, now: _clock());
    } catch (_) {
      // Suppress only a transition that durable readback proves already
      // invalidated this permit. The write-ahead filesystem fence remains in
      // place in either case and blocks every later process until explicit
      // reconciliation.
      CloudKitWriterAuthoritySnapshot? current;
      try {
        current = _authority.read(permit.scope);
      } catch (_) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_authority_fence_failed',
        );
      }
      final alreadyFenced =
          current == null ||
          current.state != CloudKitWriterAuthorityState.stable ||
          current.owner != permit.owner ||
          current.epoch != permit.epoch;
      if (!alreadyFenced) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_authority_fence_failed',
        );
      }
    }
  }
}

/// A content-free write-ahead fence independent of ObjectBox.
///
/// The file is armed before the network action starts and removed only after
/// the action and all identity/authority postconditions succeed. A crash or an
/// ObjectBox write failure therefore leaves a durable startup poison instead
/// of silently restoring a replay-capable stable authority.
final class _PersistentCloudKitMutationFence {
  _PersistentCloudKitMutationFence({required String privateStorageDirectory})
    : _file = File(
        path.join(
          privateStorageDirectory,
          '.openbubbles-cloudkit-writer-mutation-v1.fence',
        ),
      );

  final File _file;

  void requireClear() {
    if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_reconciliation_required',
      );
    }
  }

  void arm(
    CloudKitWriterPermit permit, {
    required String protectedStoreIdentity,
    required String capabilityDigest,
    required String preparedHandleBindingSha256,
  }) {
    requireClear();

    final encoded = _encode(
      permit,
      protectedStoreIdentity: protectedStoreIdentity,
      capabilityDigest: capabilityDigest,
      preparedHandleBindingSha256: preparedHandleBindingSha256,
    );
    RandomAccessFile? handle;
    try {
      // Exclusive creation makes a crash between creation and payload flush
      // fail closed: the empty file is still a durable reconciliation fence.
      _file.createSync(exclusive: true);
      handle = _file.openSync(mode: FileMode.write);
      handle.writeStringSync(encoded, encoding: utf8);
      handle.flushSync();
    } on FileSystemException {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_fence_arm_failed',
      );
    } finally {
      try {
        handle?.closeSync();
      } on FileSystemException {
        // Exact readback below remains authoritative.
      }
    }

    try {
      if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          _file.readAsStringSync(encoding: utf8) != encoded) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_arm_failed',
        );
      }
    } on FileSystemException {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_fence_arm_failed',
      );
    }
  }

  void disarm(
    CloudKitWriterPermit permit, {
    required String protectedStoreIdentity,
    required String capabilityDigest,
    required String preparedHandleBindingSha256,
  }) {
    final encoded = _encode(
      permit,
      protectedStoreIdentity: protectedStoreIdentity,
      capabilityDigest: capabilityDigest,
      preparedHandleBindingSha256: preparedHandleBindingSha256,
    );
    try {
      if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          _file.readAsStringSync(encoding: utf8) != encoded) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_corrupt',
        );
      }
      _file.deleteSync();
      if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_release_failed',
        );
      }
    } on CloudKitWriterAuthorityFailure {
      rethrow;
    } on FileSystemException {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_fence_release_failed',
      );
    }
  }

  String _encode(
    CloudKitWriterPermit permit, {
    required String protectedStoreIdentity,
    required String capabilityDigest,
    required String preparedHandleBindingSha256,
  }) => jsonEncode(<String, Object>{
    'accountFingerprint': permit.scope.accountFingerprint,
    'capabilitySha256': capabilityDigest,
    'container': permit.scope.container,
    'database': permit.scope.database,
    'epoch': permit.epoch,
    'owner': permit.owner.name,
    'preparedHandleBindingSha256': preparedHandleBindingSha256,
    'protectedStoreIdentity': protectedStoreIdentity,
    'version': 2,
  });
}
