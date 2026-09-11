import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_identity.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic fixtures only. GUIDs reuse the native codec test spellings so
// cross-implementation comparison is direct; no real user data appears here.
const _mutationGuid = '2C174D2E-BAA7-4435-A8D5-88BF2C969A44';
const _targetGuid = '5BC3779B-7898-4A15-A768-2EA04D3ABAA0';
const _otherGuid = 'F47AC10B-58CC-4372-A567-0E02B2C3D479';
const _nilGuid = '00000000-0000-0000-0000-000000000000';
const _sender = 'mailto:sender@example.test';
const _peer = 'mailto:peer@example.test';

String _digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

api.IndexedMessagePart _textPart(
  String text, {
  int? idx = 2,
  bool bold = true,
  bool italic = false,
  bool underline = true,
  bool strikethrough = false,
}) {
  return api.IndexedMessagePart(
    part_: api.MessagePart.text(
      text,
      api.TextFormat.flags(
        api.TextFlags(
          bold: bold,
          italic: italic,
          underline: underline,
          strikethrough: strikethrough,
        ),
      ),
    ),
    idx: idx,
  );
}

api.MessageInst _baseEdit() {
  return api.MessageInst(
    id: _mutationGuid,
    sender: _sender,
    conversation: api.ConversationData(participants: <String>[_peer]),
    message: api.Message.edit(
      api.EditMessage(
        tuuid: _targetGuid,
        editPart: 2,
        newParts: api.MessageParts(
          field0: <api.IndexedMessagePart>[_textPart('Edited message')],
        ),
      ),
    ),
    sentTimestamp: 1700000000000,
    sendDelivered: false,
    verificationFailed: false,
  );
}

api.MessageInst _baseUnsend() {
  final wire = _baseEdit();
  wire.message = const api.Message.unsend(
    api.UnsendMessage(tuuid: _targetGuid, editPart: 2),
  );
  return wire;
}

void main() {
  test('handle whitespace matches native Unicode White_Space', () {
    for (final code in [
      0x20,
      0x85,
      0xa0,
      0x1680,
      0x2000,
      0x200a,
      0x2028,
      0x2029,
      0x202f,
      0x205f,
      0x3000,
    ]) {
      final wire = _baseEdit()
        ..sender = 'mailto:a${String.fromCharCode(code)}b@example.test';
      expect(
        CloudSyncLocalMutationIdentity.captureWire(wire),
        isNull,
        reason: 'Unicode codepoint $code',
      );
    }
    // BOM is neither White_Space nor Cc in the native predicate.
    final wire = _baseEdit()..sender = 'mailto:a\ufeffb@example.test';
    expect(CloudSyncLocalMutationIdentity.captureWire(wire), isNotNull);
  });
  group('edit and unsend capture', () {
    test('captures the edit wire with guid and source hashes', () {
      final identity = CloudSyncLocalMutationIdentity.captureWire(_baseEdit());
      expect(identity, isNotNull);
      expect(identity!.kind, CloudSyncLocalMutationKind.edit);
      expect(identity.targetPart, 2);
      expect(
        identity.guidHash,
        _digest(<Object?>['cloud-sync-local-send-guid-v1', _mutationGuid]),
      );
      expect(
        identity.targetGuidHash,
        _digest(<Object?>['cloud-sync-local-send-guid-v1', _targetGuid]),
      );
      expect(identity.guidHash, isNot(identity.targetGuidHash));
      final again = CloudSyncLocalMutationIdentity.captureWire(_baseEdit())!;
      expect(again.sourceSha256, identity.sourceSha256);
      expect(again.guidHash, identity.guidHash);
      expect(
        CloudSyncLocalMutationIdentity.captureWire(
          _baseEdit(),
          expectedSourceSha256: identity.sourceSha256,
        ),
        isNotNull,
      );
      expect(
        CloudSyncLocalMutationIdentity.captureWire(
          _baseEdit(),
          expectedSourceSha256: '0' * 64,
        ),
        isNull,
      );
    });

    test('captures the unsend wire under a distinct source', () {
      final edit = CloudSyncLocalMutationIdentity.captureWire(_baseEdit())!;
      final unsend = CloudSyncLocalMutationIdentity.captureWire(_baseUnsend());
      expect(unsend, isNotNull);
      expect(unsend!.kind, CloudSyncLocalMutationKind.unsend);
      expect(unsend.targetPart, 2);
      expect(unsend.guidHash, edit.guidHash);
      expect(unsend.targetGuidHash, edit.targetGuidHash);
      expect(unsend.sourceSha256, isNot(edit.sourceSha256));
    });
  });

  group('exact source changes', () {
    test('every bound field change breaks the expected source', () {
      final original = CloudSyncLocalMutationIdentity.captureWire(_baseEdit())!;
      final mutations = <String, void Function(api.MessageInst)>{
        'mutation id': (w) => w.id = _otherGuid,
        'target guid': (w) {
          w.message = const api.Message.unsend(
            api.UnsendMessage(tuuid: _otherGuid, editPart: 2),
          );
        },
        'target part': (w) {
          w.message = const api.Message.unsend(
            api.UnsendMessage(tuuid: _targetGuid, editPart: 3),
          );
        },
        'kind': (w) {
          w.message = const api.Message.unsend(
            api.UnsendMessage(tuuid: _targetGuid, editPart: 2),
          );
        },
        'sender': (w) => w.sender = 'mailto:other@example.test',
        'participant added': (w) =>
            w.conversation!.participants.add('mailto:other@example.test'),
        'sender guid': (w) => w.conversation = api.ConversationData(
          participants: <String>[_peer],
          senderGuid: 'group-sender-guid',
        ),
        'after guid': (w) => w.conversation = api.ConversationData(
          participants: <String>[_peer],
          afterGuid: 'after-guid',
        ),
        'conversation name': (w) => w.conversation = api.ConversationData(
          participants: <String>[_peer],
          cvName: 'Group Name',
        ),
        'timestamp': (w) => w.sentTimestamp += 1,
        'delivered flag': (w) => w.sendDelivered = true,
      };
      for (final entry in mutations.entries) {
        final wire = _baseEdit();
        entry.value(wire);
        expect(
          CloudSyncLocalMutationIdentity.captureWire(
            wire,
            expectedSourceSha256: original.sourceSha256,
          ),
          isNull,
          reason: entry.key,
        );
      }
    });

    test(
      'target part, route, body, and format substitutions move the source',
      () {
        final original = CloudSyncLocalMutationIdentity.captureWire(
          _baseEdit(),
        )!;
        api.MessageInst freshEdit({
          String? body,
          bool? bold,
          int? part,
          int? idx,
          bool clearIndex = false,
        }) {
          final wire = _baseEdit();
          wire.message = api.Message.edit(
            api.EditMessage(
              tuuid: _targetGuid,
              editPart: part ?? 2,
              newParts: api.MessageParts(
                field0: <api.IndexedMessagePart>[
                  _textPart(
                    body ?? 'Edited message',
                    bold: bold ?? true,
                    idx: clearIndex ? null : (idx ?? 2),
                  ),
                ],
              ),
            ),
          );
          return wire;
        }

        final byPart = CloudSyncLocalMutationIdentity.captureWire(
          freshEdit(part: 3),
        )!;
        expect(byPart.targetPart, 3);
        expect(byPart.sourceSha256, isNot(original.sourceSha256));
        expect(byPart.targetGuidHash, original.targetGuidHash);

        final byBody = CloudSyncLocalMutationIdentity.captureWire(
          freshEdit(body: 'Edited message v2'),
        )!;
        expect(byBody.sourceSha256, isNot(original.sourceSha256));

        final byFormat = CloudSyncLocalMutationIdentity.captureWire(
          freshEdit(bold: false),
        )!;
        expect(byFormat.sourceSha256, isNot(original.sourceSha256));

        final byIndex = CloudSyncLocalMutationIdentity.captureWire(
          freshEdit(idx: 3),
        )!;
        expect(byIndex.sourceSha256, isNot(original.sourceSha256));

        final nullIndex = CloudSyncLocalMutationIdentity.captureWire(
          freshEdit(clearIndex: true),
        );
        // Null and zero indexes are distinct targets; null must still decode.
        expect(nullIndex, isNotNull);
        expect(nullIndex!.sourceSha256, isNot(original.sourceSha256));
        final zeroIndexWire = freshEdit();
        zeroIndexWire.message = api.Message.edit(
          api.EditMessage(
            tuuid: _targetGuid,
            editPart: 2,
            newParts: api.MessageParts(
              field0: <api.IndexedMessagePart>[
                _textPart('Edited message', idx: 0),
              ],
            ),
          ),
        );
        final zeroIndex = CloudSyncLocalMutationIdentity.captureWire(
          zeroIndexWire,
        )!;
        expect(zeroIndex.sourceSha256, isNot(nullIndex.sourceSha256));

        final reordered = _baseEdit();
        reordered.conversation = api.ConversationData(
          participants: <String>[_peer, _sender],
        );
        final routed = CloudSyncLocalMutationIdentity.captureWire(reordered)!;
        expect(routed.sourceSha256, isNot(original.sourceSha256));
        final flipped = _baseEdit();
        flipped.conversation = api.ConversationData(
          participants: <String>[_sender, _peer],
        );
        final flippedIdentity = CloudSyncLocalMutationIdentity.captureWire(
          flipped,
        )!;
        expect(flippedIdentity.sourceSha256, isNot(routed.sourceSha256));
      },
    );
  });

  group('self targets and malformed ids', () {
    test('rejects equal, nil, and malformed mutation and target ids', () {
      final cases = <String, void Function(api.MessageInst)>{
        'equal self target': (w) => w.id = _targetGuid,
        'case-insensitive self target': (w) => w.id = _targetGuid.toLowerCase(),
        'nil mutation id': (w) => w.id = _nilGuid,
        'malformed mutation id': (w) => w.id = 'not-a-uuid',
        'empty mutation id': (w) => w.id = '',
        'nil target': (w) {
          w.message = const api.Message.unsend(
            api.UnsendMessage(tuuid: _nilGuid, editPart: 2),
          );
        },
        'malformed target': (w) {
          w.message = const api.Message.unsend(
            api.UnsendMessage(
              tuuid: 'p:AAAAAAAAAAAAAAAAAAAAAAAAAAAA',
              editPart: 2,
            ),
          );
        },
      };
      for (final entry in cases.entries) {
        final wire = _baseEdit();
        entry.value(wire);
        expect(
          CloudSyncLocalMutationIdentity.captureWire(wire),
          isNull,
          reason: entry.key,
        );
      }
    });

    test('preserves GUID case in the digests', () {
      final upper = CloudSyncLocalMutationIdentity.captureWire(_baseEdit())!;
      final lower = _baseEdit()..id = _mutationGuid.toLowerCase();
      final lowered = CloudSyncLocalMutationIdentity.captureWire(lower)!;
      expect(
        lowered.guidHash,
        _digest(<Object?>[
          'cloud-sync-local-send-guid-v1',
          _mutationGuid.toLowerCase(),
        ]),
      );
      expect(lowered.guidHash, isNot(upper.guidHash));
      expect(lowered.sourceSha256, isNot(upper.sourceSha256));
    });
  });

  group('prepared and unsupported wires', () {
    test('excludes staged targets, verification, and context', () {
      final withTarget = _baseEdit()
        ..target = [const api.MessageTarget.uuid('prepared-target')];
      expect(CloudSyncLocalMutationIdentity.captureWire(withTarget), isNull);

      final withEmptyTarget = _baseEdit()..target = <api.MessageTarget>[];
      expect(
        CloudSyncLocalMutationIdentity.captureWire(withEmptyTarget),
        isNull,
      );

      final verified = _baseEdit()..verificationFailed = true;
      expect(CloudSyncLocalMutationIdentity.captureWire(verified), isNull);

      final certified = _baseEdit()
        ..certifiedContext = api.CertifiedContext(
          version: 1,
          receipt: Uint8List(0),
          sender: '',
          target: '',
          uuid: Uint8List(0),
          token: Uint8List(0),
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(certified), isNull);
    });

    test('rejects non-mutation message kinds', () {
      for (final message in <api.Message>[
        const api.Message.read(),
        const api.Message.delivered(),
      ]) {
        final wire = _baseEdit()..message = message;
        expect(CloudSyncLocalMutationIdentity.captureWire(wire), isNull);
      }
    });

    test('rejects unsupported replacement parts without flattening', () {
      final mention = _baseEdit()
        ..message = const api.Message.edit(
          api.EditMessage(
            tuuid: _targetGuid,
            editPart: 2,
            newParts: api.MessageParts(
              field0: <api.IndexedMessagePart>[
                api.IndexedMessagePart(
                  part_: api.MessagePart.mention('person', 'id'),
                  idx: 2,
                ),
              ],
            ),
          ),
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(mention), isNull);

      final object = _baseEdit()
        ..message = const api.Message.edit(
          api.EditMessage(
            tuuid: _targetGuid,
            editPart: 2,
            newParts: api.MessageParts(
              field0: <api.IndexedMessagePart>[
                api.IndexedMessagePart(
                  part_: api.MessagePart.object('object'),
                  idx: 2,
                ),
              ],
            ),
          ),
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(object), isNull);

      final empty = _baseEdit()
        ..message = const api.Message.edit(
          api.EditMessage(
            tuuid: _targetGuid,
            editPart: 2,
            newParts: api.MessageParts(field0: <api.IndexedMessagePart>[]),
          ),
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(empty), isNull);

      final tooMany = _baseEdit()
        ..message = api.Message.edit(
          api.EditMessage(
            tuuid: _targetGuid,
            editPart: 2,
            newParts: api.MessageParts(
              field0: List<api.IndexedMessagePart>.generate(
                129,
                (_) => _textPart('x', idx: null),
              ),
            ),
          ),
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(tooMany), isNull);

      final oversized = _baseEdit()
        ..message = api.Message.edit(
          api.EditMessage(
            tuuid: _targetGuid,
            editPart: 2,
            newParts: api.MessageParts(
              field0: <api.IndexedMessagePart>[
                _textPart('a' * (256 * 1024 + 1), idx: null),
              ],
            ),
          ),
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(oversized), isNull);
    });
  });

  group('bounds and nullability', () {
    test('rejects missing or malformed routing', () {
      final nullSender = _baseEdit()..sender = null;
      expect(CloudSyncLocalMutationIdentity.captureWire(nullSender), isNull);

      final bareSender = _baseEdit()..sender = 'sender@example.test';
      expect(CloudSyncLocalMutationIdentity.captureWire(bareSender), isNull);

      final blankSuffix = _baseEdit()..sender = 'mailto:';
      expect(CloudSyncLocalMutationIdentity.captureWire(blankSuffix), isNull);

      final spaced = _baseEdit()..sender = 'mailto:sender @example.test';
      expect(CloudSyncLocalMutationIdentity.captureWire(spaced), isNull);

      // U+00A0 is White_Space under the codec is_whitespace check; an
      // ASCII-only blank scan would wrongly admit this handle.
      final nbsp = _baseEdit()..sender = 'mailto:sender\u00A0@example.test';
      expect(CloudSyncLocalMutationIdentity.captureWire(nbsp), isNull);

      final nullConversation = _baseEdit()..conversation = null;
      expect(
        CloudSyncLocalMutationIdentity.captureWire(nullConversation),
        isNull,
      );

      final emptyParticipants = _baseEdit()
        ..conversation = api.ConversationData(participants: <String>[]);
      expect(
        CloudSyncLocalMutationIdentity.captureWire(emptyParticipants),
        isNull,
      );

      final duplicated = _baseEdit()
        ..conversation = api.ConversationData(
          participants: <String>[_peer, _peer],
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(duplicated), isNull);

      final tooManyParticipants = _baseEdit()
        ..conversation = api.ConversationData(
          participants: List<String>.generate(
            65,
            (i) => 'mailto:user$i@example.test',
          ),
        );
      expect(
        CloudSyncLocalMutationIdentity.captureWire(tooManyParticipants),
        isNull,
      );

      final badParticipant = _baseEdit()
        ..conversation = api.ConversationData(
          participants: <String>['not-a-handle'],
        );
      expect(
        CloudSyncLocalMutationIdentity.captureWire(badParticipant),
        isNull,
      );
    });

    test('rejects invalid integers and labels', () {
      final negativePart = _baseUnsend()
        ..message = const api.Message.unsend(
          api.UnsendMessage(tuuid: _targetGuid, editPart: -1),
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(negativePart), isNull);

      final negativeIndex = _baseEdit()
        ..message = api.Message.edit(
          api.EditMessage(
            tuuid: _targetGuid,
            editPart: 2,
            newParts: api.MessageParts(
              field0: <api.IndexedMessagePart>[
                _textPart('Edited message', idx: -1),
              ],
            ),
          ),
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(negativeIndex), isNull);

      final negativeTimestamp = _baseEdit()..sentTimestamp = -1;
      expect(
        CloudSyncLocalMutationIdentity.captureWire(negativeTimestamp),
        isNull,
      );

      final controlName = _baseEdit()
        ..conversation = api.ConversationData(
          participants: <String>[_peer],
          cvName: 'Name${String.fromCharCode(0x01)}',
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(controlName), isNull);

      final longLabel = _baseEdit()
        ..conversation = api.ConversationData(
          participants: <String>[_peer],
          senderGuid: 'g' * 4097,
        );
      expect(CloudSyncLocalMutationIdentity.captureWire(longLabel), isNull);
    });
  });

  group('captured hash immutability', () {
    test('mutating the wire afterwards never changes the capture', () {
      final wire = _baseEdit();
      final identity = CloudSyncLocalMutationIdentity.captureWire(wire)!;
      final guidHash = identity.guidHash;
      final targetGuidHash = identity.targetGuidHash;
      final sourceSha256 = identity.sourceSha256;
      wire
        ..id = _otherGuid
        ..sender = 'mailto:other@example.test'
        ..message = const api.Message.unsend(
          api.UnsendMessage(tuuid: _otherGuid, editPart: 9),
        );
      expect(identity.kind, CloudSyncLocalMutationKind.edit);
      expect(identity.targetPart, 2);
      expect(identity.guidHash, guidHash);
      expect(identity.targetGuidHash, targetGuidHash);
      expect(identity.sourceSha256, sourceSha256);
    });

    test('toString is redacted and retains no raw text or handles', () {
      final identity = CloudSyncLocalMutationIdentity.captureWire(_baseEdit())!;
      final rendered = identity.toString();
      expect(rendered, 'CloudSyncLocalMutationIdentity(redacted)');
      for (final secret in <String>[
        _mutationGuid,
        _targetGuid,
        _sender,
        _peer,
        'Edited message',
        identity.guidHash,
        identity.targetGuidHash,
        identity.sourceSha256,
      ]) {
        expect(rendered.contains(secret), isFalse);
      }
    });
  });
}
