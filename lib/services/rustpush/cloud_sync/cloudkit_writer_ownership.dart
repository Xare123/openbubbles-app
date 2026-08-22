/// The only CloudKit implementation permitted to mutate the Messages zones.
enum CloudKitWriterOwner { none, legacy, v2 }

/// A fail-closed interpretation of the build-time writer selection.
final class CloudKitWriterOwnershipDecision {
  const CloudKitWriterOwnershipDecision({
    required this.owner,
    required this.configurationValid,
  });

  final CloudKitWriterOwner owner;
  final bool configurationValid;

  bool get legacyMutationsEnabled =>
      configurationValid && owner == CloudKitWriterOwner.legacy;

  bool get v2MutationsEnabled =>
      configurationValid && owner == CloudKitWriterOwner.v2;

  String get safeStatusCode => configurationValid
      ? 'cloudkit_writer_${owner.name}'
      : 'cloudkit_writer_configuration_invalid';

  @override
  String toString() =>
      'CloudKitWriterOwnershipDecision(status=$safeStatusCode)';
}

/// A single build-time selector prevents the legacy and V2 implementations
/// from independently enabling writes in the same application build.
///
/// Unknown or missing values fail closed to [CloudKitWriterOwner.none]. The
/// raw build value is intentionally never retained in diagnostics.
abstract final class CloudKitWriterOwnership {
  static const String _configuredOwner = String.fromEnvironment(
    'OPENBUBBLES_CLOUDKIT_WRITER_OWNER',
    defaultValue: 'none',
  );

  static final CloudKitWriterOwnershipDecision decision = resolve(
    _configuredOwner,
  );

  static bool get legacyMutationsEnabled => decision.legacyMutationsEnabled;

  static bool get v2MutationsEnabled => decision.v2MutationsEnabled;

  static CloudKitWriterOwnershipDecision resolve(String configuredOwner) {
    final owner = switch (configuredOwner) {
      'none' => CloudKitWriterOwner.none,
      'legacy' => CloudKitWriterOwner.legacy,
      'v2' => CloudKitWriterOwner.v2,
      _ => CloudKitWriterOwner.none,
    };
    return CloudKitWriterOwnershipDecision(
      owner: owner,
      configurationValid:
          configuredOwner == 'none' ||
          configuredOwner == 'legacy' ||
          configuredOwner == 'v2',
    );
  }
}
