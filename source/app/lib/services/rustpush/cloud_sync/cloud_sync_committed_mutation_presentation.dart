/// Presents an already persisted mutation; never commits or authorizes one.
/// The caller reloads by journal local ID and supplies that Message's Chat.
/// Only synchronous presentation adapters belong here, not generic handlers.
void presentCloudSyncCommittedMutation<C, M>({
  required bool isUiThread,
  required C? chat,
  required M? message,
  required String? Function(M) guidOf,
  required void Function(C, M) refresh,
  required void Function(String) emit,
}) {
  if (!isUiThread || chat == null || message == null) return;
  final guid = guidOf(message);
  if (guid == null || guid.isEmpty) return;
  refresh(chat, message);
  emit('message-updated-$guid');
}
