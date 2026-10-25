import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_send_body.dart';
import 'package:bluebubbles/services/rustpush/imessage_attachment_submission.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

const descriptor = '<synthetic-mmcs-descriptor/>';
api.TextFormat format(Attributes attributes) => api.TextFormat.flags(api.TextFlags(
  bold: attributes.bold == true, italic: attributes.italic == true,
  underline: attributes.underline == true,
  strikethrough: attributes.strikethrough == true,
));
api.Attachment wireAttachment() => api.Attachment(
  aType: api.AttachmentType.mmcs(api.MMCSFile(signature: Uint8List(0),
    object: 'synthetic', url: 'https://example.invalid', key: Uint8List(0), size: 1)),
  part_: 1, utiType: 'public.png', mime: 'image/png', name: 'fixture.png', iris: false,
);
AttributedBody body({String placeholder = '\uFFFC', String guid = 'local'}) =>
  AttributedBody(string: 'marker$placeholder', runs: [
    Run(range: [0, 6], attributes: Attributes(messagePart: 0)),
    Run(range: [6, 1], attributes: Attributes(messagePart: 1, attachmentGuid: guid)),
  ]);

void main() {
  test('actual ordered attachment builder matches source on first send and retry', () async {
    final local = Attachment(guid: 'local', mimeType: 'image/png',
      metadata: {'rustpush': descriptor});
    final original = Message(text: 'marker\uFFFC', attributedBody: [body()],
      attachments: [local], hasAttachments: true);
    final source = CloudSyncAttachmentSendBody.capture(original)!;
    final frozen = AttributedBody.fromMap(original.attributedBody.single.toMap());
    original.attributedBody[0] = AttributedBody.raw('changed');
    final built = <api.MessageParts>[];
    for (var attempt = 0; attempt < 2; attempt++) {
      final attachment = wireAttachment();
      final parts = buildIMessageAttachmentParts(body: frozen, attachmentGuid: 'local',
        wireAttachment: attachment, textFormat: format);
      built.add(parts);
      expect(parts.field0.length, 2);
      expect((parts.field0.first.part_ as api.MessagePart_Text).field0, 'marker');
      expect(identical((parts.field0.last.part_ as api.MessagePart_Attachment).field0,
        attachment), isTrue);
      final wire = api.MessageInst(id: 'synthetic', message: api.Message.message(
        api.NormalMessage(parts: parts, service: const api.MessageType.iMessage(), voice: false)),
        sentTimestamp: 0, sendDelivered: false, verificationFailed: false);
      expect(await source.matchesWire(wire, serializeAttachment: (_) async => descriptor), isTrue);
    }
    expect(identical(built[0].field0.last.part_, built[1].field0.last.part_), isFalse);
  });

  test('body-only and reflected placeholders keep supported attachment behavior', () {
    for (final value in [null, AttributedBody(string: '', runs: [])]) {
      expect(buildIMessageAttachmentParts(body: value, attachmentGuid: 'local',
        wireAttachment: wireAttachment(), textFormat: format).field0.length, 1);
    }
    expect(buildIMessageAttachmentParts(body: body(placeholder: ' '), attachmentGuid: 'local',
      wireAttachment: wireAttachment(), textFormat: format).field0.length, 2);
  });

  test('malformed or retargeted body cannot silently drop text into attachment-only send', () {
    for (final value in [body(guid: 'other'), body(placeholder: 'X'),
      AttributedBody(string: 'marker', runs: [Run(range: [0, 6], attributes: Attributes())]),
      AttributedBody(string: 'marker\uFFFC', runs: [
        Run(range: [0, 3], attributes: Attributes()),
        Run(range: [6, 1], attributes: Attributes(attachmentGuid: 'local')),
      ])]) {
      expect(() => buildIMessageAttachmentParts(body: value, attachmentGuid: 'local',
        wireAttachment: wireAttachment(), textFormat: format), throwsStateError);
    }
  });
}
