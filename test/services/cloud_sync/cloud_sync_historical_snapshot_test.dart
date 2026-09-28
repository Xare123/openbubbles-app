import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot_codec.dart';
import 'package:flutter_test/flutter_test.dart';

const _time = 1700000000000;
const _account = CloudSyncHistoricalAccountBinding(
  accountFingerprint: 'account',
  protectedStoreIdentity: 'store',
);

CloudSyncHistoricalRowView _row({
  int id = 1,
  String guid = 'one',
  String text = 'original',
}) => CloudSyncHistoricalRowView(
  guid: guid,
  text: text,
  attributedBodies: [AttributedBody.raw(text)],
  hasActualEditOrUnsend: false,
  dateEditedPresent: false,
  associationPresent: false,
  isFromMe: true,
  senderAddress: 'sender@example.invalid',
  chat: const CloudSyncHistoricalChatView(
    id: 1,
    guid: 'iMessage;-;peer@example.invalid',
    style: 45,
    chatIdentifier: 'peer@example.invalid',
    isRoutingStub: false,
    dateDeletedPresent: false,
    isRpSms: false,
    participantCount: 1,
    participantAddress: 'peer@example.invalid',
    participantService: 'iMessage',
  ),
  dateCreatedMs: _time - 1000,
  error: 0,
  isTemp: false,
  stagingGuid: null,
  sendingServiceId: null,
  hasBeenForwarded: false,
  verificationFailed: false,
  ckRecordId: null,
  ckSyncState: false,
  messageId: id,
  itemType: 0,
  groupActionType: 0,
  groupTitle: null,
  isDeleted: false,
  dateScheduledPresent: false,
  threadOriginatorPresent: false,
  hasAttachments: false,
  attachmentCount: 0,
  subjectPresent: false,
  expressiveSendStyleIdPresent: false,
  balloonBundleIdPresent: false,
  payloadDataPresent: false,
  hasApplePayloadData: false,
  amkSessionIdPresent: false,
  rowSnapshotSha256: '0' * 64,
);

void main() {
  CloudSyncHistoricalSnapshot capture({
    List<String>? rows,
    CloudSyncHistoricalAccountBinding account = _account,
    List<String> handles = const ['sender@example.invalid'],
    int time = _time,
    int rowLimit = CloudSyncHistoricalSnapshot.maximumRows,
    int byteLimit = CloudSyncHistoricalSnapshot.maximumBytes,
  }) => CloudSyncHistoricalSnapshot.fromEncodedRows(
    encodedRows: rows ?? [encodeHistoricalSnapshotRow(_row())],
    account: account,
    accountHandles: handles,
    capturedAtMs: time,
    rowLimit: rowLimit,
    byteLimit: byteLimit,
  );

  test(
    'content snapshot stamps one stable digest and detaches mutable callers',
    () async {
      final view = _row();
      final rows = [encodeHistoricalSnapshotRow(view)];
      final handles = ['sender@example.invalid'];
      final snapshot = capture(rows: rows, handles: handles);
      final digest = snapshot.manifest.snapshotSha256;
      expect(capture().manifest.snapshotSha256, digest);
      rows[0] = encodeHistoricalSnapshotRow(_row(text: 'changed'));
      handles[0] = 'different@example.invalid';
      view.attributedBodies.single.runs.clear();
      final page = await snapshot.readPage(limit: 10);
      expect(page.views.single.text, 'original');
      expect(page.views.single.rowSnapshotSha256, digest);
      expect(snapshot.manifest.accountHandles, ['sender@example.invalid']);
      expect(
        () => snapshot.manifest.accountHandles.clear(),
        throwsUnsupportedError,
      );
      expect(page.nextCursor, isNull);
      final read = (await snapshot.readExact('one'))!;
      // Returned objects may be immutable or fresh mutable values. Neither lets a
      // consumer alter the encoded source used by later stages.
      try {
        read.attributedBodies.single.runs.clear();
      } on UnsupportedError {
        // An immutable returned view satisfies the isolation contract too.
      }
      expect(
        (await snapshot.readExact('one'))!.attributedBodies.single.runs,
        isNotEmpty,
      );
    },
  );

  test(
    'snapshot digest binds content, account, installation, aliases and time',
    () {
      final base = capture().manifest.snapshotSha256;
      for (final other in [
        capture(rows: [encodeHistoricalSnapshotRow(_row(text: 'changed'))]),
        capture(
          account: const CloudSyncHistoricalAccountBinding(
            accountFingerprint: 'other',
            protectedStoreIdentity: 'store',
          ),
        ),
        capture(
          account: const CloudSyncHistoricalAccountBinding(
            accountFingerprint: 'account',
            protectedStoreIdentity: 'other',
          ),
        ),
        capture(handles: ['other@example.invalid']),
        capture(time: _time + 1),
      ]) {
        expect(other.manifest.snapshotSha256, isNot(base));
      }
      expect(
        capture(handles: ['b', 'a']).manifest.snapshotSha256,
        capture(handles: ['a', 'b']).manifest.snapshotSha256,
      );
    },
  );

  test(
    'snapshot pages exact sparse IDs and resumes without a live database',
    () async {
      final snapshot = capture(
        rows: [
          encodeHistoricalSnapshotRow(_row(id: 2, guid: 'a')),
          encodeHistoricalSnapshotRow(_row(id: 7, guid: 'b')),
          encodeHistoricalSnapshotRow(_row(id: 20, guid: 'c')),
        ],
      );
      final first = await snapshot.readPage(limit: 2);
      expect(first.views.map((r) => r.messageId), [2, 7]);
      final next = await snapshot.readPage(cursor: first.nextCursor, limit: 2);
      expect(next.views.map((r) => r.messageId), [20]);
      expect(next.nextCursor, isNull);
      expect((await snapshot.readExact('b'))!.messageId, 7);
      expect(await snapshot.readExact('missing'), isNull);
      expect(snapshot.manifest.messageCount, 3);
      for (final cursor in [
        'historical-scan:v1:${'a' * 64}:7',
        'historical-scan:v1:${snapshot.scope}:3',
        'historical-scan:v1:${snapshot.scope}:07',
      ]) {
        await expectLater(
          snapshot.readPage(cursor: cursor, limit: 2),
          throwsStateError,
        );
      }
    },
  );

  test(
    'ambiguous GUIDs are retained but cannot select an arbitrary source',
    () async {
      final snapshot = capture(
        rows: [
          encodeHistoricalSnapshotRow(_row(id: 1)),
          encodeHistoricalSnapshotRow(_row(id: 2)),
        ],
      );
      expect((await snapshot.readPage(limit: 2)).views, hasLength(2));
      await expectLater(snapshot.readExact('one'), throwsStateError);
    },
  );

  test('limits never return a truncated successful snapshot', () {
    final row = encodeHistoricalSnapshotRow(_row());
    expect(() => capture(rows: []), throwsStateError);
    expect(() => capture(rows: [row], byteLimit: 1), throwsStateError);
    expect(
      () => capture(
        rows: [row, encodeHistoricalSnapshotRow(_row(id: 2))],
        rowLimit: 1,
      ),
      throwsStateError,
    );
    expect(() => capture(byteLimit: 0), throwsStateError);
    expect(
      () => capture(rowLimit: CloudSyncHistoricalSnapshot.maximumRows + 1),
      throwsStateError,
    );
  });

  test('invalid source ordering, binding and encoding cannot qualify', () {
    final row = encodeHistoricalSnapshotRow(_row());
    expect(() => capture(rows: [row, row]), throwsStateError);
    expect(
      () => capture(rows: [encodeHistoricalSnapshotRow(_row(id: 2)), row]),
      throwsStateError,
    );
    expect(() => capture(rows: ['not a row']), throwsStateError);
    expect(() => capture(handles: []), throwsStateError);
    expect(() => capture(handles: ['same', 'same']), throwsStateError);
    expect(() => capture(time: -1), throwsStateError);
  });
}
