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
}) => CloudMessageEntityPayload(
  logicalEntityKeyHash: 'message-hash',
  canonicalGuid: 'message-guid',
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
