import 'dart:convert';

import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

import 'cloud_sync_received_archive_identity.dart';

enum CloudSyncReceivedMutationKind { edit, unsend }

/// Bounded identity of an edit/unsend observed on the live receive path.
///
/// The context is a caller observation, not authentication or remote authority.
/// Account/store/epoch, original-message provenance, parent proof and conditional
/// update admission remain separate. This never produces an outgoing receipt,
/// stages a source, or retains raw GUIDs, content or handles.
final class CloudSyncReceivedMutationIdentity {
  const CloudSyncReceivedMutationIdentity._({
    required this.kind,
    required this.guidHash,
    required this.targetGuidHash,
    required this.targetPart,
    required this.sourceSha256,
    required this.origin,
    required this.sentTimestamp,
  });

  final CloudSyncReceivedMutationKind kind;
  final String guidHash;
  final String targetGuidHash;
  final int targetPart;
  final String sourceSha256;
  final CloudSyncReceivedArchiveOrigin origin;
  final int sentTimestamp;

  static const _maxSignedInt64 = 0x7fffffffffffffff;
  static const _maxHandleBytes = 4096;
  static const _maxObservedLocalHandles = 64;
  static const _maxParticipants = 64;
  static const _maxParts = 128;
  static const _maxTextBytes = 256 * 1024;
  static const _nilUuid = '00000000-0000-0000-0000-000000000000';
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// Captures the exact received wire without normalizing or modifying it.
  /// Unsupported or changed sources return null. Hashes identify the received
  /// lane only; they are neither Apple record names nor cross-lane send proof.
  static CloudSyncReceivedMutationIdentity? captureWire(
    api.MessageInst wire, {
    required CloudSyncReceivedArchiveLiveContext liveContext,
    String? expectedSourceSha256,
  }) {
    if (!liveContext.observedViaLiveReceive) return null;
    return _identifyWire(
      wire,
      localHandles: liveContext.observedLocalHandles,
      recipient: liveContext.receivedOnHandle,
      expectedSourceSha256: expectedSourceSha256,
    );
  }

  /// Revalidate the typed result of native seed reopening. This does not claim
  /// another live receive or confer native authority. Account/store ownership
  /// remains the journal's responsibility. A remote updater must separately
  /// reopen the encrypted source and prove the decrypted original author.
  static CloudSyncReceivedMutationIdentity? restoreNative(
    api.CloudSyncRestoredReceivedMutation restored, {
    required String expectedGuidHash,
    required String expectedTargetGuidHash,
    required String expectedSourceSha256,
  }) {
    final recipient = restored.message.receivedOnHandle;
    if (recipient == null ||
        restored.mutationGuidHash != expectedGuidHash ||
        restored.targetGuidHash != expectedTargetGuidHash ||
        restored.sourceSha256 != expectedSourceSha256) {
      return null;
    }
    final identity = _identifyWire(
      restored.message,
      localHandles: restored.capturedLocalHandles,
      recipient: recipient,
      expectedSourceSha256: expectedSourceSha256,
    );
    if (identity?.guidHash != expectedGuidHash ||
        identity?.targetGuidHash != expectedTargetGuidHash) {
      return null;
    }
    return identity;
  }

  static CloudSyncReceivedMutationIdentity? _identifyWire(
    api.MessageInst wire, {
    required List<String> localHandles,
    required String recipient,
    String? expectedSourceSha256,
  }) {
    final sender = wire.sender;
    if (localHandles.isEmpty ||
        localHandles.length > _maxObservedLocalHandles ||
        localHandles.any((handle) => !_isHandle(handle)) ||
        !_isHandle(recipient) ||
        !localHandles.contains(recipient) ||
        wire.receivedOnHandle != recipient ||
        wire.verificationFailed ||
        sender == null ||
        !_isHandle(sender) ||
        wire.sentTimestamp <= 0 ||
        wire.sentTimestamp > _maxSignedInt64) {
      return null;
    }
    final targets = wire.target;
    if (targets != null &&
        targets.isNotEmpty &&
        (targets.length != 1 ||
            targets.single is! api.MessageTarget_Token ||
            (targets.single as api.MessageTarget_Token).field0.length != 32)) {
      return null;
    }
    final certified = wire.certifiedContext;
    if (certified != null &&
        (certified.sender != sender || certified.target != recipient)) {
      return null;
    }

    final String targetGuid;
    final int targetPart;
    final CloudSyncReceivedMutationKind kind;
    final List<List<Object?>>? editParts;
    final message = wire.message;
    if (message is api.Message_Edit) {
      targetGuid = message.field0.tuuid;
      targetPart = message.field0.editPart;
      kind = CloudSyncReceivedMutationKind.edit;
      editParts = _editParts(message.field0.newParts.field0);
      if (editParts == null) return null;
    } else if (message is api.Message_Unsend) {
      targetGuid = message.field0.tuuid;
      targetPart = message.field0.editPart;
      kind = CloudSyncReceivedMutationKind.unsend;
      editParts = null;
    } else {
      return null;
    }
    if (targetPart < 0 ||
        targetPart > _maxSignedInt64 ||
        !_isUuid(wire.id) ||
        !_isUuid(targetGuid) ||
        wire.id.toLowerCase() == targetGuid.toLowerCase()) {
      return null;
    }

    final conversation = wire.conversation;
    if (conversation == null ||
        conversation.participants.isEmpty ||
        conversation.participants.length > _maxParticipants ||
        conversation.participants.toSet().length !=
            conversation.participants.length ||
        conversation.participants.any((handle) => !_isHandle(handle)) ||
        !_isLabel(conversation.cvName) ||
        !_isLabel(conversation.senderGuid) ||
        !_isLabel(conversation.afterGuid)) {
      return null;
    }
    final participants = [...conversation.participants]..sort();
    final local = localHandles.toSet();
    final counterparts = participants.where(
      (handle) => !local.contains(handle),
    );
    final origin = local.contains(sender)
        ? CloudSyncReceivedArchiveOrigin.mirrored
        : CloudSyncReceivedArchiveOrigin.incoming;
    if (counterparts.isEmpty ||
        (origin == CloudSyncReceivedArchiveOrigin.incoming &&
            !counterparts.contains(sender)) ||
        (counterparts.length > 1 && !_isUuid(conversation.senderGuid))) {
      return null;
    }
    final referencedHandles = {recipient, sender, ...participants};
    final selfHandles = local.where(referencedHandles.contains).toList()
      ..sort();
    final sourceSha256 = _digest([
      'cloud-sync-received-mutation-source-v1',
      wire.id,
      targetGuid,
      targetPart,
      sender,
      recipient,
      wire.sentTimestamp,
      origin.name,
      participants,
      conversation.cvName,
      conversation.senderGuid,
      conversation.afterGuid,
      kind.name,
      editParts,
      selfHandles,
    ]);
    if (expectedSourceSha256 != null && expectedSourceSha256 != sourceSha256) {
      return null;
    }
    return CloudSyncReceivedMutationIdentity._(
      kind: kind,
      guidHash: _digest(['cloud-sync-received-mutation-guid-v1', wire.id]),
      targetGuidHash: _digest([
        'cloud-sync-received-archive-guid-v1',
        targetGuid,
      ]),
      targetPart: targetPart,
      sourceSha256: sourceSha256,
      origin: origin,
      sentTimestamp: wire.sentTimestamp,
    );
  }

  static List<List<Object?>>? _editParts(List<api.IndexedMessagePart> parts) {
    if (parts.isEmpty || parts.length > _maxParts) return null;
    final rows = <List<Object?>>[];
    var textBytes = 0;
    for (final indexed in parts) {
      final part = indexed.part_;
      if (indexed.ext != null ||
          part is! api.MessagePart_Text ||
          part.field1 is! api.TextFormat_Flags ||
          (indexed.idx != null &&
              (indexed.idx! < 0 || indexed.idx! > _maxSignedInt64))) {
        return null;
      }
      textBytes += utf8.encode(part.field0).length;
      if (textBytes > _maxTextBytes) return null;
      final flags = (part.field1 as api.TextFormat_Flags).field0;
      rows.add([
        part.field0,
        indexed.idx,
        flags.bold,
        flags.italic,
        flags.underline,
        flags.strikethrough,
      ]);
    }
    return rows;
  }

  static bool _isUuid(String? value) =>
      value != null &&
      value.length == 36 &&
      _uuid.hasMatch(value) &&
      value.toLowerCase() != _nilUuid;

  static bool _isHandle(String value) {
    final prefixLength = value.startsWith('mailto:')
        ? 7
        : value.startsWith('tel:')
        ? 4
        : 0;
    if (prefixLength == 0 ||
        value.length <= prefixLength ||
        utf8.encode(value).length > _maxHandleBytes) {
      return false;
    }
    for (final rune in value.runes) {
      // Unicode White_Space plus C0/C1 controls, matching the native predicate.
      if (rune <= 0x20 ||
          (rune >= 0x7f && rune <= 0xa0) ||
          rune == 0x1680 ||
          (rune >= 0x2000 && rune <= 0x200a) ||
          rune == 0x2028 ||
          rune == 0x2029 ||
          rune == 0x202f ||
          rune == 0x205f ||
          rune == 0x3000) {
        return false;
      }
    }
    return true;
  }

  static bool _isLabel(String? value) =>
      value == null ||
      (utf8.encode(value).length <= _maxHandleBytes &&
          !value.runes.any(
            (rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f),
          ));

  static String _digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  @override
  String toString() => 'CloudSyncReceivedMutationIdentity(redacted)';
}
