/// Supplies input to the existing PCS recovery flow. Selecting a device or
/// supplying a password never establishes native membership/readiness itself.
/// The service keeps its existing identity/interlock checks around each await.
final class CloudSyncRecoveryInput {
  const CloudSyncRecoveryInput({
    required this.chooseDevice,
    required this.password,
  });
  final Future<int?> Function(
    List<String> deviceNames,
    bool Function() stillCurrent,
  )
  chooseDevice;
  final Future<String?> Function(
    String deviceName,
    bool Function() stillCurrent,
  )
  password;
}
