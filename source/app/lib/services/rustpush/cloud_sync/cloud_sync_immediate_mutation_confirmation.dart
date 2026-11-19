import 'cloud_sync_local_source_operations.dart';

/// Retains one immediate send result through its direct confirmation callback.
/// No timeout, retry, deferred owner storage or authority is introduced.
/// Callbacks must never await this tracker's quiesce or account reset.
Future<void> runCloudSyncImmediateMutationConfirmation<T>({
  required CloudSyncLocalSourceOperations operations,
  required void Function() validate,
  required Future<T> Function() send,
  required Future<void> Function(T) confirm,
}) => operations.run<void>(
  validate: validate,
  action: () async {
    final sent = await send();
    validate();
    await confirm(sent);
  },
);
