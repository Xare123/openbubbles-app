import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_prepared_extension.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_repair_content_digest.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_extension_test_fixture.dart';

CloudMessageEntityPayload _payload({
  CloudSyncPreparedExtension? prepared,
  Uint8List? bytes,
  CloudSemanticFieldState state = CloudSemanticFieldState.value,
  CloudSemanticFieldState bundleState = CloudSemanticFieldState.value,
  String? bundle = extensionTestBundle,
  CloudSemanticAssociationKind association = CloudSemanticAssociationKind.none,
  String logicalKey = 'message-hash',
  String guid = 'message-guid',
}) => CloudMessageEntityPayload(
  logicalEntityKeyHash: logicalKey,
  canonicalGuid: guid,
  chatAliasKeyHash: 'chat-hash',
  chatIdentifier: 'iMessage;-;chat',
  body: 'body',
  senderHandle: 'sender@example.invalid',
  balloonBundleIdState: bundleState,
  balloonBundleId: bundle,
  decodedExtensionPayloadState: state,
  decodedExtensionPayload: bytes,
  preparedExtension: prepared,
  associationKind: association,
  associationParentCanonicalGuid:
      association == CloudSemanticAssociationKind.none ? null : 'parent',
  associationParentLogicalKeyHash:
      association == CloudSemanticAssociationKind.none ? null : 'parent-hash',
);

void main() {
  // No services, native initialization, network, or database required.
  final json = extensionTestJson();
  final prepared = CloudSyncPreparedExtension.parse(
    json,
    expectedParentBundleId: extensionTestBundle,
  );

  test('extension value requires a prepared object and exact bytes', () {
    expect(() => _payload(bytes: prepared.canonicalUtf8), throwsArgumentError);
    expect(() => _payload(prepared: prepared), throwsArgumentError);
    expect(
      () => _payload(prepared: prepared, bytes: Uint8List.fromList([1])),
      throwsArgumentError,
    );
    final different = Uint8List.fromList(prepared.canonicalUtf8)..[0] = 32;
    expect(
      () => _payload(prepared: prepared, bytes: different),
      throwsArgumentError,
    );
  });

  test('v2 session context binds base identity and a distinct update dependency', () {
    final hash = 'A' * 43;
    CloudSyncPreparedExtension session(String role, String guid, String key) {
      final value = jsonDecode(json) as Map<String, dynamic>;
      value['version'] = 2;
      value['context'] = {'role': role, 'session_guid': guid, 'session_logical_key_hash': key};
      return CloudSyncPreparedExtension.parse(jsonEncode(value), expectedParentBundleId: extensionTestBundle);
    }
    final base = session('base', 'message-guid', hash);
    final payload = _payload(prepared: base, bytes: base.canonicalUtf8, logicalKey: hash);
    expect(payload.semanticParentLogicalKeyHash, isNull);
    expect(() => _payload(prepared: base, bytes: base.canonicalUtf8), throwsArgumentError);
    expect(() => _payload(prepared: base, bytes: base.canonicalUtf8, logicalKey: hash, guid: 'other'), throwsArgumentError);
    final update = session('update', 'base-guid', hash);
    final next = _payload(prepared: update, bytes: update.canonicalUtf8, logicalKey: 'B' * 43);
    expect(next.extensionParentCanonicalGuid, 'base-guid');
    expect(next.semanticParentLogicalKeyHash, hash);
    expect(next.replyParentCanonicalGuid, isNull);
    expect(next.associationKind, CloudSemanticAssociationKind.none);
    expect(() => _payload(prepared: update, bytes: update.canonicalUtf8, logicalKey: hash), throwsArgumentError);
    expect(() => _payload(prepared: update, bytes: update.canonicalUtf8, guid: 'base-guid'), throwsArgumentError);
  });

  test('prepared value requires matching balloon value and no reaction', () {
    expect(
      () => _payload(
        prepared: prepared,
        bytes: prepared.canonicalUtf8,
        bundle: 'other',
      ),
      throwsArgumentError,
    );
    for (final state in [
      CloudSemanticFieldState.absent,
      CloudSemanticFieldState.explicitClear,
    ]) {
      expect(
        () => _payload(
          prepared: prepared,
          bytes: prepared.canonicalUtf8,
          bundleState: state,
          bundle: null,
        ),
        throwsArgumentError,
      );
      expect(
        () => _payload(prepared: prepared, state: state),
        throwsArgumentError,
      );
    }
    for (final association in [
      CloudSemanticAssociationKind.reactionAdd,
      CloudSemanticAssociationKind.reactionRemove,
    ]) {
      expect(
        () => _payload(
          prepared: prepared,
          bytes: prepared.canonicalUtf8,
          association: association,
        ),
        throwsArgumentError,
      );
    }
  });

  test('digest uses immutable exact native bytes, not renderer JSON', () {
    final source = Uint8List.fromList(prepared.canonicalUtf8);
    final payload = _payload(prepared: prepared, bytes: source);
    final digest = CloudKitV2CanonicalRepairDigest.forPayload(payload);
    source[0] = 32;
    expect(payload.decodedExtensionPayload, utf8.encode(json));
    expect(
      () => payload.decodedExtensionPayload![0] = 32,
      throwsUnsupportedError,
    );
    expect(
      () => payload.decodedExtensionPayload!.buffer.asUint8List()[0] = 32,
      throwsUnsupportedError,
    );
    expect(CloudKitV2CanonicalRepairDigest.forPayload(payload), digest);
    final spaced = CloudSyncPreparedExtension.parse(
      ' $json\n',
      expectedParentBundleId: extensionTestBundle,
    );
    expect(spaced.toPayloadData().toJson(), prepared.toPayloadData().toJson());
    expect(
      CloudKitV2CanonicalRepairDigest.forPayload(
        _payload(prepared: spaced, bytes: spaced.canonicalUtf8),
      ),
      isNot(digest),
    );
    expect(
      () => _payload(prepared: spaced, bytes: prepared.canonicalUtf8),
      throwsArgumentError,
    );
  });
}
