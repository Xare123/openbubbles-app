[CmdletBinding()]
param(
    [string] $RepoRoot = (
        Resolve-Path (Join-Path $PSScriptRoot "..\..")
    ).Path,

    [switch] $RequireEphemeralSymlink
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Assertions = 0

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
    $script:Assertions++
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string] $Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

$repo = Get-NormalizedPath -Path $RepoRoot
$package = Join-Path $repo "packages\media_kit_libs_windows_video"
$pubspecPath = Join-Path $repo "pubspec.yaml"
$lockPath = Join-Path $repo "pubspec.lock"
$packagePubspecPath = Join-Path $package "pubspec.yaml"
$pluginCmakePath = Join-Path $package "windows\CMakeLists.txt"
$rootCmakePath = Join-Path $repo "windows\CMakeLists.txt"
$generatedPluginsPath = Join-Path $repo "windows\flutter\generated_plugins.cmake"
$provenancePath = Join-Path $package "provenance\native-dependencies.json"
$noticesPath = Join-Path $package "THIRD_PARTY_NOTICES.md"
$verifiedBuildPath = Join-Path $repo (
    "tooling\windows\build_verified_native_media_runner.ps1"
)
$runtimeSmokePath = Join-Path $package "tool\runtime_smoke.ps1"
$workflowPath = Join-Path $repo (
    ".github\workflows\windows-arm64-native-media.yml"
)
$validationWorkflowPath = Join-Path $repo (
    ".github\workflows\windows-build.yml"
)

foreach ($required in @(
    $pubspecPath,
    $lockPath,
    $packagePubspecPath,
    $pluginCmakePath,
    $rootCmakePath,
    $generatedPluginsPath,
    $provenancePath,
    $noticesPath,
    $verifiedBuildPath,
    $runtimeSmokePath,
    $workflowPath,
    $validationWorkflowPath
)) {
    Assert-True `
        -Condition (Test-Path -LiteralPath $required -PathType Leaf) `
        -Message "required integration file must exist: $required"
}

$pubspec = Get-Content -LiteralPath $pubspecPath -Raw
Assert-True `
    -Condition ($pubspec -match '(?ms)^dependency_overrides:\s*.*?^  media_kit_libs_windows_video:\s*\r?\n    path: packages/media_kit_libs_windows_video\s*$') `
    -Message "root pubspec must override media_kit_libs_windows_video to the reviewed local package"

$lock = Get-Content -LiteralPath $lockPath -Raw
$lockMatch = [regex]::Match(
    $lock,
    '(?m)^  media_kit_libs_windows_video:\s*\r?\n(?<block>(?: {4}[^\r\n]*(?:\r?\n|$))+)(?=^  [a-zA-Z0-9_]+:)'
)
Assert-True `
    -Condition $lockMatch.Success `
    -Message "pubspec.lock must contain media_kit_libs_windows_video"
$lockBlock = $lockMatch.Groups["block"].Value
Assert-True `
    -Condition ($lockBlock -match '(?m)^      path: "packages/media_kit_libs_windows_video"\r?$') `
    -Message "lockfile must resolve the reviewed relative path"
Assert-True `
    -Condition ($lockBlock -match '(?m)^    source: path\r?$') `
    -Message "lockfile media package source must be path"
Assert-True `
    -Condition ($lockBlock -match '(?m)^    version: "1\.0\.11\+openbubbles\.1"\r?$') `
    -Message "lockfile must preserve the reviewed local package version"

$packagePubspec = Get-Content -LiteralPath $packagePubspecPath -Raw
Assert-True `
    -Condition ($packagePubspec -match '(?m)^name: media_kit_libs_windows_video\r?$') `
    -Message "local package name must match the upstream plugin"
Assert-True `
    -Condition ($packagePubspec -match '(?m)^version: 1\.0\.11\+openbubbles\.1\r?$') `
    -Message "local package version must match the lockfile"
Assert-True `
    -Condition ($packagePubspec -match '(?m)^publish_to: none\r?$') `
    -Message "review package must not be publishable by accident"

$packageConfigPath = Join-Path $repo ".dart_tool\package_config.json"
if (Test-Path -LiteralPath $packageConfigPath -PathType Leaf) {
    $packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw |
        ConvertFrom-Json -ErrorAction Stop
    $resolved = @(
        $packageConfig.packages |
            Where-Object { $_.name -eq "media_kit_libs_windows_video" }
    )
    Assert-True `
        -Condition ($resolved.Count -eq 1) `
        -Message "Dart package config must resolve exactly one Windows media package"
    $rootUri = [Uri]::new(
        [Uri]::new((Split-Path $packageConfigPath -Parent) + "\"),
        [string] $resolved[0].rootUri
    )
    Assert-True `
        -Condition ((Get-NormalizedPath -Path $rootUri.LocalPath) -eq
            (Get-NormalizedPath -Path $package)) `
        -Message "Dart package config must resolve the repo-local media package"
}

$symlinkPath = Join-Path $repo (
    "windows\flutter\ephemeral\.plugin_symlinks\" +
    "media_kit_libs_windows_video"
)
if ($RequireEphemeralSymlink -or (Test-Path -LiteralPath $symlinkPath)) {
    $symlink = Get-Item -LiteralPath $symlinkPath -Force -ErrorAction Stop
    Assert-True `
        -Condition ($symlink.LinkType -eq "SymbolicLink") `
        -Message "Flutter media plugin entry must be a symbolic link"
    $target = @($symlink.Target)[0]
    Assert-True `
        -Condition ((Get-NormalizedPath -Path $target) -eq
            (Get-NormalizedPath -Path $package)) `
        -Message "Flutter plugin symlink must target the reviewed local package"
}

$generatedPlugins = Get-Content -LiteralPath $generatedPluginsPath -Raw
Assert-True `
    -Condition ($generatedPlugins -match '(?m)^  media_kit_libs_windows_video\r?$') `
    -Message "Flutter generated plugin list must register the local media package"
Assert-True `
    -Condition ($generatedPlugins.Contains(
        'list(APPEND PLUGIN_BUNDLED_LIBRARIES ${${plugin}_bundled_libraries})'
    )) `
    -Message "Flutter generated CMake must propagate plugin runtime libraries"

$pluginCmake = Get-Content -LiteralPath $pluginCmakePath -Raw
foreach ($requiredText in @(
    'supports only Windows x64 and ARM64',
    'MEDIA_KIT_NATIVE_MEDIA_PORTABLE_EVIDENCE_FILES',
    'media_kit_libs_windows_video_portable_evidence_files',
    'media_kit_libs_windows_video_angle_license_directory',
    'PARENT_SCOPE'
)) {
    Assert-True `
        -Condition $pluginCmake.Contains($requiredText) `
        -Message "plugin CMake must contain '$requiredText'"
}

$rootCmake = Get-Content -LiteralPath $rootCmakePath -Raw
foreach ($requiredText in @(
    'media_kit_libs_windows_video_portable_evidence_files',
    'media_kit_libs_windows_video_angle_license_directory',
    '${INSTALL_BUNDLE_DATA_DIR}/native-media',
    '${INSTALL_BUNDLE_DATA_DIR}/native-media/angle-licenses',
    'install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"'
)) {
    Assert-True `
        -Condition $rootCmake.Contains($requiredText) `
        -Message "runner CMake must contain '$requiredText'"
}

$verifiedBuild = Get-Content -LiteralPath $verifiedBuildPath -Raw
foreach ($requiredText in @(
    'The Flutter toolchain must use $expectedDartArch Dart',
    'Runner bundle is missing required native-media evidence',
    'Public redistribution gate must remain closed',
    'Runner native media hash mismatch',
    'Runner native media PE mismatch',
    'libmpv_toolchain_abi_load = "passed"'
)) {
    Assert-True `
        -Condition $verifiedBuild.Contains($requiredText) `
        -Message "verified runner wrapper must contain '$requiredText'"
}

$workflow = Get-Content -LiteralPath $workflowPath -Raw
foreach ($requiredText in @(
    "if: github.event_name == 'workflow_dispatch'",
    'runner: windows-2025',
    'runner: windows-11-arm',
    'build_official_angle.ps1',
    'runtime_smoke.ps1',
    'build_verified_native_media_runner.ps1',
    'libmpv_binary_in_artifact = $false',
    'official-angle-${{ matrix.arch }}-${{ github.sha }}'
)) {
    Assert-True `
        -Condition $workflow.Contains($requiredText) `
        -Message "native-media workflow must contain '$requiredText'"
}
$angleBuildPath = Join-Path $package "tool\\build_official_angle.ps1"
$angleBuild = Get-Content -LiteralPath $angleBuildPath -Raw
foreach ($requiredText in @(
    'function Initialize-PinnedDepotTools',
    'bootstrap\win_tools.bat',
    'python3_bin_reldir.txt',
    'DEPOT_TOOLS_UPDATE stays disabled'
)) {
    Assert-True `
        -Condition $angleBuild.Contains($requiredText) `
        -Message "ANGLE bootstrap must contain '$requiredText'"
}
Assert-True `
    -Condition ($workflow -notmatch
        '(?ms)Upload short-lived engineering artifact.*?build[\\/]windows') `
    -Message "native-media workflow must not upload the blocked runner bundle"

$validationWorkflow = Get-Content -LiteralPath $validationWorkflowPath -Raw
foreach ($requiredText in @(
    'name: Windows validation',
    'Verify architecture-aware native media integration',
    'Enforce public native-binary release gate',
    '.github/workflows/windows-arm64-native-media.yml',
    'blocked_pending_transitive_license_inventory'
)) {
    Assert-True `
        -Condition $validationWorkflow.Contains($requiredText) `
        -Message "Windows validation workflow must contain '$requiredText'"
}
foreach ($forbiddenText in @(
    'hard-codes an x86_64 libmpv',
    'flutter build windows',
    'Compress-Archive',
    'actions/upload-artifact@'
)) {
    Assert-True `
        -Condition (-not $validationWorkflow.Contains($forbiddenText)) `
        -Message "Windows validation workflow must not contain '$forbiddenText'"
}

foreach ($workflowSource in @($workflow, $validationWorkflow)) {
    $actionReferences = [regex]::Matches(
        $workflowSource,
        '(?m)^\s*uses:\s*(?<reference>[^\s#]+)\s*$'
    )
    foreach ($actionReference in $actionReferences) {
        Assert-True `
            -Condition ($actionReference.Groups["reference"].Value -match
                '@[0-9a-f]{40}$') `
            -Message (
                "GitHub Actions must be pinned to a full commit: " +
                $actionReference.Groups["reference"].Value
            )
    }
}

$runtimeSmoke = Get-Content -LiteralPath $runtimeSmokePath -Raw
Assert-True `
    -Condition $runtimeSmoke.Contains(
        'Runtime smoke requires a native $expectedMachine PowerShell process'
    ) `
    -Message "full DLL smoke must reject an emulated PowerShell process"

$provenance = Get-Content -LiteralPath $provenancePath -Raw |
    ConvertFrom-Json -ErrorAction Stop
Assert-True `
    -Condition ($provenance.schema_version -eq 1) `
    -Message "native dependency provenance schema must remain recognized"
foreach ($hash in @(
    [string] $provenance.libmpv.artifacts.x64.sha256,
    [string] $provenance.libmpv.artifacts.arm64.sha256
)) {
    Assert-True `
        -Condition ($hash -match '^[0-9a-f]{64}$') `
        -Message "each libmpv architecture must have a full lowercase SHA-256"
}
Assert-True `
    -Condition ($provenance.libmpv.license_mode_evidence.redistribution_status -eq
        "blocked_pending_transitive_license_inventory") `
    -Message "public redistribution must fail closed until libmpv inventory is complete"

$forbidden = @(
    Get-ChildItem -LiteralPath $package -File -Recurse |
        Where-Object {
            $_.Extension.ToLowerInvariant() -in @(
                ".dll", ".exe", ".7z", ".zip", ".msix", ".appx", ".pfx"
            )
        }
)
Assert-True `
    -Condition ($forbidden.Count -eq 0) `
    -Message "no native binary, archive, installer, or signing key may be committed in the local package"

$parseErrors = [System.Collections.Generic.List[string]]::new()
$scripts = @(
    Get-ChildItem -LiteralPath (Join-Path $package "tool") -Filter "*.ps1" -File
    Get-ChildItem -LiteralPath (Join-Path $repo "tooling\windows") -Filter "*.ps1" -File
)
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref] $tokens,
        [ref] $errors
    ) | Out-Null
    foreach ($error in @($errors)) {
        $parseErrors.Add("$($script.Name): $($error.Message)")
    }
}
Assert-True `
    -Condition ($parseErrors.Count -eq 0) `
    -Message "native-media PowerShell must parse: $($parseErrors -join '; ')"

[pscustomobject]@{
    result = "passed"
    assertions = $script:Assertions
    package_root = $package
    redistribution_status = (
        $provenance.libmpv.license_mode_evidence.redistribution_status
    )
} | ConvertTo-Json -Depth 4
