import 'apple_handle_validation.dart';

/// Optional results belong to the route that was captured before the request.
/// Never select a replacement sender or apply a result to changed recipients.
bool optionalAppleRouteMatches({
  required String? capturedHandle,
  required String? currentHandle,
  required List<String> capturedPeers,
  required List<String> currentPeers,
}) {
  if (capturedHandle != currentHandle ||
      capturedPeers.length != currentPeers.length) {
    return false;
  }
  for (var i = 0; i < capturedPeers.length; i++) {
    if (capturedPeers[i] != currentPeers[i]) return false;
  }
  return true;
}

Future<String?> validateOptionalAppleHandle({
  required String? selectedHandle,
  required Future<List<String>> Function() getLiveHandles,
}) async {
  if (selectedHandle == null || selectedHandle.isEmpty) return null;
  try {
    return validateLiveAppleHandle(
      selectedHandle: selectedHandle,
      liveHandles: await getLiveHandles(),
    );
  } catch (_) {
    return null;
  }
}

class OptionalLookupFence {
  int _generation = 0;

  int begin() => ++_generation;

  void cancel() {
    _generation++;
  }

  bool isCurrent(int generation) => generation == _generation;

  T? acceptResource<T>({
    required int generation,
    required T? resource,
    required bool contextIsCurrent,
    required void Function(T resource) dispose,
  }) {
    if (resource == null) return null;
    if (!isCurrent(generation) || !contextIsCurrent) {
      dispose(resource);
      return null;
    }
    return resource;
  }
}
