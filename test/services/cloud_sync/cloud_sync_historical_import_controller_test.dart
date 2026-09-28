import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_import_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_producer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot_codec.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:flutter_test/flutter_test.dart';

/// Composition tests for the manual import lifecycle over synthetic
/// immutable snapshots. No ObjectBox store is opened and no native bridge
/// is touched: snapshots come from fromEncodedRows, cursors are
/// [MemoryHistoricalCursorStore], and archiving is an in-memory callback.
/// Row GUIDs are valid UUIDs and bodies are complete plain structures so
/// real eligibility runs instead of being skipped.
String _t(String c) => List.filled(43, c).join();

String _uuid(int i) =>
    'a3f1c2d4-e5b6-4c7d-8e9f-${i.toRadixString(16).padLeft(12, '0')}';

CloudSyncHistoricalAccountBinding _account() =>
    CloudSyncHistoricalAccountBinding(
      accountFingerprint: _t('A'),
      protectedStoreIdentity: 'obcs2.store.${_t('S')}',
    );

CloudSyncHistoricalChatView _chat() => const CloudSyncHistoricalChatView(
  id: 11,
  guid: 'iMessage;-;peer@example.com',
  style: 45,
  chatIdentifier: 'peer@example.com',
  isRoutingStub: false,
  dateDeletedPresent: false,
  isRpSms: false,
  participantCount: 1,
  participantAddress: 'peer@example.com',
  participantService: 'iMessage',
);

String _row(int id, {bool attachments = false}) {
  final text = 'import row $id body';
  return encodeHistoricalSnapshotRow(
    CloudSyncHistoricalRowView(
      guid: _uuid(id),
      text: text,
      attributedBodies: [
        if (attachments)
          AttributedBody(
            string: text,
            runs: [
              Run(
                range: [0, text.length],
                attributes: Attributes(
                  messagePart: 0,
                  attachmentGuid: 'attach-$id',
                ),
              ),
            ],
          )
        else
          AttributedBody.raw(text),
      ],
      hasActualEditOrUnsend: false,
      dateEditedPresent: false,
      associationPresent: false,
      isFromMe: false,
      senderAddress: 'peer@example.com',
      chat: _chat(),
      dateCreatedMs: 1700000000000,
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
      hasAttachments: attachments,
      attachmentCount: attachments ? 1 : 0,
      subjectPresent: false,
      expressiveSendStyleIdPresent: false,
      balloonBundleIdPresent: false,
      payloadDataPresent: false,
      hasApplePayloadData: false,
      amkSessionIdPresent: false,
      rowSnapshotSha256: '0' * 64,
    ),
  );
}

CloudSyncHistoricalSnapshot _snapshot(List<String> rows) =>
    CloudSyncHistoricalSnapshot.fromEncodedRows(
      encodedRows: rows,
      account: _account(),
      accountHandles: const ['me@example.com'],
      capturedAtMs: DateTime.now().millisecondsSinceEpoch,
    );

/// Shared synthetic fixture for the Profile widget composition tests.
CloudSyncHistoricalSnapshot historicalImportTestSnapshot([int count = 3]) =>
    _snapshot([for (var i = 1; i <= count; i++) _row(i)]);

final class _EmptyRegistry extends HistoricalOwnershipRegistry {
  @override
  Set<String> get ownedGuids => const {};
  @override
  Set<String> get conflictGuids => const {};
}

/// In-memory archive callback. Records every presented GUID so resume
/// duplicates are visible; returning the same disposition for repeats
/// models the idempotent journal put-if-absent contract.
final class _Archive {
  // Mutable hook fields so individual tests can arm behavior after
  // construction.
  CloudSyncHistoricalArchiveDisposition Function(String guid)? dispositionFor;
  Future<void> Function(String guid)? beforeReturn;
  bool Function(String guid)? throwFor;
  StagedHistoricalSource Function(StagedHistoricalSource)? transformSource;
  int calls = 0;
  final Map<String, int> callsByGuid = {};

  Future<
    ({
      StagedHistoricalSource source,
      CloudSyncHistoricalArchiveDisposition disposition,
    })
  >
  call(CloudSyncHistoricalArchiveRequest request, List<int> bytes) async {
    calls++;
    callsByGuid.update(request.guid, (v) => v + 1, ifAbsent: () => 1);
    await beforeReturn?.call(request.guid);
    if (throwFor?.call(request.guid) ?? false) {
      throw Exception('secret body text must not leak');
    }
    final source = StagedHistoricalSource(
      key: request.sourceSha256,
      sha256: historicalBytesSha256(bytes),
      byteLength: bytes.length,
      guid: request.guid,
    );
    return (
      source: transformSource?.call(source) ?? source,
      disposition:
          dispositionFor?.call(request.guid) ??
          CloudSyncHistoricalArchiveDisposition.confirmedCreate,
    );
  }
}

void main() {
  late MemoryHistoricalCursorStore cursors;
  late _Archive archive;
  late bool live;
  late Future<void> Function() validateIdentity;

  CloudSyncHistoricalSnapshot snapshot([int count = 3]) =>
      _snapshot([for (var i = 1; i <= count; i++) _row(i)]);

  CloudSyncHistoricalImportPlan planFor(CloudSyncHistoricalSnapshot snap) =>
      CloudSyncHistoricalImportPlan(
        snapshot: snap,
        accountLabel: 'Example Account',
        archiveCursors: cursors,
        registry: _EmptyRegistry(),
        stillCurrent: () => live,
        validateIdentity: () => validateIdentity(),
        archive: archive.call,
      );

  Future<CloudSyncHistoricalImportConfirmation> prepareFor(
    CloudSyncHistoricalImportController controller,
    CloudSyncHistoricalSnapshot snap,
  ) => controller.prepare(() async => planFor(snap));

  Matcher busy() => throwsA(
    isA<StateError>().having(
      (e) => e.message,
      'message',
      'cloud_sync_historical_import_busy',
    ),
  );

  Matcher expired() => throwsA(
    isA<StateError>().having(
      (e) => e.message,
      'message',
      'cloud_sync_historical_import_confirmation_expired',
    ),
  );

  setUp(() {
    cursors = MemoryHistoricalCursorStore();
    archive = _Archive();
    live = true;
    validateIdentity = () async {};
  });

  test('prepare previews without uploading', () async {
    final controller = CloudSyncHistoricalImportController();
    final snap = snapshot();
    final confirmation = await prepareFor(controller, snap);
    expect(archive.calls, 0);
    expect(
      controller.phase,
      CloudSyncHistoricalImportPhase.awaitingConfirmation,
    );
    expect(controller.sourceRows, 3);
    expect(confirmation.messageCount, 3);
    expect(confirmation.accountLabel, 'Example Account');
    expect(
      confirmation.toString(),
      'CloudSyncHistoricalImportConfirmation(redacted)',
    );
  });

  test('cancelled and foreign confirmations are rejected', () async {
    final controller = CloudSyncHistoricalImportController();
    final snap = snapshot();
    final confirmation = await prepareFor(controller, snap);
    controller.cancel(confirmation);
    expect(controller.phase, CloudSyncHistoricalImportPhase.idle);
    await expectLater(controller.confirm(confirmation), expired());
    final other = CloudSyncHistoricalImportController();
    final foreign = await prepareFor(other, snap);
    await expectLater(controller.confirm(foreign), expired());
    expect(archive.calls, 0);
  });

  test(
    'duplicate prepare and confirm during a pending action reject',
    () async {
      final controller = CloudSyncHistoricalImportController();
      final snap = snapshot();
      final confirmation = await prepareFor(controller, snap);
      final pending = controller.confirm(confirmation);
      await expectLater(controller.prepare(() async => planFor(snap)), busy());
      await expectLater(controller.confirm(confirmation), busy());
      await pending;
      expect(controller.scanComplete, isTrue);
    },
  );

  test('exact consent is consumed once', () async {
    final controller = CloudSyncHistoricalImportController();
    final confirmation = await prepareFor(controller, snapshot());
    await controller.confirm(confirmation);
    expect(controller.confirmedCreates, 3);
    await expectLater(controller.confirm(confirmation), expired());
    expect(archive.calls, 3);
  });

  test('identity loss after preview prevents any archive', () async {
    final controller = CloudSyncHistoricalImportController();
    final confirmation = await prepareFor(controller, snapshot());
    live = false;
    await expectLater(
      controller.confirm(confirmation),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_import_identity_changed',
        ),
      ),
    );
    expect(archive.calls, 0);
    expect(controller.confirmedCreates, 0);
    expect(
      controller.failureCode,
      'cloud_sync_historical_import_identity_changed',
    );
    expect(controller.phase, CloudSyncHistoricalImportPhase.needsAttention);
  });

  test(
    'pause during in-flight archive finishes the row and admits nothing more',
    () async {
      final controller = CloudSyncHistoricalImportController();
      archive.beforeReturn = (guid) async {
        if (archive.calls == 1) controller.pause();
      };
      final confirmation = await prepareFor(controller, snapshot());
      await controller.confirm(confirmation);
      expect(archive.calls, 1);
      expect(controller.handled, 1);
      expect(controller.confirmedCreates, 1);
      expect(controller.phase, CloudSyncHistoricalImportPhase.paused);
      expect(controller.scanComplete, isFalse);
    },
  );

  test('pause during validation prevents any new archive', () async {
    final controller = CloudSyncHistoricalImportController();
    final confirmation = await prepareFor(controller, snapshot());
    var pauseOnNextValidate = true;
    validateIdentity = () async {
      if (pauseOnNextValidate) {
        pauseOnNextValidate = false;
        controller.pause();
      }
    };
    await controller.confirm(confirmation);
    expect(archive.calls, 0);
    expect(controller.handled, 0);
    expect(controller.phase, CloudSyncHistoricalImportPhase.paused);
  });

  test('partial page resumes idempotently on a fresh controller', () async {
    final snap = snapshot();
    final first = CloudSyncHistoricalImportController();
    archive.beforeReturn = (guid) async {
      if (archive.calls == 1) first.pause();
    };
    await first.confirm(await prepareFor(first, snap));
    expect(first.handled, 1);
    final second = CloudSyncHistoricalImportController();
    archive.beforeReturn = null;
    await second.confirm(await prepareFor(second, snap));
    expect(second.scanComplete, isTrue);
    expect(second.confirmedCreates, 3);
    expect(archive.calls, 4);
    expect(archive.callsByGuid.length, 3);
  });

  test('scan continues across the 20-row page boundary', () async {
    final controller = CloudSyncHistoricalImportController();
    final confirmation = await prepareFor(controller, snapshot(25));
    await controller.confirm(confirmation);
    expect(controller.handled, 25);
    expect(controller.confirmedCreates, 25);
    expect(controller.scanComplete, isTrue);
    expect(controller.phase, CloudSyncHistoricalImportPhase.scanComplete);
  });

  test(
    'reader handoffs are counted separately from confirmed creates',
    () async {
      final controller = CloudSyncHistoricalImportController();
      var n = 0;
      archive.dispositionFor = (guid) {
        n++;
        return n.isEven
            ? CloudSyncHistoricalArchiveDisposition.retainedByReader
            : CloudSyncHistoricalArchiveDisposition.confirmedCreate;
      };
      await controller.confirm(await prepareFor(controller, snapshot(5)));
      expect(controller.handled, 5);
      expect(controller.confirmedCreates, 3);
      expect(controller.readerHandoffs, 2);
      expect(controller.scanComplete, isTrue);
    },
  );

  test(
    'metadata deferral does not count as upload or block later rows',
    () async {
      final controller = CloudSyncHistoricalImportController();
      archive.dispositionFor = (guid) => guid == _uuid(1)
          ? CloudSyncHistoricalArchiveDisposition.retainedMissingMetadata
          : CloudSyncHistoricalArchiveDisposition.confirmedCreate;
      await controller.confirm(await prepareFor(controller, snapshot()));
      expect(archive.calls, 3);
      expect(controller.handled, 3);
      expect(controller.deferredMissingMetadata, 1);
      expect(controller.confirmedCreates, 2);
      expect(controller.readerHandoffs, 0);
      expect(controller.scanComplete, isTrue);
    },
  );

  test('all-ineligible complete scan has zero confirmed uploads', () async {
    final controller = CloudSyncHistoricalImportController();
    final snap = _snapshot([
      for (var i = 1; i <= 4; i++) _row(i, attachments: true),
    ]);
    await controller.confirm(await prepareFor(controller, snap));
    expect(controller.scanComplete, isTrue);
    expect(controller.phase, CloudSyncHistoricalImportPhase.scanComplete);
    expect(controller.handled, 0);
    expect(controller.confirmedCreates, 0);
    expect(controller.readerHandoffs, 0);
    expect(
      controller.ineligibleByReason[CloudSyncHistoricalArchiveReasons.media],
      4,
    );
  });

  test('prior done cursor claims no new confirmations', () async {
    final controller = CloudSyncHistoricalImportController();
    final snap = snapshot();
    await cursors.save(
      HistoricalProducerCursor(scope: snap.scope, lastId: null, done: true),
    );
    await controller.confirm(await prepareFor(controller, snap));
    expect(archive.calls, 0);
    expect(controller.confirmedCreates, 0);
    expect(controller.scanComplete, isTrue);
  });

  test('raw archive errors become fixed safe failures', () async {
    final controller = CloudSyncHistoricalImportController();
    archive.throwFor = (guid) => true;
    await expectLater(
      controller.confirm(await prepareFor(controller, snapshot())),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_import_failed',
        ),
      ),
    );
    expect(controller.failureCode, 'cloud_sync_historical_import_failed');
    expect(controller.phase, CloudSyncHistoricalImportPhase.needsAttention);
    expect(controller.failureCode!.contains('secret'), isFalse);
  });

  test('disposal waits for drain', () async {
    final controller = CloudSyncHistoricalImportController();
    final confirmation = await prepareFor(controller, snapshot(2));
    // Hold the first archive open so drain arrives mid-flight: the row
    // must finish, the next row must never be admitted, and disposal
    // must wait for the drain.
    final gate = Completer<void>();
    final started = Completer<void>();
    archive.beforeReturn = (guid) async {
      if (archive.calls == 1) {
        started.complete();
        await gate.future;
      }
    };
    final pending = controller.confirm(confirmation);
    await started.future;
    expect(archive.calls, 1);
    expect(() => controller.dispose(), throwsStateError);
    gate.complete();
    await controller.drain();
    await pending;
    expect(controller.handled, 1);
    expect(controller.phase, CloudSyncHistoricalImportPhase.paused);
    controller.dispose();
  });

  test(
    'invalid returned source cannot publish a confirmation or cursor',
    () async {
      final controller = CloudSyncHistoricalImportController();
      archive.transformSource = (source) => StagedHistoricalSource(
        key: source.key,
        sha256: 'f' * 64,
        byteLength: source.byteLength,
        guid: source.guid,
      );
      await expectLater(
        controller.confirm(await prepareFor(controller, snapshot())),
        throwsStateError,
      );
      expect(controller.confirmedCreates, 0);
      expect(controller.handled, 0);
      expect(await cursors.load(), isNull);
      expect(controller.scanComplete, isFalse);
    },
  );

  test(
    'account change during archive suppresses stale success and drains',
    () async {
      final controller = CloudSyncHistoricalImportController();
      archive.beforeReturn = (_) async {
        live = false;
      };
      final confirmation = await prepareFor(controller, snapshot());
      await expectLater(controller.confirm(confirmation), throwsStateError);
      await controller.drain();
      expect(controller.active, isFalse);
      expect(controller.confirmedCreates, 0);
      expect(await cursors.load(), isNull);
      controller.dispose();
    },
  );

  test(
    'explicit invalidation revokes preview even if identity returns',
    () async {
      final controller = CloudSyncHistoricalImportController();
      final confirmation = await prepareFor(controller, snapshot());
      controller.invalidate();
      await expectLater(controller.confirm(confirmation), expired());
      expect(archive.calls, 0);
    },
  );

  test('new preparation expires the previous exact confirmation', () async {
    final controller = CloudSyncHistoricalImportController();
    final snap = snapshot();
    final old = await prepareFor(controller, snap);
    final replacement = await prepareFor(controller, snap);
    await expectLater(controller.confirm(old), expired());
    expect(archive.calls, 0);
    await controller.confirm(replacement);
    expect(archive.calls, 3);
  });
}
