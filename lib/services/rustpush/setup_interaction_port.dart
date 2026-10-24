/// Presentation-only input/status port for the existing setup workflow.
/// Implementations never establish login or registration success themselves.
abstract interface class SetupInteractionPort {
  Future<T> wait<T>(Future<T> operation);
  Future<int?> chooseSmsDestination(
    List<String> privateLabels, {
    required bool Function() stillCurrent,
  });
  Future<void> registrationSupportRequired();
}
