import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_parent_coverage.dart';

CloudInboxChangeEntity _row(
  int sequence,
  String record, {
  bool deleted = false,
}) => CloudInboxChangeEntity(
  changeKey: 'synthetic-$sequence',
  scopeKey: 'synthetic-scope',
  accountFingerprint: 'a' * 43,
  zone: 'chatManateeZone',
  changeIdHash: 'change-$sequence',
  generation: 1,
  fetchSequence: sequence,
  batchId: 'batch',
  changeType: deleted ? 'delete' : 'save',
  serverRecordIdHash: record,
  isTombstone: deleted,
  status: 1,
  createdAtMs: sequence,
  updatedAtMs: sequence,
);

void main() {
  test('cached parent comparison notices case-only UUID wrapper differences', () {
    const upper = 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE';
    const lower = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    expect(parentCoverageCaseFoldedReferenceOverlap(upper, lower), isTrue);
    expect(
      parentCoverageCaseFoldedReferenceOverlap(upper, 'iMessage;+;$lower'),
      isTrue,
    );
    expect(
      parentCoverageCaseFoldedReferenceOverlap('iMessage;+;$upper', lower),
      isTrue,
    );
  });

  test('cached parent comparison rejects unrelated or empty references', () {
    expect(parentCoverageCaseFoldedReferenceOverlap('', ''), isFalse);
    expect(
      parentCoverageCaseFoldedReferenceOverlap('opaque-one', 'opaque-two'),
      isFalse,
    );
    expect(
      parentCoverageCaseFoldedReferenceOverlap('+15555550100', '+15555550101'),
      isFalse,
    );
  });

  test(
    'cached parent coverage retains latest physical tombstone over old save',
    () {
      final tombstone = _row(4, 'first', deleted: true);
      final other = _row(3, 'second');
      final old = _row(2, 'first');
      final latest = latestParentCoverageChatRows([tombstone, other, old]);
      expect(latest, [same(tombstone), same(other)]);
      expect(latest.first.isTombstone, isTrue);
      expect(old.isTombstone, isFalse);
    },
  );

  test('cached parent coverage includes records beyond obsolete event cap', () {
    final repeated = [
      for (var sequence = 1100; sequence > 1; sequence--)
        _row(sequence, 'same-physical-chat'),
      _row(1, 'older-distinct-chat'),
    ];
    final latest = latestParentCoverageChatRows(repeated);
    expect(latest.map((row) => row.serverRecordIdHash), [
      'same-physical-chat',
      'older-distinct-chat',
    ]);
    expect(latest.first.fetchSequence, 1100);
    expect(repeated.length, 1100);
  });

  test('cached parent coverage never selects beyond the bounded journal', () {
    final rows = [
      for (var index = 0; index <= parentCoverageChatJournalLimit; index++)
        _row(parentCoverageChatJournalLimit + 1 - index, 'record-$index'),
    ];
    expect(
      latestParentCoverageChatRows(rows).length,
      parentCoverageChatJournalLimit,
    );
    expect(rows.length, parentCoverageChatJournalLimit + 1);
  });
}
