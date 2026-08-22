import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

enum LegacyCloudKitDeletionKind { message, attachment, chat }

enum CloudKitDeletionIntentState { pending, quarantined }

final class LegacyCloudKitDeletionContext {
  const LegacyCloudKitDeletionContext({
    required this.scope,
    required this.writerEpoch,
  }) : assert(writerEpoch > 0);

  final CloudKitWriterScope scope;
  final int writerEpoch;
}

final class LegacyCloudKitDeletionIntent {
  const LegacyCloudKitDeletionIntent({
    required this.id,
    required this.scope,
    required this.writerEpoch,
    required this.kind,
    required this.recordId,
  });

  final int id;
  final CloudKitWriterScope scope;
  final int writerEpoch;
  final LegacyCloudKitDeletionKind kind;
  final String recordId;
}

final class LegacyCloudKitDeletionIntentFailure implements Exception {
  const LegacyCloudKitDeletionIntentFailure(this.safeCode);

  final String safeCode;

  @override
  String toString() => 'LegacyCloudKitDeletionIntentFailure($safeCode)';
}

/// Durable adapter for the legacy CloudKit delete API.
///
/// The old implementation stored three account-less StringLists in
/// SharedPreferences. This adapter accepts only a complete scope plus the
/// authority epoch that admitted the delete. It also checks the durable
/// authority again when selecting a remote batch, so an old process cannot
/// send a target after an account switch or writer transition.
final class LegacyCloudKitDeletionIntentStore {
  LegacyCloudKitDeletionIntentStore({
    required Store store,
    ObjectBoxCloudKitWriterAuthority? authority,
  }) : _store = store,
       _intents = store.box<CloudKitDeletionIntentEntity>(),
       _quarantines = store.box<CloudKitDeletionQuarantineEntity>(),
       _authority = authority ?? ObjectBoxCloudKitWriterAuthority(store: store);

  static const legacyMessageKey = 'messageDeletionIds-1';
  static const legacyAttachmentKey = 'attachmentDeletionIds-1';
  static const legacyChatKey = 'chatDeletionIds-1';

  static const _pendingState = 0;
  static const _quarantinedState = 1;

  final Store _store;
  final Box<CloudKitDeletionIntentEntity> _intents;
  final Box<CloudKitDeletionQuarantineEntity> _quarantines;
  final ObjectBoxCloudKitWriterAuthority _authority;

  void enqueue({
    required LegacyCloudKitDeletionContext context,
    required LegacyCloudKitDeletionKind kind,
    required String recordId,
    required DateTime now,
  }) {
    _validateRecordId(recordId);
    final key = _intentKey(context, kind, recordId);
    final timestamp = now.millisecondsSinceEpoch;
    _store.runInTransaction(TxMode.write, () {
      final query = _intents
          .query(CloudKitDeletionIntentEntity_.intentKey.equals(key))
          .build();
      try {
        final existing = query.findFirst();
        if (existing != null) {
          if (existing.accountFingerprint != context.scope.accountFingerprint ||
              existing.container != context.scope.container ||
              existing.database != context.scope.database ||
              existing.writerEpoch != context.writerEpoch ||
              existing.kind != _kindCode(kind) ||
              existing.recordId != recordId) {
            throw const LegacyCloudKitDeletionIntentFailure(
              'cloudkit_delete_intent_identity_collision',
            );
          }
          return;
        }
      } finally {
        query.close();
      }

      _intents.put(
        CloudKitDeletionIntentEntity(
          intentKey: key,
          accountFingerprint: context.scope.accountFingerprint,
          container: context.scope.container,
          database: context.scope.database,
          writerEpoch: context.writerEpoch,
          kind: _kindCode(kind),
          recordId: recordId,
          createdAtMs: timestamp,
          updatedAtMs: timestamp,
        ),
      );
    });
  }

  /// Returns only targets authorized by the currently durable legacy writer.
  /// A stale requested epoch therefore returns no target, even if a caller
  /// still holds an old in-memory context.
  List<LegacyCloudKitDeletionIntent> pendingForFlush({
    required CloudKitWriterScope scope,
    required int writerEpoch,
    required LegacyCloudKitDeletionKind kind,
  }) {
    if (writerEpoch <= 0) return const [];
    final snapshot = _authority.read(scope);
    if (snapshot == null ||
        snapshot.owner != CloudKitWriterOwner.legacy ||
        snapshot.state != CloudKitWriterAuthorityState.stable ||
        snapshot.epoch != writerEpoch) {
      return const [];
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.write, () {
      _quarantineStaleRows(scope, writerEpoch, now);
      final query = _intents
          .query(
            CloudKitDeletionIntentEntity_.accountFingerprint.equals(
                  scope.accountFingerprint,
                ) &
                CloudKitDeletionIntentEntity_.container.equals(
                  scope.container,
                ) &
                CloudKitDeletionIntentEntity_.database.equals(scope.database) &
                CloudKitDeletionIntentEntity_.writerEpoch.equals(writerEpoch) &
                CloudKitDeletionIntentEntity_.kind.equals(_kindCode(kind)) &
                CloudKitDeletionIntentEntity_.state.equals(_pendingState),
          )
          .build();
      try {
        return query
            .find()
            .map(
              (entity) => LegacyCloudKitDeletionIntent(
                id: entity.id,
                scope: scope,
                writerEpoch: entity.writerEpoch,
                kind: _kindFromCode(entity.kind),
                recordId: entity.recordId,
              ),
            )
            .toList(growable: false);
      } finally {
        query.close();
      }
    });
  }

  /// Removes exactly the intents that the corresponding legacy API confirmed.
  /// A changed scope or epoch is rejected and leaves every row durable.
  void confirmFlushed({
    required LegacyCloudKitDeletionContext context,
    required LegacyCloudKitDeletionKind kind,
    required List<LegacyCloudKitDeletionIntent> intents,
  }) {
    if (intents.isEmpty) return;
    final snapshot = _authority.read(context.scope);
    if (snapshot == null ||
        snapshot.owner != CloudKitWriterOwner.legacy ||
        snapshot.state != CloudKitWriterAuthorityState.stable ||
        snapshot.epoch != context.writerEpoch) {
      throw const LegacyCloudKitDeletionIntentFailure(
        'cloudkit_delete_intent_confirmation_scope_stale',
      );
    }

    _store.runInTransaction(TxMode.write, () {
      for (final intent in intents) {
        final entity = _intents.get(intent.id);
        if (entity == null ||
            entity.state != _pendingState ||
            entity.accountFingerprint != context.scope.accountFingerprint ||
            entity.container != context.scope.container ||
            entity.database != context.scope.database ||
            entity.writerEpoch != context.writerEpoch ||
            entity.kind != _kindCode(kind) ||
            entity.recordId != intent.recordId) {
          throw const LegacyCloudKitDeletionIntentFailure(
            'cloudkit_delete_intent_confirmation_mismatch',
          );
        }
      }
      for (final intent in intents) {
        _intents.remove(intent.id);
      }
    });
  }

  /// Moves stale rows for one scope out of the sendable state.
  int quarantineStale({
    required CloudKitWriterScope scope,
    required int currentWriterEpoch,
    required DateTime now,
  }) {
    if (currentWriterEpoch <= 0) return 0;
    return _store.runInTransaction(TxMode.write, () {
      return _quarantineStaleRows(
        scope,
        currentWriterEpoch,
        now.millisecondsSinceEpoch,
      );
    });
  }

  /// Quarantines every pre-V2 preference value before any legacy sync can
  /// inspect it. The values are retained as evidence and never become a
  /// scoped pending intent.
  Future<int> quarantineLegacySharedPreferenceQueues(
    SharedPreferences prefs, {
    required DateTime now,
  }) async {
    final entries = <(String, String)>[];
    final presentKeys = <String>[];
    for (final sourceKey in const [
      legacyMessageKey,
      legacyAttachmentKey,
      legacyChatKey,
    ]) {
      final value = prefs.get(sourceKey);
      if (value == null) continue;
      presentKeys.add(sourceKey);
      if (value is List && value.every((item) => item is String)) {
        for (final recordId in value.cast<String>()) {
          entries.add((sourceKey, recordId));
        }
      } else {
        entries.add((sourceKey, '<malformed-value>'));
      }
    }

    if (entries.isEmpty) {
      await Future.wait(presentKeys.map((key) => prefs.remove(key)));
      return 0;
    }
    final timestamp = now.millisecondsSinceEpoch;
    final inserted = _store.runInTransaction(TxMode.write, () {
      var count = 0;
      for (final (sourceKey, recordId) in entries) {
        final key = _quarantineKey(sourceKey, recordId);
        final query = _quarantines
            .query(CloudKitDeletionQuarantineEntity_.quarantineKey.equals(key))
            .build();
        try {
          if (query.findFirst() != null) continue;
        } finally {
          query.close();
        }
        _quarantines.put(
          CloudKitDeletionQuarantineEntity(
            quarantineKey: key,
            sourceKey: sourceKey,
            recordId: recordId,
            reason: 'legacy_unscoped_shared_preferences',
            createdAtMs: timestamp,
          ),
        );
        count++;
      }
      return count;
    });

    // Removal happens only after durable quarantine succeeds. Re-running is
    // idempotent because quarantineKey is unique.
    await Future.wait(presentKeys.map((key) => prefs.remove(key)));
    return inserted;
  }

  /// Retains a newly requested delete when no complete active scope exists.
  /// This is deliberately not represented as a pending intent.
  void quarantineUnscoped({
    required LegacyCloudKitDeletionKind kind,
    required String recordId,
    required String reason,
    required DateTime now,
  }) {
    _validateRecordId(recordId);
    final sourceKey = 'new-${_kindName(kind)}';
    final key = _quarantineKey('$sourceKey:$reason', recordId);
    _store.runInTransaction(TxMode.write, () {
      final query = _quarantines
          .query(CloudKitDeletionQuarantineEntity_.quarantineKey.equals(key))
          .build();
      try {
        if (query.findFirst() != null) return;
      } finally {
        query.close();
      }
      _quarantines.put(
        CloudKitDeletionQuarantineEntity(
          quarantineKey: key,
          sourceKey: sourceKey,
          recordId: recordId,
          reason: reason,
          createdAtMs: now.millisecondsSinceEpoch,
        ),
      );
    });
  }

  int get pendingCount => _countIntentsWithState(_pendingState);

  int get quarantinedIntentCount => _countIntentsWithState(_quarantinedState);

  int get quarantineEvidenceCount => _quarantines.count();

  int _countIntentsWithState(int state) {
    final query = _intents
        .query(CloudKitDeletionIntentEntity_.state.equals(state))
        .build();
    try {
      return query.count();
    } finally {
      query.close();
    }
  }

  int _quarantineStaleRows(
    CloudKitWriterScope scope,
    int currentWriterEpoch,
    int nowMs,
  ) {
    final query = _intents
        .query(
          CloudKitDeletionIntentEntity_.accountFingerprint.equals(
                scope.accountFingerprint,
              ) &
              CloudKitDeletionIntentEntity_.container.equals(scope.container) &
              CloudKitDeletionIntentEntity_.database.equals(scope.database) &
              CloudKitDeletionIntentEntity_.state.equals(_pendingState),
        )
        .build();
    try {
      final stale = query
          .find()
          .where((entity) => entity.writerEpoch != currentWriterEpoch)
          .toList(growable: false);
      for (final entity in stale) {
        entity
          ..state = _quarantinedState
          ..quarantineReason = 'writer_epoch_stale'
          ..updatedAtMs = nowMs;
        _intents.put(entity);
      }
      return stale.length;
    } finally {
      query.close();
    }
  }

  static int _kindCode(LegacyCloudKitDeletionKind kind) => switch (kind) {
    LegacyCloudKitDeletionKind.message => 0,
    LegacyCloudKitDeletionKind.attachment => 1,
    LegacyCloudKitDeletionKind.chat => 2,
  };

  static LegacyCloudKitDeletionKind _kindFromCode(int value) => switch (value) {
    0 => LegacyCloudKitDeletionKind.message,
    1 => LegacyCloudKitDeletionKind.attachment,
    2 => LegacyCloudKitDeletionKind.chat,
    _ => throw const LegacyCloudKitDeletionIntentFailure(
      'cloudkit_delete_intent_kind_invalid',
    ),
  };

  static String _kindName(LegacyCloudKitDeletionKind kind) => kind.name;

  static String _intentKey(
    LegacyCloudKitDeletionContext context,
    LegacyCloudKitDeletionKind kind,
    String recordId,
  ) => sha256
      .convert(
        utf8.encode(
          'legacy-cloudkit-delete\u001f${context.scope.storageKey}\u001f${context.writerEpoch}\u001f${kind.name}\u001f$recordId',
        ),
      )
      .toString();

  static String _quarantineKey(String sourceKey, String recordId) => sha256
      .convert(
        utf8.encode(
          'legacy-cloudkit-quarantine\u001f$sourceKey\u001f$recordId',
        ),
      )
      .toString();

  static void _validateRecordId(String value) {
    if (value.isEmpty || value.length > 1024) {
      throw const LegacyCloudKitDeletionIntentFailure(
        'cloudkit_delete_intent_record_id_invalid',
      );
    }
    for (final codeUnit in value.codeUnits) {
      if (codeUnit < 0x20 || (codeUnit >= 0x7f && codeUnit <= 0x9f)) {
        throw const LegacyCloudKitDeletionIntentFailure(
          'cloudkit_delete_intent_record_id_invalid',
        );
      }
    }
  }
}
