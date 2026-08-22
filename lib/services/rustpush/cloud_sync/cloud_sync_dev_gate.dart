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
}
