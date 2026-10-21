/// Compares the numeric build suffix used by the existing client updater.
/// Desktop tags, unknown package metadata and overflowing codes are not updates.
bool isNewerClientUpdateBuild(String releaseBuild, String installedBuild) {
  final decimal = RegExp(r'^[0-9]+$');
  if (decimal.stringMatch(releaseBuild) != releaseBuild ||
      decimal.stringMatch(installedBuild) != installedBuild) {
    return false;
  }
  final release = int.tryParse(releaseBuild);
  final installed = int.tryParse(installedBuild);
  return release != null && installed != null && release > installed;
}
