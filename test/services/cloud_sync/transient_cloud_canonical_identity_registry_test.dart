import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/transient_cloud_canonical_identity_registry.dart';
import 'package:flutter_test/flutter_test.dart';

final _scopeA = _makeScope();
final _scopeB = _makeScope(zone: 'zone-b');

CloudSyncScope _makeScope({String zone = 'zone-a'}) {
  return CloudSyncScope(
    accountFingerprint: List.filled(43, 'a').join(),
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: zone,
  );
}

CloudSemanticSnapshot _snapshot(CloudSemanticEntityPayload payload) {
  return CloudSemanticSnapshot(
    kind: payload.kind,
    logicalEntityKeyHash: payload.logicalEntityKeyHash,
  );
}

CloudDecodedMutation _upsert(
  CloudSemanticEntityPayload payload, {
  CloudSyncScope? scope,
  int generation = 7,
}) {
  return CloudDecodedMutation.upsert(
    scope: scope ?? _scopeA,
    generation: generation,
    changeId: 'change-${payload.logicalEntityKeyHash}',
    snapshot: _snapshot(payload),
    payload: payload,
  );
}

CloudMessageEntityPayload _message({
  String logicalKey = 'message-key',
  String canonicalGuid = 'message-guid',
  String? replyKey = 'reply-key',
  String? replyGuid = 'reply-guid',
  String? associationKey,
  String? associationGuid,
}) {
  return CloudMessageEntityPayload(
    logicalEntityKeyHash: logicalKey,
    canonicalGuid: canonicalGuid,
    chatAliasKeyHash: 'chat-key',
    chatIdentifier: 'iMessage;-;chat',
    body: 'message body',
    senderHandle: 'sender@example.invalid',
    replyParentLogicalKeyHash: replyKey,
    replyParentCanonicalGuid: replyGuid,
    replyParentPart: replyKey == null ? null : '0',
    associationKind: associationKey == null
        ? CloudSemanticAssociationKind.none
        : CloudSemanticAssociationKind.reactionAdd,
    associationParentLogicalKeyHash: associationKey,
    associationParentCanonicalGuid: associationGuid,
    associationParentPart: associationKey == null ? null : 0,
    associatedRangeLocation: associationKey == null ? null : 0,
    associatedRangeLength: associationKey == null ? null : 5,
  );
}

CloudReactionEntityPayload _reaction() {
  return CloudReactionEntityPayload(
    logicalEntityKeyHash: 'reaction-key',
    canonicalGuid: 'reaction-guid',
    parentLogicalKeyHash: 'parent-message-key',
    parentCanonicalGuid: 'parent-message-guid',
    parentPart: 0,
    senderHandle: 'sender@example.invalid',
    reactionType: 'like',
  );
}

CloudAttachmentEntityPayload _ownedAttachment() {
  return CloudAttachmentEntityPayload(
    logicalEntityKeyHash: 'attachment-key',
    canonicalGuid: 'attachment-guid',
    ownerLogicalKeyHash: 'owner-message-key',
    ownerCanonicalGuid: 'owner-message-guid',
    ownerPart: 0,
    fileName: 'photo.jpg',
    mimeType: 'image/jpeg',
    bodyCapability: CloudAttachmentBodyCapability.materializable,
    protectedLocalReference: 'protected:attachment',
  );
}

CloudChatEntityPayload _chat() {
  return CloudChatEntityPayload(
    logicalEntityKeyHash: 'chat-key',
    canonicalGuid: 'chat-guid',
    chatIdentifier: 'iMessage;-;chat',
    displayName: 'Test chat',
    participantHandles: const ['participant@example.invalid'],
  );
}

void main() {
  test('binds message, reply, and association parent identities', () {
    final registry = TransientCloudCanonicalIdentityRegistry();
    final lease = registry.bind(
      _upsert(
        _message(
          associationKey: 'associated-message-key',
          associationGuid: 'associated-message-guid',
        ),
      ),
    );

    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'message-key',
      ),
      'message-guid',
    );
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'reply-key',
      ),
      'reply-guid',
    );
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'associated-message-key',
      ),
      'associated-message-guid',
    );

    lease.release();
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'message-key',
      ),
      isNull,
    );
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'reply-key',
      ),
      isNull,
    );
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'associated-message-key',
      ),
      isNull,
    );
  });

  test('binds reaction and its parent message identity', () {
    final registry = TransientCloudCanonicalIdentityRegistry();
    final lease = registry.bind(_upsert(_reaction()));

    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.reaction,
        logicalEntityKeyHash: 'reaction-key',
      ),
      'reaction-guid',
    );
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'parent-message-key',
      ),
      'parent-message-guid',
    );

    lease.release();
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.reaction,
        logicalEntityKeyHash: 'reaction-key',
      ),
      isNull,
    );
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'parent-message-key',
      ),
      isNull,
    );
  });

  test(
    'rejects one canonical GUID shared across message and reaction kinds',
    () {
      final registry = TransientCloudCanonicalIdentityRegistry();
      final payload = CloudReactionEntityPayload(
        logicalEntityKeyHash: 'reaction-key',
        canonicalGuid: 'shared-guid',
        parentLogicalKeyHash: 'parent-message-key',
        parentCanonicalGuid: 'shared-guid',
        parentPart: 0,
        senderHandle: 'sender@example.invalid',
        reactionType: 'like',
      );

      expect(() => registry.bind(_upsert(payload)), throwsA(isA<StateError>()));
      expect(registry.hasActiveLease, isFalse);
    },
  );

  test('binds an owned attachment and its owner message identity', () {
    final registry = TransientCloudCanonicalIdentityRegistry();
    final lease = registry.bind(_upsert(_ownedAttachment()));

    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.attachment,
        logicalEntityKeyHash: 'attachment-key',
      ),
      'attachment-guid',
    );
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'owner-message-key',
      ),
      'owner-message-guid',
    );

    lease.release();
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.attachment,
        logicalEntityKeyHash: 'attachment-key',
      ),
      isNull,
    );
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'owner-message-key',
      ),
      isNull,
    );
  });

  test('binds a chat identity', () {
    final registry = TransientCloudCanonicalIdentityRegistry();
    final lease = registry.bind(_upsert(_chat()));

    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: 'chat-key',
      ),
      'chat-guid',
    );

    lease.release();
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: 'chat-key',
      ),
      isNull,
    );
  });

  test('fences every lookup by exact scope, generation, kind, and hash', () {
    final registry = TransientCloudCanonicalIdentityRegistry();
    final lease = registry.bind(_upsert(_reaction()));

    String? resolve({
      CloudSyncScope? scope,
      int generation = 7,
      CloudEntityKind kind = CloudEntityKind.reaction,
      String hash = 'reaction-key',
    }) {
      return registry.resolveCanonicalGuid(
        scope: scope ?? _scopeA,
        generation: generation,
        kind: kind,
        logicalEntityKeyHash: hash,
      );
    }

    expect(resolve(), 'reaction-guid');
    expect(resolve(scope: _scopeB), isNull);
    expect(resolve(generation: 8), isNull);
    expect(resolve(kind: CloudEntityKind.message), isNull);
    expect(resolve(hash: 'parent-message-key'), isNull);
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'parent-message-key',
      ),
      'parent-message-guid',
    );

    lease.release();
  });

  test('release clears every mapping and is idempotent', () {
    final registry = TransientCloudCanonicalIdentityRegistry();
    final lease = registry.bind(
      _upsert(
        _message(
          associationKey: 'associated-message-key',
          associationGuid: 'associated-message-guid',
        ),
      ),
    );

    expect(registry.hasActiveLease, isTrue);
    lease.release();
    lease.release();

    expect(registry.hasActiveLease, isFalse);
    for (final entry in const [
      (CloudEntityKind.message, 'message-key'),
      (CloudEntityKind.message, 'reply-key'),
      (CloudEntityKind.message, 'associated-message-key'),
    ]) {
      expect(
        registry.resolveCanonicalGuid(
          scope: _scopeA,
          generation: 7,
          kind: entry.$1,
          logicalEntityKeyHash: entry.$2,
        ),
        isNull,
      );
    }
  });

  test('overlapping bind fails closed and preserves the active lease', () {
    final registry = TransientCloudCanonicalIdentityRegistry();
    final firstLease = registry.bind(_upsert(_message()));

    expect(() => registry.bind(_upsert(_chat())), throwsA(isA<StateError>()));
    expect(registry.hasActiveLease, isTrue);
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'message-key',
      ),
      'message-guid',
    );

    firstLease.release();
    final secondLease = registry.bind(_upsert(_chat()));
    expect(registry.hasActiveLease, isTrue);
    secondLease.release();
  });

  test('unsupported profile and tombstone leave no active state', () {
    final registry = TransientCloudCanonicalIdentityRegistry();
    final profile = CloudProfileEntityPayload(
      logicalEntityKeyHash: 'profile-key',
      displayName: 'Profile',
      handle: 'profile@example.invalid',
    );

    expect(() => registry.bind(_upsert(profile)), throwsA(isA<StateError>()));
    expect(registry.hasActiveLease, isFalse);

    final tombstone = CloudDecodedMutation.tombstone(
      scope: _scopeA,
      generation: 7,
      changeId: 'tombstone-change',
      tombstone: CloudSemanticTombstone(
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'deleted-message-key',
        deletedAt: DateTime.utc(2026, 8, 22),
        serverConfirmed: true,
      ),
    );
    expect(() => registry.bind(tombstone), throwsA(isA<StateError>()));
    expect(registry.hasActiveLease, isFalse);

    final lease = registry.bind(_upsert(_chat()));
    expect(registry.hasActiveLease, isTrue);
    lease.release();
  });

  test('conflicting duplicate logical mapping leaves no active state', () {
    final registry = TransientCloudCanonicalIdentityRegistry();
    final conflicting = _message(
      logicalKey: 'same-logical-key',
      canonicalGuid: 'own-guid',
      replyKey: 'same-logical-key',
      replyGuid: 'different-parent-guid',
    );

    expect(
      () => registry.bind(_upsert(conflicting)),
      throwsA(isA<StateError>()),
    );
    expect(registry.hasActiveLease, isFalse);
    expect(
      registry.resolveCanonicalGuid(
        scope: _scopeA,
        generation: 7,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'same-logical-key',
      ),
      isNull,
    );
  });
}
