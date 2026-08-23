#!/usr/bin/env bash
#
# Teach the CargoKit copies vendored inside pub packages how to work with
# Flutter 3.44.8's Gradle plugin.
#
# Three packages in this project ship their own CargoKit: rust_builder (tracked
# in this repository and already fixed), irondash_engine_context, and
# super_native_extensions. The latter two live in the pub cache, are refetched
# by `flutter pub get`, and cannot be fixed by a committed edit, so they are
# patched here before every Android build.
#
# Two separate defects are addressed, and the second is why this matters:
#
#   1. CargoKit locates Flutter's plugin by comparing the class name to
#      "FlutterPlugin". The Kotlin rewrite moved it to
#      com.flutter.gradle.FlutterPlugin, so the match fails and the Rust build
#      is skipped. The package then ships with no native library, and
#      IrondashEngineContextPlugin's static initializer throws
#      UnsatisfiedLinkError at startup. That throw happens inside
#      GeneratedPluginRegistrant.registerWith, which aborts registration for
#      EVERY plugin, so path_provider never registers and the app hangs during
#      startup with an unrelated-looking channel error.
#
#   2. Simply fixing the match is not enough and is actively worse. Once
#      CargoKit finds the Kotlin plugin it calls `plugin.project`, now a private
#      field, and `plugin.getTargetPlatforms()`, which was moved to
#      FlutterPluginUtils. Both throw once per variant. Gradle 8.9 then hands
#      the pile to MultipleBuildFailuresExceptionAnalyser, whose
#      DefaultFailureFactory recurses over the combined cause graph and never
#      returns. The build hangs with no error output at all.
#
# So the patch does both: match the Kotlin class name, and stop reaching through
# the plugin instance entirely by resolving the Flutter Project directly.
#
# Idempotent. Safe to run repeatedly and on already-patched files.
set -euo pipefail

patched=0
skipped=0
scanned=0

patch_file() {
    local file="$1"
    scanned=$((scanned + 1))

    if grep -q "_findFlutterProject" "$file"; then
        skipped=$((skipped + 1))
        return 0
    fi

    if ! grep -q "_findFlutterPlugin" "$file"; then
        echo "  ?? $file does not look like CargoKit's plugin.gradle; leaving it alone" >&2
        return 0
    fi

    # Rename the search so it yields the Project rather than the Plugin. The
    # recursive call is rewritten as its own block first so the remaining bare
    # `return plugin;` is unambiguously the one inside the plugin loop.
    perl -0777 -pi -e '
        s/private Plugin findFlutterPlugin\(/private Project findFlutterProject(/;
        s/private Plugin _findFlutterPlugin\(/private Project _findFlutterProject(/;
        s/_findFlutterPlugin\(rootProject\.childProjects\)/_findFlutterProject(rootProject.childProjects)/;
        s/def plugin = _findFlutterPlugin\(project\.value\.childProjects\);\s*\n(\s*)if \(plugin != null\) \{\s*\n\s*return plugin;\s*\n\s*\}/def found = _findFlutterProject(project.value.childProjects);\n$1if (found != null) {\n$1    return found;\n$1}/;
        s/if \(plugin\.class\.name == "FlutterPlugin"\) \{\s*\n(\s*)return plugin;/if (plugin.class.name == "FlutterPlugin" ||\n$1        plugin.class.name.endsWith(".FlutterPlugin")) {\n$1    return project.value;/;
        s/return plugin;/return project.value;/;
        s/def plugin = findFlutterPlugin\(project\.rootProject\);/def flutterProject = findFlutterProject(project.rootProject);/;
        s/if \(plugin == null\) \{/if (flutterProject == null) {/;
        s/\bprint\("Flutter plugin not found/println("Flutter plugin not found/;
        s/plugin\.getTargetPlatforms\(\)/flutterTargetPlatforms(flutterProject)/g;
        s/plugin\.project\b/flutterProject/g;
    ' "$file"

    # getTargetPlatforms moved into FlutterPluginUtils, which is Kotlin-internal
    # and unreachable from Groovy. Flutter passes -Ptarget-platform; the
    # fallback list matches the Flutter plugin's own default.
    perl -0777 -pi -e '
        s/(\n    \@Override\n    void apply\(Project project\) \{)/\n    private static List<String> flutterTargetPlatforms(Project flutterProject) {\n        if (flutterProject.hasProperty("target-platform")) {\n            return flutterProject\n                    .property("target-platform")\n                    .toString()\n                    .split(",")\n                    .collect { it.trim() }\n                    .findAll { !it.isEmpty() }\n        }\n        return ["android-arm", "android-arm64", "android-x64"]\n    }\n$1/;
    ' "$file"

    if ! grep -q "flutterTargetPlatforms" "$file"; then
        echo "  !! $file: helper was not inserted; the file shape is unexpected" >&2
        return 1
    fi

    echo "  patched $file"
    patched=$((patched + 1))
}

roots=()
if [ "$#" -gt 0 ]; then
    roots=("$@")
else
    # Default pub cache locations, Windows first since that is the dev host.
    for candidate in \
        "${PUB_CACHE:-}" \
        "$HOME/AppData/Local/Pub/Cache" \
        "$HOME/.pub-cache"
    do
        [ -n "$candidate" ] && [ -d "$candidate" ] && roots+=("$candidate")
    done
fi

if [ "${#roots[@]}" -eq 0 ]; then
    echo "error: no pub cache found; CargoKit patch cannot be verified" >&2
    exit 1
fi

for root in "${roots[@]}"; do
    while IFS= read -r file; do
        patch_file "$file"
    done < <(find "$root" -path "*cargokit/gradle/plugin.gradle" -type f 2>/dev/null)
done

echo "cargokit pub-cache patch: ${patched} patched, ${skipped} already current, ${scanned} scanned"

if [ "$scanned" -eq 0 ]; then
    echo "error: no vendored CargoKit copies were found." >&2
    echo "If irondash_engine_context or super_native_extensions are still" >&2
    echo "dependencies, the Android build will produce an APK that hangs on" >&2
    echo "startup. Check that pub get has run." >&2
    exit 1
fi
