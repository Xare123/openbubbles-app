#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
output="${1:?New absolute output directory required}"
[[ "$output" == /* && ! -e "$output" && ! -L "$output" ]] || { echo 'New absolute output required' >&2; exit 2; }
mkdir -- "$output"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
clang="$(xcrun --find clang)"
"$clang" -isysroot "$sdk" -fobjc-arc -fblocks -Wall -Werror=return-type \
  -I "$root/src" -framework Foundation -framework Security \
  "$root/tests/relay-foundation-tests.m" "$root/src/OBRelayDispatcher.m" \
  "$root/src/OBRelayConnection.m" "$root/src/OBRelayAuthBundle.m" \
  "$root/src/OBRelayRegistrationStore.m" "$root/src/OBRelayPushProtocol.m" \
  "$root/src/OBRelayPushService.m" "$root/src/OBRelayNativePush.m" -o "$output/relay-foundation-tests"
"$clang" -isysroot "$sdk" -fobjc-arc -fblocks -Wall -Werror=return-type \
  -I "$root/src" -framework Foundation "$root/tests/push-protocol-tests.m" \
  "$root/src/OBRelayPushProtocol.m" -o "$output/push-protocol-tests"
"$clang" -isysroot "$sdk" -fobjc-arc -fblocks -Wall -Werror=return-type \
  -I "$root/src" -framework Foundation "$root/tests/push-service-tests.m" \
  "$root/src/OBRelayPushProtocol.m" "$root/src/OBRelayPushService.m" -o "$output/push-service-tests"
"$clang" -isysroot "$sdk" -fobjc-arc -fblocks -Wall -Werror=return-type \
  -I "$root/src" -framework Foundation "$root/tests/registration-store-tests.m" \
  "$root/src/OBRelayRegistrationStore.m" -o "$output/registration-store-tests"
"$output/relay-foundation-tests" | tee "$output/relay-results.txt"
"$output/registration-store-tests" | tee "$output/registration-results.txt"
"$output/push-protocol-tests" | tee "$output/push-protocol-results.txt"
"$output/push-service-tests" | tee "$output/push-service-results.txt"
printf '%s\n' 'Executed Foundation host fixtures only. Native iOS/private frameworks/NAC and account login unrun.' > "$output/SCOPE.txt"
