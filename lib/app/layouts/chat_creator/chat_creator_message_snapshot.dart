import 'package:bluebubbles/database/global/attributed_body.dart';
import 'package:bluebubbles/database/global/platform_file.dart';

/// The outgoing composer contents, detached from editor/navigation lifecycle.
class ChatCreatorMessageSnapshot {
  ChatCreatorMessageSnapshot({
    required AttributedBody body,
    required List<PlatformFile> attachments,
    this.replyGuid,
    this.replyPart,
  }) : body = AttributedBody(
         string: body.string,
         runs: List.unmodifiable(
           body.runs.map(
             (run) => Run(
               range: List.unmodifiable(run.range),
               attributes: run.attributes,
             ),
           ),
         ),
       ),
       attachments = List.unmodifiable(attachments);

  final AttributedBody body;
  final List<PlatformFile> attachments;
  final String? replyGuid;
  final int? replyPart;

  /// Message.attributedBodyToMessagePart sorts runs in place. Give each send
  /// its own mutable containers without exposing the captured snapshot.
  AttributedBody bodyForSend() => AttributedBody(
    string: body.string,
    runs: body.runs
        .map((run) => Run(range: List.of(run.range), attributes: run.attributes))
        .toList(),
  );
}
