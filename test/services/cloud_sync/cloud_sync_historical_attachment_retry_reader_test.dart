import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_attachment_inventory.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_attachment_retry_reader.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_producer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:flutter_test/flutter_test.dart';

const _now = 1700000002000;
final _account = CloudSyncHistoricalAccountBinding(
  accountFingerprint: 'A' * 43,
  protectedStoreIdentity: 'obcs2.store.${'S' * 43}',
);
final _manifest = CloudSyncHistoricalSourceManifest(
  snapshotSha256: 'a' * 64,
  accountFingerprint: _account.accountFingerprint,
  accountHandles: const ['owner@example.invalid'],
  messageCount: 3,
  capturedAtMs: _now - 1000,
);
const _chat = CloudSyncHistoricalChatView(
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
);

CloudSyncHistoricalRowView _row(String guid, {bool media = true}) {
  final part = Attachment(
    id: 1,
    guid: '${guid}_0',
    uti: 'public.jpeg',
    mimeType: 'image/jpeg',
    isOutgoing: true,
    transferName: 'photo.jpg',
    totalBytes: 128,
  )..message.targetId = 7;
  return CloudSyncHistoricalRowView(
    guid: guid,
    text: media ? null : 'synthetic text',
    attributedBodies: media
        ? [
            AttributedBody(
              string: ' ',
              runs: [
                Run(
                  range: [0, 1],
                  attributes: Attributes(
                    messagePart: 0,
                    attachmentGuid: '${guid}_0',
                  ),
                ),
              ],
            ),
          ]
        : [],
    hasActualEditOrUnsend: false,
    dateEditedPresent: false,
    associationPresent: false,
    isFromMe: true,
    senderAddress: 'owner@example.invalid',
    chat: _chat,
    dateCreatedMs: _now - 2000,
    error: 0,
    isTemp: false,
    stagingGuid: null,
    sendingServiceId: null,
    hasBeenForwarded: false,
    verificationFailed: false,
    ckRecordId: null,
    ckSyncState: false,
    messageId: 7,
    itemType: 0,
    groupActionType: 0,
    groupTitle: null,
    isDeleted: false,
    dateScheduledPresent: false,
    threadOriginatorPresent: false,
    hasAttachments: media,
    attachmentCount: media ? 1 : 0,
    subjectPresent: false,
    expressiveSendStyleIdPresent: false,
    balloonBundleIdPresent: false,
    payloadDataPresent: false,
    hasApplePayloadData: false,
    amkSessionIdPresent: false,
    rowSnapshotSha256: _manifest.snapshotSha256,
    attachmentInventory: media
        ? CloudSyncHistoricalAttachmentInventory.capture([part])
        : null,
  );
}

class _Pages implements HistoricalRowReader {
  _Pages(this.pages);
  final List<HistoricalRowPage> pages;
  final List<String?> cursors = [];
  @override
  Future<HistoricalRowPage> readPage({
    String? cursor,
    required int limit,
  }) async {
    cursors.add(cursor);
    return pages[cursor == null ? 0 : int.parse(cursor)];
  }
}

class _Unowned extends HistoricalOwnershipRegistry {}

void main() {
  CloudSyncHistoricalAttachmentRetryReader reader(
    _Pages pages, {
    bool Function(CloudSyncHistoricalArchiveRequest)? include,
    Future<void> Function()? validate,
  }) => CloudSyncHistoricalAttachmentRetryReader(
    source: pages,
    manifest: _manifest,
    account: _account,
    nowMs: _now,
    validate: validate ?? () async {},
    needsRetryOrRecovery: include ?? (_) => true,
  );

  test(
    'only qualified pending media is presented, without altering page cursor',
    () async {
      final seen = <String>[];
      final pages = _Pages([
        HistoricalRowPage(
          views: [
            _row('pending'),
            _row('confirmed'),
            _row('text', media: false),
          ],
          nextCursor: '1',
        ),
      ]);
      final result = await reader(
        pages,
        include: (request) {
          seen.add(request.guid);
          return request.guid == 'pending';
        },
      ).readPage(limit: 3);
      expect(result.views.map((v) => v.guid), ['pending']);
      expect(seen, ['pending', 'confirmed']);
      expect(result.nextCursor, '1');
      expect(pages.cursors, [null]);
    },
  );

  test(
    'filtered empty page still continues to the next original page',
    () async {
      final pages = _Pages([
        HistoricalRowPage(views: [_row('text', media: false)], nextCursor: '1'),
        HistoricalRowPage(views: [_row('pending')], nextCursor: null),
      ]);
      final retry = reader(pages);
      final first = await retry.readPage(limit: 1);
      expect(first.views, isEmpty);
      expect(
        (await retry.readPage(
          cursor: first.nextCursor,
          limit: 1,
        )).views.single.guid,
        'pending',
      );
      expect(pages.cursors, [null, '1']);
    },
  );

  test(
    'uncertain outcome selection failure propagates instead of skipping it',
    () async {
      final pages = _Pages([
        HistoricalRowPage(views: [_row('pending')], nextCursor: null),
      ]);
      await expectLater(
        reader(
          pages,
          include: (_) => throw StateError(
            'cloud_sync_historical_archive_confirmation_pending',
          ),
        ).readPage(limit: 1),
        throwsStateError,
      );
    },
  );

  test(
    'identity is revalidated after the asynchronous page before journal selection',
    () async {
      var checks = 0;
      var selections = 0;
      final pages = _Pages([
        HistoricalRowPage(views: [_row('pending')], nextCursor: null),
      ]);
      await expectLater(
        reader(
          pages,
          validate: () async {
            if (++checks == 2) throw StateError('identity_changed');
          },
          include: (_) {
            selections++;
            return true;
          },
        ).readPage(limit: 1),
        throwsStateError,
      );
      expect(selections, 0);
    },
  );

  test('oversized and repeating pages fail before filtering', () async {
    await expectLater(
      reader(
        _Pages([
          HistoricalRowPage(views: [_row('a'), _row('b')], nextCursor: null),
        ]),
      ).readPage(limit: 1),
      throwsStateError,
    );
    final repeated = _Pages([
      const HistoricalRowPage(views: [], nextCursor: null),
      const HistoricalRowPage(views: [], nextCursor: '1'),
    ]);
    await expectLater(
      reader(repeated).readPage(cursor: '1', limit: 1),
      throwsStateError,
    );
  });

  for (final enabled in [false, true]) {
    test(
      'producer media eligibility requires explicit complete-media composition: $enabled',
      () async {
        final view = _row('pending');
        final pages = _Pages([
          HistoricalRowPage(views: [view], nextCursor: null),
        ]);
        var stages = 0;
        final original = MemoryHistoricalCursorStore();
        final done = HistoricalProducerCursor(
          scope: historicalArchiveScope(_manifest, _account),
          lastId: null,
          done: true,
        );
        await original.save(done);
        final result = await CloudSyncHistoricalProducer(
          reader: reader(pages),
          registry: _Unowned(),
          cursors: MemoryHistoricalCursorStore(),
          manifest: _manifest,
          account: _account,
          nowMs: _now,
          includeMediaSource: enabled,
          readCurrentRow: (_) async => view,
          stageAndAdopt: (request, bytes) async {
            stages++;
            expect(request.media, isNotNull);
            expect(request.media!.inventory.attachments, hasLength(1));
            return StagedHistoricalSource(
              key: request.sourceSha256,
              guid: request.guid,
              sha256: historicalBytesSha256(bytes),
              byteLength: bytes.length,
            );
          },
        ).run();
        expect(result.summary.completed, isTrue);
        expect(stages, enabled ? 1 : 0);
        expect(identical(await original.load(), done), isTrue);
      },
    );
  }
}
