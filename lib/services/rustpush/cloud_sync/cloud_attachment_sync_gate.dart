import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:synchronized/synchronized.dart';

/// Both CloudKit attachment transports use the native CloudKit client whose
/// writers are paused by a semantic pull. IDS downloads are independent.
bool cloudAttachmentLaneWaitsForSemanticPull(
  CloudAttachmentDownloadLane lane,
) =>
    lane == CloudAttachmentDownloadLane.cloudSyncV2 ||
    lane == CloudAttachmentDownloadLane.legacyCloudKit;

/// Gives on-demand media and mutation preparation a turn between native sessions,
/// the bounded windows of the retained-record projection sweep.
///
/// This is only in-isolate scheduling. The operation's durable interlock,
/// native writer pause and authentication checks remain authoritative. Never
/// hold this gate for the whole automatic catch-up or acquire it recursively.
final class CloudAttachmentSyncGate {
  final Lock _lock = Lock();
  int _waiting = 0;

  /// Cooperative automatic passes may hand back the gate at a settled boundary.
  /// This is queue state only, never authority to overlap or cancel native work.
  bool get hasWaitingWork => _waiting > 0;

  Future<T> run<T>({
    required void Function() validate,
    required Future<T> Function() action,
    Duration? waitTimeout,
  }) async {
    if (waitTimeout != null && waitTimeout <= Duration.zero) {
      throw ArgumentError('cloud_sync_gate_wait_timeout_invalid');
    }
    var entered = false;
    _waiting++;
    try {
      return await _lock.synchronized(() {
        entered = true;
        _waiting--;
        // An account transition or cancellation may have happened while queued.
        validate();
        return action();
      }, timeout: waitTimeout);
    } on TimeoutException {
      if (entered) rethrow;
      // Only queue admission timed out. The active owner's work is untouched
      // and this callback cannot run later. Never time out an entered mutation.
      throw const CloudKitOperationInterlockException('cloudkit_interlock_busy');
    } finally {
      if (!entered) _waiting--;
    }
  }

  /// Called after new work is quiesced, before native client disposal.
  /// Timing out this wait must not release an active operation's lock.
  Future<void> drain() => run(validate: () {}, action: () async {});
}
