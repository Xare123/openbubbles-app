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
      evidence: const CloudKitWriterTransitionEvidence(
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
}

CloudKitWriterScope _scope(String suffix) => CloudKitWriterScope(
  accountFingerprint: suffix == 'A'
      ? 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      : 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
);

DateTime _time(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
