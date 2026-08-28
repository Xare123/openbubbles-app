import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_repair_content_digest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart independently matches every pinned neutral digest vector', () {
    final expected = _readCorpus();
    final actual = _vectors();
    expect(actual.keys, orderedEquals(expected.keys));
    final mismatches = <String>[];
    for (final entry in actual.entries) {
      if (entry.value != expected[entry.key]) {
        mismatches.add('${entry.key}\t${entry.value}');
      }
    }
    if (mismatches.isNotEmpty) {
      fail('cloudkit_repair_digest_golden_mismatch\n${mismatches.join('\n')}');
    }
  });

  test('semantic and ordered-list mutations change the digest', () {
    expect(
      CloudKitV2CanonicalRepairDigest.forPayload(_basicMessage(body: 'body')),
      isNot(
        CloudKitV2CanonicalRepairDigest.forPayload(
          _basicMessage(body: 'changed'),
        ),
      ),
    );
    expect(
      CloudKitV2CanonicalRepairDigest.forPayload(
        _nestedMessage(retractedParts: const [1, 2]),
      ),
      isNot(
        CloudKitV2CanonicalRepairDigest.forPayload(
          _nestedMessage(retractedParts: const [2, 1]),
        ),
      ),
    );
    expect(
      CloudKitV2CanonicalRepairDigest.forPayload(
        _reaction(removed: false, parentPart: null),
      ),
      isNot(
        CloudKitV2CanonicalRepairDigest.forPayload(
          _reaction(removed: false, parentPart: 0),
        ),
      ),
    );
  });
}

Map<String, String> _readCorpus() {
  final result = <String, String>{};
  for (final line in File(
    'test/fixtures/cloud_sync/cloudkit_repair_digest_golden_v1.tsv',
  ).readAsLinesSync()) {
    if (line.isEmpty || line.startsWith('#')) continue;
    final fields = line.split('\t');
    if (fields.length != 2 || result.containsKey(fields.first)) {
      throw StateError('invalid_cloudkit_repair_digest_corpus');
    }
    result[fields.first] = fields.last;
  }
  return result;
}

Map<String, String> _vectors() => <String, String>{
  'basic-message': CloudKitV2CanonicalRepairDigest.forPayload(_basicMessage()),
  'reaction-add-partless': CloudKitV2CanonicalRepairDigest.forPayload(
    _reaction(removed: false, parentPart: null),
  ),
  'reaction-remove-part-zero': CloudKitV2CanonicalRepairDigest.forPayload(
    _reaction(removed: true, parentPart: 0),
  ),
  'unicode-multibyte': CloudKitV2CanonicalRepairDigest.forPayload(
    _basicMessage(body: 'مرحبا 👩🏽‍🚀 café 漢字'),
  ),
  'fields-absent': CloudKitV2CanonicalRepairDigest.forPayload(
    _fieldStateMessage(CloudSemanticFieldState.absent),
  ),
  'fields-explicit-clear': CloudKitV2CanonicalRepairDigest.forPayload(
    _fieldStateMessage(CloudSemanticFieldState.explicitClear),
  ),
  'known-flags-present': CloudKitV2CanonicalRepairDigest.forPayload(
    _basicMessage(body: 'flags'),
  ),
  'known-flags-absent': CloudKitV2CanonicalRepairDigest.forPayload(
    _basicMessage(body: 'flags', knownFlags: null),
  ),
  'nested-attributed-edits': CloudKitV2CanonicalRepairDigest.forPayload(
    _nestedMessage(retractedParts: const [3, 1]),
  ),
  'retracted-order-1-2': CloudKitV2CanonicalRepairDigest.forPayload(
    _nestedMessage(retractedParts: const [1, 2]),
  ),
  'retracted-order-2-1': CloudKitV2CanonicalRepairDigest.forPayload(
    _nestedMessage(retractedParts: const [2, 1]),
  ),
  'raw-bytes-framing': CloudKitV2CanonicalRepairDigest.testOnlyFramingProbe(
    unicodeText: 'é🙂',
    rawBytes: Uint8List.fromList(const [0, 255, 1, 128, 10]),
  ),
};

const _flags = CloudSemanticKnownMessageFlags(
  fromMe: true,
  delivered: false,
  read: true,
  hasDataDetectorResults: false,
  deliveredQuietly: true,
  didNotifyRecipient: false,
);

CloudMessageEntityPayload _basicMessage({
  String? body = 'body',
  CloudSemanticKnownMessageFlags? knownFlags = _flags,
}) => CloudMessageEntityPayload(
  logicalEntityKeyHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  canonicalGuid: 'guid',
  chatAliasKeyHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  chatIdentifier: 'chat',
  body: body,
  senderHandle: 'sender',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
  error: 2,
  service: CloudSemanticService.iMessage,
  subjectState: CloudSemanticFieldState.value,
  subject: 'subject',
  bodyState: CloudSemanticFieldState.value,
  knownFlags: knownFlags,
);

CloudMessageEntityPayload _fieldStateMessage(CloudSemanticFieldState state) =>
    CloudMessageEntityPayload(
      logicalEntityKeyHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      canonicalGuid: 'field-guid',
      chatAliasKeyHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      chatIdentifier: 'field-chat',
      body: null,
      senderHandle: 'sender',
      createdAt: DateTime.fromMillisecondsSinceEpoch(2, isUtc: true),
      error: 0,
      service: CloudSemanticService.iMessage,
      subjectState: state,
      bodyState: state,
      attributedBodiesState: state,
      balloonBundleIdState: state,
      // Native defers extension payloads before the FRB boundary, so the only
      // reachable repair state for this field is absent.
      decodedExtensionPayloadState: CloudSemanticFieldState.absent,
      effectState: state,
      readAtState: state,
      deliveredAtState: state,
      knownFlags: _flags,
      editsState: state,
      retractedPartsState: state,
    );

CloudMessageEntityPayload _nestedMessage({required List<int> retractedParts}) {
  final firstBody = CloudSemanticAttributedBody(
    text: 'A🙂B',
    runs: [
      CloudSemanticTextRun(
        startUtf16: 0,
        lengthUtf16: 3,
        messagePart: 0,
        attachmentCanonicalGuid: 'attachment_guid',
        attachmentLogicalKeyHash: 'ccccccccccccccccccccccccccccccccccccccccccc',
        mentionHandle: 'person@example.com',
        audioTranscript: 'spoken',
        textEffect: 7,
        bold: true,
        italic: false,
        strikethrough: null,
        underline: true,
      ),
    ],
  );
  final secondBody = CloudSemanticAttributedBody(
    text: 'second',
    runs: const [],
  );
  return CloudMessageEntityPayload(
    logicalEntityKeyHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    canonicalGuid: 'nested-guid',
    chatAliasKeyHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    chatIdentifier: 'nested-chat',
    body: 'A🙂B',
    senderHandle: 'sender',
    createdAt: DateTime.fromMillisecondsSinceEpoch(3, isUtc: true),
    error: 0,
    service: CloudSemanticService.iMessage,
    bodyState: CloudSemanticFieldState.value,
    attributedBodiesState: CloudSemanticFieldState.value,
    attributedBodies: [firstBody, secondBody],
    knownFlags: _flags,
    editsState: CloudSemanticFieldState.value,
    edits: [
      CloudSemanticMessageEdit(
        part: 0,
        revision: 2,
        bodies: [secondBody, firstBody],
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(4, isUtc: true),
        originalRangeLocation: 1,
        originalRangeLength: 2,
      ),
    ],
    retractedPartsState: CloudSemanticFieldState.value,
    retractedParts: retractedParts,
  );
}

CloudReactionEntityPayload _reaction({
  required bool removed,
  required int? parentPart,
}) => CloudReactionEntityPayload(
  logicalEntityKeyHash: 'ddddddddddddddddddddddddddddddddddddddddddd',
  canonicalGuid: removed ? 'reaction-remove' : 'reaction-add',
  parentLogicalKeyHash: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
  parentCanonicalGuid: 'parent-guid',
  parentPart: parentPart,
  senderHandle: 'sender',
  reactionType: removed ? '-emoji' : 'emoji',
  associatedEmoji: '🔥',
  createdAt: DateTime.fromMillisecondsSinceEpoch(5, isUtc: true),
  error: 0,
  service: CloudSemanticService.iMessage,
  knownFlags: _flags,
  readAtState: CloudSemanticFieldState.value,
  readAt: DateTime.fromMillisecondsSinceEpoch(6, isUtc: true),
  deliveredAtState: CloudSemanticFieldState.explicitClear,
  associatedRangeLocation: 1,
  associatedRangeLength: 2,
);
