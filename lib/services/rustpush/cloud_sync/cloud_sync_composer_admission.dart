import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';

import 'cloud_sync_local_send_journal.dart';

/// One composer-selected V2 admission. The stable IDS UUID is allocated before
/// the first durable Message write, and the Message plus state-0 intent commit
/// through the caller's existing persistence operation in one transaction.
final class CloudSyncComposerAdmission {
  CloudSyncComposerAdmission._({
    required this.stableGuid,
    required this._message,
    required this._identity,
    required this._journal,
    required this._authFence,
    required this._admittedAt,
    required this._newlyGeneratedGuid,
    required this._previousStagingGuid,
  });

  final String stableGuid;
  final Message _message;
  final CloudSyncLocalSendIdentity _identity;
  final CloudSyncLocalSendJournal _journal;
  final CloudSyncLocalSendAuthFence _authFence;
  final DateTime _admittedAt;
  final bool _newlyGeneratedGuid;
  final String? _previousStagingGuid;

  static bool isPlainTextCandidate(Message message) =>
      !message.fullText.replaceAll("\n", " ").hasUrl;

  static String? selectStableGuid({
    required Store store,
    required Message message,
    required String Function() allocate,
  }) {
    final existing = message.stagingGuid;
    if (existing == null) return allocate();
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(existing)) {
      return null;
    }
    return CloudSyncLocalSendJournal.hasPendingComposerAdmission(store, message)
        ? existing
        : null;
  }

  static CloudSyncComposerAdmission? captureFresh({
    required String stableGuid,
    required Message message,
    required Chat chat,
    required CloudSyncLocalSendJournal journal,
    required CloudSyncLocalSendAuthFence authFence,
    required DateTime admittedAt,
  }) {
    if (!admittedAt.isUtc ||
        admittedAt.millisecondsSinceEpoch <= 0 ||
        !isPlainTextCandidate(message) ||
        !RegExp(r'^temp-[A-Za-z0-9]{8}$').hasMatch(message.guid ?? '') ||
        (message.stagingGuid != null && message.stagingGuid != stableGuid)) {
      return null;
    }
    final previousStagingGuid = message.stagingGuid;
    final newlyGeneratedGuid = previousStagingGuid == null;
    message.stagingGuid = stableGuid;
    final identity = CloudSyncLocalSendIdentity.capture(
      message,
      chat,
      stableGuid,
    );
    if (identity == null) {
      if (newlyGeneratedGuid) message.stagingGuid = null;
      return null;
    }
    return CloudSyncComposerAdmission._(
      stableGuid: stableGuid,
      message: message,
      identity: identity,
      journal: journal,
      authFence: authFence,
      admittedAt: admittedAt,
      newlyGeneratedGuid: newlyGeneratedGuid,
      previousStagingGuid: previousStagingGuid,
    );
  }

  Future<Message> persist(Message Function() persistMessage) async {
    final previousId = _message.id;
    try {
      return await _authFence.run(() {
        late Message saved;
        _journal.saveSubmission(
          identity: _identity,
          newlyGeneratedGuid: _newlyGeneratedGuid,
          persistMessage: () {
            saved = persistMessage();
            return saved.id ?? 0;
          },
          now: _admittedAt,
        );
        return saved;
      });
    } catch (_) {
      // ObjectBox rolls the row back, but not the in-memory ID from Box.put.
      _message.id = previousId;
      _message.stagingGuid = _previousStagingGuid;
      rethrow;
    }
  }
}
