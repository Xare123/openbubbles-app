import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/legacy_cloudkit_deletion_intents.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory directory;
  late Store objectBox;
  late LegacyCloudKitDeletionIntentStore deletionStore;
  late ObjectBoxCloudKitWriterAuthority authority;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-legacy-cloudkit-deletion-',
    );
    objectBox = await openStore(directory: directory.path);
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: objectBox,
      buildDecision: const CloudKitWriterOwnershipDecision(
        owner: CloudKitWriterOwner.legacy,
        configurationValid: true,
      ),
    );
    deletionStore = LegacyCloudKitDeletionIntentStore(
      store: objectBox,
      authority: authority,
    );
  });

  tearDown(() async {
    if (!objectBox.isClosed()) objectBox.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  CloudKitWriterAuthoritySnapshot provision(CloudKitWriterScope scope) {
    final initial = ObjectBoxCloudKitWriterAuthority.forTest(
      store: objectBox,
      buildDecision: const CloudKitWriterOwnershipDecision(
        owner: CloudKitWriterOwner.none,
        configurationValid: true,
      ),
    ).initializeDisabled(scope, now: _time(0));
    return authority.provisionInitialOwner(
      scope,
      owner: CloudKitWriterOwner.legacy,
      expectedEpoch: initial.epoch,
      evidence: const CloudKitWriterTransitionEvidence.forTest(
        operationsQuiesced: true,
        activeIdentityRevalidated: true,
        legacyMutationQueues: LegacyMutationQueueDisposition.empty,
      ),
      now: _time(1),
    );
  }

  test('an intent admitted under account A cannot flush under account B', () {
    final scopeA = _scope('A');
    final scopeB = _scope('B');
    final authorityA = provision(scopeA);
    provision(scopeB);

    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(
        scope: scopeA,
        writerEpoch: authorityA.epoch,
      ),
      kind: LegacyCloudKitDeletionKind.message,
      recordId: 'message-a',
      now: _time(2),
    );

    expect(
      deletionStore.pendingForFlush(
        scope: scopeB,
        writerEpoch: 2,
        kind: LegacyCloudKitDeletionKind.message,
      ),
      isEmpty,
    );
    expect(
      deletionStore
          .pendingForFlush(
            scope: scopeA,
            writerEpoch: authorityA.epoch,
            kind: LegacyCloudKitDeletionKind.message,
          )
          .map((intent) => intent.recordId),
      ['message-a'],
    );
  });

  test('a stale writer epoch cannot flush and is quarantined', () {
    final scope = _scope('A');
    final current = provision(scope);

    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(
        scope: scope,
        writerEpoch: current.epoch - 1,
      ),
      kind: LegacyCloudKitDeletionKind.attachment,
      recordId: 'attachment-stale',
      now: _time(2),
    );

    expect(
      deletionStore.pendingForFlush(
        scope: scope,
        writerEpoch: current.epoch,
        kind: LegacyCloudKitDeletionKind.attachment,
      ),
      isEmpty,
    );
    final row = objectBox.box<CloudKitDeletionIntentEntity>().getAll().single;
    expect(row.state, 1);
    expect(row.quarantineReason, 'writer_epoch_stale');
  });

  test('a caller holding an old epoch cannot select a current intent', () {
    final scope = _scope('A');
    final current = provision(scope);
    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(
        scope: scope,
        writerEpoch: current.epoch,
      ),
      kind: LegacyCloudKitDeletionKind.chat,
      recordId: 'chat-current',
      now: _time(2),
    );

    expect(
      deletionStore.pendingForFlush(
        scope: scope,
        writerEpoch: current.epoch - 1,
        kind: LegacyCloudKitDeletionKind.chat,
      ),
      isEmpty,
    );
    expect(
      deletionStore
          .pendingForFlush(
            scope: scope,
            writerEpoch: current.epoch,
            kind: LegacyCloudKitDeletionKind.chat,
          )
          .single
          .recordId,
      'chat-current',
    );
  });

  test(
    'legacy preference values are durably quarantined and never pending',
    () async {
      SharedPreferences.setMockInitialValues({
        LegacyCloudKitDeletionIntentStore.legacyMessageKey: ['message-old'],
        LegacyCloudKitDeletionIntentStore.legacyAttachmentKey: [
          'attachment-old',
        ],
        LegacyCloudKitDeletionIntentStore.legacyChatKey: ['chat-old'],
      });
      final prefs = await SharedPreferences.getInstance();

      final inserted = await deletionStore
          .quarantineLegacySharedPreferenceQueues(prefs, now: _time(2));

      expect(inserted, 3);
      expect(deletionStore.pendingCount, 0);
      expect(deletionStore.quarantineEvidenceCount, 3);
      expect(
        prefs.get(LegacyCloudKitDeletionIntentStore.legacyMessageKey),
        isNull,
      );
      expect(
        prefs.get(LegacyCloudKitDeletionIntentStore.legacyAttachmentKey),
        isNull,
      );
      expect(
        prefs.get(LegacyCloudKitDeletionIntentStore.legacyChatKey),
        isNull,
      );
    },
  );

  test(
    'legacy preference inventory counts entries and malformed values',
    () async {
      SharedPreferences.setMockInitialValues({
        LegacyCloudKitDeletionIntentStore.legacyMessageKey: [
          'message-a',
          'message-b',
        ],
        LegacyCloudKitDeletionIntentStore.legacyAttachmentKey: 'malformed',
      });
      final prefs = await SharedPreferences.getInstance();

      expect(deletionStore.legacySharedPreferenceQueueEntryCount(prefs), 3);
    },
  );

  test('pending count matches the full scope across writer epochs', () {
    final scope = _scope('A');
    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(scope: scope, writerEpoch: 1),
      kind: LegacyCloudKitDeletionKind.message,
      recordId: 'message-epoch-1',
      now: _time(2),
    );
    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(scope: scope, writerEpoch: 99),
      kind: LegacyCloudKitDeletionKind.attachment,
      recordId: 'attachment-epoch-99',
      now: _time(3),
    );

    expect(deletionStore.pendingCountForScope(scope), 2);
  });

  test('pending count excludes another account and container', () {
    final scope = _scope('A');
    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(scope: scope, writerEpoch: 1),
      kind: LegacyCloudKitDeletionKind.message,
      recordId: 'message-matching',
      now: _time(2),
    );
    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(
        scope: _scope('B'),
        writerEpoch: 1,
      ),
      kind: LegacyCloudKitDeletionKind.message,
      recordId: 'message-other-account',
      now: _time(3),
    );
    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(
        scope: _scope('A', container: 'com.example.other'),
        writerEpoch: 1,
      ),
      kind: LegacyCloudKitDeletionKind.message,
      recordId: 'message-other-container',
      now: _time(4),
    );

    expect(deletionStore.pendingCountForScope(scope), 1);
  });

  test('pending count excludes quarantined rows in the same scope', () {
    final scope = _scope('A');
    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(scope: scope, writerEpoch: 1),
      kind: LegacyCloudKitDeletionKind.message,
      recordId: 'message-quarantined',
      now: _time(2),
    );
    deletionStore.enqueue(
      context: LegacyCloudKitDeletionContext(scope: scope, writerEpoch: 2),
      kind: LegacyCloudKitDeletionKind.message,
      recordId: 'message-pending',
      now: _time(3),
    );

    expect(
      deletionStore.quarantineStale(
        scope: scope,
        currentWriterEpoch: 2,
        now: _time(4),
      ),
      1,
    );
    expect(deletionStore.pendingCountForScope(scope), 1);
  });

  test('pending count is zero when the scope has no pending rows', () {
    expect(deletionStore.pendingCountForScope(_scope('A')), 0);
  });
}

CloudKitWriterScope _scope(
  String suffix, {
  String container = 'com.apple.messages.cloud',
}) => CloudKitWriterScope(
  accountFingerprint: suffix == 'A'
      ? 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      : 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
  container: container,
);

DateTime _time(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
