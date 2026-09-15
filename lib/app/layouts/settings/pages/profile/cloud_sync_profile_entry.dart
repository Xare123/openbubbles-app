/// Normal Profile placement policy for iCloud message sync.
///
/// Decides which entries the Profile sync section shows. The V2 history
/// card is the normal entry whenever the existing capability gate
/// (RustPushService.cloudSyncV2ProgressVisible) allows it; the legacy
/// "Messages in iCloud (BETA)" controls are the normal entry otherwise.
///
/// An enabled legacy account keeps its full legacy section, including the
/// off switch, unchanged: nothing here turns legacy off, resets it, or
/// migrates its queue, and the panel never enables legacy on its own, so
/// an account stays in legacy mode until an explicit migration. While V2
/// is visible, fresh legacy opt-in is hidden in the normal section; it is
/// not moved to another path by this policy.
///
/// Pure static helpers with no Flutter or service dependencies. They do
/// not start sync, touch encryption, or show dialogs.
class CloudSyncProfileEntry {
  const CloudSyncProfileEntry._();

  /// Whether the Profile sync section shows the V2 history sync card.
  static bool showV2Card({required bool v2Visible}) => v2Visible;

  /// Whether the Profile sync section shows the legacy BETA controls.
  /// False only while V2 is visible and legacy is not enabled.
  static bool showLegacySection({
    required bool v2Visible,
    required bool legacyEnabled,
  }) => !v2Visible || legacyEnabled;
}
