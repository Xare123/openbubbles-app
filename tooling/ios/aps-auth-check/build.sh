#!/bin/bash
# Separate one-shot diagnostic only. No account/device input or installation.
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
output="${1:?Pass a NEW absolute output directory}"
source_sha="${OB_SOURCE_SHA:?Exact source SHA required}"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid source SHA' >&2; exit 2; }
[[ "$output" == /* && ! -e "$output" && ! -L "$output" ]] || { echo 'New absolute output required' >&2; exit 2; }
mkdir -- "$output"
mkdir -- "$output/Payload"
app="$output/Payload/OBAPSAuthCheck.app"
mkdir -- "$app"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
clang="$(xcrun --find clang)"
"$clang" -target arm64-apple-ios14.0 -isysroot "$sdk" -fobjc-arc -fblocks \
  -Wall -Werror=return-type -Werror=implicit-function-declaration \
  "-DOB_SOURCE_SHA=\"$source_sha\"" "$source_dir/main.m" \
  -framework UIKit -framework Foundation -framework Security -o "$app/OBAPSAuthCheck"
cp -- "$source_dir/Info.plist" "$app/Info.plist"
plutil -lint "$app/Info.plist" "$source_dir/entitlements.plist"
codesign --force --sign - --entitlements "$source_dir/entitlements.plist" --generate-entitlement-der "$app"
codesign --verify --deep --strict "$app"
[[ "$(lipo -archs "$app/OBAPSAuthCheck")" == 'arm64' ]] || { echo 'ARM64 required' >&2; exit 3; }
(
  cd -- "$output"
  /usr/bin/zip -qr OBAPSAuthCheck.tipa Payload
  shasum -a 256 OBAPSAuthCheck.tipa Payload/OBAPSAuthCheck.app/OBAPSAuthCheck > SHA256SUMS
)
printf '%s\n' "$source_sha" > "$output/SOURCE_SHA"
printf '%s\n' 'Build/signature checks only. Native signing and APS acceptance UNQUALIFIED.'
