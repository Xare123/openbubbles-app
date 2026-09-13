// Opt-in comparison for hash-verified local copies captured under the profile
// lock. No network or sends; missing input files must not create empty stores.
import 'dart:convert';
import 'dart:io';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Platform.environment['OPENBUBBLES_PROJECTION_DELTA_COPIES'];
  test('compare bounded new message rows after a protected replay', () async {
    expect(root, isNotEmpty);
    expect(File('$root/before/data.mdb').existsSync(), isTrue);
    expect(File('$root/after/data.mdb').existsSync(), isTrue);
    final before = await openStore(directory: '$root/before');
    final after = await openStore(directory: '$root/after');
    try {
      final oldBox = before.box<Message>();
      final newBox = after.box<Message>();
      final latest =
          (oldBox.query()..order(Message_.id, flags: Order.descending)).build()
            ..limit = 1;
      late final int lastId;
      try {
        lastId = latest.findFirst()?.id ?? 0;
      } finally {
        latest.close();
      }
      final added = newBox.query(Message_.id.greaterThan(lastId)).build()
        ..limit = 501;
      late final List<Message> rows;
      try {
        rows = added.find();
      } finally {
        added.close();
      }
      expect(rows.length, lessThanOrEqualTo(500));
      var textBodies = 0;
      var replacementCharacters = 0;
      var replyRows = 0;
      var multipartReplyRows = 0;
      for (final row in rows) {
        final text =
            row.text ?? row.attributedBody.map((part) => part.string).join();
        if (text.replaceAll('\uFFFC', '').trim().isNotEmpty) textBodies++;
        replacementCharacters += '\uFFFD'.allMatches(text).length;
        if (row.threadOriginatorGuid != null) replyRows++;
        if (row.threadOriginatorGuid != null &&
            row.threadOriginatorPart?.contains(':') == true)
          multipartReplyRows++;
      }
      // Counts are evidence, not a claim of complete-history or visual QA.
      print(
        'projection_delta=${jsonEncode({'before_message_rows': oldBox.count(), 'after_message_rows': newBox.count(), 'new_distinct_rows': rows.length, 'new_rows_with_text': textBodies, 'replacement_characters': replacementCharacters, 'new_reply_rows': replyRows, 'new_multipart_reply_rows': multipartReplyRows})}',
      );
    } finally {
      after.close();
      before.close();
    }
  }, skip: root == null);
}
