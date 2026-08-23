import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;

import 'cloud_sync_models.dart';

final class CloudSyncProtectedOutboundStageData {
  const CloudSyncProtectedOutboundStageData({
    required this.logicalEntityKeyHash,
    required this.protectedEnvelopeReference,
    required this.payloadSha256,
    required this.serverRecordIdHash,
    required this.leaseReference,
  });

  final String logicalEntityKeyHash;
  final String protectedEnvelopeReference;
  final String payloadSha256;
  final String serverRecordIdHash;
  final String leaseReference;
}

abstract interface class CloudSyncOutboundStagingTransport {
  /// Holds the same per-store gate used by recovery across the complete
  /// stage -> durable adoption -> native lease commit crash window.
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action);

  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
  });

  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  );

  Future<void> rollbackOutboundLease(String leaseReference);
}
