import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_send_body.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

const _descriptorA = '<attachment><id>A</id></attachment>';
const _descriptorB = '<attachment><id>B</id></attachment>';

void main() {
  group('capture', () {
    test('single pre-send row aliases post-reflection body', () {
      final pre = CloudSyncAttachmentSendBody.capture(
        Message(text: '', attachments: [_localAtt('LOCAL-GUID', _descriptorA)]),
      )!;

      final post = CloudSyncAttachmentSendBody.capture(
        Message(
          attachments: [_localAtt('MSGID_0', _descriptorA)],
          attributedBody: [
            AttributedBody(
              string: ' ',
              runs: [
                Run(
                  range: const [0, 1],
                  attributes: Attributes(
                    attachmentGuid: 'MSGID_0',
                    messagePart: 99,
                  ),
                ),
              ],
            ),
          ],
        ),
      )!;

      expect(post.sourceSha256, pre.sourceSha256);
      expect(post.attachmentGuids, ['MSGID_0']);
      expect(pre.attachmentGuids, ['LOCAL-GUID']);
      expect(post.descriptorStrings, [_descriptorA]);
    });

    test('U+FFFC and space placeholders alias', () {
      CloudSyncAttachmentSendBody? captureWith(String placeholder) =>
          CloudSyncAttachmentSendBody.capture(
            Message(
              attachments: [_localAtt('G', _descriptorA)],
              attributedBody: [
                AttributedBody(
                  string: placeholder,
                  runs: [
                    Run(
                      range: const [0, 1],
                      attributes: Attributes(attachmentGuid: 'G'),
                    ),
                  ],
                ),
              ],
            ),
          );

      final fffc = captureWith('\uFFFC')!;
      final space = captureWith(' ')!;
      expect(space.sourceSha256, fffc.sourceSha256);
    });

    test('messagePart renumbering is ignored', () {
      final first = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 0),
      )!;
      final second = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 41),
      )!;
      expect(second.sourceSha256, first.sourceSha256);
    });

    test('filenames and flags outside the digest are ignored', () {
      final first = CloudSyncAttachmentSendBody.capture(
        Message(
          attachments: [
            _localAtt(
              'G',
              _descriptorA,
              transferName: 'a.png',
              isOutgoing: true,
            ),
          ],
          attributedBody: [_singleAttachmentBody('G', ' ')],
        ),
      )!;
      final second = CloudSyncAttachmentSendBody.capture(
        Message(
          attachments: [
            _localAtt(
              'G',
              _descriptorA,
              transferName: 'renamed.png',
              isOutgoing: false,
            ),
          ],
          attributedBody: [_singleAttachmentBody('G', ' ')],
        ),
      )!;
      expect(second.sourceSha256, first.sourceSha256);
    });

    test('adjacent same-flag text merges', () {
      final merged = CloudSyncAttachmentSendBody.capture(
        Message(
          attributedBody: [
            AttributedBody(
              string: 'hello',
              runs: [
                Run(range: const [0, 5], attributes: Attributes()),
              ],
            ),
            // No attachments referenced; body-only text still needs the
            // attachment list empty, which is tested separately for null.
          ],
        ),
      );
      expect(merged, isNull);

      final split = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('he', 'llo', bold: false),
      );
      final single = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('hello', '', bold: false),
      );
      expect(split, isNotNull);
      expect(single, isNotNull);
      expect(single!.sourceSha256, split!.sourceSha256);
    });

    test('replaced descriptor differs', () {
      final first = CloudSyncAttachmentSendBody.capture(
        _attachmentOnly('G', _descriptorA),
      )!;
      final second = CloudSyncAttachmentSendBody.capture(
        _attachmentOnly('G', _descriptorB),
      )!;
      expect(second.sourceSha256, isNot(first.sourceSha256));
    });

    test('reordered descriptors differ', () {
      final first = CloudSyncAttachmentSendBody.capture(
        _twoAttachments(['G1', 'G2'], [_descriptorA, _descriptorB]),
      )!;
      final second = CloudSyncAttachmentSendBody.capture(
        _twoAttachments(['G1', 'G2'], [_descriptorB, _descriptorA]),
      )!;
      expect(second.sourceSha256, isNot(first.sourceSha256));
    });

    test('swapped run order differs', () {
      final first = CloudSyncAttachmentSendBody.capture(
        _twoAttachments(['G1', 'G2'], [_descriptorA, _descriptorB]),
      )!;
      final flipped = CloudSyncAttachmentSendBody.capture(
        Message(
          attachments: [
            _localAtt('G1', _descriptorA),
            _localAtt('G2', _descriptorB),
          ],
          attributedBody: [
            AttributedBody(
              string: '  ',
              runs: [
                Run(
                  range: const [0, 1],
                  attributes: Attributes(attachmentGuid: 'G2'),
                ),
                Run(
                  range: const [1, 1],
                  attributes: Attributes(attachmentGuid: 'G1'),
                ),
              ],
            ),
          ],
        ),
      )!;
      expect(flipped.attachmentGuids, ['G2', 'G1']);
      expect(flipped.sourceSha256, isNot(first.sourceSha256));
    });

    test('text edits differ', () {
      final first = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('look ', '', bold: false),
      )!;
      final second = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('look! ', '', bold: false),
      )!;
      expect(second.sourceSha256, isNot(first.sourceSha256));
    });

    test('text spacing is not normalized', () {
      final single = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('a b ', '', bold: false),
      )!;
      final double = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('a  b ', '', bold: false),
      )!;
      expect(double.sourceSha256, isNot(single.sourceSha256));

      final trailing = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('a ', '', bold: false),
      )!;
      final bare = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('a', '', bold: false, placeholder: null),
      )!;
      expect(bare.sourceSha256, isNot(trailing.sourceSha256));
    });

    test('formatting flags participate', () {
      final plain = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('hi ', '', bold: false),
      )!;
      final bold = CloudSyncAttachmentSendBody.capture(
        _textWithAttachment('hi ', '', bold: true),
      )!;
      expect(bold.sourceSha256, isNot(plain.sourceSha256));
    });

    test('pre-send requires empty text and exactly one attachment', () {
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(text: 'hi', attachments: [_localAtt('G', _descriptorA)]),
        ),
        isNull,
      );
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            text: '',
            attachments: [
              _localAtt('G1', _descriptorA),
              _localAtt('G2', _descriptorB),
            ],
          ),
        ),
        isNull,
      );
      expect(CloudSyncAttachmentSendBody.capture(Message(text: '')), isNull);
    });

    test('extra bodies are rejected', () {
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            attachments: [_localAtt('G', _descriptorA)],
            attributedBody: [
              _singleAttachmentBody('G', ' '),
              _singleAttachmentBody('G', ' '),
            ],
          ),
        ),
        isNull,
      );
    });

    test('row text disagreeing with the body string is rejected', () {
      final agreeing = Message(
        text: ' ',
        attachments: [_localAtt('G', _descriptorA)],
        attributedBody: [_singleAttachmentBody('G', ' ')],
      );
      expect(CloudSyncAttachmentSendBody.capture(agreeing), isNotNull);
      final disagreeing = Message(
        text: 'stale',
        attachments: [_localAtt('G', _descriptorA)],
        attributedBody: [_singleAttachmentBody('G', ' ')],
      );
      expect(CloudSyncAttachmentSendBody.capture(disagreeing), isNull);
    });

    test('malformed ranges fail closed', () {
      // Gap between runs.
      expect(CloudSyncAttachmentSendBody.capture(_gapBody()), isNull);
      // Overlapping runs.
      expect(CloudSyncAttachmentSendBody.capture(_overlapBody()), isNull);
      // Ragged end: string longer than covered ranges.
      expect(CloudSyncAttachmentSendBody.capture(_raggedBody()), isNull);
      // Zero-length text run.
      expect(
        CloudSyncAttachmentSendBody.capture(_zeroLengthTextBody()),
        isNull,
      );
      // Null attributes.
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            attributedBody: [
              AttributedBody(
                string: 'x',
                runs: [
                  Run(range: const [0, 1]),
                ],
              ),
            ],
          ),
        ),
        isNull,
      );
      // Wrong placeholder character.
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            attachments: [_localAtt('G', _descriptorA)],
            attributedBody: [
              AttributedBody(
                string: 'x',
                runs: [
                  Run(
                    range: const [0, 1],
                    attributes: Attributes(attachmentGuid: 'G'),
                  ),
                ],
              ),
            ],
          ),
        ),
        isNull,
      );
    });

    test('attachment binding rejects duplicates, strays, and misses', () {
      // Unreferenced extra row.
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            attachments: [
              _localAtt('G', _descriptorA),
              _localAtt('STRAY', _descriptorB),
            ],
            attributedBody: [_singleAttachmentBody('G', ' ')],
          ),
        ),
        isNull,
      );
      // Conflicting duplicate rows (same GUID, different descriptors).
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            attachments: [
              _localAtt('G', _descriptorA),
              _localAtt('G', _descriptorB),
            ],
            attributedBody: [_singleAttachmentBody('G', ' ')],
          ),
        ),
        isNull,
      );
      // Identical duplicate rows merge: the same row often appears in both
      // `attachments` and `dbAttachments`.
      final mergedDuplicates = CloudSyncAttachmentSendBody.capture(
        Message(
          attachments: [
            _localAtt('G', _descriptorA),
            _localAtt('G', _descriptorA),
          ],
          attributedBody: [_singleAttachmentBody('G', ' ')],
        ),
      )!;
      expect(mergedDuplicates.attachmentGuids, ['G']);
      expect(
        mergedDuplicates.sourceSha256,
        CloudSyncAttachmentSendBody.capture(
          _attachmentOnly('G', _descriptorA),
        )!.sourceSha256,
      );
      // Run references an unknown GUID.
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            attachments: [_localAtt('G', _descriptorA)],
            attributedBody: [_singleAttachmentBody('OTHER', ' ')],
          ),
        ),
        isNull,
      );
      // Same GUID claimed by two runs.
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            attachments: [_localAtt('G', _descriptorA)],
            attributedBody: [
              AttributedBody(
                string: '  ',
                runs: [
                  Run(
                    range: const [0, 1],
                    attributes: Attributes(attachmentGuid: 'G'),
                  ),
                  Run(
                    range: const [1, 1],
                    attributes: Attributes(attachmentGuid: 'G'),
                  ),
                ],
              ),
            ],
          ),
        ),
        isNull,
      );
    });

    test('unmodeled run kinds fail closed', () {
      expect(CloudSyncAttachmentSendBody.capture(_mentionBody()), isNull);
      expect(CloudSyncAttachmentSendBody.capture(_effectBody()), isNull);
      expect(CloudSyncAttachmentSendBody.capture(_stickerBody()), isNull);
      expect(CloudSyncAttachmentSendBody.capture(_transcriptBody()), isNull);
    });

    test('live photos and bad descriptors fail closed', () {
      Attachment live() => Attachment(
        guid: 'G',
        hasLivePhoto: true,
        metadata: const {'rustpush': _descriptorA},
      );
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            attachments: [live()],
            attributedBody: [_singleAttachmentBody('G', ' ')],
          ),
        ),
        isNull,
      );
      Attachment iris() => Attachment(
        guid: 'G',
        metadata: const {'rustpush': _descriptorA, 'myIris': '<iris/>'},
      );
      expect(
        CloudSyncAttachmentSendBody.capture(
          Message(
            attachments: [iris()],
            attributedBody: [_singleAttachmentBody('G', ' ')],
          ),
        ),
        isNull,
      );
      for (final Map<String, dynamic>? metadata in <Map<String, dynamic>?>[
        null,
        <String, dynamic>{},
        <String, dynamic>{'rustpush': ''},
        <String, dynamic>{'rustpush': 42},
      ]) {
        expect(
          CloudSyncAttachmentSendBody.capture(
            Message(
              attachments: [Attachment(guid: 'G', metadata: metadata)],
              attributedBody: [_singleAttachmentBody('G', ' ')],
            ),
          ),
          isNull,
        );
      }
    });

    test('toString exposes no raw material', () {
      final capture = CloudSyncAttachmentSendBody.capture(
        _attachmentOnly('SECRET-GUID', _descriptorA),
      )!;
      final rendered = capture.toString();
      expect(rendered, isNot(contains('SECRET-GUID')));
      expect(rendered, isNot(contains(_descriptorA)));
      expect(rendered, isNot(contains('attachment')));
    });
  });

  group('matchesWire', () {
    test('accepts the reflected alias', () async {
      final capture = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 0),
      )!;
      final wire = _wireTextPlusAttachment(descriptor: _descriptorA);
      expect(
        await capture.matchesWire(wire, serializeAttachment: _serializer),
        isTrue,
      );
    });

    test('rejects wrong descriptor and wrong order', () async {
      final capture = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 0),
      )!;
      final wrongDescriptor = _wireTextPlusAttachment(
        descriptor: _descriptorB,
        attachmentName: 'b.png',
      );
      expect(
        await capture.matchesWire(
          wrongDescriptor,
          serializeAttachment: _serializer,
        ),
        isFalse,
      );

      final flipped = _wireAttachmentPlusText(descriptor: _descriptorA);
      expect(
        await capture.matchesWire(flipped, serializeAttachment: _serializer),
        isFalse,
      );
    });

    test('rejects text mismatch and flag mismatch', () async {
      final capture = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 0),
      )!;
      final edited = _wireParts([
        _wireText('look! '),
        _wireAttachmentPart('file.png'),
      ], descriptor: _descriptorA);
      expect(
        await capture.matchesWire(edited, serializeAttachment: _serializer),
        isFalse,
      );

      final bolded = _wireParts([
        _wireText('look ', bold: true),
        _wireAttachmentPart('file.png'),
      ], descriptor: _descriptorA);
      expect(
        await capture.matchesWire(bolded, serializeAttachment: _serializer),
        isFalse,
      );
    });

    test('rejects non-plain wire parts', () async {
      final capture = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 0),
      )!;
      Future<bool> check(api.MessageInst wire) =>
          capture.matchesWire(wire, serializeAttachment: _serializer);

      expect(await check(_wireMention()), isFalse);
      expect(await check(_wireObject()), isFalse);
      expect(await check(_wireEffectText()), isFalse);
      expect(await check(_wireInlineAttachment()), isFalse);
      expect(await check(_wireIrisAttachment()), isFalse);
      expect(
        await check(_wireStickerExtension(descriptor: _descriptorA)),
        isFalse,
      );
      expect(await check(_wireVoice(descriptor: _descriptorA)), isFalse);
    });

    test('serializer failure fails closed', () async {
      final capture = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 0),
      )!;
      final wire = _wireTextPlusAttachment(descriptor: _descriptorA);
      expect(
        await capture.matchesWire(
          wire,
          serializeAttachment: (_) async => throw StateError('boom'),
        ),
        isFalse,
      );
    });

    test('serializer replacing the staged message fails closed', () async {
      final capture = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 0),
      )!;
      final wire = _wireTextPlusAttachment(descriptor: _descriptorA);
      Future<String> swap(api.Attachment _) async {
        wire.message = api.Message.message(
          api.NormalMessage(
            parts: api.MessageParts(
              field0: [_wireText('changed '), _wireAttachmentPart('a.png')],
            ),
            service: const api.MessageType.iMessage(),
            voice: false,
          ),
        );
        return _descriptorA;
      }

      expect(
        await capture.matchesWire(wire, serializeAttachment: swap),
        isFalse,
      );
    });

    test('serializer mutating MMCS key bytes fails closed', () async {
      final capture = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 0),
      )!;
      final key = Uint8List.fromList([1, 2, 3]);
      final attachment = api.Attachment(
        aType: api.AttachmentType.mmcs(
          api.MMCSFile(
            signature: Uint8List(0),
            object: 'a.png',
            url: 'https://example.com',
            key: key,
            size: 1,
          ),
        ),
        part_: 0,
        utiType: 'public.png',
        mime: 'image/png',
        name: 'a.png',
        iris: false,
      );
      final wire = _wireParts([
        _wireText('look '),
        api.IndexedMessagePart(part_: api.MessagePart.attachment(attachment)),
      ], descriptor: _descriptorA);
      Future<String> flip(api.Attachment _) async {
        key[0] = 9;
        return _descriptorA;
      }

      expect(
        await capture.matchesWire(wire, serializeAttachment: flip),
        isFalse,
      );
    });

    test('serializer mutating the parts list fails closed', () async {
      final capture = CloudSyncAttachmentSendBody.capture(
        _textPlusAttachment(messagePart: 0),
      )!;
      final liveParts = [_wireText('look '), _wireAttachmentPart('a.png')];
      final wire = _wireParts(liveParts, descriptor: _descriptorA);
      Future<String> append(api.Attachment _) async {
        liveParts.add(_wireText('late '));
        return _descriptorA;
      }

      expect(
        await capture.matchesWire(wire, serializeAttachment: append),
        isFalse,
      );
    });
  });
}

Attachment _localAtt(
  String guid,
  String descriptor, {
  String? transferName,
  bool? isOutgoing,
}) => Attachment(
  guid: guid,
  transferName: transferName,
  isOutgoing: isOutgoing,
  metadata: {'rustpush': descriptor, 'myIris': null},
);

AttributedBody _singleAttachmentBody(String guid, String placeholder) =>
    AttributedBody(
      string: placeholder,
      runs: [
        Run(
          range: const [0, 1],
          attributes: Attributes(attachmentGuid: guid),
        ),
      ],
    );

Message _attachmentOnly(String guid, String descriptor) => Message(
  attachments: [_localAtt(guid, descriptor)],
  attributedBody: [_singleAttachmentBody(guid, '\uFFFC')],
);

Message _textPlusAttachment({required int messagePart}) => Message(
  attachments: [_localAtt('G', _descriptorA)],
  attributedBody: [
    AttributedBody(
      string: 'look \uFFFC',
      runs: [
        Run(
          range: const [0, 5],
          attributes: Attributes(messagePart: messagePart),
        ),
        Run(
          range: const [5, 1],
          attributes: Attributes(
            attachmentGuid: 'G',
            messagePart: messagePart + 1,
          ),
        ),
      ],
    ),
  ],
);

Message _textWithAttachment(
  String first,
  String second, {
  required bool bold,
  String? placeholder,
}) {
  final text = first + second;
  final runs = <Run>[];
  if (first.isNotEmpty) {
    runs.add(
      Run(
        range: [0, first.length],
        attributes: Attributes(bold: bold ? true : null),
      ),
    );
  }
  if (second.isNotEmpty) {
    runs.add(
      Run(
        range: [first.length, second.length],
        attributes: Attributes(bold: bold ? true : null),
      ),
    );
  }
  final suffix = placeholder ?? '';
  final body = text + suffix;
  if (suffix.isNotEmpty) {
    runs.add(
      Run(
        range: [text.length, suffix.length],
        attributes: Attributes(attachmentGuid: 'G'),
      ),
    );
  }
  final attachments = suffix.isEmpty
      ? <Attachment>[]
      : [_localAtt('G', _descriptorA)];
  // Every candidate attachment must be referenced; every run GUID resolved.
  // The default placeholder keeps the attachment token so spacing cases bind
  // the same descriptor on both sides.
  final withAttachment = placeholder ?? ' ';
  if (suffix.isEmpty && withAttachment.isNotEmpty) {
    return Message(
      attachments: [_localAtt('G', _descriptorA)],
      attributedBody: [
        AttributedBody(
          string: text + withAttachment,
          runs: [
            ...runs,
            Run(
              range: [text.length, withAttachment.length],
              attributes: Attributes(attachmentGuid: 'G'),
            ),
          ],
        ),
      ],
    );
  }
  return Message(
    attachments: attachments,
    attributedBody: [AttributedBody(string: body, runs: runs)],
  );
}

Message _twoAttachments(List<String> guids, List<String> descriptors) =>
    Message(
      attachments: [
        for (var i = 0; i < guids.length; i++)
          _localAtt(guids[i], descriptors[i]),
      ],
      attributedBody: [
        AttributedBody(
          string: '  ',
          runs: [
            for (var i = 0; i < guids.length; i++)
              Run(
                range: [i, 1],
                attributes: Attributes(attachmentGuid: guids[i]),
              ),
          ],
        ),
      ],
    );

Message _gapBody() => Message(
  attributedBody: [
    AttributedBody(
      string: 'abc',
      runs: [
        Run(range: const [0, 1], attributes: Attributes()),
        Run(range: const [2, 1], attributes: Attributes()),
      ],
    ),
  ],
);

Message _overlapBody() => Message(
  attributedBody: [
    AttributedBody(
      string: 'abc',
      runs: [
        Run(range: const [0, 2], attributes: Attributes()),
        Run(range: const [1, 2], attributes: Attributes()),
      ],
    ),
  ],
);

Message _raggedBody() => Message(
  attributedBody: [
    AttributedBody(
      string: 'abcd',
      runs: [
        Run(range: const [0, 3], attributes: Attributes()),
      ],
    ),
  ],
);

Message _zeroLengthTextBody() => Message(
  attributedBody: [
    AttributedBody(
      string: '',
      runs: [
        Run(range: const [0, 0], attributes: Attributes()),
      ],
    ),
  ],
);

Message _mentionBody() => Message(
  attributedBody: [
    AttributedBody(
      string: 'hi',
      runs: [
        Run(
          range: const [0, 2],
          attributes: Attributes(mention: 'user@example.com'),
        ),
      ],
    ),
  ],
);

Message _effectBody() => Message(
  attributedBody: [
    AttributedBody(
      string: 'hi',
      runs: [
        Run(
          range: const [0, 2],
          attributes: Attributes(textEffect: Attributes.BIG),
        ),
      ],
    ),
  ],
);

Message _stickerBody() => Message(
  attributedBody: [
    AttributedBody(
      string: 'hi',
      runs: [
        Run(
          range: const [0, 2],
          attributes: Attributes(stickerData: _stickerData()),
        ),
      ],
    ),
  ],
);

Message _transcriptBody() => Message(
  attributedBody: [
    AttributedBody(
      string: 'hi',
      runs: [
        Run(
          range: const [0, 2],
          attributes: Attributes(audioTranscript: 'hello'),
        ),
      ],
    ),
  ],
);

StickerData _stickerData() => StickerData(
  msgWidth: 1,
  rotation: 0,
  sai: 0,
  scale: 1,
  update: false,
  sli: 0,
  normalizedX: 0,
  normalizedY: 0,
  version: 1,
  hash: 'h',
  safi: 0,
  effectType: 0,
  stickerId: 's',
);

Future<String> _serializer(api.Attachment attachment) async =>
    attachment.name == 'a.png' ? _descriptorA : _descriptorB;

api.Attachment _wireAttachment(
  String name, {
  bool iris = false,
  bool inline = false,
}) => api.Attachment(
  aType: inline
      ? api.AttachmentType.inline(Uint8List(0))
      : api.AttachmentType.mmcs(
          api.MMCSFile(
            signature: Uint8List(0),
            object: name,
            url: 'https://example.com',
            key: Uint8List(0),
            size: 1,
          ),
        ),
  part_: 0,
  utiType: 'public.png',
  mime: 'image/png',
  name: name,
  iris: iris,
);

api.IndexedMessagePart _wireText(String text, {bool bold = false}) =>
    api.IndexedMessagePart(
      part_: api.MessagePart.text(
        text,
        api.TextFormat.flags(
          api.TextFlags(
            bold: bold,
            italic: false,
            underline: false,
            strikethrough: false,
          ),
        ),
      ),
    );

api.IndexedMessagePart _wireAttachmentPart(String name) =>
    api.IndexedMessagePart(
      part_: api.MessagePart.attachment(_wireAttachment(name)),
    );

api.MessageInst _wireParts(
  List<api.IndexedMessagePart> parts, {
  required String descriptor,
  bool voice = false,
}) => api.MessageInst(
  id: 'wire-1',
  message: api.Message.message(
    api.NormalMessage(
      parts: api.MessageParts(field0: parts),
      service: const api.MessageType.iMessage(),
      voice: voice,
    ),
  ),
  sentTimestamp: 0,
  sendDelivered: false,
  verificationFailed: false,
);

api.MessageInst _wireTextPlusAttachment({
  required String descriptor,
  String attachmentName = 'a.png',
}) => _wireParts([
  _wireText('look '),
  _wireAttachmentPart(attachmentName),
], descriptor: descriptor);

api.MessageInst _wireAttachmentPlusText({required String descriptor}) =>
    _wireParts([
      _wireAttachmentPart('a.png'),
      _wireText('look '),
    ], descriptor: descriptor);

api.MessageInst _wireMention() => _wireParts([
  const api.IndexedMessagePart(
    part_: api.MessagePart.mention('user@example.com', 'hi'),
  ),
], descriptor: _descriptorA);

api.MessageInst _wireObject() => _wireParts([
  const api.IndexedMessagePart(part_: api.MessagePart.object('ldText')),
], descriptor: _descriptorA);

api.MessageInst _wireEffectText() => _wireParts([
  const api.IndexedMessagePart(
    part_: api.MessagePart.text(
      'look ',
      api.TextFormat.effect(api.TextEffect.big),
    ),
  ),
], descriptor: _descriptorA);

api.MessageInst _wireInlineAttachment() => api.MessageInst(
  id: 'wire-1',
  message: api.Message.message(
    api.NormalMessage(
      parts: api.MessageParts(
        field0: [
          api.IndexedMessagePart(
            part_: api.MessagePart.attachment(
              _wireAttachment('a.png', inline: true),
            ),
          ),
        ],
      ),
      service: const api.MessageType.iMessage(),
      voice: false,
    ),
  ),
  sentTimestamp: 0,
  sendDelivered: false,
  verificationFailed: false,
);

api.MessageInst _wireIrisAttachment() => api.MessageInst(
  id: 'wire-1',
  message: api.Message.message(
    api.NormalMessage(
      parts: api.MessageParts(
        field0: [
          api.IndexedMessagePart(
            part_: api.MessagePart.attachment(
              _wireAttachment('a.png', iris: true),
            ),
          ),
        ],
      ),
      service: const api.MessageType.iMessage(),
      voice: false,
    ),
  ),
  sentTimestamp: 0,
  sendDelivered: false,
  verificationFailed: false,
);

api.MessageInst _wireStickerExtension({required String descriptor}) =>
    api.MessageInst(
      id: 'wire-1',
      message: api.Message.message(
        api.NormalMessage(
          parts: api.MessageParts(
            field0: [
              api.IndexedMessagePart(
                part_: api.MessagePart.attachment(_wireAttachment('a.png')),
                ext: api.PartExtension.sticker(
                  msgWidth: 1,
                  rotation: 0,
                  sai: BigInt.zero,
                  scale: 1,
                  sli: BigInt.zero,
                  normalizedX: 0,
                  normalizedY: 0,
                  version: BigInt.one,
                  hash: 'h',
                  safi: BigInt.zero,
                  effectType: 0,
                  stickerId: 's',
                ),
              ),
            ],
          ),
          service: const api.MessageType.iMessage(),
          voice: false,
        ),
      ),
      sentTimestamp: 0,
      sendDelivered: false,
      verificationFailed: false,
    );

api.MessageInst _wireVoice({required String descriptor}) => _wireParts(
  [_wireAttachmentPart('a.png')],
  descriptor: descriptor,
  voice: true,
);
