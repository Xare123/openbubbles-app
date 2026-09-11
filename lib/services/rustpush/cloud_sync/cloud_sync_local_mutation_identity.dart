import 'dart:convert';

import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

/// Bounded wire-only identity for a locally staged edit or unsend mutation.
///
/// Mirrors the eligibility and bounds of the native mutation-source codec
/// (intent_from_message in cloud_sync_ids_mutation_source.rs): only
/// Message_Edit and Message_Unsend wires are admitted, staged targets,
/// verification failures, and certified contexts are excluded exactly as
/// the codec excludes them, and unsupported replacement parts (mentions,
/// effects, attachments, objects, extensions) are rejected without
/// flattening them into plaintext. The mutation id must be a non-nil UUID
/// distinct from the target GUID; both spellings stay verbatim because the
/// downstream record name keys over exact strings, so case is preserved in
/// every digest.
///
/// The hyphenated-spelling gate is stricter than the native UUID parser,
/// which also accepts simple, braced, and urn spellings: everything
/// admitted here still decodes natively, while non-hyphenated spellings
/// are declined Dart-side even though the codec would take them.
///
/// What it proves: the wire is a well-formed pre-send edit or unsend whose
/// routing, body, and bookkeeping fields are bound into sourceSha256.
/// What it never proves: delivery, CloudKit authorization, or permission
/// to send or save. The durable journal and a positive IDS receipt remain
/// required. No message-row validation, no ckRecordId prerequisite, and no
/// raw text or handles are retained here; toString is redacted.
enum CloudSyncLocalMutationKind { edit, unsend }

/// Immutable capture of a mutation wire's identity. All hashes are hex
/// digests; the raw GUID spellings, text, and handles are never retained.
final class CloudSyncLocalMutationIdentity {
  const CloudSyncLocalMutationIdentity._(
    this.kind,
    this.guidHash,
    this.targetGuidHash,
    this.targetPart,
    this.sourceSha256,
    this._routeSha256,
  );

  /// Whether the wire carries an edit or an unsend.
  final CloudSyncLocalMutationKind kind;

  /// Digest of the mutation's own GUID, in the shared
  /// cloud-sync-local-send-guid-v1 namespace so journal intent keys stay
  /// uniform across send kinds.
  final String guidHash;

  /// Digest of the mutation's target GUID, same namespace as guidHash.
  /// The part selects inside the target and never alters this hash.
  final String targetGuidHash;

  /// Exact target part from the wire (u64 domain; negatives rejected).
  final int targetPart;

  /// Versioned digest of the immutable mutation source: exact mutation and
  /// target GUID spellings, target part, sender, ordered participants,
  /// nullable conversation labels, timestamp, delivery flag, and the full
  /// text-with-flags edit parts with their nullable indexes.
  final String sourceSha256;
  final String _routeSha256;

  /// Compares the actual wire route with a separately loaded local chat.
  /// Sorting is only for set equality here; sourceSha256 above retains order.
  /// Sender inclusion follows native prepare_send without retaining handles.
  bool matchesRoute({
    required String sender,
    required String chatGuid,
    required List<String> participants,
  }) => _routeSha256 == _routeDigest(sender, chatGuid, participants);

  static String _routeDigest(
    String sender,
    String? guid,
    List<String> members,
  ) {
    final participants = [...members];
    if (!participants.contains(sender)) participants.add(sender);
    participants.sort();
    return _digest([
      'cloud-sync-mutation-route-v1',
      sender,
      guid,
      participants,
    ]);
  }

  static const _guidNamespace = 'cloud-sync-local-send-guid-v1';
  static const _sourceNamespace = 'cloud-sync-local-mutation-source-v1';
  static const _maxParts = 128;
  static const _maxTextBytes = 256 * 1024;
  static const _maxParticipants = 64;
  static const _maxLabelBytes = 4096;
  static const _nilUuid = '00000000-0000-0000-0000-000000000000';

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// Capture the identity of a pre-send edit or unsend wire.
  ///
  /// Returns null when the wire is not an eligible mutation source per the
  /// native codec bounds. Pass expectedSourceSha256 to revalidate a
  /// previously captured source instead of trusting the wire as-is.
  static CloudSyncLocalMutationIdentity? captureWire(
    api.MessageInst wire, {
    String? expectedSourceSha256,
  }) {
    // Exactly the codec's three exclusions: staged targets, verification
    // failures, and certified contexts never decode as a mutation source.
    // Any non-null target list (even empty) counts as a staged target.
    if (wire.target != null ||
        wire.certifiedContext != null ||
        wire.verificationFailed) {
      return null;
    }
    final String targetGuid;
    final int targetPart;
    final CloudSyncLocalMutationKind kind;
    final List<List<Object?>>? editParts;
    final payload = wire.message;
    if (payload is api.Message_Unsend) {
      targetGuid = payload.field0.tuuid;
      targetPart = payload.field0.editPart;
      kind = CloudSyncLocalMutationKind.unsend;
      editParts = null;
    } else if (payload is api.Message_Edit) {
      targetGuid = payload.field0.tuuid;
      targetPart = payload.field0.editPart;
      kind = CloudSyncLocalMutationKind.edit;
      editParts = _editPartDigests(payload.field0.newParts.field0);
      if (editParts == null) return null;
    } else {
      return null;
    }
    // Native u64 domain: negative Dart ints can never come off the wire.
    if (targetPart < 0 || wire.sentTimestamp < 0) return null;
    // UUID spellings stay verbatim in the digests, but nil and
    // self-targeting ids are rejected on their parsed value, matching the
    // codec's case-insensitive comparison.
    // The hyphenated-only gate above is stricter than the native parser;
    // the equality itself stays case-insensitive like the codec compare.
    if (!_uuid.hasMatch(wire.id) || !_uuid.hasMatch(targetGuid)) return null;
    final mutationId = wire.id.toLowerCase();
    final targetId = targetGuid.toLowerCase();
    if (mutationId == _nilUuid ||
        targetId == _nilUuid ||
        mutationId == targetId) {
      return null;
    }
    final sender = wire.sender;
    if (sender == null || !_isHandle(sender)) return null;
    final conversation = wire.conversation;
    if (conversation == null) return null;
    final participants = conversation.participants;
    if (participants.isEmpty ||
        participants.length > _maxParticipants ||
        participants.toSet().length != participants.length) {
      return null;
    }
    for (final handle in participants) {
      if (!_isHandle(handle)) return null;
    }
    if (!_isOptionalLabel(conversation.cvName) ||
        !_isOptionalLabel(conversation.senderGuid) ||
        !_isOptionalLabel(conversation.afterGuid)) {
      return null;
    }
    final sourceSha256 = _digest(<Object?>[
      _sourceNamespace,
      wire.id,
      targetGuid,
      targetPart,
      sender,
      participants,
      conversation.cvName,
      conversation.senderGuid,
      conversation.afterGuid,
      wire.sentTimestamp,
      wire.sendDelivered,
      kind.name,
      editParts,
    ]);
    if (expectedSourceSha256 != null && expectedSourceSha256 != sourceSha256) {
      return null;
    }
    return CloudSyncLocalMutationIdentity._(
      kind,
      _digest(<Object?>[_guidNamespace, wire.id]),
      _digest(<Object?>[_guidNamespace, targetGuid]),
      targetPart,
      sourceSha256,
      _routeDigest(sender, conversation.senderGuid, participants),
    );
  }

  /// Flatten edit parts into digest rows, preserving order, full text,
  /// flags, and nullable indexes. Returns null for any out-of-bounds or
  /// unsupported replacement part without flattening it.
  static List<List<Object?>>? _editPartDigests(
    List<api.IndexedMessagePart> parts,
  ) {
    if (parts.isEmpty || parts.length > _maxParts) return null;
    var totalBytes = 0;
    final rows = <List<Object?>>[];
    for (final indexed in parts) {
      if (indexed.ext != null) return null;
      final part = indexed.part_;
      // Preserve unsupported edits as caller-side pending work; never
      // flatten mentions, effects, attachments, or objects into text.
      if (part is! api.MessagePart_Text) return null;
      if (part.field1 is! api.TextFormat_Flags) return null;
      if (indexed.idx != null && indexed.idx! < 0) return null;
      totalBytes += utf8.encode(part.field0).length;
      if (totalBytes > _maxTextBytes) return null;
      final flags = (part.field1 as api.TextFormat_Flags).field0;
      rows.add(<Object?>[
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

  static bool _isHandle(String value) {
    final String? suffix;
    if (value.startsWith('mailto:')) {
      suffix = value.substring('mailto:'.length);
    } else if (value.startsWith('tel:')) {
      suffix = value.substring('tel:'.length);
    } else {
      return false;
    }
    if (suffix.isEmpty) return false;
    if (utf8.encode(value).length > _maxLabelBytes) return false;
    return _hasNoWhitespaceOrControl(value);
  }

  static bool _isOptionalLabel(String? value) {
    if (value == null) return true;
    if (utf8.encode(value).length > _maxLabelBytes) return false;
    for (final rune in value.runes) {
      if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) return false;
    }
    return true;
  }

  /// Rust uses Unicode White_Space plus control characters, not the
  /// ECMAScript whitespace class (which additionally treats BOM as blank).
  static bool _hasNoWhitespaceOrControl(String value) {
    for (final rune in value.runes) {
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

  static String _digest(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  @override
  String toString() => 'CloudSyncLocalMutationIdentity(redacted)';
}
