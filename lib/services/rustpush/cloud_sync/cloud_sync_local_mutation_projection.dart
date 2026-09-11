import 'dart:convert';

import 'package:bluebubbles/database/global/attributed_body.dart';
import 'package:bluebubbles/database/global/message_summary_info.dart';
import 'package:bluebubbles/database/io/message.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

/// First local-only projection of a staged edit/unsend onto display values.
///
/// Pure and source-derived: validates everything up front, then returns
/// independent deep copies of text/body/summary/dateEdited.
/// Never mutates the target, source wire, or database. The caller must
/// independently verify the native IDS receipt; the supplied timestamp
/// is the actual prepared time and is never treated here
/// as CloudKit write proof. Does not mark wider production complete.
final class CloudSyncLocalMutationProjection {
  const CloudSyncLocalMutationProjection._({
    required this.kind,
    required this.text,
    required this.attributedBody,
    required this.messageSummaryInfo,
    required this.dateEdited,
    required this.preparedSentTimestampMs,
  });

  /// Edit or unsend, mirrored from the captured wire identity.
  final CloudSyncLocalMutationKind kind;

  /// Replacement display text for part 0 (unsend keeps the original text).
  final String text;

  /// Deep-copied replacement body list (single part-0 body).
  final List<AttributedBody> attributedBody;

  /// Deep-copied replacement summary list (single summary).
  final List<MessageSummaryInfo> messageSummaryInfo;

  /// Exact prepared edit time.
  final DateTime dateEdited;

  /// Echo of the validated prepared time.
  final int preparedSentTimestampMs;

  /// Largest millisecond value Dart DateTime accepts.
  static const int _maxIntMs = 8640000000000000;

  /// Project [wire] onto [target] display values without mutating either.
  ///
  /// [target] is the journal-validated pre-mutation row and supplies the history
  /// baseline (original snapshot/dateCreated, prior summaries). [source] is
  /// the adopted native source binding. [preparedSentTimestampMs] must be
  /// greater than zero, DateTime-representable, at or after the original
  /// creation time, and strictly after any known prior edit time. There is
  /// no clock fallback: invalid times throw.
  /// Throws [StateError] on any ineligible shape or mismatch, before
  /// producing output; nothing is mutated on failure or success.
  static CloudSyncLocalMutationProjection projectFirst({
    required Message target,
    required api.MessageInst wire,
    required CloudSyncLocalMutationSourceBinding source,
    required int preparedSentTimestampMs,
  }) {
    final identity = CloudSyncLocalMutationIdentity.captureWire(
      wire,
      expectedSourceSha256: source.sourceSha256,
    );
    if (identity == null) {
      throw StateError('cloud_sync_mutation_projection_ineligible_wire');
    }
    if (identity.guidHash != source.mutationGuidHash ||
        identity.targetGuidHash != source.targetGuidHash ||
        identity.sourceSha256 != source.sourceSha256 ||
        identity.targetPart != source.targetPart) {
      throw StateError('cloud_sync_mutation_projection_source_mismatch');
    }
    if (source.targetPart != 0 || identity.targetPart != 0) {
      throw StateError('cloud_sync_mutation_projection_part_not_supported');
    }
    final targetGuid = target.guid;
    final payload = wire.message;
    final wireTarget = switch (payload) {
      api.Message_Edit() => payload.field0.tuuid,
      api.Message_Unsend() => payload.field0.tuuid,
      _ => null,
    };
    if (targetGuid == null || targetGuid != wireTarget) {
      throw StateError('cloud_sync_mutation_projection_guid_mismatch');
    }
    _requireEligibleTarget(target);
    final preparedTime = _requirePreparedTime(
      preparedSentTimestampMs: preparedSentTimestampMs,
      original: target,
    );
    final targetBody = _singlePartZeroBody(target);
    final priorSummary = _singleSummary(target);
    final priorEditMs = _latestPriorEditMs(priorSummary, target.dateEdited);
    if (preparedSentTimestampMs <= priorEditMs) {
      throw StateError('cloud_sync_mutation_projection_time_not_after_prior');
    }

    if (payload is api.Message_Edit) {
      if (priorSummary.retractedParts.contains(0)) {
        throw StateError('cloud_sync_mutation_projection_already_retracted');
      }
      final replacement = _replacementBody(payload.field0.newParts);
      final history = _historyForEdit(
        priorSummary: priorSummary,
        originalBody: targetBody,
        originalCreatedMs: target.dateCreated?.millisecondsSinceEpoch,
        replacement: replacement,
        preparedMs: preparedSentTimestampMs,
      );
      final priorRange = priorSummary.originalTextRange['0'];
      final nextSummary = MessageSummaryInfo(
        retractedParts: List<int>.from(priorSummary.retractedParts),
        editedContent: history,
        originalTextRange: <String, List<int>>{
          '0': priorRange == null
              ? _utf16Range(history['0']!.first.text!.values.single.string)
              : List<int>.from(priorRange),
        },
        editedParts: <int>[0],
      );
      return CloudSyncLocalMutationProjection._(
        kind: CloudSyncLocalMutationKind.edit,
        text: replacement.string,
        attributedBody: <AttributedBody>[
          AttributedBody.fromMap(
            jsonDecode(jsonEncode(replacement.toMap())) as Map<String, dynamic>,
          ),
        ],
        messageSummaryInfo: <MessageSummaryInfo>[
          MessageSummaryInfo.fromJson(
            jsonDecode(jsonEncode(nextSummary.toJson()))
                as Map<String, dynamic>,
          ),
        ],
        dateEdited: preparedTime,
        preparedSentTimestampMs: preparedSentTimestampMs,
      );
    }
    if (payload is api.Message_Unsend) {
      if (priorSummary.retractedParts.contains(0)) {
        throw StateError('cloud_sync_mutation_projection_already_retracted');
      }
      final nextSummary = MessageSummaryInfo(
        retractedParts: <int>[...priorSummary.retractedParts, 0],
        editedContent: _deepEditedContent(priorSummary.editedContent),
        originalTextRange: _deepOriginalRange(priorSummary.originalTextRange),
        editedParts: List<int>.from(priorSummary.editedParts),
      );
      return CloudSyncLocalMutationProjection._(
        kind: CloudSyncLocalMutationKind.unsend,
        text: target.text ?? targetBody.string,
        attributedBody: <AttributedBody>[
          AttributedBody.fromMap(
            jsonDecode(jsonEncode(targetBody.toMap())) as Map<String, dynamic>,
          ),
        ],
        messageSummaryInfo: <MessageSummaryInfo>[
          MessageSummaryInfo.fromJson(
            jsonDecode(jsonEncode(nextSummary.toJson()))
                as Map<String, dynamic>,
          ),
        ],
        dateEdited: preparedTime,
        preparedSentTimestampMs: preparedSentTimestampMs,
      );
    }
    throw StateError('cloud_sync_mutation_projection_ineligible_wire');
  }

  static void _requireEligibleTarget(Message message) {
    if (message.attributedBody.length != 1 ||
        message.messageSummaryInfo.length > 1) {
      throw StateError('cloud_sync_mutation_projection_shape_not_supported');
    }
    if (message.hasAttachments ||
        message.attachments.isNotEmpty ||
        message.dbAttachments.isNotEmpty ||
        message.associatedMessageType != null ||
        message.associatedMessageGuid != null ||
        message.hasReactions ||
        message.associatedMessages.isNotEmpty ||
        message.dateScheduled != null ||
        message.isFromMe != true ||
        message.temp ||
        message.error != 0 ||
        message.subject?.isNotEmpty == true ||
        message.verificationFailed ||
        message.dateDeleted != null) {
      throw StateError('cloud_sync_mutation_projection_shape_not_supported');
    }
  }

  static DateTime _requirePreparedTime({
    required int preparedSentTimestampMs,
    required Message original,
  }) {
    if (preparedSentTimestampMs <= 0 || preparedSentTimestampMs > _maxIntMs) {
      throw StateError('cloud_sync_mutation_projection_bad_time');
    }
    final createdMs = original.dateCreated?.millisecondsSinceEpoch;
    if (createdMs == null || preparedSentTimestampMs < createdMs) {
      throw StateError('cloud_sync_mutation_projection_bad_time');
    }
    try {
      return DateTime.fromMillisecondsSinceEpoch(
        preparedSentTimestampMs,
        isUtc: true,
      );
    } on ArgumentError {
      throw StateError('cloud_sync_mutation_projection_bad_time');
    }
  }

  static AttributedBody _singlePartZeroBody(Message message) {
    if (message.attributedBody.length != 1) {
      throw StateError('cloud_sync_mutation_projection_shape_not_supported');
    }
    final body = message.attributedBody.first;
    if (body.runs.isEmpty) {
      throw StateError('cloud_sync_mutation_projection_shape_not_supported');
    }
    var covered = 0;
    for (final run in body.runs) {
      final attrs = run.attributes;
      if (attrs == null ||
          attrs.messagePart != 0 ||
          attrs.attachmentGuid != null ||
          attrs.mention != null ||
          attrs.audioTranscript != null ||
          attrs.stickerData != null ||
          attrs.textEffect != null) {
        throw StateError('cloud_sync_mutation_projection_shape_not_supported');
      }
      if (run.range.length != 2 ||
          run.range[0] != covered ||
          run.range[1] < 0) {
        throw StateError('cloud_sync_mutation_projection_shape_not_supported');
      }
      covered += run.range[1];
    }
    if (covered != body.string.length) {
      throw StateError('cloud_sync_mutation_projection_shape_not_supported');
    }
    return body;
  }

  static MessageSummaryInfo _singleSummary(Message message) {
    if (message.messageSummaryInfo.isEmpty) return MessageSummaryInfo.empty();
    if (message.messageSummaryInfo.length != 1) {
      throw StateError('cloud_sync_mutation_projection_shape_not_supported');
    }
    final summary = message.messageSummaryInfo.first;
    for (final key in summary.editedContent.keys) {
      if (key != '0') {
        throw StateError('cloud_sync_mutation_projection_shape_not_supported');
      }
    }
    for (final key in summary.originalTextRange.keys) {
      if (key != '0') {
        throw StateError('cloud_sync_mutation_projection_shape_not_supported');
      }
    }
    for (final part in <int>[
      ...summary.retractedParts,
      ...summary.editedParts,
    ]) {
      if (part != 0) {
        throw StateError('cloud_sync_mutation_projection_shape_not_supported');
      }
    }
    return summary;
  }

  static bool _sameBodyShape(AttributedBody a, AttributedBody b) {
    return jsonEncode(a.toMap()) == jsonEncode(b.toMap());
  }

  static int _latestPriorEditMs(
    MessageSummaryInfo summary,
    DateTime? dateEdited,
  ) {
    var latest = dateEdited?.millisecondsSinceEpoch ?? 0;
    for (final entries in summary.editedContent.values) {
      for (final entry in entries) {
        final raw = entry.date;
        const appleEpochMs = 978307200000;
        const maximumMs = 253402300799999;
        if (raw == null ||
            !raw.isFinite ||
            raw <= 0 ||
            raw > maximumMs ||
            entry.text?.values.isNotEmpty != true) {
          throw StateError('cloud_sync_mutation_projection_history_mismatch');
        }
        // Same established encodings as the canonical adapter: V2/live Unix
        // milliseconds or legacy Apple-epoch seconds. Preserve stored history.
        final int ms;
        if (raw >= appleEpochMs && raw == raw.floorToDouble()) {
          ms = raw.toInt();
        } else if (raw <= (maximumMs - appleEpochMs) / 1000) {
          ms = appleEpochMs + (raw * 1000).floor();
        } else {
          throw StateError('cloud_sync_mutation_projection_history_mismatch');
        }
        if (ms > latest) latest = ms;
      }
    }
    return latest;
  }

  /// Validate replacement native parts and fold them into one part-0 body.
  ///
  /// Accepts multiple Text+Flags runs with idx 0 or null only; preserves
  /// exact UTF-16 ranges and all four flags. Anything else throws.
  static AttributedBody _replacementBody(api.MessageParts parts) {
    if (parts.field0.isEmpty) {
      throw StateError('cloud_sync_mutation_projection_parts_not_supported');
    }
    var full = '';
    final runs = <Run>[];
    var offset = 0;
    for (final indexed in parts.field0) {
      if (indexed.ext != null || (indexed.idx != null && indexed.idx != 0)) {
        throw StateError('cloud_sync_mutation_projection_parts_not_supported');
      }
      final part = indexed.part_;
      if (part is! api.MessagePart_Text) {
        throw StateError('cloud_sync_mutation_projection_parts_not_supported');
      }
      if (part.field1 is! api.TextFormat_Flags) {
        throw StateError('cloud_sync_mutation_projection_parts_not_supported');
      }
      final flags = (part.field1 as api.TextFormat_Flags).field0;
      final text = part.field0;
      final length = text.length;
      full += text;
      runs.add(
        Run(
          range: <int>[offset, length],
          attributes: Attributes(
            messagePart: 0,
            bold: flags.bold ? true : null,
            italic: flags.italic ? true : null,
            strikethrough: flags.strikethrough ? true : null,
            underline: flags.underline ? true : null,
          ),
        ),
      );
      offset += length;
    }
    if (full.isEmpty) {
      throw StateError('cloud_sync_mutation_projection_parts_not_supported');
    }
    return AttributedBody(string: full, runs: runs);
  }

  static List<int> _utf16Range(String text) {
    return <int>[0, text.length];
  }

  /// History keeps prior entries, then appends; the first entry is the
  /// original snapshot at dateCreated and later entries carry the exact
  /// prepared time. Unknown Apple fields are never synthesized.
  static Map<String, List<EditedContent>> _historyForEdit({
    required MessageSummaryInfo priorSummary,
    required AttributedBody originalBody,
    required int? originalCreatedMs,
    required AttributedBody replacement,
    required int preparedMs,
  }) {
    final history = _deepEditedContent(priorSummary.editedContent);
    final entries = history.putIfAbsent('0', () => <EditedContent>[]);
    if (entries.isEmpty) {
      if (originalCreatedMs == null) {
        throw StateError('cloud_sync_mutation_projection_bad_time');
      }
      entries.add(
        EditedContent(
          text: Content(
            values: <AttributedBody>[
              AttributedBody.fromMap(
                jsonDecode(jsonEncode(originalBody.toMap()))
                    as Map<String, dynamic>,
              ),
            ],
          ),
          date: originalCreatedMs.toDouble(),
        ),
      );
    } else {
      final lastBody = entries.last.text?.values;
      if (lastBody == null ||
          lastBody.length != 1 ||
          entries.first.text?.values.length != 1 ||
          !_sameBodyShape(lastBody.single, originalBody)) {
        throw StateError('cloud_sync_mutation_projection_history_mismatch');
      }
    }
    entries.add(
      EditedContent(
        text: Content(
          values: <AttributedBody>[
            AttributedBody.fromMap(
              jsonDecode(jsonEncode(replacement.toMap()))
                  as Map<String, dynamic>,
            ),
          ],
        ),
        date: preparedMs.toDouble(),
      ),
    );
    return history;
  }

  static Map<String, List<EditedContent>> _deepEditedContent(
    Map<String, List<EditedContent>> value,
  ) {
    final copy = <String, List<EditedContent>>{};
    value.forEach((key, entries) {
      copy[key] = entries
          .map(
            (entry) => EditedContent.fromJson(
              jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
            ),
          )
          .toList();
    });
    return copy;
  }

  static Map<String, List<int>> _deepOriginalRange(
    Map<String, List<int>> value,
  ) {
    final copy = <String, List<int>>{};
    value.forEach((key, list) => copy[key] = List<int>.from(list));
    return copy;
  }

  @override
  String toString() => 'CloudSyncLocalMutationProjection(redacted)';
}
