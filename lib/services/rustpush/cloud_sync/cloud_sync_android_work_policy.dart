/// Platform-neutral contract mirrored by Android's WorkManager adapter.
///
/// This is deliberately a policy description, not an execution switch. The
/// Android adapter starts disabled and, while dormant, its worker does not
/// initialize Flutter, Rust, or CloudKit.
enum CloudSyncAndroidWorkKind { metadata, automaticMedia, userVisibleManual }

enum CloudSyncAndroidNetworkRequirement { connected, unmetered }

class CloudSyncAndroidWorkPolicy {
  const CloudSyncAndroidWorkPolicy({
    required this.networkRequirement,
    this.requiresBatteryNotLow = true,
    this.requiresStorageNotLow = true,
    this.coalescingDelay = const Duration(seconds: 15),
    this.requestsExpeditedExecution = false,
  });

  /// The earliest a durable Android wake may run after the first hint.
  ///
  /// Repeated hints use unique-work KEEP semantics, so they coalesce rather
  /// than resetting this delay or producing a queue of CloudKit work.
  final Duration coalescingDelay;
  final CloudSyncAndroidNetworkRequirement networkRequirement;
  final bool requiresBatteryNotLow;
  final bool requiresStorageNotLow;

  /// V2 never requests expedited work. [userVisibleManual] is named
  /// explicitly so a later user-visible design cannot silently inherit an
  /// expedited policy without a separate review.
  final bool requestsExpeditedExecution;

  static const uniqueWorkPrefix = 'cloud-sync-v2/';

  static CloudSyncAndroidWorkPolicy forKind(CloudSyncAndroidWorkKind kind) {
    switch (kind) {
      case CloudSyncAndroidWorkKind.metadata:
      case CloudSyncAndroidWorkKind.userVisibleManual:
        return const CloudSyncAndroidWorkPolicy(
          networkRequirement: CloudSyncAndroidNetworkRequirement.connected,
        );
      case CloudSyncAndroidWorkKind.automaticMedia:
        return const CloudSyncAndroidWorkPolicy(
          networkRequirement: CloudSyncAndroidNetworkRequirement.unmetered,
        );
    }
  }

  /// WorkManager receives only a canonical SHA-256 of the full V2 scope key.
  ///
  /// Keeping validation here prevents accidental use of a partial account,
  /// zone, or raw Apple identifier as WorkManager's durable unique-work name.
  static String uniqueWorkNameForScopeHash(String scopeHash) {
    final normalized = scopeHash.trim();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
      throw ArgumentError.value(
        scopeHash,
        'scopeHash',
        'Must be a lowercase SHA-256 hash of the complete Cloud Sync scope',
      );
    }
    return '$uniqueWorkPrefix$normalized';
  }
}
