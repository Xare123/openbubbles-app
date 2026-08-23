/// Compile-time gate for the developer-only Cloud Sync V2 shadow sampler.
///
/// Production builds omit the sampler unless the build explicitly supplies
/// `--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true`.
abstract final class CloudSyncDevGate {
  static const bool manualShadowSamplerEnabled = bool.fromEnvironment(
    'OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER',
    defaultValue: false,
  );

  /// Separate opt-in for the developer-only local semantic projection canary.
  /// Enabling the read-only sampler alone can never enable local mutations.
  static const bool manualSemanticPullEnabled = bool.fromEnvironment(
    'OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL',
    defaultValue: false,
  );

  /// Independent opt-in for the one-existing-text, create-only write canary.
  /// This gate is insufficient by itself: the build must also select the V2
  /// writer owner, Developer Mode must be active, and two confirmations are
  /// required at runtime.
  static const bool manualOutboundCanaryEnabled = bool.fromEnvironment(
    'OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY',
    defaultValue: false,
  );

  /// Separate compile-time availability gate for the local-only protocol
  /// evidence trace. Ordinary Alpha, Beta, and production artifacts omit the
  /// toggle even if a stale preference exists.
  static const bool protocolEvidenceAvailable = bool.fromEnvironment(
    'OPENBUBBLES_CLOUD_SYNC_V2_EVIDENCE',
    defaultValue: false,
  );
}
