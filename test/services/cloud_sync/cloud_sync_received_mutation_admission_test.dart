import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_parent_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_update_executor.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_update_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_mutation_lineage.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_message_dependency.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_message_update_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_archive_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';

const _owner = 'mailto:owner@example.invalid';
const _remote = 'mailto:remote@example.invalid';
const _target = '99999999-8888-4777-8666-555555555555';
const _event = '11111111-2222-4333-8444-555555555555';
const _otherEvent = '11111111-2222-4333-8444-666666666666';
const _localEvent = '77777777-2222-4333-8444-666666666666';
const _live = CloudSyncReceivedArchiveLiveContext(
  observedViaLiveReceive: true,
  observedLocalHandles: [_owner],
  receivedOnHandle: _owner,
);
final _scope = CloudSyncScope(
  accountFingerprint: 'A' * 43,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: cloudSyncSchemaVersion,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
// Opaque synthetic native-shaped values, not native keyed hashes/Apple proof.
final _logical = 'L' * 43;
final _record = 'R' * 43;
final _etag = 'E' * 43;
final _now = DateTime.utc(2026, 10, 21);
final _rejected = throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>()));
final _updateLease = 'obcs2.lease.${'c' * 32}';
final _readbackLease = 'obcs2.lease.${'e' * 32}';
final _readbackReference = 'obcs2.ref.${'V' * 43}';
final _readbackEtag = 'T' * 43;

api.MessageInst _wire({
  bool mirrored = false,
  bool unsend = false,
  String event = _event,
  int timestamp = 1700000010000,
  String text = 'Edited',
}) => api.MessageInst(
  id: event,
  sender: mirrored ? _owner : _remote,
  receivedOnHandle: _owner,
  conversation: api.ConversationData(
    participants: [_owner, _remote],
    senderGuid: 'direct-opaque',
  ),
  message: unsend
      ? const api.Message.unsend(api.UnsendMessage(tuuid: _target, editPart: 0))
      : api.Message.edit(
          api.EditMessage(
            tuuid: _target,
            editPart: 0,
            newParts: api.MessageParts(
              field0: [
                api.IndexedMessagePart(
                  part_: api.MessagePart.text(
                    text,
                    const api.TextFormat.flags(
                      api.TextFlags(
                        bold: false,
                        italic: false,
                        underline: false,
                        strikethrough: false,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
  sentTimestamp: timestamp,
  sendDelivered: false,
  verificationFailed: false,
);

void main() {
  for (final mirrored in [false, true]) {
    for (final unsend in [false, true]) {
      test(
        'exact update adoption mirrored=$mirrored unsend=$unsend has no IDS receipt',
        () async {
          final f = await _Fixture.create(mirrored: mirrored, unsend: unsend);
          addTearDown(f.close);
          final source = f.admission;
          expect(source.writerEpoch, f.owner.epoch);
          expect(source.ownershipEpoch, f.row.ownershipEpoch);
          expect(source.protectedStoreIdentity, f.auth.protectedStoreIdentity);
          expect(
            source.origin,
            mirrored
                ? CloudSyncReceivedArchiveOrigin.mirrored
                : CloudSyncReceivedArchiveOrigin.incoming,
          );
          expect(source.kind, unsend ? 1 : 0);
          expect(source.matchesReflectedParent(f.target), isTrue);
          expect(
            source.toString(),
            'CloudSyncReceivedMutationAdmissionSource(redacted)',
          );
          expect(
            source
                .requirePredecessor(store: f.db, messageScope: _scope)
                .recordMapping
                .serverRecordIdHash,
            _record,
          );
          expect(f.journal.isBoundToStore(f.db), isTrue);
          final operation = f.adopt(captured: source);
          expect(f.row.state, 2);
          expect(f.row.ownershipEpoch, source.ownershipEpoch);
          expect(f.row.protectedSourceBinding, f.seed.encode());
          expect(
            f.journal.hasAdoptedOperationId(operation.operationId),
            isTrue,
          );
          expect(
            f.db.runInTransaction(
              TxMode.read,
              () => f.journal.adoptedOperationIdInOutboxTransaction(
                f.db,
                source,
                currentAuth: f.auth,
                stillCurrent: () => true,
              ),
            ),
            operation.operationId,
          );
          f.journal.validateAdoptedOperation(f.db, operation, f.mapping);
          expect(f.db.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
          expect(f.db.box<CloudSyncLocalSendIntentEntity>().count(), 0);
          expect(f.db.box<CloudOutboxOperationEntity>().count(), 1);
          expect(
            f.journal.readPending(
              currentAuth: f.auth,
              onlyPendingReflection: true,
            ),
            isEmpty,
          );
        },
      );
    }
  }

  group('received admission fences', () {
    late _Fixture f;
    setUp(() async => f = await _Fixture.create());
    tearDown(() async => f.close());

    test(
      'pre-release received-domain snapshots hold without rewriting their hashes or seed',
      () {
        final target = f.target
          ..attributedBody = [AttributedBody.raw('Edited')]
          ..messageSummaryInfo = [
            MessageSummaryInfo(
              retractedParts: [],
              editedContent: {},
              originalTextRange: {
                '9': [1, 2],
                '0': [0, 1],
              },
              editedParts: [],
            ),
          ];
        f.db.box<Message>().put(target);
        // Old received-only domain and insertion order are not converted to a
        // shared snapshot by guessing before-images from the current Message.
        final legacyBytes = utf8.encode(
          jsonEncode([
            'cloud-sync-received-mutation-target-v1',
            f.messageId,
            _target,
            f.chatId,
            false,
            9001,
            null,
            1700000000000,
            1700000010000,
            null,
            'Edited',
            null,
            false,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            false,
            [
              {
                'string': 'Edited',
                'runs': [
                  {
                    'range': [0, 6],
                    'attributes': {'__kIMMessagePartAttributeName': 0},
                  },
                ],
              },
            ],
            [
              {
                'retractedParts': [],
                'editedContent': {},
                'originalTextRange': {
                  '9': [1, 2],
                  '0': [0, 1],
                },
                'editedParts': [],
              },
            ],
          ]),
        );
        final legacySnapshot = sha256.convert(legacyBytes).toString();
        expect(
          CloudSyncReceivedMutationJournal.snapshot(f.target),
          isNot(legacySnapshot),
        );
        expect(
          CloudSyncReceivedMutationJournal.intentKey(
            f.auth.accountFingerprint,
            f.seed.mutationGuidHash,
          ),
          sha256
              .convert(
                utf8.encode(
                  jsonEncode([
                    'cloud-sync-received-mutation-intent-v1',
                    f.auth.accountFingerprint,
                    f.seed.mutationGuidHash,
                  ]),
                ),
              )
              .toString(),
        );
        f.db.box<CloudSyncReceivedMutationIntentEntity>().put(
          f.row..reflectedSnapshotSha256 = legacySnapshot,
        );
        expect(() => f.admission, _rejected);
        expect(() => f.adopt(), _rejected);
        expect(f.row.state, 1);
        expect(f.row.reflectedSnapshotSha256, legacySnapshot);
        expect(f.row.protectedSourceBinding, f.seed.encode());
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    test(
      'parent correlation cannot use a callback to bypass snapshot drift',
      () {
        final source = f.admission;
        expect(source.matchesReflectedParent(f.target), isTrue);
        for (final change in <void Function(Message)>[
          (m) => m.id = f.messageId + 1,
          (m) => m.chat.targetId = f.chatId + 1,
          (m) => m.guid = _otherEvent,
          (m) => m.guid = null,
          (m) => m.isFromMe = true,
          (m) => m.text = 'Newer local data',
        ]) {
          final changed = f.target;
          change(changed);
          expect(source.matchesReflectedParent(changed), isFalse);
        }
        f.db.box<Message>().put(f.target..text = 'Newer local data');
        var calls = 0;
        expect(
          () => source.requirePredecessor(
            store: f.db,
            messageScope: _scope,
            readConfirmedLocalParent: (_) {
              calls++;
              return null;
            },
          ),
          _rejected,
        );
        expect(calls, 0);
        expect(f.row.state, 1);
      },
    );

    test(
      'duplicate exact retry and restart recover the same immutable operation',
      () async {
        final captured = f.admission;
        final op = f.adopt(captured: captured);
        final binding = f.row.admittedBindingSha256;
        final updated = f.row.updatedAtMs;
        f.adopt(operation: op, captured: captured);
        expect(f.row.updatedAtMs, updated);
        expect(f.row.admittedBindingSha256, binding);
        await f.reopen();
        final recovered = f.journal.readAdoptedForUpdate(
          operationId: op.operationId,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        expect(recovered.sameReflectedMutationAs(captured), isTrue);
        expect(recovered.adoptedOperationId, op.operationId);
        f.adopt(operation: op, captured: recovered);
        f.journal.validateAdoptedOperation(f.db, op, f.mapping);
        expect(f.row.admittedBindingSha256, binding);
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 1);
        expect(f.row.protectedSourceBinding, f.seed.encode());
      },
    );

    test('changed operation metadata or payload cannot reuse an adoption', () {
      final op = f.adopt();
      final binding = f.row.admittedBindingSha256;
      for (final changed in [
        op.copyWith(encryptedPayloadReference: 'obcs2.ref.${'N' * 43}'),
        op.copyWith(payloadSha256: 'd' * 64),
        op.copyWith(protectedLeaseReference: 'obcs2.lease.${'d' * 32}'),
        f.operation(revision: 2),
        f.operation(version: 1),
      ]) {
        expect(() => f.adopt(operation: changed), _rejected);
        expect(
          () => f.journal.validateAdoptedOperation(f.db, changed, f.mapping),
          _rejected,
        );
        expect(f.row.admittedBindingSha256, binding);
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 1);
      }
    });

    test('ciphertext is immutable before and after operation adoption', () {
      final captured = f.admission;
      final original = f.row;
      final changedSeed = CloudSyncReceivedMutationSourceBinding(
        accountFingerprint: f.seed.accountFingerprint,
        protectedStoreIdentity: f.seed.protectedStoreIdentity,
        mutationGuidHash: f.seed.mutationGuidHash,
        sourceSha256: f.seed.sourceSha256,
        ciphertext: 'obcs2.test.different',
      );
      f.db.box<CloudSyncReceivedMutationIntentEntity>().put(
        f.row..protectedSourceBinding = changedSeed.encode(),
      );
      expect(() => f.adopt(captured: captured), _rejected);
      expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
      f.db.box<CloudSyncReceivedMutationIntentEntity>().put(original);
      final op = f.adopt();
      f.db.box<CloudSyncReceivedMutationIntentEntity>().put(
        f.row..protectedSourceBinding = changedSeed.encode(),
      );
      expect(
        () => f.journal.validateAdoptedOperation(f.db, op, f.mapping),
        _rejected,
      );
      expect(f.row.state, 2);
      expect(
        f.row.protectedSourceBinding,
        changedSeed.encode(),
        reason: 'rejection never overwrites retained evidence',
      );
    });

    test('changed native account or protected store rolls back admission', () {
      final source = f.admission;
      final operation = f.operation();
      for (final accountChanged in [false, true]) {
        final foreign = CloudSyncNativeAuthSnapshot.fromNative(
          nativeSessionId: 'synthetic-other-session',
          accountFingerprint: accountChanged
              ? 'B' * 43
              : f.auth.accountFingerprint,
          protectedStoreIdentity: accountChanged
              ? f.auth.protectedStoreIdentity
              : 'obcs2.store.${'T' * 43}',
          cloudMessagesClient: Object(),
        );
        expect(
          () => f.journal.readReflectedForUpdate(
            intentId: f.intentId,
            currentAuth: foreign,
            stillCurrent: () => true,
          ),
          _rejected,
        );
        expect(
          () => f.db.runInTransaction(TxMode.write, () {
            f.writeOperation(operation);
            f.journal.adoptInOutboxTransaction(
              f.db,
              source,
              operation,
              f.mapping,
              currentAuth: foreign,
              stillCurrent: () => true,
              now: _now,
            );
          }),
          _rejected,
        );
        expect(f.row.state, 1);
        expect(f.row.protectedSourceBinding, f.seed.encode());
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
      }
    });

    test('adoption stays pinned when both map views change together', () {
      final operation = f.adopt();
      final binding = f.row.admittedBindingSha256;
      final changed = f.mapping..etagHash = 'N' * 43;
      f.db.box<CloudRecordMapEntity>().put(changed);
      expect(
        () => f.adopt(operation: operation, predecessor: changed),
        _rejected,
      );
      expect(
        () => f.journal.validateAdoptedOperation(f.db, operation, changed),
        _rejected,
      );
      expect(f.row.state, 2);
      expect(f.row.admittedBindingSha256, binding);
      expect(f.row.protectedSourceBinding, f.seed.encode());
      expect(f.db.box<CloudOutboxOperationEntity>().count(), 1);
    });

    test('missing persisted outbox cannot produce an adopted marker', () {
      final source = f.admission;
      expect(
        () => f.db.runInTransaction(
          TxMode.write,
          () => f.journal.adoptInOutboxTransaction(
            f.db,
            source,
            f.operation(),
            f.mapping,
            currentAuth: f.auth,
            stillCurrent: () => true,
            now: _now,
          ),
        ),
        _rejected,
      );
      expect(f.row.state, 1);
      expect(f.row.admittedOperationId, isNull);
    });

    test(
      'outer transaction and post-adoption auth failure roll back both rows',
      () {
        expect(
          () => f.adopt(
            afterAdopt: () => throw StateError('synthetic-outer-rollback'),
          ),
          _rejected,
        );
        expect(f.row.state, 1);
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
        var checks = 0;
        expect(() => f.adopt(stillCurrent: () => ++checks < 2), _rejected);
        expect(checks, 2);
        expect(f.row.state, 1);
        expect(f.row.admittedBindingSha256, isNull);
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
        expect(f.row.protectedSourceBinding, f.seed.encode());
      },
    );

    test(
      'writer epoch is current while row keeps the automatic ownership epoch',
      () {
        final captured = f.admission;
        final ownership = f.row.ownershipEpoch;
        final permit = f.authority.issuePermit(
          f.writerScope,
          expectedOwner: CloudKitWriterOwner.v2,
        );
        f.authority.markMutationUnknown(permit, now: _now);
        expect(() => f.adopt(captured: captured), _rejected);
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
        f.bind();
        final current = f.admission;
        expect(current.writerEpoch, f.owner.epoch);
        expect(current.writerEpoch, greaterThan(ownership));
        expect(current.ownershipEpoch, ownership);
        expect(
          () => f.adopt(captured: current),
          _rejected,
          reason: 'unknown is not fresh admission authority',
        );
        expect(f.row.state, 1);
      },
    );

    test(
      'exact Store and source Store identities cannot be substituted',
      () async {
        final other = await _Fixture.create();
        addTearDown(other.close);
        expect(f.journal.isBoundToStore(other.db), isFalse);
        expect(
          () => f.journal.adoptInOutboxTransaction(
            other.db,
            f.admission,
            f.operation(),
            f.mapping,
            currentAuth: f.auth,
            stillCurrent: () => true,
            now: _now,
          ),
          _rejected,
        );
        expect(() => f.adopt(captured: other.admission), _rejected);
        expect(
          () => f.admission.requirePredecessor(
            store: other.db,
            messageScope: _scope,
          ),
          _rejected,
        );
        expect(f.row.state, 1);
        expect(other.row.state, 1);
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
        expect(other.db.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    final targetChanges = <String, void Function(Message)>{
      'body': (m) => m.text = 'Newer local data',
      'direction': (m) => m.isFromMe = true,
      'author': (m) => m.handleId = 9002,
      'chat': (m) => m.chat.targetId = 12345,
      'deletion': (m) => m.dateDeleted = _now,
    };
    for (final change in targetChanges.entries) {
      test('target ${change.key} drift rolls back admission', () {
        final source = f.admission;
        final target = f.target;
        change.value(target);
        f.db.box<Message>().put(target);
        expect(() => f.adopt(captured: source), _rejected);
        expect(f.row.state, 1);
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
      });
    }
    final mapChanges = <String, void Function(CloudRecordMapEntity)>{
      'ETag': (m) => m.etagHash = 'N' * 43,
      'raw reference': (m) => m.encryptedRawRecordRef = 'obcs2.ref.${'N' * 43}',
      'raw generation': (m) => m.rawRecordGeneration = 2,
      'account': (m) => m.accountFingerprint = 'B' * 43,
    };
    for (final change in mapChanges.entries) {
      test('predecessor ${change.key} drift rolls back admission', () {
        final source = f.admission;
        final previous = f.mapping;
        final changed = f.mapping;
        change.value(changed);
        f.db.box<CloudRecordMapEntity>().put(changed);
        expect(
          () => f.adopt(captured: source, predecessor: previous),
          _rejected,
        );
        expect(f.row.state, 1);
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
      });
    }

    test('generation and latest pending inbox remain mandatory', () {
      final captured = f.admission;
      final checkpoints = f.db.box<CloudSyncCheckpointEntity>();
      final checkpoint = checkpoints.getAll().single;
      checkpoints.put(checkpoint..generation = 2);
      expect(() => f.adopt(captured: captured), _rejected);
      checkpoints.put(checkpoint..generation = 1);
      final inbox = f.db.box<CloudInboxChangeEntity>();
      inbox.put(inbox.getAll().single..status = CloudInboxStatus.pending.index);
      expect(() => f.adopt(captured: captured), _rejected);
      expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
      expect(f.row.state, 1);
    });

    test(
      'confirmation requires exact persisted readback, not save success or IDS',
      () async {
        final operation = f.adopt();
        final confirmed = f.confirmed(operation);
        expect(() => f.confirm(confirmed), _rejected);
        final saveOnly = operation.copyWith(
          status: CloudOutboxStatus.confirmed,
          confirmedAt: _now,
        );
        f.writeOperation(saveOnly);
        expect(
          () => f.confirm(saveOnly),
          _rejected,
          reason: 'native update lease is still live',
        );
        f.writeOperation(confirmed);
        for (final changed in [
          confirmed.copyWith(attemptCount: 99),
          confirmed.copyWith(confirmedAt: _now.add(const Duration(seconds: 1))),
          confirmed.copyWith(
            encryptedPayloadReference: 'obcs2.ref.${'N' * 43}',
          ),
        ]) {
          expect(() => f.confirm(changed), _rejected);
          expect(f.row.state, 2);
        }
        expect(f.confirm(confirmed).encode(), f.seed.encode());
        final time = f.row.updatedAtMs;
        expect(f.row.state, 3);
        expect(f.journal.hasAdoptedOperationId(operation.operationId), isTrue);
        expect(() => f.admission, _rejected);
        expect(
          () => f.journal.readAdoptedForUpdate(
            operationId: operation.operationId,
            currentAuth: f.auth,
            stillCurrent: () => true,
          ),
          _rejected,
        );
        await f.reopen();
        expect(f.confirm(confirmed).encode(), f.seed.encode());
        expect(f.row.updatedAtMs, time);
        expect(
          f.journal.readPending(
            currentAuth: f.auth,
            onlyPendingReflection: true,
          ),
          isEmpty,
        );
        expect(f.db.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
        expect(f.db.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      },
    );

    test(
      'outer exact-readback transaction rolls back terminal marker and receipt together',
      () {
        final operation = f.adopt();
        expect(
          () => f.db.runInTransaction<void>(TxMode.write, () {
            f.writeOperation(f.confirmed(operation));
            f.confirm(f.confirmed(operation));
            throw StateError('synthetic-terminal-rollback');
          }),
          _rejected,
        );
        expect(f.row.state, 2);
        expect(
          f.db.box<CloudOutboxOperationEntity>().getAll().single.state,
          CloudOutboxStatus.pending.index,
        );
        expect(f.row.protectedSourceBinding, f.seed.encode());
      },
    );

    test(
      'row states require snapshot and adoption fields iff their stage permits them',
      () {
        final rows = f.db.box<CloudSyncReceivedMutationIntentEntity>();
        final original = f.row;
        final changes = <void Function(CloudSyncReceivedMutationIntentEntity)>[
          (r) => r.state = 0,
          (r) => r.reflectedSnapshotSha256 = null,
          (r) => r.beforeSnapshotSha256 = null,
          (r) => r.admittedOperationId = 'op1:${'a' * 64}',
          (r) => r.state = 2,
          (r) {
            r.state = 3;
            r.admittedOperationId = 'not-operation';
            r.admittedBindingSha256 = 'b' * 64;
          },
          (r) => r.state = 4,
          (r) => r.admittedWriterEpoch = f.owner.epoch,
        ];
        for (final change in changes) {
          final malformed = f.row;
          change(malformed);
          rows.put(malformed);
          expect(() => f.journal.readPending(currentAuth: f.auth), _rejected);
          rows.put(original);
        }
      },
    );

    test(
      'an earlier retained event blocks a later reflected source without losing either seed',
      () {
        final captured = f.admission;
        final earlier = _wire(event: _otherEvent, timestamp: 1700000009000);
        final earlierSeed = f.sourceFor(earlier);
        final id = f.retain(earlier, earlierSeed);
        expect(() => f.admission, _rejected);
        expect(() => f.adopt(captured: captured), _rejected);
        expect(f.row.state, 1);
        expect(
          f.db.box<CloudSyncReceivedMutationIntentEntity>().get(id)!.state,
          0,
        );
        expect(
          f.db
              .box<CloudSyncReceivedMutationIntentEntity>()
              .get(id)!
              .protectedSourceBinding,
          earlierSeed.encode(),
        );
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    for (final confirmed in [false, true]) {
      test(
        'late event remains protected after ${confirmed ? 'confirmation' : 'adoption'}',
        () {
          final operation = f.adopt();
          if (confirmed) {
            final terminal = f.confirmed(operation);
            f.writeOperation(terminal);
            f.confirm(terminal);
          }
          final late = _wire(event: _otherEvent, timestamp: 1700000009000);
          final id = f.retain(late, f.sourceFor(late));
          final before = f.target;
          expect(
            () => f.journal.commitReflection(
              intentId: id,
              wire: late,
              liveContext: _live,
              currentAuth: f.auth,
              stillCurrent: () => true,
              expectedBeforeSnapshot: CloudSyncReceivedMutationJournal.snapshot(
                before,
              ),
              reflected: f.target..text = 'Late overwrite',
              now: _now,
            ),
            _rejected,
          );
          expect(f.target.text, 'Edited');
          expect(
            f.db.box<CloudSyncReceivedMutationIntentEntity>().get(id)!.state,
            0,
          );
          expect(f.row.state, confirmed ? 3 : 2);
        },
      );
    }
  });

  group('shared forward lineage and adopted epoch', () {
    test(
      'pins a received descendant tip, preserves markers, and waits for exact readback',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final original = f.admission;
        final firstAfter = f.row.reflectedSnapshotSha256;
        final second = f.appendReceived();
        expect(original.matchesReflectedParent(f.target), isFalse);
        expect(() => f.adopt(captured: original), _rejected);
        final refreshed = f.admission;
        expect(refreshed.reflectedSnapshotSha256, firstAfter);
        expect(refreshed.matchesReflectedParent(f.target), isTrue);
        expect(refreshed.sameReflectedMutationAs(original), isFalse);
        expect(() => f.sourceAt(second), _rejected);
        expect(
          f.journal
              .readUpdateCandidates(currentAuth: f.auth, limit: 1)
              .single
              .id,
          f.intentId,
        );
        f.journal.markUpdateConsidered(
          intentId: f.intentId,
          currentAuth: f.auth,
          stillCurrent: () => true,
          now: _now,
        );
        expect(
          f.journal
              .readUpdateCandidates(currentAuth: f.auth, limit: 1)
              .single
              .id,
          second,
        );
        expect(
          () => f.journal.readUpdateCandidates(currentAuth: f.auth, limit: 21),
          _rejected,
        );
        expect(
          f.journal.hasPendingReadbackRetirement(currentAuth: f.auth),
          isFalse,
        );
        final operation = f.adopt(captured: refreshed);
        expect(f.row.admittedWriterEpoch, original.writerEpoch);
        final adopted = f.journal.readAdoptedForUpdate(
          operationId: operation.operationId,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        expect(adopted.adoptedOperationId, operation.operationId);
        expect(adopted.reflectedSnapshotSha256, firstAfter);
        expect(adopted.matchesReflectedParent(f.target), isTrue);
        expect(
          f.journal.hasPendingReadbackRetirement(currentAuth: f.auth),
          isTrue,
        );
        expect(() => f.sourceAt(second), _rejected);
        final terminal = f.confirmed(operation);
        f.writeOperation(terminal);
        f.confirm(terminal);
        expect(f.sourceAt(second).matchesReflectedParent(f.target), isTrue);
        expect(
          f.journal.hasPendingReadbackRetirement(currentAuth: f.auth),
          isFalse,
        );
        expect(f.row.reflectedSnapshotSha256, firstAfter);
      },
    );

    test(
      'mixed lanes with the same row ID require both exact-readback markers in order',
      () async {
        final f = await _Fixture.create(mirrored: true);
        addTearDown(f.close);
        final localId = f.appendLocal();
        expect(
          localId,
          f.intentId,
          reason: 'IDs are unique within a lane, not across lanes',
        );
        expect(
          f.lineage(received: true, intent: f.intentId),
          cloudSyncMutationTargetSnapshot(f.target),
        );
        expect(() => f.lineage(received: false, intent: localId), _rejected);
        final first = f.adopt();
        final firstTerminal = f.confirmed(first);
        f.writeOperation(firstTerminal);
        f.confirm(firstTerminal);
        expect(
          f.lineage(received: false, intent: localId),
          cloudSyncMutationTargetSnapshot(f.target),
        );
        final localJournal = f._emptyOutgoingJournal();
        final localSource = localJournal.readReflectedForUpdate(
          intentId: localId,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        final localOperation = f
            .operation(revision: 2)
            .copyWith(
              encryptedPayloadReference: 'obcs2.ref.${'Q' * 43}',
              protectedLeaseReference: 'obcs2.lease.${'d' * 32}',
            );
        f.db.runInTransaction(TxMode.write, () {
          f.writeOperation(localOperation);
          localJournal.adoptInOutboxTransaction(
            f.db,
            localSource,
            localOperation,
            f.mapping,
            currentAuth: f.auth,
            stillCurrent: () => true,
            now: _now,
          );
        });
        final last = f.appendReceived(
          timestamp: 1700000012000,
          text: 'Received after local',
        );
        expect(
          () => f.sourceAt(last),
          _rejected,
          reason: 'local IDS/reflection/adoption is not CloudKit readback',
        );
        final localTerminal = f.confirmed(localOperation);
        f.writeOperation(localTerminal);
        localJournal.markExactReadbackConfirmed(
          intentId: localId,
          operation: localTerminal,
          currentAuth: f.auth,
          stillCurrent: () => true,
          now: _now,
        );
        expect(f.sourceAt(last).matchesReflectedParent(f.target), isTrue);
        expect(
          f.db.box<CloudSyncLocalMutationIntentEntity>().get(localId)!.state,
          5,
        );
        expect(f.row.state, 3);
      },
    );

    test(
      'branches, cycles, unsend successors and detached unfinished history hold',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final secondId = f.appendReceived();
        final rows = f.db.box<CloudSyncReceivedMutationIntentEntity>();
        final first = f.row;
        final second = rows.get(secondId)!;
        final changes =
            <
              void Function(
                CloudSyncReceivedMutationIntentEntity,
                CloudSyncReceivedMutationIntentEntity,
              )
            >[
              (a, b) => b.beforeSnapshotSha256 = a.beforeSnapshotSha256,
              (a, b) => a.beforeSnapshotSha256 = b.reflectedSnapshotSha256,
              (a, b) => a.kind = 1,
              (a, b) {
                a.beforeSnapshotSha256 = 'a' * 64;
                a.reflectedSnapshotSha256 = 'b' * 64;
              },
            ];
        for (final change in changes) {
          final a = f.row;
          final b = rows.get(secondId)!;
          change(a, b);
          rows.putMany([a, b]);
          expect(() => f.admission, _rejected);
          rows.putMany([first, second]);
        }
        expect(f.admission.matchesReflectedParent(f.target), isTrue);
      },
    );

    test(
      'original adopted stage epoch survives an actual ownership advance and reopen',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final captured = f.admission;
        final operation = f.adopt(captured: captured);
        final binding = f.row.admittedBindingSha256;
        final permit = f.authority.issuePermit(
          f.writerScope,
          expectedOwner: CloudKitWriterOwner.v2,
        );
        f.authority.markMutationUnknown(permit, now: _now);
        await f.reopen();
        expect(f.owner.epoch, greaterThan(captured.writerEpoch));
        final recovered = f.journal.readAdoptedForUpdate(
          operationId: operation.operationId,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        expect(recovered.writerEpoch, captured.writerEpoch);
        expect(recovered.sameReflectedMutationAs(captured), isTrue);
        expect(f.row.admittedWriterEpoch, captured.writerEpoch);
        f.adopt(operation: operation, captured: recovered);
        f.journal.validateAdoptedOperation(f.db, operation, f.mapping);
        expect(f.row.admittedBindingSha256, binding);
        f.db.box<CloudSyncReceivedMutationIntentEntity>().put(
          f.row..admittedWriterEpoch = f.owner.epoch,
        );
        expect(
          () => f.adopt(operation: operation, captured: recovered),
          _rejected,
        );
        expect(
          () => f.journal.validateAdoptedOperation(f.db, operation, f.mapping),
          _rejected,
        );
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 1);
      },
    );

    test(
      'legacy zero ownership allows only its exact stable captured stage epoch',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final authorities = f.db.box<CloudKitWriterAuthorityEntity>();
        authorities.put(authorities.getAll().single..ownershipEpoch = 0);
        f.bind();
        final captured = f.admission;
        final operation = f.adopt(captured: captured);
        f.journal.validateAdoptedOperation(f.db, operation, f.mapping);
        expect(f.row.admittedWriterEpoch, captured.writerEpoch);
        final changed = authorities.getAll().single;
        changed.epoch++;
        authorities.put(changed);
        f.bind();
        expect(
          () => f.journal.readAdoptedForUpdate(
            operationId: operation.operationId,
            currentAuth: f.auth,
            stillCurrent: () => true,
          ),
          _rejected,
        );
        expect(f.row.admittedWriterEpoch, captured.writerEpoch);
      },
    );
  });

  // Real shared executor/store with synthetic native results. These cases do
  // not prove Apple's network/actor behavior; the graph tests above separately
  // cover local/mirrored ordering and exact-readback markers.
  group('received updates through the real executor', () {
    for (final safeCode in [
      'cloudkit_writer_mutation_outcome_unknown',
      'synthetic_unrelated_guard_failure',
    ]) {
      test(
        'automatic adapter classifies only its exact guarded unknown: $safeCode',
        () async {
          final f = await _Fixture.create();
          addTearDown(f.close);
          final cloudStore = f.executorStore();
          await f.seedExecutorDependencies(cloudStore);
          final transport = _ReceivedExecutorTransport(
            f,
            consumptionFailure: CloudKitWriterAuthorityFailure(safeCode),
          );
          var allowed = true;
          CloudSyncReceivedMutationArchiveAdapter adapterAt([DateTime? at]) =>
              CloudSyncReceivedMutationArchiveAdapter(
                store: f.db,
                durable: cloudStore,
                journal: f.journal,
                executor: f.executor(cloudStore, transport, now: at),
                auth: f.auth,
                warmReadDependencies: () async {},
                validate: () async {},
                stillCurrent: () => true,
                receivedArchiveAllowed: () => allowed,
              );
          final adapter = adapterAt();
          if (safeCode != 'cloudkit_writer_mutation_outcome_unknown') {
            await expectLater(
              adapter.admitPending(_scope),
              throwsA(
                isA<CloudKitWriterAuthorityFailure>().having(
                  (e) => e.safeCode,
                  'safeCode',
                  safeCode,
                ),
              ),
            );
            expect(transport.submissions, hasLength(1));
            expect(transport.receivedReadbacks, 0);
            return;
          }
          final first = await adapter.admitPending(_scope);
          expect(first.admitted, 1);
          expect(first.outboxBlocked, isTrue);
          final unknown = (await cloudStore.readOutboxEntries(_scope)).single;
          expect(unknown.status, CloudOutboxStatus.unknownOutcome);
          expect(unknown.appleRequestUuid, isNotNull);
          expect(unknown.appleOperationUuid, isNotNull);
          // Pausing fresh archival cannot strand the already-submitted native
          // envelope's exact readback or cause another conditional submission.
          allowed = false;
          // A later bounded queue pass runs after the unknown lease expires.
          // Advance the executor's virtual clock instead of sleeping in a test.
          final resumed = adapterAt(
            DateTime.now().toUtc().add(const Duration(minutes: 5)),
          );
          expect(await resumed.drainExisting(_scope), isTrue);
          final terminal = (await cloudStore.readOutboxEntries(_scope)).single;
          expect(terminal.operationId, unknown.operationId);
          expect(terminal.appleRequestUuid, unknown.appleRequestUuid);
          expect(terminal.appleOperationUuid, unknown.appleOperationUuid);
          expect(terminal.status, CloudOutboxStatus.confirmed);
          expect(terminal.protectedLeaseReference, isNull);
          expect(f.row.state, 3);
          expect(transport.submissions, hasLength(1));
          expect(transport.receivedStages, 1);
          expect(transport.receivedPrepares, 1);
          expect(transport.receivedReadbacks, 1);
          transport.expectReceivedOnly();
        },
      );
    }
    test(
      'automatic adapter pauses admission, then drains once without duplicate submission',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final cloudStore = f.executorStore();
        await f.seedExecutorDependencies(cloudStore);
        final transport = _ReceivedExecutorTransport(f);
        var allowed = false;
        var warmed = 0;
        final adapter = CloudSyncReceivedMutationArchiveAdapter(
          store: f.db,
          durable: cloudStore,
          journal: f.journal,
          executor: f.executor(cloudStore, transport),
          auth: f.auth,
          warmReadDependencies: () async {
            warmed++;
          },
          validate: () async {},
          stillCurrent: () => true,
          receivedArchiveAllowed: () => allowed,
        );
        await expectLater(adapter.admitPending(_scope), _rejected);
        expect(warmed, 0);
        expect(transport.receivedStages, 0);
        expect(f.db.box<CloudOutboxOperationEntity>().count(), 0);
        allowed = true;
        final first = await adapter.admitPending(_scope);
        expect(first.admitted, 1);
        expect(first.deferred, 0);
        expect(first.outboxBlocked, isFalse);
        expect(warmed, 1);
        final submitted = transport.submissions.single;
        await f.expectExecutorSettlement(cloudStore, submitted);
        expect(
          f.row.state,
          3,
          reason: 'executor retires the exact finalized readback',
        );
        final duplicate = await adapter.admitPending(_scope);
        expect(duplicate.admitted, 0);
        expect(await adapter.drainExisting(_scope), isTrue);
        expect(transport.receivedStages, 1);
        expect(transport.receivedPrepares, 1);
        expect(transport.receivedReadbacks, 1);
        expect(transport.submissions, hasLength(1));
        expect(warmed, 1);
        transport.expectReceivedOnly();
      },
    );

    test(
      'exact retry stages once and exact readback hands off both leases',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final cloudStore = f.executorStore();
        await f.seedExecutorDependencies(cloudStore);
        final transport = _ReceivedExecutorTransport(f);
        final executor = f.executor(cloudStore, transport);
        final source = f.admission;
        final predecessor = source.requirePredecessor(
          store: f.db,
          messageScope: _scope,
        );
        final parent = f.parentProof;
        final operation = await executor.admitReflectedReceivedUpdate(
          _scope,
          source: source,
          predecessor: predecessor,
          parent: parent,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        final retry = await executor.admitReflectedReceivedUpdate(
          _scope,
          source: source,
          predecessor: predecessor,
          parent: parent,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        expect(retry.operationId, operation.operationId);
        expect(
          retry.encryptedPayloadReference,
          operation.encryptedPayloadReference,
        );
        expect(
          transport.receivedStages,
          1,
          reason: 'exact retry restages zero times',
        );
        expect(transport.stagedParents.single, parent);
        expect(transport.committedLeases, [_updateLease]);
        expect(f.row.state, 2);

        final result = await executor.runOnce(
          _scope,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        expect(result.submitted, 1);
        expect(result.confirmed, 1);
        expect(result.reconciledUnknown, 0);
        expect(transport.receivedPrepares, 1);
        expect(transport.receivedReadbacks, 1);
        expect(transport.submissions.single.operationId, operation.operationId);
        expect(transport.readbacks.single.operationId, operation.operationId);
        expect(transport.committedLeases, [_updateLease, _readbackLease]);
        expect(transport.retainedReferences, [
          {operation.encryptedPayloadReference!},
          {_readbackReference},
        ]);
        expect(transport.acknowledgedLeases, [_updateLease, _readbackLease]);
        expect(transport.completedStatuses, [CloudOutboxStatus.confirmed]);
        expect(transport.releasedPrepared, 1);
        final terminal = await f.expectExecutorSettlement(
          cloudStore,
          operation,
        );
        expect(
          f.row.state,
          3,
          reason: 'real executor retirement, not manual promotion',
        );
        expect(f.confirm(terminal).encode(), f.seed.encode());
        expect(f.row.state, 3);
        transport.expectReceivedOnly();
      },
    );

    test(
      'mirrored unsend lost response resumes the same outbox by readback only',
      () async {
        final f = await _Fixture.create(mirrored: true, unsend: true);
        addTearDown(f.close);
        final cloudStore = f.executorStore();
        await f.seedExecutorDependencies(cloudStore);
        final transport = _ReceivedExecutorTransport(f, loseResponse: true);
        final executor = f.executor(cloudStore, transport);
        final source = f.admission;
        final operation = await executor.admitReflectedReceivedUpdate(
          _scope,
          source: source,
          predecessor: source.requirePredecessor(
            store: f.db,
            messageScope: _scope,
          ),
          parent: f.parentProof,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        await expectLater(
          executor.runOnce(
            _scope,
            currentAuth: f.auth,
            stillCurrent: () => true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'synthetic_received_update_response_lost',
            ),
          ),
        );
        final unknown = (await cloudStore.readOutboxEntries(_scope)).single;
        expect(unknown.status, CloudOutboxStatus.unknownOutcome);
        expect(unknown.operationId, operation.operationId);
        expect(unknown.appleRequestUuid, isNotNull);
        expect(unknown.appleOperationUuid, isNotNull);
        expect(
          unknown.attemptCount,
          0,
          reason:
              'first submission is durable before the retry counter advances',
        );
        expect(unknown.protectedLeaseReference, _updateLease);
        expect(transport.submissions.single.operationId, unknown.operationId);
        expect(transport.receivedReadbacks, 0);
        expect(transport.releasedPrepared, 1);
        expect(f.row.state, 2);
        expect(f.row.protectedSourceBinding, f.seed.encode());
        transport.expectReceivedOnly();

        // Retained late input vetoes fresh dispatch, not the already-submitted
        // envelope's exact readback. Preserve it as state 0 through recovery.
        final late = _wire(
          mirrored: true,
          event: _otherEvent,
          timestamp: 1700000009000,
        );
        final lateId = f.retain(late, f.sourceFor(late));

        await f.reopen();
        final restartedStore = f.executorStore();
        final restartedTransport = _ReceivedExecutorTransport(f);
        final restarted = f.executor(
          restartedStore,
          restartedTransport,
          now: _now.add(const Duration(minutes: 5)),
        );
        final result = await restarted.runOnce(
          _scope,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        expect(result.reconciledUnknown, 1);
        expect(result.submitted, 0);
        expect(result.confirmed, 1);
        expect(restartedTransport.receivedStages, 0);
        expect(restartedTransport.receivedPrepares, 0);
        expect(restartedTransport.submissions, isEmpty);
        expect(restartedTransport.receivedReadbacks, 1);
        final readback = restartedTransport.readbacks.single;
        expect(readback.operationId, unknown.operationId);
        expect(readback.appleRequestUuid, unknown.appleRequestUuid);
        expect(readback.appleOperationUuid, unknown.appleOperationUuid);
        expect(readback.attemptCount, unknown.attemptCount);
        expect(restartedTransport.committedLeases, [_readbackLease]);
        expect(restartedTransport.acknowledgedLeases, [
          _updateLease,
          _readbackLease,
        ]);
        final terminal = await f.expectExecutorSettlement(
          restartedStore,
          operation,
        );
        expect(f.row.state, 3);
        expect(terminal.appleRequestUuid, unknown.appleRequestUuid);
        expect(terminal.appleOperationUuid, unknown.appleOperationUuid);
        expect(terminal.attemptCount, unknown.attemptCount);
        expect(f.confirm(terminal).encode(), f.seed.encode());
        expect(f.row.state, 3);
        expect(
          f.db.box<CloudSyncReceivedMutationIntentEntity>().get(lateId)!.state,
          0,
        );
        restartedTransport.expectReceivedOnly();
      },
    );

    test(
      'restart completes a committed readback lease handoff without reread or submit',
      () async {
        final f = await _Fixture.create(unsend: true);
        addTearDown(f.close);
        final cloudStore = f.executorStore();
        await f.seedExecutorDependencies(cloudStore);
        final transport = _ReceivedExecutorTransport(
          f,
          failReadbackCommit: true,
        );
        final executor = f.executor(cloudStore, transport);
        final source = f.admission;
        final operation = await executor.admitReflectedReceivedUpdate(
          _scope,
          source: source,
          predecessor: source.requirePredecessor(
            store: f.db,
            messageScope: _scope,
          ),
          parent: f.parentProof,
          currentAuth: f.auth,
          stillCurrent: () => true,
        );
        await expectLater(
          executor.runOnce(
            _scope,
            currentAuth: f.auth,
            stillCurrent: () => true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'synthetic_received_readback_commit_failed',
            ),
          ),
        );
        final committed = (await cloudStore.readOutboxEntries(_scope)).single;
        expect(committed.status, CloudOutboxStatus.confirmed);
        expect(committed.protectedLeaseReference, _updateLease);
        expect(f.mapping.etagHash, _readbackEtag);
        expect(f.mapping.encryptedRawRecordRef, _readbackReference);
        expect(f.mapping.protectedReadbackLeaseReference, _readbackLease);
        expect(f.mapping.pendingUpdateOperationId, operation.operationId);
        expect(f.mapping.pendingUpdatePredecessorEtagHash, _etag);
        expect(() => f.confirm(committed), _rejected);
        expect(f.row.state, 2);
        expect(transport.acknowledgedLeases, isEmpty);
        transport.expectReceivedOnly();

        await f.reopen();
        final restartedStore = f.executorStore();
        final restartedTransport = _ReceivedExecutorTransport(f);
        final result = await f
            .executor(restartedStore, restartedTransport)
            .runOnce(_scope, currentAuth: f.auth, stillCurrent: () => true);
        expect(result.recoveredReadbacks, 1);
        expect(result.submitted, 0);
        expect(result.reconciledUnknown, 0);
        expect(restartedTransport.receivedStages, 0);
        expect(restartedTransport.receivedPrepares, 0);
        expect(restartedTransport.receivedReadbacks, 0);
        expect(restartedTransport.submissions, isEmpty);
        expect(restartedTransport.committedLeases, [_readbackLease]);
        expect(restartedTransport.acknowledgedLeases, [
          _updateLease,
          _readbackLease,
        ]);
        expect(restartedTransport.completedStatuses, [
          CloudOutboxStatus.confirmed,
        ]);
        final terminal = await f.expectExecutorSettlement(
          restartedStore,
          operation,
        );
        expect(terminal.appleRequestUuid, committed.appleRequestUuid);
        expect(terminal.appleOperationUuid, committed.appleOperationUuid);
        expect(f.confirm(terminal).encode(), f.seed.encode());
        expect(f.row.state, 3);
        restartedTransport.expectReceivedOnly();
      },
    );
  });
}

final class _Fixture {
  _Fixture(this.directory, this.db, this.mirrored, this.unsend);
  final Directory directory;
  Store db;
  final bool mirrored;
  final bool unsend;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitWriterAuthoritySnapshot owner;
  late CloudSyncNativeAuthSnapshot auth;
  late CloudSyncReceivedMutationJournal journal;
  late int messageId;
  late int chatId;
  late int intentId;
  late api.MessageInst wire;
  late CloudSyncReceivedMutationSourceBinding seed;
  CloudKitWriterScope get writerScope =>
      CloudKitWriterScope(accountFingerprint: _scope.accountFingerprint);
  Message get target => db.box<Message>().get(messageId)!;
  CloudSyncReceivedMutationIntentEntity get row =>
      db.box<CloudSyncReceivedMutationIntentEntity>().get(intentId)!;
  CloudRecordMapEntity get mapping =>
      db.box<CloudRecordMapEntity>().getAll().singleWhere(
        (m) =>
            m.scopeKey == cloudSyncPersistentScopeKey(_scope) &&
            m.logicalEntityKeyHash == _logical,
      );
  CloudSyncReceivedMutationAdmissionSource get admission =>
      journal.readReflectedForUpdate(
        intentId: intentId,
        currentAuth: auth,
        stillCurrent: () => true,
      );
  CloudSyncReceivedMutationAdmissionSource sourceAt(int id) =>
      journal.readReflectedForUpdate(
        intentId: id,
        currentAuth: auth,
        stillCurrent: () => true,
      );

  String lineage({required bool received, required int intent}) =>
      requireCloudSyncMutationForwardLineage(
        store: db,
        target: target,
        accountFingerprint: auth.accountFingerprint,
        protectedStoreIdentity: auth.protectedStoreIdentity,
        maximumWriterEpoch: owner.epoch,
        automaticArchiveEpoch: owner.automaticArchiveEpoch,
        receivedOrigin: received,
        intentId: intent,
        reject: () => throw StateError('synthetic_lineage_rejected'),
      );

  int appendReceived({
    int timestamp = 1700000011000,
    String text = 'Second received',
  }) {
    final next = _wire(
      mirrored: mirrored,
      event: _otherEvent,
      timestamp: timestamp,
      text: text,
    );
    final id = retain(next, sourceFor(next));
    final before = target;
    final reflected = target
      ..text = text
      ..attributedBody = [AttributedBody.raw(text)];
    journal.commitReflection(
      intentId: id,
      wire: next,
      liveContext: _live,
      currentAuth: auth,
      stillCurrent: () => true,
      expectedBeforeSnapshot: CloudSyncReceivedMutationJournal.snapshot(before),
      reflected: reflected,
      now: _now,
    );
    return id;
  }

  int appendLocal() {
    // A distinct synthetic OUTGOING source; never a received wire with receive
    // metadata stripped off. Its positive native collaborator receipt is only
    // a fixture input to the real local journal, not an Apple/IDS claim.
    final wire = api.MessageInst(
      id: _localEvent,
      sender: _owner,
      conversation: api.ConversationData(
        participants: [_owner, _remote],
        senderGuid: target.chat.target!.guid,
      ),
      message: const api.Message.edit(
        api.EditMessage(
          tuuid: _target,
          editPart: 0,
          newParts: api.MessageParts(
            field0: [
              api.IndexedMessagePart(
                part_: api.MessagePart.text(
                  'Local descendant',
                  api.TextFormat.flags(
                    api.TextFlags(
                      bold: false,
                      italic: false,
                      underline: false,
                      strikethrough: false,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      sentTimestamp: 0,
      sendDelivered: false,
      verificationFailed: false,
    );
    final identity = CloudSyncLocalMutationIdentity.captureWire(wire)!;
    final source = CloudSyncLocalMutationSourceBinding(
      accountFingerprint: auth.accountFingerprint,
      protectedStoreIdentity: auth.protectedStoreIdentity,
      mutationGuidHash: identity.guidHash,
      targetGuidHash: identity.targetGuidHash,
      targetPart: 0,
      sourceSha256: identity.sourceSha256,
      protectedReference: 'obcs2.ref.${'M' * 43}',
      leaseReference: 'obcs2.lease.${'b' * 32}',
      payloadSha256: 'b' * 64,
      payloadLength: 128,
    );
    final local = _emptyOutgoingJournal();
    final before = local.captureTargetSnapshot(
      localMessageId: messageId,
      identity: identity,
    );
    final id = local.adoptSource(
      localMessageId: messageId,
      identity: identity,
      targetSnapshotSha256: before,
      source: source,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _now,
    );
    local.beginSubmission(
      intentId: id,
      committedSource: source,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _now,
    );
    final receipt = api.CloudSyncNativeSendReceipt(
      receiptId: 'obcs2.ids.${'I' * 43}',
      guidHash: identity.guidHash,
      nativeSessionId: auth.nativeSessionId,
      preparedSentTimestampMs: BigInt.from(1700000011000),
      sourceBinding: api.CloudSyncNativeSendSourceBinding(
        kind: api.CloudSyncNativeSendSourceKind.mutation,
        sourceSha256: source.sourceSha256,
        protectedReference: source.protectedReference,
        leaseReference: source.leaseReference,
        payloadSha256: source.payloadSha256,
        payloadLength: BigInt.from(source.payloadLength),
      ),
    );
    local.recordNativeReceipt(
      intentId: id,
      receipt: receipt,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _now,
    );
    local.reflectConfirmed(
      intentId: id,
      receipt: receipt,
      currentAuth: auth,
      stillCurrent: () => true,
      now: _now,
      project: (target, timestamp) => target
        ..text = 'Local descendant'
        ..attributedBody = [AttributedBody.raw('Local descendant')]
        ..dateEdited = DateTime.fromMillisecondsSinceEpoch(timestamp),
    );
    return id;
  }

  CloudSyncHistoricalParentProof get parentProof =>
      requireCloudSyncHistoricalParentProof(
        store: db,
        messageScope: _scope,
        chatId: chatId,
      );

  CloudSyncLocalMutationJournal _emptyOutgoingJournal() =>
      CloudSyncLocalMutationJournal(
        store: db,
        authority: authority,
        authoritySnapshot: owner,
      );

  ObjectBoxCloudSyncStore executorStore() => ObjectBoxCloudSyncStore(
    store: db,
    protector: _ExecutorProtector(),
    localMutationJournal: _emptyOutgoingJournal(),
    receivedMutationJournal: journal,
    clock: () => _now,
  );

  CloudSyncMessageUpdateExecutor executor(
    ObjectBoxCloudSyncStore cloudStore,
    _ReceivedExecutorTransport transport, {
    DateTime? now,
  }) {
    var sequence = 0;
    return CloudSyncMessageUpdateExecutor(
      objectBoxStore: db,
      cloudStore: cloudStore,
      journal: _emptyOutgoingJournal(),
      transport: transport,
      preparedSubmissionReleaser: transport,
      leaseTransport: transport,
      receivedJournal: journal,
      receivedTransport: transport,
      clock: () => now ?? _now.add(const Duration(minutes: 1)),
      uuidFactory: () =>
          '00000000-0000-4000-8000-${(++sequence).toString().padLeft(12, '0')}',
    );
  }

  Future<void> seedExecutorDependencies(
    ObjectBoxCloudSyncStore cloudStore,
  ) async {
    final chatScope = _zoneScope('chatManateeZone');
    final applied = await seedSyntheticRestoredChatAppliedSource(
      objectBox: db,
      store: cloudStore,
      chatScope: chatScope,
      now: _now,
    );
    await seedSyntheticRestoredChatProof(
      objectBox: db,
      store: cloudStore,
      chatScope: chatScope,
      chat: db.box<Chat>().get(chatId)!,
      appliedSource: applied,
      now: _now,
    );
    for (final zone in ['messageManateeZone', 'attachmentManateeZone']) {
      final scope = _zoneScope(zone);
      final checkpoint = await cloudStore.readCheckpoint(scope);
      final fence = await cloudStore.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'received-update-fixture-$zone',
        now: _now,
        leaseDuration: const Duration(minutes: 10),
      );
      if (fence == null) {
        throw StateError('received_update_fixture_lease_missing');
      }
      try {
        final messageZone = zone == 'messageManateeZone';
        final sequence = checkpoint.fetchedSequence + 1;
        await cloudStore.journalFetchedBatch(
          CloudFetchBatch(
            scope: scope,
            changes: [
              CloudFetchedChange(
                changeId: 'J' * 43,
                recordIdHash: messageZone ? _record : 'Z' * 43,
                type: CloudChangeType.save,
                etagHash: messageZone ? _etag : 'Z' * 43,
                encryptedServerRecordId:
                    'obcs2.ref.${messageZone ? 'R' * 43 : 'Z' * 43}',
                protectedSystemFieldsReference: 'obcs2.ref.${'X' * 43}',
                encryptedPayloadReference:
                    'obcs2.ref.${messageZone ? 'P' * 43 : 'Z' * 43}',
                payloadSha256: 'a' * 64,
              ),
            ],
            batchId: 'received-update-fixture-$zone-$sequence',
            generation: checkpoint.generation,
            nextToken: 'received-update-token-$zone-$sequence',
            hasMore: false,
          ),
          now: _now,
          leaseFence: fence,
          expectedGeneration: checkpoint.generation,
          expectedFetchedToken: checkpoint.fetchedToken,
        );
        await cloudStore.markInboxApplied(
          scope,
          sequence: sequence,
          now: _now,
          leaseFence: fence,
        );
        await cloudStore.recordPullSuccess(scope, now: _now);
      } finally {
        await cloudStore.releaseCoordinatorLease(scope, leaseFence: fence);
      }
    }
    // Read the real current-generation parent and predecessor after seeding;
    // neither is a synthetic outgoing-send receipt or an unchecked callback.
    expect(parentProof.generation, greaterThan(0));
    expect(
      admission.requirePredecessor(store: db, messageScope: _scope).generation,
      1,
    );
  }

  Future<CloudOutboxOperation> expectExecutorSettlement(
    ObjectBoxCloudSyncStore cloudStore,
    CloudOutboxOperation admitted,
  ) async {
    final terminal = (await cloudStore.readOutboxEntries(_scope)).single;
    expect(terminal.operationId, admitted.operationId);
    expect(terminal.checkpointGeneration, admitted.checkpointGeneration);
    expect(terminal.payloadVersion, cloudSyncMessageUpdatePayloadVersion);
    expect(terminal.status, CloudOutboxStatus.confirmed);
    expect(terminal.confirmedAt, isNotNull);
    expect(terminal.protectedLeaseReference, isNull);
    expect(terminal.appleRequestUuid, isNotNull);
    expect(terminal.appleOperationUuid, isNotNull);
    expect(mapping.etagHash, _readbackEtag);
    expect(mapping.encryptedRawRecordRef, _readbackReference);
    expect(mapping.rawRecordGeneration, admitted.checkpointGeneration);
    expect(mapping.encryptedServerRecordId, 'obcs2.ref.${'R' * 43}');
    expect(mapping.protectedReadbackLeaseReference, isNull);
    expect(mapping.pendingUpdateOperationId, isNull);
    expect(mapping.pendingUpdatePredecessorEtagHash, isNull);
    expect(row.protectedSourceBinding, seed.encode());
    expect(db.box<CloudOutboxOperationEntity>().count(), 1);
    expect(db.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
    expect(db.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    return terminal;
  }

  void bind() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: db,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    if (authority.read(writerScope) == null) {
      final disabled = authority.initializeDisabled(writerScope, now: _now);
      authority.provisionInitialOwner(
        writerScope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: _now,
      );
    }
    owner = authority.read(writerScope)!;
    auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic-session',
      accountFingerprint: _scope.accountFingerprint,
      protectedStoreIdentity: 'obcs2.store.${'S' * 43}',
      cloudMessagesClient: Object(),
    );
    journal = CloudSyncReceivedMutationJournal(
      store: db,
      authority: authority,
      owner: owner,
    );
  }

  static Future<_Fixture> create({
    bool mirrored = false,
    bool unsend = false,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'received-mutation-admission-',
    );
    final f = _Fixture(
      directory,
      await openStore(directory: directory.path),
      mirrored,
      unsend,
    )..bind();
    final handle = Handle(
      address: 'remote@example.invalid',
      service: 'iMessage',
      uniqueAddressAndService: 'remote@example.invalid/iMessage',
    )..originalROWID = 9001;
    f.db.box<Handle>().put(handle);
    final chat = Chat(
      guid: 'iMessage;-;remote@example.invalid',
      chatIdentifier: 'remote@example.invalid',
      style: 45,
      usingHandle: _owner,
      isRpSms: false,
    )..handles.add(handle);
    f.chatId = f.db.box<Chat>().put(chat);
    final target = Message(
      guid: _target,
      text: 'Original',
      isFromMe: mirrored,
      handleId: mirrored ? 0 : 9001,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      hasAttachments: false,
    )..chat.target = chat;
    f.messageId = f.db.box<Message>().put(target);
    f.wire = _wire(mirrored: mirrored, unsend: unsend);
    f.seed = f.sourceFor(f.wire);
    f.intentId = f.retain(f.wire, f.seed);
    final reflected = f.target..text = unsend ? 'Original' : 'Edited';
    reflected.messageSummaryInfo = [
      MessageSummaryInfo.empty()..retractedParts.addAll(unsend ? [0] : []),
    ];
    f.journal.commitReflection(
      intentId: f.intentId,
      wire: f.wire,
      liveContext: _live,
      currentAuth: f.auth,
      stillCurrent: () => true,
      expectedBeforeSnapshot: CloudSyncReceivedMutationJournal.snapshot(target),
      reflected: reflected,
      now: _now,
    );
    f.seedPredecessor();
    return f;
  }

  CloudSyncReceivedMutationSourceBinding sourceFor(api.MessageInst wire) {
    final identity = CloudSyncReceivedMutationIdentity.captureWire(
      wire,
      liveContext: _live,
    )!;
    return CloudSyncReceivedMutationSourceBinding(
      accountFingerprint: auth.accountFingerprint,
      protectedStoreIdentity: auth.protectedStoreIdentity,
      mutationGuidHash: identity.guidHash,
      sourceSha256: identity.sourceSha256,
      ciphertext: 'obcs2.test.ciphertext',
    );
  }

  int retain(
    api.MessageInst wire,
    CloudSyncReceivedMutationSourceBinding seed,
  ) => journal.retain(
    wire: wire,
    liveContext: _live,
    source: seed,
    currentAuth: auth,
    stillCurrent: () => true,
    now: _now,
  );

  void seedPredecessor() {
    final key = cloudSyncPersistentScopeKey(_scope);
    final generationKey =
        'semantic-generation4:${sha256.convert(utf8.encode('$key\u001f1'))}';
    db.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: key,
        accountFingerprint: _scope.accountFingerprint,
        container: _scope.container,
        database: _scope.database,
        zone: _scope.zone,
        streamKind: _scope.streamKind.name,
        schemaVersion: _scope.schemaVersion,
        persistenceLane: _scope.persistenceLane.name,
        generation: 1,
        fetchedSequence: 1,
        appliedSequence: 1,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    db.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: cloudSyncCanonicalRecordMapKey(_scope, _logical),
        scopeKey: key,
        accountFingerprint: _scope.accountFingerprint,
        zone: _scope.zone,
        logicalEntityKeyHash: _logical,
        serverRecordIdHash: _record,
        generation: 1,
        encryptedServerRecordId: 'obcs2.ref.${'R' * 43}',
        etagHash: _etag,
        encryptedRawRecordRef: 'obcs2.ref.${'P' * 43}',
        rawRecordGeneration: 1,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    db.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        snapshotKey: 'semantic-snapshot4:$generationKey:message:$_logical',
        scopeGenerationKey: generationKey,
        scopeKey: key,
        accountFingerprint: _scope.accountFingerprint,
        container: _scope.container,
        database: _scope.database,
        zone: _scope.zone,
        streamKind: _scope.streamKind.name,
        schemaVersion: _scope.schemaVersion,
        generation: 1,
        entityKind: CloudEntityKind.message.name,
        logicalEntityKeyHash: _logical,
        canonicalGuidLookupHash:
            CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
              scope: _scope,
              generation: 1,
              canonicalGuid: _target,
            ),
        canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
          scope: _scope,
          generation: 1,
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: _logical,
          canonicalGuid: _target,
        ),
        etagHash: _etag,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    db.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: 'synthetic-change',
        changeIdHash: 'C' * 43,
        scopeKey: key,
        accountFingerprint: _scope.accountFingerprint,
        zone: _scope.zone,
        serverRecordIdHash: _record,
        etagHash: _etag,
        changeType: CloudChangeType.save.name,
        encryptedServerRecordId: 'obcs2.ref.${'R' * 43}',
        encryptedPayloadRef: 'obcs2.ref.${'P' * 43}',
        batchId: 'synthetic-batch',
        generation: 1,
        fetchSequence: 1,
        status: CloudInboxStatus.applied.index,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
  }

  CloudOutboxOperation operation({
    int revision = 1,
    int version = cloudSyncMessageUpdatePayloadVersion,
  }) => CloudOutboxOperation(
    scope: _scope,
    operationId: CloudOperationIdentity.forMutation(
      scope: _scope,
      logicalEntityKeyHash: _logical,
      action: CloudOutboxAction.save,
      payloadVersion: version,
      mutationRevision: revision,
      payloadSha256: 'c' * 64,
    ),
    logicalEntityKeyHash: _logical,
    action: CloudOutboxAction.save,
    payloadVersion: version,
    mutationRevision: revision,
    checkpointGeneration: 1,
    dependencyOperationIds: const {},
    createdAt: _now,
    encryptedPayloadReference: 'obcs2.ref.${'U' * 43}',
    payloadSha256: 'c' * 64,
    serverRecordIdHash: _record,
    protectedLeaseReference: 'obcs2.lease.${'c' * 32}',
  );

  CloudOutboxOperation adopt({
    CloudOutboxOperation? operation,
    CloudSyncReceivedMutationAdmissionSource? captured,
    CloudRecordMapEntity? predecessor,
    void Function()? afterAdopt,
    bool Function()? stillCurrent,
  }) {
    final source = captured ?? admission;
    final op = operation ?? this.operation();
    return db.runInTransaction(TxMode.write, () {
      if (!db.box<CloudOutboxOperationEntity>().getAll().any(
        (r) => r.operationId == op.operationId,
      )) {
        writeOperation(op);
      }
      journal.adoptInOutboxTransaction(
        db,
        source,
        op,
        predecessor ?? mapping,
        currentAuth: auth,
        stillCurrent: stillCurrent ?? () => true,
        now: _now,
      );
      afterAdopt?.call();
      return op;
    });
  }

  void writeOperation(CloudOutboxOperation op) {
    final existing = db.box<CloudOutboxOperationEntity>().getAll().where(
      (r) => r.operationId == op.operationId,
    );
    db.box<CloudOutboxOperationEntity>().put(
      CloudOutboxOperationEntity(
        id: existing.isEmpty ? 0 : existing.single.id,
        operationId: op.operationId,
        scopeKey: cloudSyncPersistentScopeKey(op.scope),
        accountFingerprint: op.scope.accountFingerprint,
        zone: op.scope.zone,
        logicalEntityKeyHash: op.logicalEntityKeyHash,
        action: op.action.index,
        payloadVersion: op.payloadVersion,
        mutationRevision: op.mutationRevision,
        checkpointGeneration: op.checkpointGeneration,
        encryptedPayloadRef: op.encryptedPayloadReference,
        payloadSha256: op.payloadSha256,
        protectedLeaseReference: op.protectedLeaseReference,
        serverRecordIdHash: op.serverRecordIdHash,
        state: op.status.index,
        attemptCount: op.attemptCount,
        confirmedAtMs: op.confirmedAt?.millisecondsSinceEpoch ?? 0,
        nextEligibleAtMs: op.nextEligibleAt?.millisecondsSinceEpoch ?? 0,
        lastErrorCategory: op.lastFailure?.name,
        leaseIdHash: op.leaseId,
        leaseExpiresAtMs: op.leaseExpiresAt?.millisecondsSinceEpoch ?? 0,
        appleRequestUuid: op.appleRequestUuid,
        appleOperationUuid: op.appleOperationUuid,
        createdAtMs: op.createdAt.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
  }

  CloudOutboxOperation confirmed(CloudOutboxOperation op) => op.copyWith(
    status: CloudOutboxStatus.confirmed,
    confirmedAt: _now,
    attemptCount: 1,
    clearProtectedLeaseReference: true,
  );
  CloudSyncReceivedMutationSourceBinding confirm(CloudOutboxOperation op) =>
      journal.markExactReadbackConfirmed(
        intentId: intentId,
        operation: op,
        currentAuth: auth,
        stillCurrent: () => true,
        now: _now,
      );
  Future<void> reopen() async {
    db.close();
    db = await openStore(directory: directory.path);
    bind();
  }

  Future<void> close() async {
    if (!db.isClosed()) db.close();
    await directory.delete(recursive: true);
  }
}

CloudSyncScope _zoneScope(String zone) => CloudSyncScope(
  accountFingerprint: _scope.accountFingerprint,
  container: _scope.container,
  database: _scope.database,
  zone: zone,
  streamKind: _scope.streamKind,
  schemaVersion: _scope.schemaVersion,
  persistenceLane: _scope.persistenceLane,
);

/// Only the native collaborator is synthetic. The production executor owns all
/// staging/adoption, leasing, UUID persistence, unknown and readback transitions.
final class _ReceivedExecutorTransport
    implements
        CloudSyncMessageUpdateTransport,
        CloudSyncReceivedMessageUpdateTransport,
        CloudSyncPreparedSubmissionReleaser,
        CloudProtectedPageLeaseTransport {
  _ReceivedExecutorTransport(
    this.fixture, {
    this.loseResponse = false,
    this.failReadbackCommit = false,
    this.consumptionFailure,
  });
  final _Fixture fixture;
  final bool loseResponse;
  final bool failReadbackCommit;
  final Object? consumptionFailure;
  int receivedStages = 0;
  int receivedPrepares = 0;
  int receivedReadbacks = 0;
  int outgoingStages = 0;
  int outgoingPrepares = 0;
  int outgoingReadbacks = 0;
  int releasedPrepared = 0;
  final stagedParents = <CloudSyncHistoricalParentProof>[];
  final submissions = <CloudOutboxOperation>[];
  final readbacks = <CloudOutboxOperation>[];
  final committedLeases = <String>[];
  final retainedReferences = <Set<String>>[];
  final acknowledgedLeases = <String>[];
  final rolledBackLeases = <String>[];
  final completedStatuses = <CloudOutboxStatus>[];
  final unexpectedMethods = <Symbol>[];

  void expectReceivedOnly() {
    expect(outgoingStages, 0);
    expect(outgoingPrepares, 0);
    expect(outgoingReadbacks, 0);
    expect(unexpectedMethods, isEmpty);
    expect(rolledBackLeases, isEmpty);
    expect(fixture.db.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    expect(fixture.db.box<CloudSyncLocalMutationIntentEntity>().count(), 0);
    expect(
      fixture.db.box<CloudOutboxOperationEntity>().getAll().every(
        (row) =>
            row.payloadVersion == cloudSyncMessageUpdatePayloadVersion &&
            row.action == CloudOutboxAction.save.index,
      ),
      isTrue,
      reason:
          'only an existing-record conditional update; no create/IDS receipt',
    );
  }

  @override
  String get protectedPageLeaseRecoveryIdentity =>
      fixture.auth.protectedStoreIdentity;

  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      action();

  @override
  Future<CloudSyncProtectedMessageUpdateStage> stageReceivedMessageUpdate(
    CloudSyncScope scope, {
    required CloudSyncReceivedMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
    required CloudSyncHistoricalParentProof parent,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) async {
    receivedStages++;
    expect(scope, _scope);
    expect(source.matchesReflectedParent(fixture.target), isTrue);
    expect(source.protectedSourceBinding, fixture.seed.encode());
    expect(
      source.origin,
      fixture.mirrored
          ? CloudSyncReceivedArchiveOrigin.mirrored
          : CloudSyncReceivedArchiveOrigin.incoming,
    );
    expect(source.kind, fixture.unsend ? 1 : 0);
    expect(currentAuth.accountFingerprint, source.accountFingerprint);
    expect(currentAuth.protectedStoreIdentity, source.protectedStoreIdentity);
    expect(parent, fixture.parentProof);
    stagedParents.add(parent);
    return CloudSyncProtectedMessageUpdateStage(
      protectedReference: 'obcs2.ref.${'U' * 43}',
      leaseReference: _updateLease,
      payloadSha256: 'c' * 64,
      logicalEntityKeyHash: predecessor.recordMapping.logicalEntityKeyHash,
      serverRecordIdHash: predecessor.recordMapping.serverRecordIdHash,
    );
  }

  @override
  Future<CloudSyncPreparedSubmission> prepareReceivedMessageUpdateSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required CloudOutboxOperation operation,
    required CloudSyncProtectedWriteOperation protectedOperation,
    required CloudSyncReceivedMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  }) async {
    receivedPrepares++;
    expect(source.adoptedOperationId, operation.operationId);
    expect(operation.status, CloudOutboxStatus.leased);
    return CloudSyncPreparedSubmission.fromProtectedPreflight(
      scope: scope,
      identity: submissionIdentity,
      operations: [protectedOperation],
    );
  }

  @override
  Future<void> consumePreparedMessageUpdate(
    CloudSyncScope scope, {
    required CloudSyncPreparedSubmission preparedSubmission,
    required CloudOutboxSubmissionIdentity persistedIdentity,
    required CloudOutboxOperation operation,
    required CloudSyncProtectedWriteOperation protectedOperation,
  }) async {
    preparedSubmission.claimForConsumption(
      scope,
      persistedIdentity: persistedIdentity,
      protectedOperations: [protectedOperation],
    );
    expect(operation.status, CloudOutboxStatus.unknownOutcome);
    expect(operation.appleRequestUuid, persistedIdentity.requestUuid);
    expect(
      operation.appleOperationUuid,
      persistedIdentity.operationUuids[operation.operationId],
    );
    submissions.add(operation);
    if (consumptionFailure case final failure?) throw failure;
    if (loseResponse) {
      throw StateError('synthetic_received_update_response_lost');
    }
  }

  @override
  Future<CloudSyncMessageUpdateReconciliation> reconcileReceivedMessageUpdate(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
    required CloudSyncReceivedMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  }) async {
    receivedReadbacks++;
    expect(source.adoptedOperationId, operation.operationId);
    expect(operation.status, CloudOutboxStatus.unknownOutcome);
    readbacks.add(operation);
    return CloudSyncMessageUpdateReconciliation.committed(
      CloudMessageUpdateReadbackReceipt(
        operationId: operation.operationId,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        serverRecordIdHash: operation.serverRecordIdHash!,
        predecessorEtagHash: predecessor.recordMapping.etagHash!,
        resultingEtagHash: _readbackEtag,
        protectedCurrentRawRecordReference: _readbackReference,
        protectedCurrentRawRecordLeaseReference: _readbackLease,
        rawGeneration: predecessor.generation,
        appleRequestUuid: operation.appleRequestUuid!,
        appleOperationUuid: operation.appleOperationUuid!,
      ),
    );
  }

  @override
  Future<CloudSyncProtectedMessageUpdateStage> stageMessageUpdate(
    CloudSyncScope scope, {
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required api.CloudSyncNativeSendReceipt receipt,
  }) async {
    outgoingStages++;
    throw StateError('unexpected_outgoing_update_stage');
  }

  @override
  Future<CloudSyncPreparedSubmission> prepareMessageUpdateSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required CloudOutboxOperation operation,
    required CloudSyncProtectedWriteOperation protectedOperation,
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  }) async {
    outgoingPrepares++;
    throw StateError('unexpected_outgoing_update_preparation');
  }

  @override
  Future<CloudSyncMessageUpdateReconciliation> reconcileMessageUpdate(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  }) async {
    outgoingReadbacks++;
    throw StateError('unexpected_outgoing_update_readback');
  }

  @override
  Future<void> completeMessageUpdateReconciliation(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) async {
    completedStatuses.add(operation.status);
  }

  @override
  Future<bool> releasePreparedSubmission(
    CloudSyncPreparedSubmission preparedSubmission,
  ) async {
    releasedPrepared++;
    return true;
  }

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> references,
  ) async {
    committedLeases.add(leaseReference);
    retainedReferences.add(Set.of(references));
    if (leaseReference == _readbackLease && failReadbackCommit) {
      throw StateError('synthetic_received_readback_commit_failed');
    }
  }

  @override
  Future<void> acknowledgeCommittedPageLease(String leaseReference) async =>
      acknowledgedLeases.add(leaseReference);

  @override
  Future<void> rollbackProtectedPageLease(String leaseReference) async =>
      rolledBackLeases.add(leaseReference);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedMethods.add(invocation.memberName);
    throw StateError('unexpected_received_executor_transport_operation');
  }
}

final class _ExecutorProtector implements CloudSyncProtector {
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async =>
      'test-v1:${base64UrlEncode(utf8.encode('${scope.storageKey}\u001f${kind.name}\u001f$plaintext'))}';

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    final decoded = utf8.decode(
      base64Url.decode(ciphertext.substring('test-v1:'.length)),
    );
    final prefix = '${scope.storageKey}\u001f${kind.name}\u001f';
    if (!decoded.startsWith(prefix)) throw const FormatException();
    return decoded.substring(prefix.length);
  }

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      throw StateError('unexpected_received_fixture_account_call');
}
