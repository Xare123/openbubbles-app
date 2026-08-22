import 'cloud_inbox_applier.dart';
import 'cloud_sync_models.dart';
import 'objectbox_canonical_semantic_entity_adapter.dart';

/// Single-mutation, memory-only identity bridge between native decode and the
/// synchronous canonical ObjectBox adapter.
///
/// Canonical GUIDs are never serialized or retained after [release]. One
/// registry intentionally supports only one active mutation so overlapping or
/// stale transactions fail closed.
final class TransientCloudCanonicalIdentityRegistry
    implements
        CloudCanonicalIdentityResolver,
        CloudTransientCanonicalIdentityRegistrar {
  CloudSyncScope? _scope;
  int? _generation;
  int _leaseGeneration = 0;
  Map<(CloudEntityKind, String), String>? _identities;

  bool get hasActiveLease => _identities != null;

  @override
  CloudTransientCanonicalIdentityLease bind(CloudDecodedMutation mutation) {
    if (_identities != null) {
      throw StateError('cloud_canonical_identity_registry_active');
    }
    if (mutation.kind != CloudDecodedMutationKind.upsert ||
        mutation.payload == null) {
      throw StateError('cloud_canonical_identity_registry_payload_invalid');
    }

    final identities = <(CloudEntityKind, String), String>{};
    void add(CloudEntityKind kind, String hash, String guid) {
      if (hash.isEmpty || guid.isEmpty) {
        throw StateError('cloud_canonical_identity_registry_entry_invalid');
      }
      final key = (kind, hash);
      final existing = identities[key];
      if (existing != null && existing != guid) {
        throw StateError('cloud_canonical_identity_registry_conflict');
      }
      identities[key] = guid;
    }

    final payload = mutation.payload!;
    switch (payload) {
      case CloudMessageEntityPayload value:
        add(
          CloudEntityKind.message,
          value.logicalEntityKeyHash,
          value.canonicalGuid,
        );
        if (value.replyParentLogicalKeyHash != null) {
          add(
            CloudEntityKind.message,
            value.replyParentLogicalKeyHash!,
            value.replyParentCanonicalGuid!,
          );
        }
        if (value.associationParentLogicalKeyHash != null) {
          add(
            CloudEntityKind.message,
            value.associationParentLogicalKeyHash!,
            value.associationParentCanonicalGuid!,
          );
        }
      case CloudChatEntityPayload value:
        add(
          CloudEntityKind.chat,
          value.logicalEntityKeyHash,
          value.canonicalGuid,
        );
      case CloudAttachmentEntityPayload value:
        add(
          CloudEntityKind.attachment,
          value.logicalEntityKeyHash,
          value.canonicalGuid,
        );
        if (value.ownerLogicalKeyHash != null) {
          add(
            CloudEntityKind.message,
            value.ownerLogicalKeyHash!,
            value.ownerCanonicalGuid!,
          );
        }
      case CloudReactionEntityPayload value:
        add(
          CloudEntityKind.reaction,
          value.logicalEntityKeyHash,
          value.canonicalGuid,
        );
        add(
          CloudEntityKind.message,
          value.parentLogicalKeyHash,
          value.parentCanonicalGuid,
        );
      case CloudGroupPhotoEntityPayload value:
        add(
          CloudEntityKind.groupPhoto,
          value.logicalEntityKeyHash,
          value.photoGuid,
        );
      case CloudProfileEntityPayload _:
        throw StateError(
          'cloud_canonical_identity_registry_payload_unsupported',
        );
    }

    _scope = mutation.scope;
    _generation = mutation.generation;
    _identities = Map.unmodifiable(identities);
    final leaseGeneration = ++_leaseGeneration;
    return _TransientCloudCanonicalIdentityLease(
      releaseCallback: () => _release(leaseGeneration),
    );
  }

  @override
  String? resolveCanonicalGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {
    if (_scope != scope || _generation != generation) return null;
    return _identities?[(kind, logicalEntityKeyHash)];
  }

  void _release(int leaseGeneration) {
    if (_identities == null || leaseGeneration != _leaseGeneration) return;
    _identities = null;
    _scope = null;
    _generation = null;
  }
}

final class _TransientCloudCanonicalIdentityLease
    implements CloudTransientCanonicalIdentityLease {
  _TransientCloudCanonicalIdentityLease({required this.releaseCallback});

  final void Function() releaseCallback;
  bool _released = false;

  @override
  void release() {
    if (_released) return;
    _released = true;
    releaseCallback();
  }
}
