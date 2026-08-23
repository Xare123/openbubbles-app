// ignore_for_file: prefer_initializing_formals

import 'package:objectbox/objectbox.dart';

import 'cloud_sync_production_sampler_adapter.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

typedef ActiveCloudKitClientReader = Object? Function();

/// Binds one remote mutation to the active native identity and a durable
/// single-writer permit.
///
/// This guard must run inside [CloudKitOperationInterlock]. Authority
/// transitions use the same interlock, so a transition cannot overtake a
/// mutation after its permit is issued. The post-action checks turn any
/// impossible identity/epoch race into an unknown outcome instead of allowing
/// the caller to record an unverified success.
final class CloudKitWriterMutationGuard {
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

  Future<T> run<T>({
    required CloudKitWriterOwner owner,
    required Future<T> Function() action,
  }) async {
    CloudKitOperationInterlock.requireActive(
      CloudKitOperationKind.legacyReadWrite,
    );
    final client = _readActiveClient();
    if (client == null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_active_client_missing',
      );
    }
    final before = await _capture(client);
    if (!identical(client, _readActiveClient())) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_identity_changed_before_mutation',
      );
    }
    final scope = CloudKitWriterScope(
      accountFingerprint: before.accountFingerprint,
    );
    final permit = _authority.issuePermit(scope, expectedOwner: owner);

    late final T value;
    try {
      value = await action();
    } catch (_) {
      // Once the remote action starts, an exception cannot prove that Apple
      // rejected the request. Revoke the durable writer epoch and require
      // explicit reconciliation instead of allowing any automatic retry.
      try {
        _authority.markMutationUnknown(permit, now: _clock());
      } catch (_) {
        // A concurrent fence only strengthens the fail-closed result.
      }
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
    } catch (_) {
      // The network action already returned. A failed postcondition cannot
      // prove whether CloudKit committed it, so never expose it as a normal
      // retryable failure.
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_outcome_unknown',
      );
    }
    return value;
  }

  Future<CloudSyncNativeAuthMetadata> _capture(Object client) =>
      _nativeAuthBinding.capture(
        cloudMessagesClient: client,
        privateStorageDirectory: _privateStorageDirectory,
      );
}
