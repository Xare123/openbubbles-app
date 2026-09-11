import 'cloud_sync_outbound_staging.dart';

/// The caller holds the account-wide CloudKit interlock. Preparation must
/// additionally exclude protected-store recovery while it adopts native plans
/// and results. Release that narrower exclusion before draining record saves:
/// their timeout handler may need to quiesce every tracked native operation.
/// Holding preparation open during that wait would make it wait for itself.
///
/// Child readback is mandatory after the drain and before returning the source
/// that may be used to admit the parent. Admission independently revalidates it.
Future<T> prepareCloudSyncAttachmentParent<T>({
  required CloudSyncOutboundStagingTransport staging,
  required Future<T> Function() prepareChildren,
  required Future<bool> Function() drainChildren,
  required Future<void> Function() requireChildReadback,
}) async {
  final source = await staging.runOutboundAdmissionExclusive(prepareChildren);
  if (!await drainChildren()) {
    throw StateError('cloud_sync_attachment_parent_readback_pending');
  }
  await requireChildReadback();
  return source;
}
