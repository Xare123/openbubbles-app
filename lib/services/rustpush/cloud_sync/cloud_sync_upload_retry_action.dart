// ignore_for_file: prefer_initializing_formals

/// One in-memory, single-use confirmation for an already queued iCloud upload.
/// The service binds it to the exact operation and account before the dialog.
/// Dismissing the dialog or disposing its card disarms it without queue changes.
final class CloudSyncUploadRetryAction {
  CloudSyncUploadRetryAction({
    required Future<String> Function() confirm,
    required void Function() cancel,
  }) : _confirm = confirm, _cancel = cancel;

  final Future<String> Function() _confirm;
  final void Function() _cancel;
  bool _used = false;

  Future<String> confirm() {
    if (_used) throw StateError('cloud_sync_upload_retry_already_used');
    _used = true;
    return _confirm();
  }

  void cancel() {
    if (_used) return;
    _used = true;
    _cancel();
  }
}
