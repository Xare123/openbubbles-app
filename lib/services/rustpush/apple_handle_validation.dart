class AppleHandleUnavailableException implements Exception {
  const AppleHandleUnavailableException({
    this.selectedHandle,
    this.noRegisteredHandles = false,
  });

  final String? selectedHandle;
  final bool noRegisteredHandles;

  String get userMessage => noRegisteredHandles
      ? 'No active Apple messaging handle is registered. Reconnect the relay or sign in again.'
      : 'This chat is using an Apple handle that is no longer registered. Select a current handle in Profile before sending.';

  @override
  String toString() => userMessage;
}
String validateLiveAppleHandle({
  required String selectedHandle,
  required Iterable<String> liveHandles,
}) {
  if (!liveHandles.contains(selectedHandle)) {
    throw AppleHandleUnavailableException(selectedHandle: selectedHandle);
  }
  return selectedHandle;
}
