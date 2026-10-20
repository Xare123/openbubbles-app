#!/bin/bash
# One source-only build. No account/device input, installation or relay access.
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
output="${1:?Pass a NEW absolute output directory}"
source_sha="${OB_SOURCE_SHA:?Exact source SHA required}"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Exact source SHA required' >&2; exit 2; }
[[ "$output" == /* && ! -e "$output" && ! -L "$output" ]] || { echo 'New absolute output required' >&2; exit 2; }
[[ -f "$source_dir/tests/run-foundation-tests.sh" ]] || { echo 'Required Foundation tests absent' >&2; exit 2; }
mkdir -- "$output"
bash "$source_dir/tests/run-foundation-tests.sh" "$output/foundation-tests"
mkdir -- "$output/generated" "$output/Payload"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
clang="$(xcrun --find clang)"
mig="$(xcrun --find mig)"
"$mig" -arch arm64 -isysroot "$sdk" \
  -header "$output/generated/OBAbsintheIPC.h" \
  -user "$output/generated/OBAbsintheIPCUser.c" \
  -server /dev/null -sheader /dev/null "$source_dir/nac/OBAbsintheIPC.defs"
# Verify finite IPC options in actual generated code, not just the input DSL.
grep -q 'MACH_SEND_TIMEOUT' "$output/generated/OBAbsintheIPCUser.c"
grep -q 'MACH_RCV_TIMEOUT' "$output/generated/OBAbsintheIPCUser.c"
grep -q '5000' "$output/generated/OBAbsintheIPCUser.c"
grep -q 'MACH_SEND_TIMED_OUT' "$output/generated/OBAbsintheIPCUser.c"
grep -q 'mach_msg_destroy' "$output/generated/OBAbsintheIPCUser.c"
for operation in 1200 1201 1202; do
  grep -Eq "msgh_id[[:space:]]*=[[:space:]]*$operation" "$output/generated/OBAbsintheIPCUser.c"
done
app="$output/Payload/OBNativeRelay.app"
mkdir -- "$app"
sources=()
for source in "$source_dir"/src/*.m; do
  # The unavailable implementation is retained for provenance/tests only.
  [[ "$(basename -- "$source")" == 'OBNACValidatorUnavailable.m' ]] && continue
  sources+=("$source")
done
"$clang" -target arm64-apple-ios15.0 -isysroot "$sdk" -fobjc-arc -fblocks \
  -Wall -Werror=return-type -Werror=implicit-function-declaration \
  "-DOB_SOURCE_SHA=\"$source_sha\"" -I "$source_dir/src" -I "$source_dir/nac" -I "$output/generated" \
  "${sources[@]}" "$source_dir/nac/OBNativeNACValidator.m" "$output/generated/OBAbsintheIPCUser.c" \
  -framework UIKit -framework Foundation -framework CoreFoundation -framework Security \
  -o "$app/OBNativeRelay"
cp -- "$source_dir/src/Info.plist" "$app/Info.plist"
plutil -insert OBSourceSHA -string "$source_sha" "$app/Info.plist"
plutil -lint "$app/Info.plist" "$source_dir/entitlements.plist"
codesign --force --sign - --entitlements "$source_dir/entitlements.plist" \
  --generate-entitlement-der "$app"
codesign --verify --deep --strict "$app"
[[ "$(lipo -archs "$app/OBNativeRelay")" == 'arm64' ]] || { echo 'ARM64 required' >&2; exit 3; }
(
  cd -- "$output"
  /usr/bin/zip -qr OBNativeRelay.tipa Payload
  shasum -a 256 OBNativeRelay.tipa Payload/OBNativeRelay.app/OBNativeRelay > SHA256SUMS
)
printf '%s\n' "$source_sha" > "$output/SOURCE_SHA"
{
  xcodebuild -version
  xcrun --sdk iphoneos --show-sdk-version
  "$clang" --version
} > "$output/BUILD_TOOLS.txt"
printf '%s\n' 'Source/Foundation/MIG/ARM64/ad-hoc checks only; native runtime, account and registration UNQUALIFIED.'
