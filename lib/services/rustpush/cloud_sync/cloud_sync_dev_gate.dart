/// Compile-time gate for the developer-only Cloud Sync V2 shadow sampler.
///
/// Production builds omit the sampler unless the build explicitly supplies
/// `--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true`.
abstract final class CloudSyncDevGate {
  static const bool manualShadowSamplerEnabled = bool.fromEnvironment(
    'OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER',
    defaultValue: false,
  );
}
