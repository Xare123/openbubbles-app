#!/bin/bash
# Builds only this separate diagnostic; never installs, launches, or logs in.
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
output="${1:?Pass a NEW absolute output directory}"
source_sha="${OB_SOURCE_SHA:?Exact source SHA required}"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid source SHA' >&2; exit 2; }
[[ "$output" == /* && ! -e "$output" && ! -L "$output" ]] || { echo 'New absolute output directory required' >&2; exit 2; }
# Source may contain exactly one patch-added final LF, only if removing that
# one byte matches the manifest's production SHA. Staged/runtime bytes are strict.
source_pins="$(python3 -B "$source_dir/validate_fixture.py" --source "$source_dir")"
mkdir -- "$output"
mkdir -- "$output/Payload"
app="$output/Payload/OBAccountQualifierFixture.app"
mkdir -- "$app"
fixture_pins="$(python3 -B "$source_dir/validate_fixture.py" --stage "$app" "$source_dir")"
[[ "$fixture_pins" == "$source_pins" ]] || { echo 'Frozen source fixture changed' >&2; exit 3; }
[[ "$(python3 -B "$source_dir/validate_fixture.py" "$app")" == "$fixture_pins" ]] || { echo 'Staged fixture differs' >&2; exit 3; }
read -r run_id body_sha fixture_sha <<< "$fixture_pins"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
clang="$(xcrun --find clang)"
"$clang" -target arm64-apple-ios14.0 -isysroot "$sdk" -fobjc-arc -fblocks \
  -Wall -Wextra -Werror=return-type -Werror=implicit-function-declaration \
  "-DOB_SOURCE_SHA=\"$source_sha\"" \
  "-DOB_FIXTURE_BODY_SHA256=\"$body_sha\"" \
  "-DOB_FIXTURE_JSON_SHA256=\"$fixture_sha\"" "$source_dir/main.m" \
  -framework UIKit -framework Foundation -framework Security \
  -o "$app/OBAccountQualifierFixture"
cp -- "$source_dir/Info.plist" "$app/Info.plist"
plutil -lint "$app/Info.plist" "$source_dir/entitlements.plist" "$app/body.plist"
[[ "$(python3 -B "$source_dir/validate_fixture.py" "$app")" == "$fixture_pins" ]] || { echo 'Frozen fixture changed' >&2; exit 3; }
codesign --force --sign - --entitlements "$source_dir/entitlements.plist" \
  --generate-entitlement-der "$app"
codesign --verify --deep --strict "$app"
[[ "$(lipo -archs "$app/OBAccountQualifierFixture")" == 'arm64' ]] || { echo 'ARM64 required' >&2; exit 3; }
(
  cd -- "$output"
  /usr/bin/zip -qr OBAccountQualifierFixture.tipa Payload
  shasum -a 256 OBAccountQualifierFixture.tipa Payload/OBAccountQualifierFixture.app/OBAccountQualifierFixture > SHA256SUMS
)
printf '%s\n' "$source_sha" > "$output/SOURCE_SHA"
printf '%s\n' "$body_sha" > "$output/BODY_SHA256"
printf '%s\n' "$fixture_sha" > "$output/FIXTURE_SHA256"
printf '%s\n' 'Separate one-use loopback fixture. iOS runtime and login UNQUALIFIED.'
