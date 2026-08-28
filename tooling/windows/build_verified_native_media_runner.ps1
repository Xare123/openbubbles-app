[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("x64", "arm64")]
    [string] $Architecture,

    [Parameter(Mandatory)]
    [string] $AngleBundleRoot,

    [string] $FlutterRoot,

    [string] $LibmpvArchivePath,

    [ValidateSet("debug", "profile", "release")]
    [string] $Configuration = "release",

    [switch] $Offline,

    [switch] $SkipPubGet,

    [string] $RepoRoot = (
        Resolve-Path (Join-Path $PSScriptRoot "..\..")
    ).Path
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [string[]] $ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($ArgumentList -join ' ')"
    }
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string] $Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Resolve-NuGetExecutable {
    param([string] $RequestedPath)

    $candidates = @()
    if ($RequestedPath) {
        $candidates += $RequestedPath
    }
    $command = Get-Command nuget.exe -ErrorAction SilentlyContinue
    if ($command) {
        $candidates += $command.Source
    }
    $candidates += "C:\Codex\Toolchains\nuget\nuget.exe"
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw "NuGet.exe is required by the Windows WebView plugins, but no existing executable was found."
}

function Patch-MediaKitVideoAngleD3d9Fallback {
    param(
        [Parameter(Mandatory)]
        [string] $PackageConfigPath
    )

    if (-not (Test-Path -LiteralPath $PackageConfigPath -PathType Leaf)) {
        throw "Dart package configuration is missing; cannot apply the reviewed media_kit_video compatibility overlay."
    }

    $packageConfig = Get-Content -LiteralPath $PackageConfigPath -Raw |
        ConvertFrom-Json -ErrorAction Stop
    $matches = @(
        $packageConfig.packages |
            Where-Object { $_.name -eq "media_kit_video" }
    )
    if ($matches.Count -ne 1) {
        throw "Expected exactly one media_kit_video package in Dart package configuration, found $($matches.Count)."
    }

    $packageUri = [Uri] ([string] $matches[0].rootUri)
    if (-not $packageUri.IsAbsoluteUri -or $packageUri.Scheme -ne "file") {
        throw "media_kit_video rootUri is not a local file URI."
    }
    $packageRoot = $packageUri.LocalPath.TrimEnd('\', '/')
    $headerPath = Join-Path $packageRoot "windows\angle_surface_manager.h"
    $sourcePath = Join-Path $packageRoot "windows\angle_surface_manager.cc"
    foreach ($path in @($headerPath, $sourcePath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Pinned media_kit_video source is missing the expected Windows file: $path"
        }
    }

    $header = (Get-Content -LiteralPath $headerPath -Raw).Replace("`r`n", "`n")
    $source = (Get-Content -LiteralPath $sourcePath -Raw).Replace("`r`n", "`n")
    $headerBefore = @"
  static constexpr EGLint kD3D9DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D9_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE,
      EGL_NONE,
  };
"@
    $headerAfter = ""
    $sourceBefore = @"
          display_ = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE,
                                              EGL_DEFAULT_DISPLAY,
                                              kD3D9DisplayAttributes);
            if (eglInitialize(display_, 0, 0) == EGL_FALSE) {
              display_ = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE,
                                                  EGL_DEFAULT_DISPLAY,
                                                  kWrapDisplayAttributes);
              if (eglInitialize(display_, 0, 0) == EGL_FALSE) {
                FAIL("eglGetPlatformDisplayEXT");
              }
            }
"@
    $sourceAfter = @"
          display_ = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE,
                                              EGL_DEFAULT_DISPLAY,
                                              kWrapDisplayAttributes);
          if (eglInitialize(display_, 0, 0) == EGL_FALSE) {
            FAIL("eglGetPlatformDisplayEXT");
          }
"@

    $headerCount = ([regex]::Matches($header, [regex]::Escape($headerBefore))).Count
    $sourceCount = ([regex]::Matches($source, [regex]::Escape($sourceBefore))).Count
    if ($headerCount -eq 1 -and $sourceCount -eq 1) {
        [IO.File]::WriteAllText(
            $headerPath,
            $header.Replace($headerBefore, $headerAfter),
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            $sourcePath,
            $source.Replace($sourceBefore, $sourceAfter),
            [Text.UTF8Encoding]::new($false)
        )
        Write-Host "Applied reviewed media_kit_video ANGLE compatibility overlay: removed unsupported D3D9 fallback."
        return
    }

    $headerAlreadyPatched =
        $header -notmatch "EGL_PLATFORM_ANGLE_TYPE_D3D9_ANGLE" -and
        $header -match "kWrapDisplayAttributes"
    $sourceAlreadyPatched =
        $source -notmatch "kD3D9DisplayAttributes" -and
        $source -match "kWrapDisplayAttributes"
    if ($headerAlreadyPatched -and $sourceAlreadyPatched) {
        Write-Host "Reviewed media_kit_video ANGLE compatibility overlay is already present."
        return
    }

    throw "Refusing to patch unexpected media_kit_video ANGLE source layout (header matches: $headerCount, source matches: $sourceCount)."
}

$repo = Get-NormalizedPath -Path $RepoRoot
$package = Join-Path $repo "packages\media_kit_libs_windows_video"
$nuget = Resolve-NuGetExecutable
$verificationModule = Join-Path $package "tool\NativeMediaVerification.psm1"
$bundleVerifier = Join-Path $package "tool\verify_native_media.ps1"
$runtimeSmoke = Join-Path $package "tool\runtime_smoke.ps1"
$librarySmoke = Join-Path $package "tool\smoke_library.dart"
$integrationVerifier = Join-Path $repo (
    "tooling\windows\verify_native_media_integration.ps1"
)

if ($FlutterRoot) {
    $flutter = Join-Path (Get-NormalizedPath -Path $FlutterRoot) "bin\flutter.bat"
    $dart = Join-Path (Get-NormalizedPath -Path $FlutterRoot) "bin\dart.bat"
}
else {
    $flutterCommand = Get-Command flutter.bat -ErrorAction SilentlyContinue
    if (-not $flutterCommand) {
        $flutterCommand = Get-Command flutter -ErrorAction Stop
    }
    $flutter = $flutterCommand.Source
    $flutterHome = Split-Path (Split-Path $flutter -Parent) -Parent
    $dart = Join-Path $flutterHome "bin\dart.bat"
}
foreach ($tool in @($flutter, $dart, $verificationModule, $bundleVerifier,
    $runtimeSmoke, $librarySmoke, $integrationVerifier)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required build tool is missing: $tool"
    }
}

$angle = (Resolve-Path -LiteralPath $AngleBundleRoot -ErrorAction Stop).Path
$provenance = Join-Path $package "provenance\native-dependencies.json"
Invoke-Checked `
    -FilePath "pwsh" `
    -ArgumentList @(
        "-NoLogo", "-NoProfile", "-File", $bundleVerifier,
        "-Architecture", $Architecture,
        "-BundleRoot", $angle,
        "-ManifestPath", (Join-Path $angle "native-manifest.json"),
        "-ProvenancePath", $provenance
    )

$dartVersion = (& $dart --version 2>&1 | Out-String).Trim()
$expectedDartArch = if ($Architecture -eq "arm64") {
    "windows_arm64"
}
else {
    "windows_x64"
}
if ($dartVersion -notmatch [regex]::Escape($expectedDartArch)) {
    throw "The Flutter toolchain must use $expectedDartArch Dart; got: $dartVersion"
}

if ($LibmpvArchivePath) {
    $libmpvArchive = (
        Resolve-Path -LiteralPath $LibmpvArchivePath -ErrorAction Stop
    ).Path
}
else {
    $libmpvArchive = $null
}

$previousAngle = $env:MEDIA_KIT_OFFICIAL_ANGLE_ROOT
$previousArchive = $env:MEDIA_KIT_LIBMPV_ARCHIVE
$previousPath = $env:PATH
try {
    $env:MEDIA_KIT_OFFICIAL_ANGLE_ROOT = $angle
    $env:PATH = "$(Split-Path -Parent $nuget);$env:PATH"
    if ($libmpvArchive) {
        $env:MEDIA_KIT_LIBMPV_ARCHIVE = $libmpvArchive
    }
    else {
        Remove-Item Env:MEDIA_KIT_LIBMPV_ARCHIVE -ErrorAction SilentlyContinue
    }

    Push-Location $repo
    try {
        Invoke-Checked `
            -FilePath $flutter `
            -ArgumentList @("config", "--enable-windows-desktop")
        if (-not $SkipPubGet) {
            $pubArguments = @("pub", "get")
            if ($Offline) {
                $pubArguments += "--offline"
            }
            Invoke-Checked -FilePath $flutter -ArgumentList $pubArguments
        }
        Patch-MediaKitVideoAngleD3d9Fallback `
            -PackageConfigPath (Join-Path $repo ".dart_tool\package_config.json")
        Invoke-Checked `
            -FilePath "pwsh" `
            -ArgumentList @(
                "-NoLogo", "-NoProfile", "-File", $integrationVerifier,
                "-RequireEphemeralSymlink"
            )
        $windowsBuild = Join-Path $repo "build\windows\$Architecture"
        $cmakeCache = Join-Path $windowsBuild "CMakeCache.txt"
        if ((Test-Path -LiteralPath $cmakeCache -PathType Leaf) -and
            (Select-String -LiteralPath $cmakeCache -Pattern '^NUGET:FILEPATH=NUGET-NOTFOUND$' -Quiet)) {
            $cmakeCommand = Get-Command cmake.exe -ErrorAction Stop
            $generator = (
                Select-String -LiteralPath $cmakeCache -Pattern '^CMAKE_GENERATOR:INTERNAL=(.*)$'
            ).Matches.Groups[1].Value
            $platform = (
                Select-String -LiteralPath $cmakeCache -Pattern '^CMAKE_GENERATOR_PLATFORM:INTERNAL=(.*)$'
            ).Matches.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($generator) -or
                [string]::IsNullOrWhiteSpace($platform)) {
                throw "The existing Windows CMake cache is missing its generator or platform."
            }
            Invoke-Checked `
                -FilePath $cmakeCommand.Source `
                -ArgumentList @(
                    "-S", (Join-Path $repo "windows"),
                    "-B", $windowsBuild,
                    "-G", $generator,
                    "-A", $platform,
                    "-DNUGET:FILEPATH=$nuget"
                )
            if (Select-String -LiteralPath $cmakeCache -Pattern '^NUGET:FILEPATH=NUGET-NOTFOUND$' -Quiet) {
                throw "CMake did not accept the discovered NuGet executable: $nuget"
            }
        }
        Invoke-Checked `
            -FilePath $flutter `
            -ArgumentList @(
                "build", "windows", "--$Configuration", "--no-pub"
            )
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($null -eq $previousAngle) {
        Remove-Item Env:MEDIA_KIT_OFFICIAL_ANGLE_ROOT -ErrorAction SilentlyContinue
    }
    else {
        $env:MEDIA_KIT_OFFICIAL_ANGLE_ROOT = $previousAngle
    }
    if ($null -eq $previousArchive) {
        Remove-Item Env:MEDIA_KIT_LIBMPV_ARCHIVE -ErrorAction SilentlyContinue
    }
    else {
        $env:MEDIA_KIT_LIBMPV_ARCHIVE = $previousArchive
    }
    $env:PATH = $previousPath
}

$configurationDirectory = (Get-Culture).TextInfo.ToTitleCase($Configuration)
$bundle = Join-Path $repo (
    "build\windows\$Architecture\runner\$configurationDirectory"
)
if (-not (Test-Path -LiteralPath $bundle -PathType Container)) {
    throw "Flutter did not produce the expected $Architecture bundle: $bundle"
}

Import-Module $verificationModule -Force
$expectedMachine = if ($Architecture -eq "arm64") { "ARM64" } else { "X64" }
$peInventory = @(
    Get-ChildItem -LiteralPath $bundle -File |
        Where-Object { $_.Extension.ToLowerInvariant() -in @(".dll", ".exe") } |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                file_name = $_.Name
                sha256 = Get-Sha256Hex -Path $_.FullName
                pe_machine = Get-PEMachine -Path $_.FullName
            }
        }
)
if ($peInventory.Count -eq 0) {
    throw "The Windows bundle contains no PE runtime files."
}
$wrongMachine = @(
    $peInventory |
        Where-Object { $_.pe_machine -ne $expectedMachine }
)
if ($wrongMachine.Count -gt 0) {
    throw "Bundle contains wrong-architecture PE files: $($wrongMachine | ConvertTo-Json -Compress)"
}

$evidenceRoot = Join-Path $bundle "data\native-media"
$requiredEvidence = @(
    "native-media-package-evidence.json",
    "angle-native-manifest.json",
    "extraction-manifest.json",
    "native-dependencies.json",
    "THIRD_PARTY_NOTICES.md",
    "angle-licenses\ANGLE-LICENSE.txt",
    "angle-licenses\license-inventory.json"
)
foreach ($relative in $requiredEvidence) {
    $required = Join-Path $evidenceRoot $relative
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Runner bundle is missing required native-media evidence: $relative"
    }
}

$packageEvidencePath = Join-Path $evidenceRoot (
    "native-media-package-evidence.json"
)
$packageEvidenceRaw = Get-Content -LiteralPath $packageEvidencePath -Raw
if ($packageEvidenceRaw -match '(?i)(?<![a-z])[a-z]:[\\/]|\\\\\\\\[^\\]') {
    throw "Installed native-media evidence contains an absolute Windows path."
}
$packageEvidence = $packageEvidenceRaw | ConvertFrom-Json -ErrorAction Stop
if ($packageEvidence.architecture -ne $Architecture) {
    throw "Installed native-media evidence architecture is incorrect."
}
if ($packageEvidence.release_gate.public_redistribution_allowed) {
    throw "Public redistribution gate must remain closed."
}

foreach ($runtime in @($packageEvidence.runtime_files)) {
    $runtimePath = Join-Path $bundle ([string] $runtime.file_name)
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        throw "Runner bundle is missing native media runtime: $($runtime.file_name)"
    }
    if ((Get-Sha256Hex -Path $runtimePath) -ne [string] $runtime.sha256) {
        throw "Runner native media hash mismatch: $($runtime.file_name)"
    }
    if ((Get-PEMachine -Path $runtimePath) -ne $expectedMachine) {
        throw "Runner native media PE mismatch: $($runtime.file_name)"
    }
}

$libmpvEvidence = @(
    $packageEvidence.runtime_files |
        Where-Object { $_.role -eq "libmpv" }
)
if ($libmpvEvidence.Count -ne 1) {
    throw "Portable evidence must contain exactly one libmpv runtime."
}
Invoke-Checked `
    -FilePath $dart `
    -ArgumentList @(
        $librarySmoke,
        (Join-Path $bundle ([string] $libmpvEvidence[0].file_name)),
        ([string] $libmpvEvidence[0].expected_export)
    )

$resolutionFiles = @(
    Get-ChildItem -LiteralPath (
        Join-Path $repo "build\windows\$Architecture"
    ) -Filter "native-media-resolution.json" -File -Recurse
)
if ($resolutionFiles.Count -ne 1) {
    throw "Expected exactly one native-media resolution record; found $($resolutionFiles.Count)."
}

$hostArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
$runtimeSmokeStatus = "skipped_host_architecture_$($hostArch.ToLowerInvariant())"
if ($hostArch -eq $expectedMachine) {
    Invoke-Checked `
        -FilePath "pwsh" `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $runtimeSmoke,
            "-ResolutionPath", $resolutionFiles[0].FullName
        )
    $runtimeSmokeStatus = "passed"
}

[pscustomobject]@{
    result = "passed"
    architecture = $Architecture
    configuration = $Configuration
    bundle = $bundle
    pe_files = $peInventory.Count
    native_runtime_files = @($packageEvidence.runtime_files).Count
    libmpv_toolchain_abi_load = "passed"
    runtime_smoke = $runtimeSmokeStatus
    public_redistribution_allowed = $false
} | ConvertTo-Json -Depth 6
