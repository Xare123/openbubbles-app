// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_received_archive_identity.dart';
import 'cloud_sync_received_archive_source_binding.dart';
import 'cloud_sync_received_record_observation.dart';
import 'cloud_operation_identity.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_binding.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

/// Durable protected-source pre-admission journal for incoming/mirrored
/// messages. Not an uploader.
///
/// This journal owns one immutable protected-source reference per
/// already-protected incoming source plus the Message/Chat row identities
/// persisted atomically in the same transaction. It stores only hashes,
/// typed metadata, and an opaque file binding or platform-encrypted retry
/// seed. It stores no plaintext body, handle, raw GUID, key, IDS send receipt,
/// or raw wire. The inline seed is not a protected-file GC reference.
///
/// Honest limits, read once. [CloudSyncReceivedArchiveIdentity.capture]
/// runs inside the save transaction on the actually persisted Message/Chat
/// plus the caller-supplied original wire, so body/sender/time drift before
/// [persistMessage] is detected and rolls back both rows. A precomputed
/// identity is never accepted as a substitute. Read-ready is metadata-ready
/// only: it revalidates journal ownership, positive ids, parent binding,
/// GUID-hash equality, direction, legacy flags, sender evidence, and
/// outgoing-intent overlap by row and by recomputed local-send GUID hash.
/// It is never upload authority. Record-map/snapshot dedup against Apple
/// records requires existing native canonical key hashes at separate
/// admission and is explicitly gated here, never guessed from the
/// lane-local received hash. The distinct received admission now binds an
/// existing native absent-only stage to the caller's atomic outbox transaction.
/// It never produces a local-send receipt or sends IDS traffic. No automatic
/// rollback of an adopted source occurs: failed retries retain exact evidence.
///
/// Crash-gap closure: the caller persists the incoming Message via the
/// synchronous [persistMessage] callback inside this journal transaction,
/// sharing one ObjectBox transaction for persistence plus adoption. An
/// already-saved-row-only call cannot prove that gap is closed. Do not
/// wrap async or UI work in that callback; persist the already-validated
/// row and its Chat link only. The Chat row itself must already be
/// persisted with a positive id before this call.
///
/// ObjectBoxCloudSyncStore includes these rows in its complete blob and
/// crash-handoff lease inventories. Every retained account/epoch/state still
/// owns its references; malformed bindings stop cleanup. The helpers below
/// are diagnostic views, not permission to release or delete anything.
final class CloudSyncReceivedArchiveJournal {
  CloudSyncReceivedArchiveJournal({
    required Store store,
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitWriterAuthoritySnapshot authoritySnapshot,
  }) : _store = store,
       _authority = authority,
       _binding = authoritySnapshot {
    if (!authority.isBoundToStore(store)) {
      throw StateError('cloud_sync_received_archive_authority_store_mismatch');
    }
  }

  final Store _store;
  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitWriterAuthoritySnapshot _binding;

  bool isBoundToStore(Store store) => identical(store, _store);

  List<int> readFoundCandidates({
    required CloudSyncNativeAuthSnapshot currentAuth, int limit = 5,
    int? maximumIntentId,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    if (limit < 1 || limit > 20 || currentAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    if (maximumIntentId != null && maximumIntentId < 0) {
      throw ArgumentError('cloud_sync_received_archive_limit_invalid');
    }
    var condition =
      CloudSyncReceivedArchiveIntentEntity_.accountFingerprint.equals(_binding.scope.accountFingerprint)
        .and(CloudSyncReceivedArchiveIntentEntity_.writerEpoch.equals(_binding.epoch))
        .and(CloudSyncReceivedArchiveIntentEntity_.state.equals(2))
        .and(CloudSyncReceivedArchiveIntentEntity_.recordObservationBinding.startsWith('[1,0,')
          .or(CloudSyncReceivedArchiveIntentEntity_.recordObservationBinding.startsWith('[1,1,')));
    if (maximumIntentId != null) {
      condition = condition.and(CloudSyncReceivedArchiveIntentEntity_.id.lessOrEqual(maximumIntentId));
    }
    final query = _store.box<CloudSyncReceivedArchiveIntentEntity>().query(condition)
        .order(CloudSyncReceivedArchiveIntentEntity_.updatedAtMs)
        .order(CloudSyncReceivedArchiveIntentEntity_.id).build()..limit = limit;
    try { return query.find().map((row) => row.id).toList(growable: false); }
    finally { query.close(); }
  });

  CloudSyncReceivedArchiveAdmissionSource readForReader({
    required int intentId, required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    final intent = _readBoundIntent(intentId);
    final source = readProtectedSource(intentId: intentId, currentAuth: currentAuth);
    final observation = _observationFor(intent, source);
    if (intent.state != 2 || source.isSeed ||
        !_isReady(intent, currentAuth, allowCloudMapping: true) ||
        (observation?.state != CloudSyncReceivedRecordState.equivalent &&
         observation?.state != CloudSyncReceivedRecordState.needsProjection) ||
        intent.admittedOperationId != null || intent.readerChangeId != null) {
      throw StateError('cloud_sync_received_archive_found_projection_not_ready');
    }
    return CloudSyncReceivedArchiveAdmissionSource._(intent, source, observation!);
  });

  void validateReaderAdmission({
    required Store transactionStore, required CloudSyncScope scope,
    required CloudSyncReceivedArchiveAdmissionSource expected,
    required CloudSyncNativeAuthSnapshot currentAuth, required bool Function() stillCurrent,
  }) {
    if (!identical(transactionStore, _store) || !stillCurrent() ||
        scope.accountFingerprint != _binding.scope.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' || scope.database != 'private' ||
        scope.zone != 'messageManateeZone' || scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    final current = readForReader(intentId: expected.intentId, currentAuth: currentAuth);
    final message = _store.box<Message>().get(expected.localMessageId)!;
    if (!current.sameSourceAs(expected) || message.dateEdited != null ||
        message.messageSummaryInfo.isNotEmpty) {
      throw StateError('cloud_sync_received_archive_admitted_source_changed');
    }
    if (requireCloudSyncRestoredDirectChat(store: _store, messageScope: scope,
        message: message) != expected.observation.parentBinding || !stillCurrent()) {
      throw StateError('cloud_sync_received_archive_parent_changed');
    }
  }

  /// Synchronous part of the caller's inbox transaction. No Message write and
  /// no replacement of the retained original Found evidence.
  void markReaderAdopted({
    required Store transactionStore, required CloudSyncScope scope,
    required CloudSyncReceivedArchiveAdmissionSource expected,
    required CloudSyncNativeAuthSnapshot currentAuth, required bool Function() stillCurrent,
    required CloudFetchedChange change, required int generation,
  }) {
    validateReaderAdmission(transactionStore: transactionStore, scope: scope,
      expected: expected, currentAuth: currentAuth, stillCurrent: stillCurrent);
    if (generation != expected.observation.generation ||
        change.recordIdHash != expected.observation.serverRecordIdHash ||
        change.type != CloudChangeType.save || change.isTombstone ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(change.changeId)) {
      throw StateError('cloud_sync_received_archive_record_mismatch');
    }
    final row = _readBoundIntent(expected.intentId)
      ..readerChangeId = change.changeId
      ..state = 4;
    _store.box<CloudSyncReceivedArchiveIntentEntity>().put(row);
  }
  /// Synchronous part of the caller's discovery inbox transaction. Same
  /// no-Message-write and no-evidence-replacement guarantees as reader
  /// adoption, but WITHOUT parent proof: the intent carries a source-bound
  /// discovery result whose owner is still unresolved. Newer local edits and
  /// summary info still block adoption. The adopted pending inbox row lets the
  /// ordinary reader retain or project once a parent is proven.
  void markDiscoveryAdopted({
    required Store transactionStore, required CloudSyncScope scope,
    required int intentId,
    required CloudSyncReceivedArchiveSourceBinding source,
    required CloudSyncNativeAuthSnapshot currentAuth, required bool Function() stillCurrent,
    required CloudFetchedChange change, required int generation,
    required int observedAtMs,
  }) {
    if (!identical(transactionStore, _store) || !stillCurrent() ||
        scope.accountFingerprint != _binding.scope.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' || scope.database != 'private' ||
        scope.zone != 'messageManateeZone' || scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    _verifyOwnership();
    if (currentAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    // Direct row read joins the caller's write transaction; the tx-wrapped
    // readMaterializedForInspection must never nest inside it.
    final intent = _readBoundIntent(intentId);
    if (intent.state != 1 && intent.state != 2 ||
        intent.admittedOperationId != null || intent.readerChangeId != null ||
        intent.messageGuidHash != source.messageGuidHash ||
        intent.sourceSha256 != source.sourceSha256) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    final nowSource = CloudSyncReceivedArchiveSourceBinding.decode(
      intent.protectedSourceBinding,
    );
    nowSource.requireOrigin(
      accountFingerprint: intent.accountFingerprint,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
    );
    // Bind the reopened source to the CURRENT protected store as well as the
    // stored intent fields: a same-account row from another store must not
    // adopt here.
    nowSource.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
    );
    if (nowSource.encode() != source.encode()) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    final message = _store.box<Message>().get(intent.localMessageId);
    if (message == null) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    if (message.dateEdited != null || message.messageSummaryInfo.isNotEmpty) {
      throw StateError('cloud_sync_received_archive_admitted_source_changed');
    }
    if (generation == 0 ||
        change.type != CloudChangeType.save || change.isTombstone ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(change.changeId)) {
      throw StateError('cloud_sync_received_archive_record_mismatch');
    }
    // Reuse the already-validated row: this runs synchronously with no awaits
    // between validation and put, and a second _readBoundIntent would reject
    // the state-4 row this adoption is about to write (no observation exists
    // until the ordinary reader proves a parent).
    // Explicit version-2 discovery-reader representation: the state-4 row
    // carries a marker with NO logical hash and NO parent binding, so later
    // journal reads, recovery scans, and reopen validate it without ever
    // mistaking it for a parent-bound observation.
    final observation = CloudSyncReceivedDiscoveryObservation(
      accountFingerprint: source.accountFingerprint,
      protectedStoreIdentity: source.protectedStoreIdentity,
      messageGuidHash: source.messageGuidHash,
      sourceSha256: source.sourceSha256,
      serverRecordIdHash: change.recordIdHash,
      generation: generation,
      observedAtMs: observedAtMs,
    );
    observation.requireSource(source);
    final row = intent
      ..readerChangeId = change.changeId
      ..recordObservationBinding = observation.encode()
      ..state = 4;
    _store.box<CloudSyncReceivedArchiveIntentEntity>().put(row);
  }

  /// Validates a duplicate discovery report without mutating: the supplied
  /// intent/source/auth triple must be bound exactly as an adoption would
  /// require, and a state-4 row must already own this exact change. A
  /// normal-history inbox row owned by another adoption still reports
  /// duplicate, but only after the triple proves linked. Anything else
  /// throws instead of reporting a benign duplicate.
  void validateDiscoveryDuplicate({
    required Store transactionStore, required CloudSyncScope scope,
    required int intentId,
    required CloudSyncReceivedArchiveSourceBinding source,
    required CloudSyncNativeAuthSnapshot currentAuth, required bool Function() stillCurrent,
    required CloudFetchedChange change,
  }) {
    if (!identical(transactionStore, _store) || !stillCurrent() ||
        scope.accountFingerprint != _binding.scope.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' || scope.database != 'private' ||
        scope.zone != 'messageManateeZone' || scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    _verifyOwnership();
    if (currentAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    final intent = _readBoundIntent(intentId);
    if (intent.admittedOperationId != null ||
        intent.messageGuidHash != source.messageGuidHash ||
        intent.sourceSha256 != source.sourceSha256) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    final nowSource = CloudSyncReceivedArchiveSourceBinding.decode(
      intent.protectedSourceBinding,
    );
    nowSource.requireOrigin(
      accountFingerprint: intent.accountFingerprint,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
    );
    nowSource.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
    );
    if (nowSource.encode() != source.encode()) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    if (intent.state == 4) {
      // The adopted row must already own this exact change under the same
      // source-bound marker; otherwise the triple is not linked to it.
      if (intent.readerChangeId != change.changeId ||
          !_isDiscoveryRetained(intent, source)) {
        throw StateError('cloud_sync_received_archive_admission_changed');
      }
      return;
    }
    // A valid unadopted discovery intent whose record the inbox already owns
    // through normal history still reports duplicate after the linkage above.
    if (intent.state != 1 && intent.state != 2 || intent.readerChangeId != null) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
  }

  List<CloudSyncReceivedArchiveAdmissionSource> readCreateCandidates({
    required CloudSyncNativeAuthSnapshot currentAuth, int limit = 5,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    if (limit < 1 || limit > 20) throw ArgumentError('cloud_sync_received_archive_limit_invalid');
    final query = _store.box<CloudSyncReceivedArchiveIntentEntity>().query(
      CloudSyncReceivedArchiveIntentEntity_.accountFingerprint.equals(_binding.scope.accountFingerprint)
        .and(CloudSyncReceivedArchiveIntentEntity_.writerEpoch.equals(_binding.epoch))
        .and(CloudSyncReceivedArchiveIntentEntity_.state.equals(2))
        .and(CloudSyncReceivedArchiveIntentEntity_.recordObservationBinding
          .startsWith('[1,${CloudSyncReceivedRecordState.absent.index},')))
        .order(CloudSyncReceivedArchiveIntentEntity_.updatedAtMs)
        .order(CloudSyncReceivedArchiveIntentEntity_.id).build()..limit = limit;
    try {
      return query.find().where((row) {
        final source = CloudSyncReceivedArchiveSourceBinding.decode(row.protectedSourceBinding);
        return _observationFor(row, source)?.state == CloudSyncReceivedRecordState.absent &&
            _isReady(row, currentAuth);
      }).map((row) => readForCreateAdmission(intentId: row.id, currentAuth: currentAuth)).toList(growable: false);
    } finally { query.close(); }
  });

  /// Metadata snapshot for one absent direct-text origin. A cached absence is
  /// NOT enough: the caller must obtain a fresh native absent-only stage before
  /// invoking the transactional outbox admission below.
  CloudSyncReceivedArchiveAdmissionSource readForCreateAdmission({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    final (intent, _, source) = readMaterializedForInspection(
      intentId: intentId, currentAuth: currentAuth);
    final observation = readRecordObservation(intentId: intentId, currentAuth: currentAuth);
    if (intent.state != 2 || intent.admittedOperationId != null ||
        intent.admittedBinding != null ||
        observation?.state != CloudSyncReceivedRecordState.absent) {
      throw StateError('cloud_sync_received_archive_not_absent');
    }
    return CloudSyncReceivedArchiveAdmissionSource._(intent, source, observation!);
  });

  void validateCreateAdmission({
    required Store transactionStore,
    required CloudSyncScope scope,
    required CloudSyncReceivedArchiveAdmissionSource expected,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) {
    if (!identical(transactionStore, _store) ||
        scope.container != 'com.apple.messages.cloud' || scope.database != 'private' ||
        scope.zone != 'messageManateeZone' ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        scope.accountFingerprint != _binding.scope.accountFingerprint || !stillCurrent()) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    final current = readForCreateAdmission(intentId: expected.intentId, currentAuth: currentAuth);
    if (!current.sameSourceAs(expected)) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    final message = _store.box<Message>().get(expected.localMessageId)!;
    if (message.dateEdited != null || message.messageSummaryInfo.isNotEmpty) {
      // Until received mutation chaining exists, never archive a stale original
      // after learning that it was edited or retracted on another device.
      throw StateError('cloud_sync_received_archive_admitted_source_changed');
    }
    if (requireCloudSyncRestoredDirectChat(store: _store, messageScope: scope,
        message: message) != expected.observation.parentBinding || !stillCurrent()) {
      throw StateError('cloud_sync_received_archive_parent_changed');
    }
  }

  /// A fresh exact read can supersede an earlier Absent. Only that no-raw
  /// predecessor is replaceable; retained Found evidence is never overwritten.
  void replaceAbsenceWithFound({
    required CloudSyncReceivedArchiveAdmissionSource expected,
    required CloudSyncReceivedRecordObservation found,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required void Function() validateParent,
  }) => _store.runInTransaction(TxMode.write, () {
    final current = readForCreateAdmission(intentId: expected.intentId, currentAuth: currentAuth);
    found.requireSource(expected.source);
    if (!stillCurrent() || !current.sameSourceAs(expected) || found.rawReference == null ||
        found.generation != expected.observation.generation ||
        found.parentBinding != expected.observation.parentBinding ||
        found.logicalEntityKeyHash != expected.observation.logicalEntityKeyHash ||
        found.serverRecordIdHash != expected.observation.serverRecordIdHash) {
      throw StateError('cloud_sync_received_archive_observation_changed');
    }
    validateParent();
    if (!stillCurrent()) throw StateError('cloud_sync_received_archive_identity_changed');
    final row = _readBoundIntent(expected.intentId)
      ..recordObservationBinding = found.encode()
      ..state = 1;
    _store.box<CloudSyncReceivedArchiveIntentEntity>().put(row);
  });

  /// Runs inside the outbox Store's synchronous write transaction. A throw
  /// rolls back the outbox, record map and received ownership together.
  void adoptInOutboxTransaction({
    required Store transactionStore,
    required CloudSyncReceivedArchiveAdmissionSource expected,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required CloudOutboxOperation operation,
  }) {
    validateCreateAdmission(transactionStore: transactionStore, scope: operation.scope,
      expected: expected, currentAuth: currentAuth, stillCurrent: stillCurrent);
    if (operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncOutboundPayloadVersion ||
        operation.status != CloudOutboxStatus.pending || operation.attemptCount != 0 ||
        operation.appleRequestUuid != null || operation.appleOperationUuid != null ||
        operation.logicalEntityKeyHash != expected.observation.logicalEntityKeyHash ||
        operation.serverRecordIdHash != expected.observation.serverRecordIdHash ||
        operation.checkpointGeneration != expected.observation.generation ||
        operation.createdAt.millisecondsSinceEpoch != expected.createdAtMs ||
        operation.operationId != CloudOperationIdentity.forInitialCreate(scope: operation.scope,
          logicalEntityKeyHash: operation.logicalEntityKeyHash, payloadVersion: operation.payloadVersion)) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    final intent = _readBoundIntent(expected.intentId);
    intent
      ..state = 3
      ..admittedOperationId = operation.operationId
      ..admittedBinding = _admittedOperationBinding(operation, intent);
    _store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
  }

  /// Source for prepare/readback, not permission to dispatch. In particular,
  /// an unknown outcome can still read back after the local UI row changed.
  CloudSyncReceivedArchiveAdmissionSource? readAdoptedSource({
    required Store transactionStore,
    required CloudOutboxOperation operation,
  }) {
    if (!identical(transactionStore, _store)) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    _verifyOwnership();
    final intent = _readUnique(_store.box<CloudSyncReceivedArchiveIntentEntity>().query(
      CloudSyncReceivedArchiveIntentEntity_.admittedOperationId.equals(operation.operationId)));
    if (intent == null) return null;
    final bound = _readBoundIntent(intent.id);
    final source = CloudSyncReceivedArchiveSourceBinding.decode(bound.protectedSourceBinding);
    final observation = _observationFor(bound, source);
    if (bound.state != 3 || observation == null ||
        observation.state != CloudSyncReceivedRecordState.absent ||
        operation.scope.accountFingerprint != bound.accountFingerprint ||
        operation.scope.container != 'com.apple.messages.cloud' ||
        operation.scope.database != 'private' || operation.scope.zone != 'messageManateeZone' ||
        operation.scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        bound.admittedBinding != _admittedOperationBinding(operation, bound)) {
      throw StateError('cloud_sync_received_archive_admitted_operation_changed');
    }
    return CloudSyncReceivedArchiveAdmissionSource._(bound, source, observation);
  }

  void requireAdoptedDispatch({
    required Store transactionStore, required CloudOutboxOperation operation,
  }) {
    final source = readAdoptedSource(transactionStore: transactionStore, operation: operation);
    if (source == null) throw StateError('cloud_sync_received_archive_admitted_operation_changed');
    final intent = _readBoundIntent(source.intentId);
    final message = _store.box<Message>().get(source.localMessageId);
    final chat = _store.box<Chat>().get(source.localChatId);
    if (message == null || chat == null || message.dateDeleted != null || chat.dateDeleted != null ||
        message.dateEdited != null || message.messageSummaryInfo.isNotEmpty ||
        message.chat.targetId != source.localChatId || message.guid == null ||
        guidHashFor(message.guid!) != source.source.messageGuidHash ||
        message.isFromMe != (intent.origin == CloudSyncReceivedArchiveOrigin.mirrored.index) ||
        _hasOutgoingOverlap(intent, message.guid!)) {
      throw StateError('cloud_sync_received_archive_admitted_source_changed');
    }
    requireCloudSyncAdoptedChatDependency(store: _store, messageScope: operation.scope,
      binding: source.observation.parentBinding, expectedChatId: source.localChatId);
  }

  static String _admittedOperationBinding(CloudOutboxOperation operation,
      CloudSyncReceivedArchiveIntentEntity intent) => _digest([
    'received-create-admission-v1', operation.scope.storageKey, operation.operationId,
    operation.logicalEntityKeyHash, operation.serverRecordIdHash, operation.checkpointGeneration,
    operation.action.name, operation.payloadVersion, operation.mutationRevision,
    operation.encryptedPayloadReference, operation.payloadSha256,
    operation.createdAt.millisecondsSinceEpoch,
    intent.writerEpoch, intent.localMessageId, intent.localChatId,
    intent.protectedSourceBinding, intent.recordObservationBinding,
  ]);

  void adoptRecordObservation({
    required int intentId,
    required CloudSyncReceivedArchiveSourceBinding expectedSource,
    required CloudSyncReceivedRecordObservation observation,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required void Function() validateParent,
  }) => _store.runInTransaction(TxMode.write, () {
    _verifyOwnership();
    if (!stillCurrent() ||
        observation.state == CloudSyncReceivedRecordState.unresolved) {
      throw StateError('cloud_sync_received_archive_observation_changed');
    }
    final intent = _readBoundIntent(intentId);
    observation.requireSource(expectedSource);
    expectedSource.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
    );
    if (intent.state != 1 ||
        intent.protectedSourceBinding != expectedSource.encode()) {
      throw StateError('cloud_sync_received_archive_intent_changed');
    }
    validateParent();
    if (!stillCurrent()) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    final encoded = observation.encode();
    if (intent.recordObservationBinding != null &&
        intent.recordObservationBinding != encoded) {
      throw StateError('cloud_sync_received_archive_observation_changed');
    }
    intent.recordObservationBinding = encoded;
    _store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
  });

  /// Retire only the local inspection work after its retained raw lease has
  /// committed. This is not remote admission, projection or upload success.
  /// A crash before this transaction keeps state1 eligible for exact recommit.
  void markRecordObservationCommitted({
    required int intentId,
    required CloudSyncReceivedArchiveSourceBinding source,
    required CloudSyncReceivedRecordObservation observation,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required void Function() validateParent,
  }) => _store.runInTransaction(TxMode.write, () {
    _verifyOwnership();
    final intent = _readBoundIntent(intentId);
    source.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
    );
    observation.requireSource(source);
    if (!stillCurrent() ||
        (intent.state != 1 && intent.state != 2) ||
        observation.state == CloudSyncReceivedRecordState.unresolved ||
        intent.protectedSourceBinding != source.encode() ||
        intent.recordObservationBinding != observation.encode()) {
      throw StateError('cloud_sync_received_archive_observation_changed');
    }
    validateParent();
    if (!stillCurrent()) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    intent.state = 2;
    _store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
  });

  CloudSyncReceivedRecordObservation? readRecordObservation({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    final intent = _readBoundIntent(intentId);
    if (intent.recordObservationBinding == null) return null;
    final observation = CloudSyncReceivedRecordObservation.decode(
      intent.recordObservationBinding!,
    );
    observation.requireSource(
      readProtectedSource(intentId: intentId, currentAuth: currentAuth),
    );
    return observation;
  });

  /// Exact metadata-ready native source, plus the current persisted row used
  /// solely to resolve its protected parent. Native opens the immutable body.
  (
    CloudSyncReceivedArchiveIntentEntity,
    Message,
    CloudSyncReceivedArchiveSourceBinding,
  )
  readMaterializedForInspection({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    final intent = _readBoundIntent(intentId);
    if ((intent.state != 1 && intent.state != 2) ||
        !_isReady(intent, currentAuth)) {
      throw StateError('cloud_sync_received_archive_not_ready');
    }
    final source = readProtectedSource(
      intentId: intentId,
      currentAuth: currentAuth,
    );
    if (source.isSeed) {
      throw StateError('cloud_sync_received_archive_not_ready');
    }
    return (intent, _store.box<Message>().get(intent.localMessageId)!, source);
  });

  /// Stable ceiling for one worker round. New captures wait for the next
  /// round so continuous traffic cannot indefinitely defer earlier failures.
  int captureReadHighWatermark() => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    final query =
        (_store.box<CloudSyncReceivedArchiveIntentEntity>().query(
              CloudSyncReceivedArchiveIntentEntity_.accountFingerprint
                  .equals(_binding.scope.accountFingerprint)
                  .and(
                    CloudSyncReceivedArchiveIntentEntity_.writerEpoch.equals(
                      _binding.epoch,
                    ),
                  ),
            )..order(
              CloudSyncReceivedArchiveIntentEntity_.id,
              flags: Order.descending,
            ))
            .build()
          ..limit = 1;
    try {
      return query.findFirst()?.id ?? 0;
    } finally {
      query.close();
    }
  });

  /// A live echo of our own journaled send must not acquire received origin.
  bool hasOutgoingOrigin(String messageGuid) =>
      _store.runInTransaction(TxMode.read, () {
        _verifyOwnership();
        return _hasOutgoingGuid(messageGuid);
      });

  bool _hasOutgoingGuid(String messageGuid) {
    final query = _store
        .box<CloudSyncLocalSendIntentEntity>()
        .query(
          CloudSyncLocalSendIntentEntity_.accountFingerprint
              .equals(_binding.scope.accountFingerprint)
              .and(
                CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
                  localSendGuidHashFor(messageGuid),
                ),
              ),
        )
        .build();
    try {
      return query.count() != 0;
    } finally {
      query.close();
    }
  }

  static String intentKeyFor({
    required String accountFingerprint,
    required String messageGuidHash,
  }) => _digest([
    'cloud-sync-received-archive-intent-v1',
    accountFingerprint,
    messageGuidHash,
  ]);

  static String guidHashFor(String guid) =>
      _digest(['cloud-sync-received-archive-guid-v1', guid]);

  static String localSendGuidHashFor(String guid) =>
      _digest(['cloud-sync-local-send-guid-v1', guid]);

  static String _digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  /// Maximum pages scanned by one [readReadyPage] call. Bounds per-call work
  /// while letting valid rows behind a bounded run of invalid head rows
  /// surface instead of starving.
  static const int _maxReadPages = 8;

  /// Durably owns one already-staged incoming source for one Message
  /// persisted atomically in the same transaction. Takes the original
  /// wire plus [liveContext] and runs full capture inside the transaction
  /// on the actually persisted rows. A precomputed identity is never
  /// accepted. Idempotent for the exact same account+GUID/source/parent
  /// plus binding; differing source/row/account/store refuses without
  /// overwriting, preserving any prior capture. Drift before persist
  /// fails capture and rolls back both rows. Native staging supplies the
  /// bound hash/ref via [source]; parent owns that next phase. Do not do
  /// async or UI work in [persistMessage]. Chat must already be persisted.
  int saveReceivedCapture({
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    required int Function() persistMessage,
    required int localChatId,
    required CloudSyncReceivedArchiveSourceBinding source,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _verifyOwnership();
    if (!stillCurrent() || !now.isUtc || now.millisecondsSinceEpoch <= 0) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    if (capturedAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    if (localChatId <= 0) {
      throw StateError('cloud_sync_received_archive_route_changed');
    }
    if (_hasOutgoingGuid(wire.id)) {
      throw StateError('cloud_sync_received_archive_outgoing_overlap');
    }
    // The typed binding is not authentication proof; account/store must
    // agree before persisting. GUID/source agreement is proven after the
    // in-transaction capture below.
    if (source.accountFingerprint != capturedAuth.accountFingerprint ||
        source.accountFingerprint != _binding.scope.accountFingerprint ||
        source.protectedStoreIdentity != capturedAuth.protectedStoreIdentity) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    // Caller-owned atomic persistence plus adoption in one transaction.
    // Synchronous only; no async or UI work is permitted here.
    final localMessageId = persistMessage();
    // The callback can synchronously trigger an account/owner change. Its
    // persistence belongs to this transaction and must roll back with capture.
    _verifyOwnership();
    if (!stillCurrent()) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    if (localMessageId <= 0) {
      throw StateError('cloud_sync_received_archive_route_changed');
    }
    final message = _store.box<Message>().get(localMessageId);
    final chat = _store.box<Chat>().get(localChatId);
    if (message == null || chat == null) {
      throw StateError('cloud_sync_received_archive_route_changed');
    }
    // Message.handle is transient and absent on a raw box read; resolve
    // it in memory exactly as Message.findOne does via getHandle, without
    // writing. Capture below then sees the same sender evidence the live
    // receive path persisted through handleId.
    if (message.handle == null && message.handleId != null) {
      message.handle = _readUnique(
        _store.box<Handle>().query(
          Handle_.originalROWID.equals(message.handleId!),
        ),
      );
    }
    final capture = CloudSyncReceivedArchiveIdentity.capture(
      message: message,
      chat: chat,
      wire: wire,
      liveContext: liveContext,
      expectedSourceSha256: source.sourceSha256,
    );
    final CloudSyncReceivedArchiveIdentity identity;
    if (capture is CloudSyncReceivedArchiveEligible) {
      identity = capture.identity;
    } else if (capture is CloudSyncReceivedArchiveIneligible) {
      throw StateError(capture.reason);
    } else {
      throw StateError('cloud_sync_received_archive_source_changed');
    }
    if (source.messageGuidHash != identity.guidHash ||
        source.sourceSha256 != identity.sourceSha256) {
      throw StateError('cloud_sync_received_archive_protected_source_changed');
    }
    final key = intentKeyFor(
      accountFingerprint: _binding.scope.accountFingerprint,
      messageGuidHash: identity.guidHash,
    );
    final existing = _readUnique(
      _store.box<CloudSyncReceivedArchiveIntentEntity>().query(
        CloudSyncReceivedArchiveIntentEntity_.intentKey.equals(key),
      ),
    );
    final encoded = source.encode();
    if (existing != null) {
      final bound = _readBoundIntent(existing.id);
      if (bound.localMessageId != localMessageId ||
          bound.localChatId != localChatId ||
          bound.messageGuidHash != identity.guidHash ||
          bound.sourceSha256 != identity.sourceSha256 ||
          bound.origin != identity.origin.index ||
          bound.protectedSourceBinding != encoded) {
        throw StateError('cloud_sync_received_archive_intent_changed');
      }
      return bound.id;
    }
    final time = now.millisecondsSinceEpoch;
    return _store.box<CloudSyncReceivedArchiveIntentEntity>().put(
      CloudSyncReceivedArchiveIntentEntity(
        intentKey: key,
        accountFingerprint: _binding.scope.accountFingerprint,
        writerEpoch: _binding.epoch,
        localMessageId: localMessageId,
        localChatId: localChatId,
        messageGuidHash: identity.guidHash,
        sourceSha256: identity.sourceSha256,
        origin: identity.origin.index,
        protectedSourceBinding: encoded,
        state: 0,
        createdAtMs: time,
        updatedAtMs: time,
      ),
    );
  });

  /// Recovers the exact adopted lease after crash. Never rolls back.
  CloudSyncReceivedArchiveSourceBinding? findProtectedSource({
    required String messageGuid,
    required int localChatId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    if (currentAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    final key = intentKeyFor(
      accountFingerprint: currentAuth.accountFingerprint,
      messageGuidHash: guidHashFor(messageGuid),
    );
    final found = _readUnique(
      _store.box<CloudSyncReceivedArchiveIntentEntity>().query(
        CloudSyncReceivedArchiveIntentEntity_.intentKey.equals(key),
      ),
    );
    if (found == null) return null;
    final existing = _readBoundIntent(found.id);
    if (existing.localChatId != localChatId) {
      throw StateError('cloud_sync_received_archive_route_changed');
    }
    final source = CloudSyncReceivedArchiveSourceBinding.decode(
      existing.protectedSourceBinding,
    );
    source.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      messageGuidHash: existing.messageGuidHash,
      sourceSha256: existing.sourceSha256,
    );
    return source;
  });

  /// Atomically replaces a retained encrypted retry seed with its native-staged
  /// descriptor. Exact immutable source equality is necessary, not upload
  /// authority. A lost commit response keeps this descriptor for recommit.
  void adoptMaterializedSource({
    required int intentId,
    required CloudSyncReceivedArchiveSourceBinding seed,
    required CloudSyncReceivedArchiveSourceBinding staged,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) => _store.runInTransaction(TxMode.write, () {
    _verifyOwnership();
    if (!stillCurrent() || !seed.isSeed || staged.isSeed) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    final intent = _readBoundIntent(intentId);
    seed.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
    );
    staged.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
    );
    if (intent.protectedSourceBinding != seed.encode()) {
      if (intent.protectedSourceBinding == staged.encode()) return;
      throw StateError('cloud_sync_received_archive_intent_changed');
    }
    intent.protectedSourceBinding = staged.encode();
    _store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
  });

  /// A successful local commit suppresses repeated materialization. It is
  /// not remote admission or evidence of a CloudKit save.
  void markSourceMaterialized({
    required int intentId,
    required CloudSyncReceivedArchiveSourceBinding source,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) => _store.runInTransaction(TxMode.write, () {
    _verifyOwnership();
    if (!stillCurrent() || source.isSeed) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    final intent = _readBoundIntent(intentId);
    source.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
    );
    if (intent.protectedSourceBinding != source.encode()) {
      throw StateError('cloud_sync_received_archive_intent_changed');
    }
    // An idempotent source recommit cannot undo completed local inspection.
    if (intent.state == 0) intent.state = 1;
    _store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
  });

  /// Recovers the exact adopted lease after crash. Never rolls back.
  CloudSyncReceivedArchiveSourceBinding readProtectedSource({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    final intent = _readBoundIntent(intentId);
    final source = CloudSyncReceivedArchiveSourceBinding.decode(
      intent.protectedSourceBinding,
    );
    source.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
    );
    return source;
  });

  /// Bounded resumable read of staged candidates. Metadata-ready only,
  /// never upload authority: a returned row proves journal ownership plus
  /// parent binding, GUID-hash equality, direction, legacy-flag and sender
  /// evidence, not full source content. Post-adoption local body edits are
  /// not detected here; full wire plus protected-source revalidation
  /// remains the separate admission job. Filters (never throws for)
  /// per-row mismatches; ownership and auth mismatches still fail closed
  /// for the whole read. Record-map/snapshot dedup against Apple records
  /// requires existing native canonical key hashes at separate admission
  /// and is explicitly gated here.
  ///
  /// Keyset pagination (stable updatedAt/id order, never mutable offset)
  /// with a caller-held opaque [cursor]: each call scans at most
  /// [_maxReadPages] pages of `limit` rows, skipping invalid rows without
  /// ever stalling behind them. The caller must drive the drain loop to
  /// [CloudSyncReceivedArchiveReadPage.exhausted], holding the returned
  /// [CloudSyncReceivedArchiveReadPage.nextCursor] between calls. The
  /// cursor is pinned to the current account/epoch and is rejected after
  /// an owner change; restart the drain from null then. The cursor itself
  /// grants nothing and is not upload authority. Permanently invalid rows
  /// are left for explicit disposition, never silently retired.
  CloudSyncReceivedArchiveReadPage readReadyPage({
    int limit = 50,
    required CloudSyncNativeAuthSnapshot currentAuth,
    String? cursor,
    bool onlyPendingMaterialization = false,
    int? maximumIntentId,
  }) => _store.runInTransaction(TxMode.read, () {
    if (limit < 1 || limit > 50) {
      throw ArgumentError('cloud_sync_received_archive_limit_invalid');
    }
    if (maximumIntentId != null && maximumIntentId < 0) {
      throw ArgumentError('cloud_sync_received_archive_limit_invalid');
    }
    _verifyOwnership();
    if (currentAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    final resume = _decodeCursor(cursor);
    final ready = <CloudSyncReceivedArchiveIntentEntity>[];
    var scanned = 0;
    var pages = 0;
    var afterUpdatedAt = resume.updatedAtMs;
    var afterId = resume.id;
    // Keyset applies from the second page on even when the call started
    // without a cursor; otherwise every page would rescan the same head
    // rows and a long stale run would stall the drain within one call.
    var keyed = resume.active;
    var exhausted = false;
    CloudSyncReceivedArchiveIntentEntity? lastScanned;
    while (ready.length < limit && pages < _maxReadPages) {
      var base = CloudSyncReceivedArchiveIntentEntity_.accountFingerprint
          .equals(_binding.scope.accountFingerprint)
          .and(
            CloudSyncReceivedArchiveIntentEntity_.writerEpoch.equals(
              _binding.epoch,
            ),
          )
          .and(
            onlyPendingMaterialization
                ? CloudSyncReceivedArchiveIntentEntity_.state.equals(0)
                : CloudSyncReceivedArchiveIntentEntity_.state.oneOf([0, 1]),
          );
      if (maximumIntentId != null) {
        base = base.and(
          CloudSyncReceivedArchiveIntentEntity_.id.lessOrEqual(maximumIntentId),
        );
      }
      final scoped = keyed
          ? base.and(
              CloudSyncReceivedArchiveIntentEntity_.updatedAtMs
                  .greaterThan(afterUpdatedAt)
                  .or(
                    CloudSyncReceivedArchiveIntentEntity_.updatedAtMs
                        .equals(afterUpdatedAt)
                        .and(
                          CloudSyncReceivedArchiveIntentEntity_.id.greaterThan(
                            afterId,
                          ),
                        ),
                  ),
            )
          : base;
      final query =
          _store
              .box<CloudSyncReceivedArchiveIntentEntity>()
              .query(scoped)
              .order(CloudSyncReceivedArchiveIntentEntity_.updatedAtMs)
              .order(CloudSyncReceivedArchiveIntentEntity_.id)
              .build()
            ..limit = limit;
      final List<CloudSyncReceivedArchiveIntentEntity> page;
      try {
        page = query.find();
      } finally {
        query.close();
      }
      if (page.isEmpty) {
        exhausted = true;
        break;
      }
      pages++;
      for (final candidate in page) {
        if (ready.length >= limit) break;
        lastScanned = candidate;
        scanned++;
        if (_isReady(candidate, currentAuth)) ready.add(candidate);
      }
      // Do not consume an unvisited tail merely because it was prefetched.
      // The next call must start after the last row actually considered.
      if (ready.length >= limit) break;
      if (page.length < limit) {
        exhausted = true;
        break;
      }
      afterUpdatedAt = page.last.updatedAtMs;
      afterId = page.last.id;
      keyed = true;
    }
    return CloudSyncReceivedArchiveReadPage(
      ready: List<CloudSyncReceivedArchiveIntentEntity>.unmodifiable(ready),
      scanned: scanned,
      nextCursor: exhausted || lastScanned == null
          ? null
          : _encodeCursor(lastScanned.updatedAtMs, lastScanned.id),
      exhausted: exhausted,
    );
  });

  /// Fair round-robin bump without changing immutable origin. Blocked rows
  /// stay ready and cannot monopolize a bounded worker.
  /// A reader-owned row may surface a lost native commit response; leave its
  /// timestamp and ownership intact so normal inbox recovery can finish it.
  void markReaderAttemptConsidered({required int intentId, required DateTime now}) =>
      _store.runInTransaction(TxMode.write, () {
        _verifyOwnership();
        final intent = _readBoundIntent(intentId);
        if (intent.state == 4) return;
        markReadConsidered(intentId: intentId, now: now);
      });

  /// Fair round-robin bump for a source not yet handed to another owner.
  void markReadConsidered({required int intentId, required DateTime now}) =>
      _store.runInTransaction(TxMode.write, () {
        _verifyOwnership();
        if (!now.isUtc || now.millisecondsSinceEpoch <= 0) {
          throw StateError('cloud_sync_received_archive_time_invalid');
        }
        final intent = _readBoundIntent(intentId);
        if (intent.state < 0 || intent.state > 2) {
          throw StateError('cloud_sync_received_archive_not_ready');
        }
        final observed = now.millisecondsSinceEpoch;
        intent.updatedAtMs = observed > intent.updatedAtMs
            ? observed
            : intent.updatedAtMs + 1;
        _store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
      });

  /// Read-only integration point for restart GC. Returns live protected
  /// blob references owned by ALL durable received rows, regardless of
  /// writer epoch, account, or state: a retained old-epoch row still owns
  /// its evidence. Malformed ownership fails closed. Bounded read-only
  /// scan; never promotes, mutates, or releases. Production GC uses the
  /// complete ObjectBoxCloudSyncStore inventory, not this consumer's scope.
  Set<String> readLiveReceivedArchiveReferences({required int maximumCount}) =>
      _store.runInTransaction(TxMode.read, () {
        if (maximumCount <= 0 || maximumCount > 4096) {
          throw ArgumentError('cloud_sync_received_archive_limit_invalid');
        }
        _verifyOwnership();
        final query = _store
            .box<CloudSyncReceivedArchiveIntentEntity>()
            .query()
            .build();
        try {
          if (query.count() > maximumCount) {
            throw StateError('cloud_sync_received_archive_not_ready');
          }
          final refs = <String>{};
          for (final intent in query.find()) {
            // Retain every durable row; never silently drop an old-epoch
            // row that still owns evidence. Malformed ownership fails closed.
            if (intent.intentKey !=
                    intentKeyFor(
                      accountFingerprint: intent.accountFingerprint,
                      messageGuidHash: intent.messageGuidHash,
                    ) ||
                !_hasConsistentBinding(intent)) {
              throw StateError('cloud_sync_received_archive_intent_changed');
            }
            final src = CloudSyncReceivedArchiveSourceBinding.decode(
              intent.protectedSourceBinding,
            );
            if (!src.isSeed) refs.add(src.protectedReference);
            final observation = _observationFor(intent, src);
            if (observation?.rawReference != null) {
              refs.add(observation!.rawReference!);
            }
            if (refs.length > maximumCount) {
              throw StateError('cloud_sync_received_archive_limit_invalid');
            }
          }
          return Set<String>.unmodifiable(refs);
        } finally {
          query.close();
        }
      });

  /// Read-only integration point for crash-handoff lease recovery.
  /// Returns live lease references owned by ALL durable received rows,
  /// regardless of writer epoch, account, or state. Malformed ownership
  /// fails closed. Bounded read-only diagnostic scan.
  Set<String> readLiveReceivedArchiveLeaseReferences({
    required int maximumCount,
  }) => _store.runInTransaction(TxMode.read, () {
    if (maximumCount <= 0 || maximumCount > 4096) {
      throw ArgumentError('cloud_sync_received_archive_limit_invalid');
    }
    _verifyOwnership();
    final query = _store
        .box<CloudSyncReceivedArchiveIntentEntity>()
        .query()
        .build();
    try {
      if (query.count() > maximumCount) {
        throw StateError('cloud_sync_received_archive_not_ready');
      }
      final leases = <String>{};
      for (final intent in query.find()) {
        // Same retain-all-or-fail-closed contract as the blob helper.
        if (intent.intentKey !=
                intentKeyFor(
                  accountFingerprint: intent.accountFingerprint,
                  messageGuidHash: intent.messageGuidHash,
                ) ||
            !_hasConsistentBinding(intent)) {
          throw StateError('cloud_sync_received_archive_intent_changed');
        }
        final src = CloudSyncReceivedArchiveSourceBinding.decode(
          intent.protectedSourceBinding,
        );
        if (!src.isSeed) leases.add(src.leaseReference);
        final observation = _observationFor(intent, src);
        if (observation?.rawLeaseReference != null) {
          leases.add(observation!.rawLeaseReference!);
        }
        if (leases.length > maximumCount) {
          throw StateError('cloud_sync_received_archive_limit_invalid');
        }
      }
      return Set<String>.unmodifiable(leases);
    } finally {
      query.close();
    }
  });

  bool _isReady(
    CloudSyncReceivedArchiveIntentEntity candidate,
    CloudSyncNativeAuthSnapshot currentAuth, {
    bool allowCloudMapping = false,
  }
  ) {
    try {
      if (candidate.accountFingerprint != _binding.scope.accountFingerprint ||
          candidate.writerEpoch != _binding.epoch ||
          (candidate.state < 0 || candidate.state > 2) ||
          candidate.intentKey !=
              intentKeyFor(
                accountFingerprint: candidate.accountFingerprint,
                messageGuidHash: candidate.messageGuidHash,
              )) {
        return false;
      }
      final source = CloudSyncReceivedArchiveSourceBinding.decode(
        candidate.protectedSourceBinding,
      );
      source.requireOrigin(
        accountFingerprint: currentAuth.accountFingerprint,
        messageGuidHash: candidate.messageGuidHash,
        sourceSha256: candidate.sourceSha256,
        protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      );
      final message = _store.box<Message>().get(candidate.localMessageId);
      final chat = _store.box<Chat>().get(candidate.localChatId);
      if (message == null ||
          chat == null ||
          message.dateDeleted != null ||
          message.id != candidate.localMessageId ||
          chat.id != candidate.localChatId) {
        return false;
      }
      // Exact parent relationship from the live rows.
      final boundChatId = message.chat.targetId;
      if (boundChatId != candidate.localChatId) return false;
      if (chat.dateDeleted != null) return false;
      final guid = message.guid;
      if (guid == null || guidHashFor(guid) != candidate.messageGuidHash) {
        return false;
      }
      final bool expectFromMe =
          candidate.origin == CloudSyncReceivedArchiveOrigin.mirrored.index;
      if (candidate.origin != CloudSyncReceivedArchiveOrigin.incoming.index &&
          candidate.origin != CloudSyncReceivedArchiveOrigin.mirrored.index) {
        return false;
      }
      if (message.isFromMe != expectFromMe) return false;
      if (!allowCloudMapping && (message.ckRecordId != null || message.ckSyncState == true)) {
        return false;
      }
      // Sender evidence still exists (transient handle or handleId lookup).
      if (!_hasSenderEvidence(message)) return false;
      // Outgoing-intent overlap: an echoed local send must not acquire a
      // second received identity. Checked by row and by recomputed
      // local-send GUID hash from the live GUID (exact, no cross-lane
      // guessing). Record-map/snapshot dedup is gated to separate
      // admission with existing native canonical key hashes.
      if (_hasOutgoingOverlap(candidate, guid)) return false;
      return true;
    } on StateError {
      return false;
    }
  }

  bool _hasSenderEvidence(Message message) {
    final direct = message.handle;
    if (direct != null) {
      if (direct.address.isEmpty) return false;
      final rowId = message.handleId;
      final handleRowId = direct.originalROWID;
      if (rowId != null && handleRowId != null && rowId != handleRowId) {
        return false;
      }
      return true;
    }
    final handleId = message.handleId;
    if (handleId == null) return false;
    final found = _readUnique(
      _store.box<Handle>().query(Handle_.originalROWID.equals(handleId)),
    );
    return found != null && found.address.isNotEmpty;
  }

  bool _hasOutgoingOverlap(
    CloudSyncReceivedArchiveIntentEntity candidate,
    String guid,
  ) {
    final byRow = _store
        .box<CloudSyncLocalSendIntentEntity>()
        .query(
          CloudSyncLocalSendIntentEntity_.localMessageId.equals(
            candidate.localMessageId,
          ),
        )
        .build();
    try {
      for (final row in byRow.find()) {
        if (row.accountFingerprint == candidate.accountFingerprint) {
          return true;
        }
      }
    } finally {
      byRow.close();
    }
    final localSendHash = localSendGuidHashFor(guid);
    final byGuid = _store
        .box<CloudSyncLocalSendIntentEntity>()
        .query(
          CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(localSendHash),
        )
        .build();
    try {
      for (final row in byGuid.find()) {
        if (row.accountFingerprint == candidate.accountFingerprint) {
          return true;
        }
      }
    } finally {
      byGuid.close();
    }
    return false;
  }

  CloudSyncReceivedArchiveIntentEntity _readBoundIntent(int intentId) {
    final intent = intentId > 0
        ? _store.box<CloudSyncReceivedArchiveIntentEntity>().get(intentId)
        : null;
    if (intent == null ||
        intent.accountFingerprint != _binding.scope.accountFingerprint ||
        intent.writerEpoch != _binding.epoch ||
        (intent.state < 0 || intent.state > 4) ||
        (intent.origin != CloudSyncReceivedArchiveOrigin.incoming.index &&
            intent.origin != CloudSyncReceivedArchiveOrigin.mirrored.index) ||
        intent.intentKey !=
            intentKeyFor(
              accountFingerprint: intent.accountFingerprint,
              messageGuidHash: intent.messageGuidHash,
            ) ||
        !_hasConsistentBinding(intent)) {
      throw StateError('cloud_sync_received_archive_intent_changed');
    }
    return intent;
  }

  static bool _hasConsistentBinding(
    CloudSyncReceivedArchiveIntentEntity intent,
  ) {
    try {
      final source = CloudSyncReceivedArchiveSourceBinding.decode(
        intent.protectedSourceBinding,
      );
      if (intent.state >= 1 && source.isSeed) return false;
      final observation = _observationFor(intent, source);
      final isDiscovery = _isDiscoveryRetained(intent, source);
      // Version-2 discovery markers are only valid on adopted state-4 rows.
      // A marker in the wrong state, a malformed marker, or one bound to a
      // different source fails closed instead of passing as an unobserved row.
      if (CloudSyncReceivedDiscoveryObservation.isEncoded(intent.recordObservationBinding) &&
          (intent.state != 4 || !isDiscovery)) {
        return false;
      }
      if (intent.state >= 2 &&
          (observation == null ||
              observation.state == CloudSyncReceivedRecordState.unresolved) &&
          !(intent.state == 4 && isDiscovery)) {
        return false;
      }
      if (intent.state == 3 &&
          (intent.admittedOperationId == null || intent.admittedBinding == null ||
              observation?.state != CloudSyncReceivedRecordState.absent)) {
        return false;
      }
    if (intent.state == 4 &&
        (intent.readerChangeId == null ||
            ((observation?.state != CloudSyncReceivedRecordState.equivalent &&
                    observation?.state !=
                        CloudSyncReceivedRecordState.needsProjection) &&
                !_isDiscoveryRetained(intent, source)) ||
            intent.admittedOperationId != null)) {
      return false;
    }
      source.requireOrigin(
        accountFingerprint: intent.accountFingerprint,
        messageGuidHash: intent.messageGuidHash,
        sourceSha256: intent.sourceSha256,
      );
    } on StateError {
      return false;
    }
    return true;
  }

  /// Accepts a version-2 source-bound discovery marker as a valid durable
  /// discovery-owned record. Anything else, including a malformed marker or
  /// one bound to a different source, fails closed like any other check.
  static bool _isDiscoveryRetained(
    CloudSyncReceivedArchiveIntentEntity intent,
    CloudSyncReceivedArchiveSourceBinding source,
  ) {
    try {
      final value = intent.recordObservationBinding;
      if (!CloudSyncReceivedDiscoveryObservation.isEncoded(value)) {
        return false;
      }
      CloudSyncReceivedDiscoveryObservation.decode(value!).requireSource(source);
      return true;
    } on StateError {
      return false;
    }
  }

  static CloudSyncReceivedRecordObservation? _observationFor(
    CloudSyncReceivedArchiveIntentEntity intent,
    CloudSyncReceivedArchiveSourceBinding source,
  ) {
    final value = intent.recordObservationBinding;
    if (value == null) return null;
    // Version-2 discovery markers are a different representation, never a
    // parent-bound observation. Callers needing discovery state decode it
    // explicitly so the two can never be mistaken.
    if (CloudSyncReceivedDiscoveryObservation.isEncoded(value)) return null;
    final observation = CloudSyncReceivedRecordObservation.decode(value);
    observation.requireSource(source);
    return observation;
  }

  T? _readUnique<T>(QueryBuilder<T> builder) {
    final query = builder.build();
    try {
      return query.findUnique();
    } finally {
      query.close();
    }
  }

  void _verifyOwnership() {
    if (_binding.owner != CloudKitWriterOwner.v2 ||
        _binding.epoch <= 0 ||
        _binding.scope.container != 'com.apple.messages.cloud' ||
        _binding.scope.database != 'private') {
      throw StateError('cloud_sync_received_archive_owner_invalid');
    }
    final current = _authority.read(_binding.scope);
    if (current == null ||
        current.owner != _binding.owner ||
        current.epoch != _binding.epoch) {
      throw StateError('cloud_sync_received_archive_owner_changed');
    }
  }

  /// Opaque resume point for [readReadyPage]. `active` is false for the
  /// initial call (no cursor). The cursor pins the drain to one account
  /// and writer epoch; any mismatch fails the call closed.
  ({bool active, int updatedAtMs, int id}) _decodeCursor(String? cursor) {
    if (cursor == null) return (active: false, updatedAtMs: 0, id: 0);
    if (cursor.length > 512) {
      throw ArgumentError('cloud_sync_received_archive_cursor_invalid');
    }
    final dynamic fields;
    try {
      fields = jsonDecode(utf8.decode(base64Url.decode(cursor)));
    } on FormatException {
      throw ArgumentError('cloud_sync_received_archive_cursor_invalid');
    }
    if (fields is! List ||
        fields.length != 5 ||
        fields[0] != 1 ||
        fields[1] is! String ||
        fields[2] is! int ||
        fields[3] is! int ||
        fields[4] is! int) {
      throw ArgumentError('cloud_sync_received_archive_cursor_invalid');
    }
    if (fields[1] != _binding.scope.accountFingerprint ||
        fields[2] != _binding.epoch ||
        fields[3] <= 0 ||
        fields[4] <= 0) {
      throw ArgumentError('cloud_sync_received_archive_cursor_invalid');
    }
    return (active: true, updatedAtMs: fields[3] as int, id: fields[4] as int);
  }

  String _encodeCursor(int updatedAtMs, int id) => base64Url.encode(
    utf8.encode(
      jsonEncode([
        1,
        _binding.scope.accountFingerprint,
        _binding.epoch,
        updatedAtMs,
        id,
      ]),
    ),
  );
}

/// Immutable metadata passed from source validation to the same-store outbox
/// transaction. The original protected source, not a mutable Message, encodes
/// the archive body. No local-send receipt is synthesized by this snapshot.
final class CloudSyncReceivedArchiveAdmissionSource {
  CloudSyncReceivedArchiveAdmissionSource._(
    CloudSyncReceivedArchiveIntentEntity intent, this.source, this.observation,
  ) : intentId = intent.id, localMessageId = intent.localMessageId,
      localChatId = intent.localChatId, writerEpoch = intent.writerEpoch,
      createdAtMs = intent.createdAtMs, admittedOperationId = intent.admittedOperationId;

  final int intentId, localMessageId, localChatId, writerEpoch, createdAtMs;
  final String? admittedOperationId;
  final CloudSyncReceivedArchiveSourceBinding source;
  final CloudSyncReceivedRecordObservation observation;
  bool sameSourceAs(CloudSyncReceivedArchiveAdmissionSource other) =>
    intentId == other.intentId && localMessageId == other.localMessageId &&
    localChatId == other.localChatId && writerEpoch == other.writerEpoch &&
    createdAtMs == other.createdAtMs && admittedOperationId == other.admittedOperationId &&
    source.encode() == other.source.encode() && observation.encode() == other.observation.encode();
  @override
  String toString() => 'CloudSyncReceivedArchiveAdmissionSource(redacted)';
}

/// Bounded read-only page from
/// [CloudSyncReceivedArchiveJournal.readReadyPage]. The cursor is opaque,
/// caller-held drain state: it grants nothing and is not upload authority.
final class CloudSyncReceivedArchiveReadPage {
  const CloudSyncReceivedArchiveReadPage({
    required this.ready,
    required this.scanned,
    required this.nextCursor,
    required this.exhausted,
  });

  /// Metadata-ready intents, at most the requested limit.
  final List<CloudSyncReceivedArchiveIntentEntity> ready;

  /// Journal rows validated (ready or skipped) during this call.
  final int scanned;

  /// Resume point for the next call, or null when [exhausted].
  final String? nextCursor;

  /// True only when this call proved no unscanned rows remain.
  final bool exhausted;

  @override
  String toString() =>
      'CloudSyncReceivedArchiveReadPage(ready=${ready.length}, scanned=$scanned, exhausted=$exhausted)';
}
