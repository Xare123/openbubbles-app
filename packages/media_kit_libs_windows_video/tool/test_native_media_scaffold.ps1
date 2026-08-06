[CmdletBinding()]
param(
    [string] $X64LibmpvArchive,
    [string] $Arm64LibmpvArchive
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$modulePath = Join-Path $PSScriptRoot "NativeMediaVerification.psm1"
$provenancePath = Join-Path $packageRoot "provenance\native-dependencies.json"
Import-Module $modulePath -Force

$script:Passed = 0

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Content
    )
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force |
        Out-Null
    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
    $script:Passed++
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $MessagePattern
    )
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "Expected error matching '$MessagePattern', got: $($_.Exception.Message)"
        }
        $script:Passed++
        return
    }
    throw "Expected an error matching '$MessagePattern', but the action succeeded."
}

function New-FakePe {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][ValidateSet("X64", "ARM64")][string] $Machine
    )

    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force |
        Out-Null
    $bytes = [byte[]]::new(512)
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int] 0x80).CopyTo($bytes, 0x3C)
    [BitConverter]::GetBytes([uint32] 0x00004550).CopyTo($bytes, 0x80)
    $machineCode = if ($Machine -eq "ARM64") {
        [uint16] 0xAA64
    }
    else {
        [uint16] 0x8664
    }
    [BitConverter]::GetBytes($machineCode).CopyTo($bytes, 0x84)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function New-SyntheticAngleBundle {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][ValidateSet("x64", "arm64")][string] $Architecture,
        [Parameter(Mandatory)][object] $Provenance
    )

    $machine = if ($Architecture -eq "arm64") { "ARM64" } else { "X64" }
    $runtimeFiles = @($Provenance.angle.runtime_files.$Architecture)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in $runtimeFiles) {
        $path = Join-Path $Root $relative
        New-FakePe -Path $path -Machine $machine
        $entries.Add([pscustomobject]@{
            relative_path = $relative
            sha256 = Get-Sha256Hex -Path $path
            pe_machine = $machine
            origin = "synthetic test fixture"
        })
    }

    $angleLicense = Join-Path $Root "licenses\ANGLE-LICENSE.txt"
    $inventory = Join-Path $Root "licenses\license-inventory.json"
    $thirdPartyLicense = Join-Path $Root (
        "licenses\source-tree\third_party\synthetic\LICENSE"
    )
    $revisions = Join-Path $Root "provenance\gclient-revisions.txt"
    $gnArgs = Join-Path $Root "provenance\gn-args.txt"
    Write-Utf8NoBom -Path $angleLicense -Content "Synthetic fixture only."
    Write-Utf8NoBom -Path $thirdPartyLicense -Content "Synthetic third-party fixture."
    $licenseInventory = @(
        [pscustomobject]@{
            source_relative_path = "third_party/synthetic/LICENSE"
            bundle_relative_path = (
                "licenses/source-tree/third_party/synthetic/LICENSE"
            )
            sha256 = Get-Sha256Hex -Path $thirdPartyLicense
        }
    )
    Write-Utf8NoBom `
        -Path $inventory `
        -Content ($licenseInventory | ConvertTo-Json -Depth 5)
    Write-Utf8NoBom -Path $revisions -Content "angle@test"
    Write-Utf8NoBom -Path $gnArgs -Content "is_debug=false"

    $manifest = [ordered]@{
        schema_version = 1
        architecture = $Architecture
        source = [ordered]@{
            angle_url = $Provenance.angle.source_url
            angle_commit = $Provenance.angle.source_commit
            depot_tools_url = $Provenance.angle.depot_tools_url
            depot_tools_commit = $Provenance.angle.depot_tools_commit
        }
        build = [ordered]@{
            synthetic_fixture = $true
        }
        files = @($entries)
        angle_license_sha256 = Get-Sha256Hex -Path $angleLicense
        license_inventory_sha256 = Get-Sha256Hex -Path $inventory
        evidence = [ordered]@{
            gclient_revisions_path = "provenance/gclient-revisions.txt"
            gclient_revisions_sha256 = Get-Sha256Hex -Path $revisions
            gn_args_path = "provenance/gn-args.txt"
            gn_args_sha256 = Get-Sha256Hex -Path $gnArgs
        }
    }
    $manifestPath = Join-Path $Root "native-manifest.json"
    Write-Utf8NoBom `
        -Path $manifestPath `
        -Content ($manifest | ConvertTo-Json -Depth 10)
    return [pscustomobject]@{
        root = $Root
        manifest = $manifestPath
        runtime_files = $runtimeFiles
    }
}

function Invoke-BundleValidation {
    param(
        [Parameter(Mandatory)][object] $Bundle,
        [Parameter(Mandatory)][object] $Provenance,
        [Parameter(Mandatory)][ValidateSet("x64", "arm64")][string] $Architecture
    )
    Test-NativeMediaBundle `
        -BundleRoot $Bundle.root `
        -ManifestPath $Bundle.manifest `
        -Architecture $Architecture `
        -ExpectedAngleSourceUrl $Provenance.angle.source_url `
        -ExpectedAngleCommit $Provenance.angle.source_commit `
        -ExpectedDepotToolsUrl $Provenance.angle.depot_tools_url `
        -ExpectedDepotToolsCommit $Provenance.angle.depot_tools_commit `
        -RequiredRuntimeFiles $Bundle.runtime_files
}

$testRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) "openbubbles-native-media-tests-$([guid]::NewGuid().ToString('N'))"
$tempPrefix = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath()
).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$testRootFull = [System.IO.Path]::GetFullPath($testRoot)
if (-not $testRootFull.StartsWith(
    $tempPrefix,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Test directory is outside the system temporary directory."
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $provenance = Get-Content -LiteralPath $provenancePath -Raw |
        ConvertFrom-Json -ErrorAction Stop

    Assert-True `
        -Condition ($provenance.schema_version -eq 1) `
        -Message "provenance schema must remain pinned"
    Assert-True `
        -Condition ($provenance.angle.source_url -eq
            "https://chromium.googlesource.com/angle/angle.git") `
        -Message "ANGLE must use Google's official source"
    Assert-True `
        -Condition ($provenance.angle.depot_tools_url -eq
            "https://chromium.googlesource.com/chromium/tools/depot_tools.git") `
        -Message "depot_tools must use Google's official source"
    Assert-True `
        -Condition ($provenance.libmpv.license_mode_evidence.redistribution_status -eq
            "blocked_pending_transitive_license_inventory") `
        -Message "public redistribution must remain blocked pending license inventory"
    Assert-True `
        -Condition (-not $provenance.libmpv.release_audit.builder_recipe.all_transitive_source_revisions_resolved) `
        -Message "release audit must retain the unresolved transitive source-revision gate"
    Assert-True `
        -Condition (@($provenance.libmpv.release_audit.archive_inventory.license_or_notice_files).Count -eq 0) `
        -Message "release audit must record that the archives contain no notices"

    $validBundles = @{}
    foreach ($architecture in @("x64", "arm64")) {
        $bundle = New-SyntheticAngleBundle `
            -Root (Join-Path $testRoot "valid-$architecture") `
            -Architecture $architecture `
            -Provenance $provenance
        $validBundles[$architecture] = $bundle
        $result = Invoke-BundleValidation `
            -Bundle $bundle `
            -Provenance $provenance `
            -Architecture $architecture
        Assert-True `
            -Condition ($result.architecture -eq $architecture) `
            -Message "valid $architecture bundle must pass"
        $wrapperResult = & (
            Join-Path $PSScriptRoot "verify_native_media.ps1"
        ) `
            -BundleRoot $bundle.root `
            -ManifestPath $bundle.manifest `
            -ProvenancePath $provenancePath `
            -Architecture $architecture |
            ConvertFrom-Json
        Assert-True `
            -Condition ($wrapperResult.architecture -eq $architecture) `
            -Message "standalone verifier must accept valid $architecture bundle"
    }

    $wrongMachine = New-SyntheticAngleBundle `
        -Root (Join-Path $testRoot "wrong-machine") `
        -Architecture "x64" `
        -Provenance $provenance
    $wrongFile = Join-Path $wrongMachine.root $wrongMachine.runtime_files[0]
    New-FakePe -Path $wrongFile -Machine "ARM64"
    $wrongManifest = Get-Content -LiteralPath $wrongMachine.manifest -Raw |
        ConvertFrom-Json
    $wrongManifest.files[0].sha256 = Get-Sha256Hex -Path $wrongFile
    Write-Utf8NoBom `
        -Path $wrongMachine.manifest `
        -Content ($wrongManifest | ConvertTo-Json -Depth 10)
    Assert-Throws `
        -Action {
            Invoke-BundleValidation `
                -Bundle $wrongMachine `
                -Provenance $provenance `
                -Architecture "x64"
        } `
        -MessagePattern "PE machine mismatch"

    $badHash = New-SyntheticAngleBundle `
        -Root (Join-Path $testRoot "bad-hash") `
        -Architecture "x64" `
        -Provenance $provenance
    $badHashManifest = Get-Content -LiteralPath $badHash.manifest -Raw |
        ConvertFrom-Json
    $badHashManifest.files[0].sha256 = "0" * 64
    Write-Utf8NoBom `
        -Path $badHash.manifest `
        -Content ($badHashManifest | ConvertTo-Json -Depth 10)
    Assert-Throws `
        -Action {
            Invoke-BundleValidation `
                -Bundle $badHash `
                -Provenance $provenance `
                -Architecture "x64"
        } `
        -MessagePattern "SHA-256 mismatch"

    $missing = New-SyntheticAngleBundle `
        -Root (Join-Path $testRoot "missing") `
        -Architecture "x64" `
        -Provenance $provenance
    Remove-Item -LiteralPath (
        Join-Path $missing.root $missing.runtime_files[0]
    ) -Force
    Assert-Throws `
        -Action {
            Invoke-BundleValidation `
                -Bundle $missing `
                -Provenance $provenance `
                -Architecture "x64"
        } `
        -MessagePattern "missing required manifest file"

    $unlisted = New-SyntheticAngleBundle `
        -Root (Join-Path $testRoot "unlisted") `
        -Architecture "x64" `
        -Provenance $provenance
    New-FakePe `
        -Path (Join-Path $unlisted.root "bin\opaque.dll") `
        -Machine "X64"
    Assert-Throws `
        -Action {
            Invoke-BundleValidation `
                -Bundle $unlisted `
                -Provenance $provenance `
                -Architecture "x64"
        } `
        -MessagePattern "unlisted PE runtime"

    $unlistedOutsideBin = New-SyntheticAngleBundle `
        -Root (Join-Path $testRoot "unlisted-outside-bin") `
        -Architecture "x64" `
        -Provenance $provenance
    New-FakePe `
        -Path (Join-Path $unlistedOutsideBin.root (
            "licenses\source-tree\third_party\synthetic\opaque.exe"
        )) `
        -Machine "X64"
    Assert-Throws `
        -Action {
            Invoke-BundleValidation `
                -Bundle $unlistedOutsideBin `
                -Provenance $provenance `
                -Architecture "x64"
        } `
        -MessagePattern "unlisted PE runtime"

    $listedExtra = New-SyntheticAngleBundle `
        -Root (Join-Path $testRoot "listed-extra") `
        -Architecture "x64" `
        -Provenance $provenance
    $listedExtraPath = Join-Path $listedExtra.root "bin\opaque.dll"
    New-FakePe -Path $listedExtraPath -Machine "X64"
    $listedExtraManifest = Get-Content `
        -LiteralPath $listedExtra.manifest `
        -Raw |
        ConvertFrom-Json
    $listedExtraManifest.files = @($listedExtraManifest.files) + @(
        [pscustomobject]@{
            relative_path = "bin/opaque.dll"
            sha256 = Get-Sha256Hex -Path $listedExtraPath
            pe_machine = "X64"
            origin = "synthetic unreviewed fixture"
        }
    )
    Write-Utf8NoBom `
        -Path $listedExtra.manifest `
        -Content ($listedExtraManifest | ConvertTo-Json -Depth 10)
    Assert-Throws `
        -Action {
            Invoke-BundleValidation `
                -Bundle $listedExtra `
                -Provenance $provenance `
                -Architecture "x64"
        } `
        -MessagePattern "unexpected runtime file"

    $badEvidence = New-SyntheticAngleBundle `
        -Root (Join-Path $testRoot "bad-evidence") `
        -Architecture "x64" `
        -Provenance $provenance
    Add-Content -LiteralPath (
        Join-Path $badEvidence.root "provenance\gn-args.txt"
    ) -Value "tampered"
    Assert-Throws `
        -Action {
            Invoke-BundleValidation `
                -Bundle $badEvidence `
                -Provenance $provenance `
                -Architecture "x64"
        } `
        -MessagePattern "evidence hash mismatch"

    $badLicense = New-SyntheticAngleBundle `
        -Root (Join-Path $testRoot "bad-license") `
        -Architecture "x64" `
        -Provenance $provenance
    Add-Content -LiteralPath (
        Join-Path $badLicense.root (
            "licenses\source-tree\third_party\synthetic\LICENSE"
        )
    ) -Value "tampered"
    Assert-Throws `
        -Action {
            Invoke-BundleValidation `
                -Bundle $badLicense `
                -Provenance $provenance `
                -Architecture "x64"
        } `
        -MessagePattern "third-party license hash mismatch"

    Assert-Throws `
        -Action {
            Assert-SafeRelativePath `
                -Root $testRoot `
                -RelativePath "..\escape.dll"
        } `
        -MessagePattern "escapes"

    $prohibitedBinaries = @(
        Get-ChildItem -LiteralPath $packageRoot -File -Recurse |
            Where-Object {
                $_.Extension.ToLowerInvariant() -in @(
                    ".dll", ".exe", ".7z", ".zip", ".lib"
                )
            }
    )
    Assert-True `
        -Condition ($prohibitedBinaries.Count -eq 0) `
        -Message "no native binaries or archives may be committed in the package"

    $textFiles = @(
        Get-ChildItem -LiteralPath $packageRoot -File -Recurse |
            Where-Object {
                $_.Extension.ToLowerInvariant() -in @(
                    ".md", ".json", ".yaml", ".yml", ".txt",
                    ".ps1", ".psm1", ".cmake"
                ) -or $_.Name -eq "CMakeLists.txt"
            }
    )
    $prohibitedPattern = @(
        ("alex" + "mercerind"),
        ("file\s*\(\s*M" + "D5"),
        ("LIBMPV_M" + "D5"),
        ("ANGLE_M" + "D5")
    ) -join "|"
    $prohibitedText = @(
        $textFiles |
            Select-String -Pattern $prohibitedPattern
    )
    Assert-True `
        -Condition ($prohibitedText.Count -eq 0) `
        -Message "opaque ANGLE URLs and MD5 verification must not return"

    $powershellFiles = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -File |
            Where-Object { $_.Extension -in @(".ps1", ".psm1") }
    )
    foreach ($file in $powershellFiles) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref] $tokens,
            [ref] $errors
        ) | Out-Null
        Assert-True `
            -Condition ($errors.Count -eq 0) `
            -Message "$($file.Name) must parse without PowerShell errors"
    }

    foreach ($architecture in @("x64", "arm64")) {
        $planOutput = & (
            Join-Path $PSScriptRoot "build_official_angle.ps1"
        ) `
            -Architecture $architecture `
            -WorkRoot (Join-Path $testRoot "plan-work-$architecture") `
            -OutputRoot (Join-Path $testRoot "plan-output-$architecture") `
            -ValidateOnly
        if ($LASTEXITCODE -ne 0) {
            throw "ANGLE build plan validation failed for $architecture."
        }
        $plan = ($planOutput | Out-String) | ConvertFrom-Json
        Assert-True `
            -Condition ($plan.architecture -eq $architecture) `
            -Message "ANGLE build plan must resolve $architecture"
    }

    $integrationArchives = @{
        x64 = $X64LibmpvArchive
        arm64 = $Arm64LibmpvArchive
    }
    foreach ($architecture in @("x64", "arm64")) {
        $integrationArchive = $integrationArchives[$architecture]
        if (-not $integrationArchive) {
            continue
        }
        $archiveEntries = @(
            & cmake -E tar tf $integrationArchive |
                ForEach-Object { ([string] $_).Trim().Replace('\', '/') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $expectedEntryCount = if ($architecture -eq "x64") {
            [int] $provenance.libmpv.release_audit.archive_inventory.x64_entry_count
        }
        else {
            [int] $provenance.libmpv.release_audit.archive_inventory.arm64_entry_count
        }
        Assert-True `
            -Condition ($archiveEntries.Count -eq $expectedEntryCount) `
            -Message "$architecture archive entry count must match the reviewed inventory"
        $archiveNoticeFiles = @(
            $archiveEntries |
                Where-Object {
                    $_ -match '(?i)(^|/)(license|copying|notice)(?:[._-].*)?$'
                }
        )
        Assert-True `
            -Condition ($archiveNoticeFiles.Count -eq 0) `
            -Message "$architecture archive must not silently gain or lose unreviewed notices"
        $integrationRoot = Join-Path $testRoot "resolver-$architecture"
        $generatedCmake = Join-Path $integrationRoot "native-media.cmake"
        $resolutionPath = Join-Path $integrationRoot "resolution.json"
        $prepareOutput = & (
            Join-Path $PSScriptRoot "prepare_native_media.ps1"
        ) `
            -Architecture $architecture `
            -AngleBundleRoot $validBundles[$architecture].root `
            -CacheRoot (Join-Path $integrationRoot "cache") `
            -GeneratedCmakePath $generatedCmake `
            -ResolutionPath $resolutionPath `
            -LibmpvArchivePath $integrationArchive `
            -Offline
        if ($LASTEXITCODE -ne 0) {
            throw "Native resolver integration failed for $architecture."
        }
        $prepareOutput | Out-Null
        $resolution = Get-Content -LiteralPath $resolutionPath -Raw |
            ConvertFrom-Json
        Assert-True `
            -Condition ($resolution.architecture -eq $architecture) `
            -Message "resolver must preserve $architecture"
        Assert-True `
            -Condition (@($resolution.runtime_files).Count -eq 3) `
            -Message "resolver must emit libmpv and two ANGLE runtimes"
        Assert-True `
            -Condition (Test-Path -LiteralPath $generatedCmake -PathType Leaf) `
            -Message "resolver must emit CMake input"
        $portableEvidencePath = Join-Path (
            Join-Path $integrationRoot "cache"
        ) "native-media-package-evidence.json"
        $portableAnglePath = Join-Path (
            Join-Path $integrationRoot "cache"
        ) "angle-native-manifest.json"
        Assert-True `
            -Condition (Test-Path -LiteralPath $portableEvidencePath -PathType Leaf) `
            -Message "resolver must emit portable package evidence"
        Assert-True `
            -Condition (Test-Path -LiteralPath $portableAnglePath -PathType Leaf) `
            -Message "resolver must emit a portable ANGLE manifest"
        $portableEvidenceRaw = Get-Content -LiteralPath $portableEvidencePath -Raw
        $portableAngleRaw = Get-Content -LiteralPath $portableAnglePath -Raw
        Assert-True `
            -Condition (-not $portableEvidenceRaw.Contains($integrationRoot)) `
            -Message "portable package evidence must omit local cache paths"
        Assert-True `
            -Condition (-not $portableAngleRaw.Contains($integrationRoot)) `
            -Message "portable ANGLE evidence must omit local cache paths"
        $portableEvidence = $portableEvidenceRaw | ConvertFrom-Json
        Assert-True `
            -Condition ($portableEvidence.architecture -eq $architecture) `
            -Message "portable evidence must preserve $architecture"
        Assert-True `
            -Condition (@($portableEvidence.runtime_files).Count -eq 3) `
            -Message "portable evidence must inventory all three runtime DLLs"
        Assert-True `
            -Condition (-not $portableEvidence.release_gate.public_redistribution_allowed) `
            -Message "portable evidence must retain the public release gate"
        Assert-True `
            -Condition ($portableEvidence.libmpv.redistribution_status -eq
                "blocked_pending_transitive_license_inventory") `
            -Message "portable evidence must retain the libmpv license blocker"
        $generatedCmakeText = Get-Content -LiteralPath $generatedCmake -Raw
        foreach ($requiredVariable in @(
            "MEDIA_KIT_NATIVE_MEDIA_PACKAGE_EVIDENCE",
            "MEDIA_KIT_NATIVE_MEDIA_ANGLE_MANIFEST",
            "MEDIA_KIT_NATIVE_MEDIA_LIBMPV_MANIFEST"
        )) {
            Assert-True `
                -Condition $generatedCmakeText.Contains($requiredVariable) `
                -Message "generated CMake must expose $requiredVariable"
        }
        & (Join-Path $PSScriptRoot "prepare_native_media.ps1") `
            -Architecture $architecture `
            -AngleBundleRoot $validBundles[$architecture].root `
            -CacheRoot (Join-Path $integrationRoot "cache") `
            -GeneratedCmakePath $generatedCmake `
            -ResolutionPath $resolutionPath `
            -LibmpvArchivePath $integrationArchive `
            -Offline |
            Out-Null
        Assert-True `
            -Condition ($LASTEXITCODE -eq 0) `
            -Message "resolver cache reuse must be idempotent for $architecture"

        $cmakeSource = Join-Path $integrationRoot "cmake-source"
        $cmakeBuild = Join-Path $integrationRoot "cmake-build"
        $fakeFlutter = Join-Path $cmakeSource "fake-flutter"
        Write-Utf8NoBom `
            -Path (Join-Path $fakeFlutter "flutter_plugin_registrar.h") `
            -Content @"
#ifndef FLUTTER_PLUGIN_REGISTRAR_H_
#define FLUTTER_PLUGIN_REGISTRAR_H_
typedef void* FlutterDesktopPluginRegistrarRef;
#endif
"@
        Write-Utf8NoBom `
            -Path (Join-Path $fakeFlutter "flutter/plugin_registrar_windows.h") `
            -Content @"
#ifndef FLUTTER_PLUGIN_REGISTRAR_WINDOWS_H_
#define FLUTTER_PLUGIN_REGISTRAR_WINDOWS_H_
#include "../flutter_plugin_registrar.h"
#endif
"@
        $windowsPackage = (
            Join-Path $packageRoot "windows"
        ).Replace('\', '/')
        $fakeFlutterForCmake = $fakeFlutter.Replace('\', '/')
        $angleForCmake = $validBundles[$architecture].root.Replace('\', '/')
        $archiveForCmake = (
            Resolve-Path -LiteralPath $integrationArchive
        ).Path.Replace('\', '/')
        $fixture = @"
cmake_minimum_required(VERSION 3.14)
project(openbubbles_native_media_configure_smoke LANGUAGES CXX)
function(apply_standard_settings target)
endfunction()
add_library(flutter INTERFACE)
add_library(flutter_wrapper_plugin INTERFACE)
target_include_directories(flutter INTERFACE "$fakeFlutterForCmake")
set(MEDIA_KIT_OFFICIAL_ANGLE_ROOT "$angleForCmake" CACHE PATH "" FORCE)
set(MEDIA_KIT_LIBMPV_ARCHIVE "$archiveForCmake" CACHE FILEPATH "" FORCE)
set(MEDIA_KIT_NATIVE_MEDIA_OFFLINE ON CACHE BOOL "" FORCE)
add_subdirectory("$windowsPackage" media_kit_native)
install(
    FILES `${media_kit_libs_windows_video_bundled_libraries}
    DESTINATION bundle
)
install(
    FILES `${media_kit_libs_windows_video_portable_evidence_files}
    DESTINATION bundle/data/native-media
)
install(
    DIRECTORY "`${media_kit_libs_windows_video_angle_license_directory}/"
    DESTINATION bundle/data/native-media/angle-licenses
)
"@
        Write-Utf8NoBom `
            -Path (Join-Path $cmakeSource "CMakeLists.txt") `
            -Content $fixture
        $vsArchitecture = if ($architecture -eq "arm64") { "ARM64" } else { "x64" }
        $cmakeCapabilities = (& cmake -E capabilities | Out-String) |
            ConvertFrom-Json
        $vsGenerator = @(
            $cmakeCapabilities.generators |
                Where-Object {
                    $_.platformSupport -and
                    $_.name -match '^Visual Studio ([0-9]+) [0-9]+$'
                } |
                ForEach-Object {
                    [pscustomobject]@{
                        name = $_.name
                        major = [int] (
                            [regex]::Match(
                                $_.name,
                                '^Visual Studio ([0-9]+)'
                            ).Groups[1].Value
                        )
                    }
                } |
                Sort-Object major -Descending
        )[0]
        if (-not $vsGenerator) {
            throw "No platform-capable Visual Studio CMake generator is installed."
        }
        $cmakeOutput = & cmake `
            -S $cmakeSource `
            -B $cmakeBuild `
            -G $vsGenerator.name `
            -A $vsArchitecture 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "CMake configure smoke failed for ${architecture}:`n$($cmakeOutput | Out-String)"
        }
        Assert-True `
            -Condition (Test-Path -LiteralPath (
                Join-Path $cmakeBuild "CMakeCache.txt"
            )) `
            -Message "CMake must configure the $architecture package"

        $buildOutput = & cmake `
            --build $cmakeBuild `
            --config Release `
            --target media_kit_libs_windows_video_plugin 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "CMake plugin build failed for ${architecture}:`n$($buildOutput | Out-String)"
        }
        $pluginDlls = @(
            Get-ChildItem -LiteralPath $cmakeBuild -Recurse -File `
                -Filter "media_kit_libs_windows_video_plugin.dll"
        )
        Assert-True `
            -Condition ($pluginDlls.Count -eq 1) `
            -Message "CMake must produce one $architecture registration DLL"
        $expectedPluginMachine = if ($architecture -eq "arm64") {
            "ARM64"
        }
        else {
            "X64"
        }
        Assert-True `
            -Condition ((Get-PEMachine -Path $pluginDlls[0].FullName) -eq
                $expectedPluginMachine) `
            -Message "registration DLL must target $expectedPluginMachine"

        $installRoot = Join-Path $integrationRoot "cmake-install"
        $installOutput = & cmake `
            --install $cmakeBuild `
            --config Release `
            --prefix $installRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "CMake package install failed for ${architecture}:`n$($installOutput | Out-String)"
        }
        $installedBundle = Join-Path $installRoot "bundle"
        foreach ($runtimeName in @(
            "libmpv-2.dll",
            "libEGL.dll",
            "libGLESv2.dll"
        )) {
            $installedRuntime = Join-Path $installedBundle $runtimeName
            Assert-True `
                -Condition (Test-Path -LiteralPath $installedRuntime -PathType Leaf) `
                -Message "CMake install must package $runtimeName for $architecture"
            Assert-True `
                -Condition ((Get-PEMachine -Path $installedRuntime) -eq
                    $expectedPluginMachine) `
                -Message "installed $runtimeName must target $expectedPluginMachine"
        }
        $installedEvidence = Join-Path $installedBundle "data\native-media"
        foreach ($evidenceName in @(
            "native-media-package-evidence.json",
            "angle-native-manifest.json",
            "extraction-manifest.json",
            "native-dependencies.json",
            "THIRD_PARTY_NOTICES.md",
            "angle-licenses\ANGLE-LICENSE.txt",
            "angle-licenses\license-inventory.json"
        )) {
            Assert-True `
                -Condition (Test-Path -LiteralPath (
                    Join-Path $installedEvidence $evidenceName
                ) -PathType Leaf) `
                -Message "CMake install must package $evidenceName"
        }
        $installedPortableEvidence = Get-Content -LiteralPath (
            Join-Path $installedEvidence "native-media-package-evidence.json"
        ) -Raw
        Assert-True `
            -Condition (-not $installedPortableEvidence.Contains($integrationRoot)) `
            -Message "installed evidence must not expose the local build path"

        $cachedLibmpv = @(
            $resolution.runtime_files |
                Where-Object { $_.role -eq "libmpv" }
        )[0].path
        $tamperStream = [System.IO.File]::OpenWrite($cachedLibmpv)
        try {
            $tamperStream.Position = $tamperStream.Length
            $tamperStream.WriteByte(0x00)
        }
        finally {
            $tamperStream.Dispose()
        }
        Assert-Throws `
            -Action {
                & (Join-Path $PSScriptRoot "prepare_native_media.ps1") `
                    -Architecture $architecture `
                    -AngleBundleRoot $validBundles[$architecture].root `
                    -CacheRoot (Join-Path $integrationRoot "cache") `
                    -GeneratedCmakePath $generatedCmake `
                    -ResolutionPath $resolutionPath `
                    -LibmpvArchivePath $integrationArchive `
                    -Offline |
                    Out-Null
            } `
            -MessagePattern "extraction hash mismatch"
    }
}
finally {
    if (Test-Path -LiteralPath $testRootFull) {
        Remove-Item -LiteralPath $testRootFull -Recurse -Force
    }
}

[pscustomobject]@{
    result = "passed"
    assertions = $script:Passed
    package_root = $packageRoot
} | ConvertTo-Json -Depth 4
