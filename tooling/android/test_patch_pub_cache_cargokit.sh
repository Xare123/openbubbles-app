#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temp_root="$(mktemp -d)"
trap 'rm -rf -- "$temp_root"' EXIT

fixture_dir="$temp_root/hosted/pub.dev/fixture-1.0.0/cargokit/gradle"
mkdir -p "$fixture_dir"
cp "$repo_root/rust_builder/cargokit/gradle/plugin.gradle" \
    "$fixture_dir/plugin.gradle"

# Model an already Flutter-3.44-compatible vendored copy that still carries
# CargoKit's old unconditional emulator-target expansion.
perl -0777 -pi -e '
    s/if \(buildType == "debug" \&\&\s*\n\s*!flutterProject\.hasProperty\("target-platform"\)\) \{/if (buildType == "debug") {/;
' "$fixture_dir/plugin.gradle"

bash "$script_dir/patch_pub_cache_cargokit.sh" "$temp_root"
bash "$script_dir/patch_pub_cache_cargokit.sh" "$temp_root"

guard_count="$(grep -c '!flutterProject.hasProperty("target-platform")' \
    "$fixture_dir/plugin.gradle")"
if [ "$guard_count" -ne 1 ]; then
    echo "expected exactly one explicit target-platform guard, found $guard_count" >&2
    exit 1
fi

if ! grep -q 'platforms.add("android-x86")' "$fixture_dir/plugin.gradle" ||
        ! grep -q 'platforms.add("android-x64")' "$fixture_dir/plugin.gradle"; then
    echo "unscoped debug emulator fallback was removed" >&2
    exit 1
fi

echo "CargoKit explicit-target patch contract passed"
