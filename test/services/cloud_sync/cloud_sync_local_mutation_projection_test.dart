import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_projection.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

const _targetGuid = '5BC3779B-7898-4A15-A768-2EA04D3ABAA0';
const _createdMs = 1789146000000;
const _preparedMs = _createdMs + 4000;

Message _target() => Message(
  guid: _targetGuid,
  isFromMe: true,
  text: 'Original',
  dateCreated: DateTime.fromMillisecondsSinceEpoch(_createdMs, isUtc: true),
  attributedBody: [AttributedBody.raw('Original')],
);

api.IndexedMessagePart _part(String text, {int? idx, bool flags = false}) =>
    api.IndexedMessagePart(
      idx: idx,
      part_: api.MessagePart.text(
        text,
        api.TextFormat.flags(
          api.TextFlags(
            bold: flags,
            italic: flags,
            underline: flags,
            strikethrough: flags,
          ),
        ),
      ),
    );

api.MessageInst _wire({
  bool unsend = false,
  List<api.IndexedMessagePart>? parts,
  int part = 0,
}) => api.MessageInst(
  id: '2C174D2E-BAA7-4435-A8D5-88BF2C969A44',
  sender: 'mailto:sender@example.invalid',
  conversation: api.ConversationData(
    participants: ['mailto:peer@example.invalid'],
  ),
  message: unsend
      ? api.Message.unsend(
          api.UnsendMessage(tuuid: _targetGuid, editPart: part),
        )
      : api.Message.edit(
          api.EditMessage(
            tuuid: _targetGuid,
            editPart: part,
            newParts: api.MessageParts(field0: parts ?? [_part('Edited')]),
          ),
        ),
  sentTimestamp: 0,
  sendDelivered: true,
  verificationFailed: false,
);

CloudSyncLocalMutationSourceBinding _source(api.MessageInst wire) {
  final identity = CloudSyncLocalMutationIdentity.captureWire(wire)!;
  return CloudSyncLocalMutationSourceBinding(
    accountFingerprint: 'A' * 43,
    protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
    mutationGuidHash: identity.guidHash,
    targetGuidHash: identity.targetGuidHash,
    targetPart: identity.targetPart,
    sourceSha256: identity.sourceSha256,
    protectedReference: 'obcs2.ref.${'B' * 43}',
    leaseReference: 'obcs2.lease.${'b' * 32}',
    payloadSha256: 'a' * 64,
    payloadLength: 512,
  );
}

CloudSyncLocalMutationProjection _project(
  Message target,
  api.MessageInst wire, {
  int time = _preparedMs,
  CloudSyncLocalMutationSourceBinding? source,
}) => CloudSyncLocalMutationProjection.projectFirst(
  target: target,
  wire: wire,
  source: source ?? _source(wire),
  preparedSentTimestampMs: time,
);

void _apply(Message target, CloudSyncLocalMutationProjection projection) {
  target
    ..text = projection.text
    ..attributedBody = projection.attributedBody
    ..messageSummaryInfo = projection.messageSummaryInfo
    ..dateEdited = projection.dateEdited;
}

void main() {
  test('first edit accepts empty summary and preserves source time zero', () {
    final target = _target();
    final wire = _wire();
    expect(target.messageSummaryInfo, isEmpty);
    final result = _project(target, wire);
    expect(result.text, 'Edited');
    expect(result.dateEdited.isUtc, isTrue);
    expect(result.dateEdited.millisecondsSinceEpoch, _preparedMs);
    final history = result.messageSummaryInfo.single.editedContent['0']!;
    expect(history.map((e) => e.text!.values.single.string), [
      'Original',
      'Edited',
    ]);
    expect(history.map((e) => e.date), [
      _createdMs.toDouble(),
      _preparedMs.toDouble(),
    ]);
    expect(target.text, 'Original');
    expect(target.messageSummaryInfo, isEmpty);
    expect(wire.sentTimestamp, 0);
  });

  test('exact source, case-sensitive target and target part are required', () {
    final wire = _wire();
    final source = _source(wire);
    expect(
      () => _project(_target()..guid = _targetGuid.toLowerCase(), wire),
      throwsStateError,
    );
    expect(
      () => _project(
        _target()..guid = 'F47AC10B-58CC-4372-A567-0E02B2C3D479',
        wire,
      ),
      throwsStateError,
    );
    expect(
      () => _project(_target(), wire..sentTimestamp = 123, source: source),
      throwsStateError,
    );
    expect(() => _project(_target(), _wire(part: 1)), throwsStateError);
    expect(
      () => _project(_target(), _wire(parts: [_part('wrong index', idx: 1)])),
      throwsStateError,
    );
  });

  test(
    'flagged text runs retain UTF16 offsets and are independently copied',
    () {
      final target = _target();
      final wire = _wire(
        parts: [_part('A😀', flags: true), _part('Z', idx: 0)],
      );
      final result = _project(target, wire);
      final body = result.attributedBody.single;
      expect(body.string, 'A😀Z');
      expect(body.runs.map((r) => r.range), [
        [0, 3],
        [3, 1],
      ]);
      final flags = body.runs.first.attributes!;
      expect([
        flags.bold,
        flags.italic,
        flags.underline,
        flags.strikethrough,
      ], everyElement(isTrue));
      final before = jsonEncode(
        target.attributedBody.map((b) => b.toMap()).toList(),
      );
      result
              .messageSummaryInfo
              .single
              .editedContent['0']!
              .first
              .text!
              .values
              .single
              .runs
              .first
              .range[0] =
          99;
      expect(
        jsonEncode(target.attributedBody.map((b) => b.toMap()).toList()),
        before,
      );
      body.runs.first.range[0] = 88;
      expect(
        result
            .messageSummaryInfo
            .single
            .editedContent['0']!
            .last
            .text!
            .values
            .single
            .runs
            .first
            .range[0],
        0,
      );
    },
  );

  test('second edit appends once, preserving original history and range', () {
    final target = _target();
    _apply(target, _project(target, _wire()));
    final before = jsonEncode(
      target.messageSummaryInfo.map((s) => s.toJson()).toList(),
    );
    final result = _project(
      target,
      _wire(parts: [_part('Third', flags: true)]),
      time: _preparedMs + 1000,
    );
    final history = result.messageSummaryInfo.single.editedContent['0']!;
    expect(history.map((e) => e.text!.values.single.string), [
      'Original',
      'Edited',
      'Third',
    ]);
    expect(result.messageSummaryInfo.single.originalTextRange['0'], [0, 8]);
    expect(
      jsonEncode(target.messageSummaryInfo.map((s) => s.toJson()).toList()),
      before,
    );
    expect(
      () => _project(target, _wire(), time: _preparedMs),
      throwsStateError,
    );
    target.attributedBody = [AttributedBody.raw('Unproved replacement')];
    expect(
      () => _project(target, _wire(), time: _preparedMs + 1000),
      throwsStateError,
    );
  });

  test(
    'legacy Apple seconds compare correctly without rewriting prior history',
    () {
      final target = _target();
      _apply(target, _project(target, _wire()));
      const appleEpochMs = 978307200000;
      final history = target.messageSummaryInfo.single.editedContent['0']!;
      for (final entry in history) {
        entry.date = (entry.date! - appleEpochMs) / 1000;
      }
      final oldDates = history.map((e) => e.date).toList();
      final result = _project(target, _wire(), time: _preparedMs + 1000);
      expect(
        result.messageSummaryInfo.single.editedContent['0']!
            .take(2)
            .map((e) => e.date),
        oldDates,
      );
      expect(
        () => _project(target, _wire(), time: _preparedMs - 1),
        throwsStateError,
      );
    },
  );

  test('unsend preserves bytes and history but cannot be resurrected', () {
    final target = _target();
    _apply(target, _project(target, _wire()));
    final before = jsonEncode(
      target.messageSummaryInfo.single.editedContent['0']!
          .map((e) => e.toJson())
          .toList(),
    );
    final result = _project(
      target,
      _wire(unsend: true),
      time: _preparedMs + 1000,
    );
    expect(result.text, 'Edited');
    expect(result.messageSummaryInfo.single.retractedParts, [0]);
    expect(
      jsonEncode(
        result.messageSummaryInfo.single.editedContent['0']!
            .map((e) => e.toJson())
            .toList(),
      ),
      before,
    );
    _apply(target, result);
    expect(
      () => _project(target, _wire(), time: _preparedMs + 2000),
      throwsStateError,
    );
    expect(
      () => _project(target, _wire(unsend: true), time: _preparedMs + 2000),
      throwsStateError,
    );
  });

  test('invalid or stale times never fall back to a clock', () {
    for (final time in [0, -1, _createdMs - 1, 8640000000000001]) {
      expect(() => _project(_target(), _wire(), time: time), throwsStateError);
    }
    final target = _target();
    _apply(target, _project(target, _wire()));
    target.messageSummaryInfo.single.editedContent['0']!.last.date = double.nan;
    expect(
      () => _project(target, _wire(), time: _preparedMs + 1000),
      throwsStateError,
    );
  });

  test('unsupported target shapes are retained rather than flattened', () {
    for (final target in [
      _target()..dateScheduled = DateTime.now(),
      _target()..verificationFailed = true,
      _target()..isFromMe = false,
      _target()..associatedMessageGuid = _targetGuid,
      _target()..attributedBody.add(AttributedBody.raw('Another part')),
      _target()..dbAttachments.add(Attachment(guid: 'attachment')),
    ]) {
      expect(() => _project(target, _wire()), throwsStateError);
    }
  });
}
