import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_transport.dart';

typedef CloudProtectedPageLeaseMaintenanceBody<T> = Future<T> Function();

/// Admission boundary shared with the owning sync/account coordinator.
///
/// [runWhenIdle] must atomically reject work while any sync is active or
/// quiescing, while an account transition/logout is in progress, or while
/// native credentials are being torn down. On success it must reserve that
/// idle state until [action] completes. A preflight boolean checked before
/// calling [action] is not sufficient because a sync or account transition
/// could start between the check and the native operation.
abstract interface class CloudProtectedPageLeaseMaintenanceAdmission {
  Future<T> runWhenIdle<T>(CloudProtectedPageLeaseMaintenanceBody<T> action);
}

/// Explicit, bounded caller for protected native-store garbage collection.
///
/// This class deliberately has no timer or background scheduler. The owning
/// coordinator should call [collectOneAfterRun] only from an after-run/manual
/// path through an admission implementation that shares its sync and account
/// transition state. Concurrent calls on one caller coalesce into one native
/// page collection. Later calls are safe because native collection preserves
/// live references, honors active leases and the 24-hour grace period, and is
/// itself idempotent.
final class CloudProtectedPageLeaseMaintenanceCaller {
  CloudProtectedPageLeaseMaintenanceCaller({
    required CloudProtectedPageLeaseLifecycle lifecycle,
    required CloudProtectedPageLeaseMaintenanceAdmission admission,
  }) : _lifecycle = lifecycle,
       _admission = admission;

  final CloudProtectedPageLeaseLifecycle _lifecycle;
  final CloudProtectedPageLeaseMaintenanceAdmission _admission;
  Future<CloudProtectedGarbageCollectionResult>? _inFlight;

  /// Collects at most one native GC page after the caller has acquired the
  /// shared idle-state reservation. No retry loop is performed here; a later
  /// explicit invocation may make bounded progress on another page.
  Future<CloudProtectedGarbageCollectionResult> collectOneAfterRun() {
    final existing = _inFlight;
    if (existing != null) return existing;

    late final Future<CloudProtectedGarbageCollectionResult> operation;
    operation = Future.sync(
      () => _admission.runWhenIdle(
        _lifecycle.collectOneProtectedGarbagePage,
      ),
    ).whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
    _inFlight = operation;
    return operation;
  }
}
