#!/bin/bash
# Dedicated TrollStore helper only. No account, secret, install or device input.
set -euo pipefail
tools="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
output="${1:?New absolute output directory required}"
upstream="${TROLLVNC_SOURCE:?Exact upstream checkout required}"
theos="${THEOS:?Exact Theos checkout required}"
source_sha="${OB_SOURCE_SHA:?Exact tooling source required}"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$output" == /* && ! -e "$output" && ! -L "$output" ]] || exit 2
[[ "$(git -C "$upstream" rev-parse HEAD)" == cfdb737e72977d961eb7d0a8110d2fe1a58551d7 ]] || exit 2
[[ "$(git -C "$theos" rev-parse HEAD)" == cfba89a53a05b4a1b822121158acc3669c20602f ]] || exit 2
mkdir -- "$output"
stage="$output/source-stage"
git clone --no-hardlinks --local "$upstream" "$stage"
python3 -B "$tools/prepare.py" --upstream "$upstream" --stage "$stage" --check > "$output/HARDENING.patch"
python3 -B "$tools/prepare.py" --upstream "$upstream" --stage "$stage" > "$output/PREPARE.json"
python3 -B "$tools/prepare.py" --upstream "$upstream" --stage "$stage" > "$output/IDEMPOTENCE.json"
python3 -B "$tools/fetch_sdks.py" --theos "$theos" --evidence "$output"
{
  xcodebuild -version
  python3 --version
  gmake --version
  git -C "$theos" submodule status --recursive
} > "$output/BUILD_TOOLS.txt"
export THEOS="$theos" THEOS_PACKAGE_SCHEME=roothide THEBOOTSTRAP=1
export THEOS_DEVICE_IP=127.0.0.1 THEOS_DEVICE_PORT=58422 THEOS_DEVICE_SIMULATOR=
(
  cd -- "$stage"
  # Preserve raw Xcode diagnostics; the upstream formatter hid a GUI error.
  FINALPACKAGE=1 gmake -j2 TARGET_XCPRETTY= package
)
shopt -s nullglob
packages=("$stage"/packages/*.tipa)
[[ ${#packages[@]} == 1 ]] || { echo 'Exactly one bootstrap package required' >&2; exit 3; }
mkdir -- "$output/package"
ditto -xk "${packages[0]}" "$output/package"
apps=("$output"/package/Payload/*.app)
[[ ${#apps[@]} == 1 ]] || exit 3
app="${apps[0]}"
managed="$app/TrollVNCPrefs.bundle/Managed.plist"
python3 -B - "$tools" "$managed" "$source_sha" <<'PY'
import plistlib, sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import prepare
resource=Path(sys.argv[2])
config=plistlib.loads(resource.read_bytes())
assert config == prepare.CONFIG
config['DesktopName']='OB USB Control '+sys.argv[3]
resource.write_bytes(plistlib.dumps(config,sort_keys=True))
PY
cp -- "$upstream/COPYING" "$app/COPYING.upstream"
for binary in trollvncserver trollvncmanager; do
  [[ -f "$app/$binary" && "$(lipo -archs "$app/$binary")" == arm64 ]] || exit 3
  codesign --force --sign - --preserve-metadata=entitlements,identifier --generate-entitlement-der "$app/$binary"
done
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName OB USB Control' "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 280' "$app/Info.plist"
codesign --force --sign - --deep --preserve-metadata=entitlements,identifier --generate-entitlement-der "$app"
codesign --verify --deep --strict "$app"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
[[ "$(lipo -archs "$app/$executable")" == arm64 ]] || exit 3
python3 -B - "$tools" "$managed" "$app/Info.plist" "$source_sha" <<'PY'
import json, plistlib, sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import prepare
expected=dict(prepare.CONFIG,DesktopName='OB USB Control '+sys.argv[4])
assert plistlib.loads(Path(sys.argv[2]).read_bytes()) == expected
info=plistlib.loads(Path(sys.argv[3]).read_bytes())
assert tuple(map(int,info['MinimumOSVersion'].split('.'))) <= (15,7,9)
assert info['CFBundleVersion'] == '280'
print(json.dumps({'arm64_package':True,'managed_resource_verified':True,'password_bundled':False,'device_runtime_qualified':False}))
PY
(
  cd -- "$output/package"
  /usr/bin/zip -qr "$output/OBUSBControl.tipa" Payload
)
shasum -a 256 "$output/OBUSBControl.tipa" "$app/$executable" "$app/trollvncserver" "$app/trollvncmanager" > "$output/SHA256SUMS"
printf '%s\n' "$source_sha" > "$output/SOURCE_SHA"
printf '%s\n' cfdb737e72977d961eb7d0a8110d2fe1a58551d7 > "$output/UPSTREAM_SHA"
printf '%s\n' 'Build/package evidence only; iPhone input, auth, listener scope and cleanup remain UNQUALIFIED.'
