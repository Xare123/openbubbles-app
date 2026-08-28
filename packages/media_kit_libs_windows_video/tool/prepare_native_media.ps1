[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("x64", "arm64")]
    [string] $Architecture,

    [Parameter(Mandatory)]
    [string] $AngleBundleRoot,

    [Parameter(Mandatory)]
    [string] $CacheRoot,

    [Parameter(Mandatory)]
    [string] $GeneratedCmakePath,

    [string] $CompatibilityRoot,

    [string] $ResolutionPath,

    [string] $LibmpvArchivePath,

    [string] $ProvenancePath = (
        Join-Path $PSScriptRoot "..\provenance\native-dependencies.json"
    ),

    [switch] $Offline
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "NativeMediaVerification.psm1") -Force

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory)]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-SafeBuildPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Label
    )

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root) {
        throw "$Label cannot be a filesystem root: $full"
    }
    if ($full.Length -lt ($root.Length + 8)) {
        throw "$Label is too broad for generated native files: $full"
    }
    return $full
}

function Write-AtomicUtf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Content
    )

    $parent = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText(
            $temporary,
            $Content,
            [System.Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Invoke-CheckedCapture {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [string] $WorkingDirectory
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Unable to start command: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Command failed with exit code $($process.ExitCode): $FilePath $($ArgumentList -join ' ')`n$stdout`n$stderr"
        }
        if ($stderr) {
            Write-Verbose $stderr.Trim()
        }
        return @($stdout -split "`r?`n")
    }
    finally {
        $process.Dispose()
    }
}

function Assert-SafeArchiveListing {
    param(
        [Parameter(Mandatory)]
        [object[]] $Entries
    )

    foreach ($rawEntry in $Entries) {
        $entry = ([string] $rawEntry).Trim().Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        if ($entry.StartsWith("/") -or
            $entry -match '^[A-Za-z]:' -or
            $entry.Split('/') -contains '..') {
            throw "libmpv archive contains an unsafe path: $entry"
        }
    }
}

function Assert-ApprovedLibmpvUrl {
    param(
        [Parameter(Mandatory)]
        [string] $Url,

        [Parameter(Mandatory)]
        [string] $Release,

        [Parameter(Mandatory)]
        [string] $ArchiveName
    )

    $uri = [Uri] $Url
    $expectedPath = (
        "/media-kit/libmpv-win32-video-cmake/releases/download/" +
        "$Release/$ArchiveName"
    )
    if ($uri.Scheme -ne "https" -or
        $uri.Host -ne "github.com" -or
        $uri.AbsolutePath -ne $expectedPath -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "Refusing libmpv URL outside the reviewed GitHub release path: $Url"
    }
}

function ConvertTo-CmakePath {
    param([Parameter(Mandatory)][string] $Path)
    if ($Path.Contains('"')) {
        throw "CMake path contains an unsupported quote: $Path"
    }
    return $Path.Replace('\', '/')
}

function Install-VerifiedCompatibilityTree {
    param(
        [Parameter(Mandatory)][string] $TargetRoot,
        [Parameter(Mandatory)][string] $Kind,
        [Parameter(Mandatory)][ValidateSet("x64", "arm64")][string] $Architecture,
        [Parameter(Mandatory)][string] $SourceManifestSha256,
        [Parameter(Mandatory)][object[]] $Mappings
    )

    $target = Get-SafeBuildPath -Path $TargetRoot -Label "$Kind compatibility root"
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($mapping in $Mappings) {
        $source = (Resolve-Path -LiteralPath ([string] $mapping.source) -ErrorAction Stop).Path
        $relative = ([string] $mapping.relative_path).Replace('\', '/')
        Assert-SafeRelativePath -Root $target -RelativePath $relative | Out-Null
        if (-not $seen.Add($relative)) {
            throw "$Kind compatibility mapping contains duplicate path: $relative"
        }
        $entries.Add([pscustomobject]@{
            relative_path = $relative
            sha256 = Get-Sha256Hex -Path $source
            source = $source
        })
    }
    if ($entries.Count -eq 0) {
        throw "$Kind compatibility mapping is empty."
    }

    $expected = [ordered]@{
        schema_version = 1
        kind = $Kind
        architecture = $Architecture
        source_manifest_sha256 = $SourceManifestSha256
        files = @(
            $entries | ForEach-Object {
                [ordered]@{
                    relative_path = $_.relative_path
                    sha256 = $_.sha256
                }
            }
        )
    }

    if (Test-Path -LiteralPath $target -PathType Container) {
        $markerPath = Join-Path $target ".openbubbles-native-compat.json"
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw "Refusing unmarked existing $Kind compatibility tree: $target"
        }
        $existing = Get-Content -LiteralPath $markerPath -Raw |
            ConvertFrom-Json -ErrorAction Stop
        if ($existing.schema_version -ne 1 -or
            [string] $existing.kind -ne $Kind -or
            [string] $existing.architecture -ne $Architecture -or
            [string] $existing.source_manifest_sha256 -ne $SourceManifestSha256) {
            throw "Existing $Kind compatibility tree does not match the verified source."
        }
        $existingFiles = @($existing.files)
        if ($existingFiles.Count -ne $entries.Count) {
            throw "Existing $Kind compatibility inventory has the wrong file count."
        }
        $expectedByPath = @{}
        foreach ($entry in $entries) {
            $expectedByPath[$entry.relative_path] = $entry.sha256
        }
        foreach ($entry in $existingFiles) {
            $relative = ([string] $entry.relative_path).Replace('\', '/')
            if (-not $expectedByPath.ContainsKey($relative) -or
                [string] $entry.sha256 -ne $expectedByPath[$relative]) {
                throw "Existing $Kind compatibility inventory mismatch: $relative"
            }
            $file = Assert-SafeRelativePath -Root $target -RelativePath $relative
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
                (Get-Sha256Hex -Path $file) -ne $expectedByPath[$relative]) {
                throw "Existing $Kind compatibility file mismatch: $relative"
            }
        }
        $actualFiles = @(
            Get-ChildItem -LiteralPath $target -File -Recurse |
                Where-Object { $_.FullName -ne $markerPath }
        )
        if ($actualFiles.Count -ne $entries.Count) {
            throw "Existing $Kind compatibility tree contains unlisted files."
        }
        return $target
    }

    $parent = Split-Path $target -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = "$target.stage-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        foreach ($entry in $entries) {
            $destination = Assert-SafeRelativePath `
                -Root $stage `
                -RelativePath $entry.relative_path
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force |
                Out-Null
            Copy-Item -LiteralPath $entry.source -Destination $destination
            if ((Get-Sha256Hex -Path $destination) -ne $entry.sha256) {
                throw "$Kind compatibility copy hash mismatch: $($entry.relative_path)"
            }
        }
        Write-AtomicUtf8NoBom `
            -Path (Join-Path $stage ".openbubbles-native-compat.json") `
            -Content ($expected | ConvertTo-Json -Depth 8)
        if (Test-Path -LiteralPath $target) {
            throw "Refusing to overwrite an existing $Kind compatibility tree: $target"
        }
        Move-Item -LiteralPath $stage -Destination $target
    }
    finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
    return $target
}

function Test-LibmpvExtraction {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][ValidateSet("x64", "arm64")][string] $Architecture,
        [Parameter(Mandatory)][string] $ArchiveSha256,
        [Parameter(Mandatory)][string] $ExpectedMachine,
        [Parameter(Mandatory)][string] $DllRelativePath
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $manifestPath = Join-Path $resolvedRoot "extraction-manifest.json"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ($manifest.schema_version -ne 1 -or
        $manifest.architecture -ne $Architecture -or
        [string] $manifest.archive_sha256 -ne $ArchiveSha256) {
        throw "Existing libmpv extraction manifest does not match the pinned archive."
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in @($manifest.files)) {
        $relative = [string] $entry.relative_path
        if (-not $seen.Add($relative)) {
            throw "libmpv extraction manifest contains a duplicate path: $relative"
        }
        if ([string] $entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw "libmpv extraction manifest has an invalid hash: $relative"
        }
        $file = Assert-SafeRelativePath `
            -Root $resolvedRoot `
            -RelativePath $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Existing libmpv extraction is missing $relative."
        }
        if ((Get-Sha256Hex -Path $file) -ne
            ([string] $entry.sha256).ToLowerInvariant()) {
            throw "Existing libmpv extraction hash mismatch: $relative"
        }
        if ([System.IO.Path]::GetExtension($file) -in @(".dll", ".exe")) {
            if ((Get-PEMachine -Path $file) -ne $ExpectedMachine) {
                throw "Existing libmpv extraction PE mismatch: $relative"
            }
        }
    }

    foreach ($required in @(
        $DllRelativePath,
        "libmpv.dll.a",
        "include/mpv/client.h"
    )) {
        if (-not $seen.Contains($required)) {
            throw "libmpv extraction manifest omits required file: $required"
        }
    }

    $rootPrefixLength = $resolvedRoot.TrimEnd('\', '/').Length + 1
    $actualFiles = @(
        Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse |
            Where-Object { $_.Name -ne "extraction-manifest.json" }
    )
    foreach ($actual in $actualFiles) {
        $relative = $actual.FullName.Substring($rootPrefixLength).Replace('\', '/')
        if (-not $seen.Contains($relative)) {
            throw "Existing libmpv extraction contains an unlisted file: $relative"
        }
    }
    if ($actualFiles.Count -ne $seen.Count) {
        throw "Existing libmpv extraction file count does not match its manifest."
    }

    return [pscustomobject]@{
        root = $resolvedRoot
        dll = Assert-SafeRelativePath `
            -Root $resolvedRoot `
            -RelativePath $DllRelativePath
        manifest = $manifestPath
    }
}

$cache = Get-SafeBuildPath -Path $CacheRoot -Label "CacheRoot"
$generatedCmake = [System.IO.Path]::GetFullPath($GeneratedCmakePath)
if (-not $ResolutionPath) {
    $ResolutionPath = Join-Path $cache "native-media-resolution.json"
}
$resolutionFile = [System.IO.Path]::GetFullPath($ResolutionPath)
$provenanceFile = (Resolve-Path -LiteralPath $ProvenancePath -ErrorAction Stop).Path
$provenance = Get-Content -LiteralPath $provenanceFile -Raw |
    ConvertFrom-Json -ErrorAction Stop

if ($provenance.schema_version -ne 1) {
    throw "Unsupported native dependency provenance schema."
}
if ($provenance.angle.source_url -ne
    "https://chromium.googlesource.com/angle/angle.git") {
    throw "Refusing non-official ANGLE source URL."
}
if ($provenance.angle.depot_tools_url -ne
    "https://chromium.googlesource.com/chromium/tools/depot_tools.git") {
    throw "Refusing non-official depot_tools source URL."
}
foreach ($pin in @(
    [string] $provenance.angle.source_commit,
    [string] $provenance.angle.depot_tools_commit,
    [string] $provenance.libmpv.builder_commit,
    [string] $provenance.libmpv.mpv_commit
)) {
    if ($pin -notmatch '^[0-9a-f]{40}$') {
        throw "Native source pins must be full lowercase Git commit hashes."
    }
}
if ([string] $provenance.libmpv.license_mode_evidence.redistribution_status -ne
    "blocked_pending_transitive_license_inventory") {
    throw "libmpv redistribution gate changed without a reviewed schema update."
}

$angleRoot = (Resolve-Path -LiteralPath $AngleBundleRoot -ErrorAction Stop).Path
$angleManifestPath = Join-Path $angleRoot "native-manifest.json"
$requiredAngleFiles = @($provenance.angle.runtime_files.$Architecture)
$angleResult = Test-NativeMediaBundle `
    -BundleRoot $angleRoot `
    -ManifestPath $angleManifestPath `
    -Architecture $Architecture `
    -ExpectedAngleSourceUrl $provenance.angle.source_url `
    -ExpectedAngleCommit $provenance.angle.source_commit `
    -ExpectedDepotToolsUrl $provenance.angle.depot_tools_url `
    -ExpectedDepotToolsCommit $provenance.angle.depot_tools_commit `
    -RequiredRuntimeFiles $requiredAngleFiles

$artifact = $provenance.libmpv.artifacts.$Architecture
if (-not $artifact) {
    throw "No pinned libmpv artifact exists for $Architecture."
}
if ([string] $artifact.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
    throw "Pinned libmpv artifact does not have a valid SHA-256."
}
Assert-ApprovedLibmpvUrl `
    -Url $artifact.url `
    -Release $provenance.libmpv.release `
    -ArchiveName $artifact.archive_name

$downloadRoot = Join-Path $cache "dl"
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
if ($LibmpvArchivePath) {
    $archive = (Resolve-Path -LiteralPath $LibmpvArchivePath -ErrorAction Stop).Path
}
else {
    $archive = Join-Path $downloadRoot $artifact.archive_name
}

if (Test-Path -LiteralPath $archive -PathType Leaf) {
    $archiveHash = Get-Sha256Hex -Path $archive
    if ($archiveHash -ne ([string] $artifact.sha256).ToLowerInvariant()) {
        throw "Existing libmpv archive SHA-256 mismatch. Refusing to delete or replace it: $archive"
    }
}
else {
    if ($LibmpvArchivePath) {
        throw "Explicit libmpv archive does not exist: $LibmpvArchivePath"
    }
    if ($Offline) {
        throw "Offline mode requires the pinned libmpv archive at $archive"
    }

    $partial = "$archive.partial-$([guid]::NewGuid().ToString('N'))"
    try {
        Invoke-WebRequest `
            -Uri $artifact.url `
            -OutFile $partial `
            -UseBasicParsing
        $partialHash = Get-Sha256Hex -Path $partial
        if ($partialHash -ne ([string] $artifact.sha256).ToLowerInvariant()) {
            throw "Downloaded libmpv archive SHA-256 mismatch."
        }
        Move-Item -LiteralPath $partial -Destination $archive
    }
    finally {
        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force
        }
    }
}

$cmake = (Get-Command cmake -ErrorAction Stop).Source
$archiveEntries = Invoke-CheckedCapture `
    -FilePath $cmake `
    -ArgumentList @("-E", "tar", "tf", $archive)
Assert-SafeArchiveListing -Entries $archiveEntries

$artifactHash = ([string] $artifact.sha256).ToLowerInvariant()
$libmpvRoot = Join-Path $cache (
    "mpv\$($provenance.libmpv.release)-$($artifactHash.Substring(0, 12))"
)
$libmpvDll = Join-Path $libmpvRoot $artifact.dll_relative_path
$libmpvHeader = Join-Path $libmpvRoot "include\mpv\client.h"

if (-not (Test-Path -LiteralPath $libmpvRoot -PathType Container)) {
    $stage = Join-Path (Split-Path $libmpvRoot -Parent) (
        ".stage-$([guid]::NewGuid().ToString('N'))"
    )
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Invoke-CheckedCapture `
            -FilePath $cmake `
            -ArgumentList @(
                "-E", "chdir", $stage,
                $cmake, "-E", "tar", "xvf", $archive
            ) |
            Out-Null
        $stagePrefixLength = $stage.TrimEnd('\', '/').Length + 1
        $extractedInventory = @(
            Get-ChildItem -LiteralPath $stage -File -Recurse |
                Sort-Object FullName |
                ForEach-Object {
                    [pscustomobject]@{
                        relative_path = $_.FullName.Substring(
                            $stagePrefixLength
                        ).Replace('\', '/')
                        sha256 = Get-Sha256Hex -Path $_.FullName
                    }
                }
        )
        $extractionManifest = [ordered]@{
            schema_version = 1
            architecture = $Architecture
            archive_sha256 = $artifactHash
            files = $extractedInventory
        }
        Write-AtomicUtf8NoBom `
            -Path (Join-Path $stage "extraction-manifest.json") `
            -Content ($extractionManifest | ConvertTo-Json -Depth 7)
        Test-LibmpvExtraction `
            -Root $stage `
            -Architecture $Architecture `
            -ArchiveSha256 $artifactHash `
            -ExpectedMachine ([string] $artifact.pe_machine) `
            -DllRelativePath ([string] $artifact.dll_relative_path) |
            Out-Null
        if (Test-Path -LiteralPath $libmpvRoot) {
            throw "Refusing to overwrite an existing libmpv extraction: $libmpvRoot"
        }
        Move-Item -LiteralPath $stage -Destination $libmpvRoot
    }
    finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
}

$libmpvExtraction = Test-LibmpvExtraction `
    -Root $libmpvRoot `
    -Architecture $Architecture `
    -ArchiveSha256 $artifactHash `
    -ExpectedMachine ([string] $artifact.pe_machine) `
    -DllRelativePath ([string] $artifact.dll_relative_path)
$libmpvDll = $libmpvExtraction.dll

$expectedMachine = [string] $artifact.pe_machine
$actualMachine = Get-PEMachine -Path $libmpvDll
if ($actualMachine -ne $expectedMachine) {
    throw "libmpv PE machine mismatch: got $actualMachine, expected $expectedMachine"
}

$extractedPeFiles = @(
    Get-ChildItem -LiteralPath $libmpvRoot -File -Recurse |
        Where-Object { $_.Extension -in @(".dll", ".exe") }
)
if ($extractedPeFiles.Count -ne 1 -or
    $extractedPeFiles[0].FullName -ne (Resolve-Path -LiteralPath $libmpvDll).Path) {
    throw "libmpv extraction contains an unexpected PE executable or DLL."
}

$compatibility = $null
if ($CompatibilityRoot) {
    $compatibilityRootPath = Get-SafeBuildPath `
        -Path $CompatibilityRoot `
        -Label "CompatibilityRoot"
    # Import libraries live below bundle/lib, while headers live below
    # bundle/include. Preserve both roots under the hard-coded ANGLE directory
    # expected by media_kit_video.
    $angleMappings = @(
        $angleResult.compile_files |
            ForEach-Object {
                [pscustomobject]@{
                    source = $_.path
                    relative_path = $_.relative_path
                }
            }
    )

    $libmpvMappings = [System.Collections.Generic.List[object]]::new()
    $libmpvImportLibrary = Join-Path $libmpvRoot "libmpv.dll.a"
    $libmpvMappings.Add([pscustomobject]@{
        source = $libmpvImportLibrary
        relative_path = "libmpv.dll.a"
    })
    $libmpvIncludeRoot = Join-Path $libmpvRoot "include\mpv"
    foreach ($header in @(
        Get-ChildItem -LiteralPath $libmpvIncludeRoot -File -Recurse |
            Sort-Object FullName
    )) {
        $headerRelative = $header.FullName.Substring(
            $libmpvIncludeRoot.TrimEnd('\', '/').Length + 1
        ).Replace('\', '/')
        $libmpvMappings.Add([pscustomobject]@{
            source = $header.FullName
            relative_path = "include/mpv/$headerRelative"
        })
        $libmpvMappings.Add([pscustomobject]@{
            source = $header.FullName
            relative_path = "include/$headerRelative"
        })
    }

    $angleCompatibilityRoot = Install-VerifiedCompatibilityTree `
        -TargetRoot (Join-Path $compatibilityRootPath "ANGLE") `
        -Kind "ANGLE" `
        -Architecture $Architecture `
        -SourceManifestSha256 (Get-Sha256Hex -Path $angleManifestPath) `
        -Mappings $angleMappings
    $libmpvCompatibilityRoot = Install-VerifiedCompatibilityTree `
        -TargetRoot (Join-Path $compatibilityRootPath "libmpv") `
        -Kind "libmpv" `
        -Architecture $Architecture `
        -SourceManifestSha256 (Get-Sha256Hex -Path $libmpvExtraction.manifest) `
        -Mappings @($libmpvMappings)
    $compatibility = [ordered]@{
        root = $compatibilityRootPath
        angle = $angleCompatibilityRoot
        libmpv = $libmpvCompatibilityRoot
    }
}

$runtimeFiles = [System.Collections.Generic.List[object]]::new()
$runtimeFiles.Add([pscustomobject]@{
    role = "libmpv"
    path = (Resolve-Path -LiteralPath $libmpvDll).Path
    sha256 = Get-Sha256Hex -Path $libmpvDll
    pe_machine = $actualMachine
    expected_export = "mpv_client_api_version"
})

foreach ($angleFile in @($angleResult.files)) {
    $expectedExport = if ($angleFile.relative_path -like "*libEGL.dll") {
        "eglGetDisplay"
    }
    else {
        "glGetString"
    }
    $runtimeFiles.Add([pscustomobject]@{
        role = "angle"
        path = $angleFile.path
        sha256 = $angleFile.sha256
        pe_machine = $angleFile.pe_machine
        expected_export = $expectedExport
    })
}

$resolution = [ordered]@{
    schema_version = 1
    architecture = $Architecture
    generated_at_utc = [DateTime]::UtcNow.ToString("o")
    provenance = [ordered]@{
        path = $provenanceFile
        sha256 = Get-Sha256Hex -Path $provenanceFile
    }
    angle = [ordered]@{
        bundle_root = $angleRoot
        manifest_path = (Resolve-Path -LiteralPath $angleManifestPath).Path
        manifest_sha256 = Get-Sha256Hex -Path $angleManifestPath
        source_commit = $provenance.angle.source_commit
        depot_tools_commit = $provenance.angle.depot_tools_commit
    }
    libmpv = [ordered]@{
        archive_path = (Resolve-Path -LiteralPath $archive).Path
        archive_url = $artifact.url
        archive_sha256 = $artifactHash
        extraction_manifest_path = $libmpvExtraction.manifest
        extraction_manifest_sha256 = Get-Sha256Hex -Path $libmpvExtraction.manifest
        builder_commit = $provenance.libmpv.builder_commit
        mpv_commit = $provenance.libmpv.mpv_commit
        redistribution_status = $provenance.libmpv.license_mode_evidence.redistribution_status
    }
    compatibility = $compatibility
    runtime_files = @($runtimeFiles)
}

Write-AtomicUtf8NoBom `
    -Path $resolutionFile `
    -Content ($resolution | ConvertTo-Json -Depth 10)

$angleManifest = Get-Content -LiteralPath $angleManifestPath -Raw |
    ConvertFrom-Json -ErrorAction Stop
$portableAngleManifestPath = Join-Path $cache "angle-native-manifest.json"
$portableAngleManifest = [ordered]@{
    schema_version = 1
    architecture = $Architecture
    source = [ordered]@{
        angle_url = $angleManifest.source.angle_url
        angle_commit = $angleManifest.source.angle_commit
        depot_tools_url = $angleManifest.source.depot_tools_url
        depot_tools_commit = $angleManifest.source.depot_tools_commit
    }
    build = [ordered]@{
        gn_args = @(
            Get-OptionalProperty -InputObject $angleManifest.build -Name "gn_args"
        )
        git_version = Get-OptionalProperty `
            -InputObject $angleManifest.build `
            -Name "git_version"
        python_version = Get-OptionalProperty `
            -InputObject $angleManifest.build `
            -Name "python_version"
        gn_version = Get-OptionalProperty `
            -InputObject $angleManifest.build `
            -Name "gn_version"
        ninja_version = Get-OptionalProperty `
            -InputObject $angleManifest.build `
            -Name "ninja_version"
        os_version = Get-OptionalProperty `
            -InputObject $angleManifest.build `
            -Name "os_version"
        process_architecture = Get-OptionalProperty `
            -InputObject $angleManifest.build `
            -Name "process_architecture"
    }
    files = @(
        $angleManifest.files |
            ForEach-Object {
                [ordered]@{
                    relative_path = $_.relative_path
                    sha256 = $_.sha256
                    pe_machine = $_.pe_machine
                    origin = $_.origin
                }
            }
    )
    compile_files = @(
        $angleManifest.compile_files |
            ForEach-Object {
                [ordered]@{
                    relative_path = $_.relative_path
                    sha256 = $_.sha256
                    origin = $_.origin
                }
            }
    )
    angle_license_sha256 = $angleManifest.angle_license_sha256
    license_inventory_sha256 = $angleManifest.license_inventory_sha256
}
$portableAngleJson = $portableAngleManifest | ConvertTo-Json -Depth 10
if ($portableAngleJson -match '(?i)(?<![a-z])[a-z]:[\\/]|\\\\\\\\[^\\]') {
    throw "Portable ANGLE manifest unexpectedly contains an absolute Windows path."
}
Write-AtomicUtf8NoBom `
    -Path $portableAngleManifestPath `
    -Content $portableAngleJson

$portableEvidencePath = Join-Path $cache "native-media-package-evidence.json"
$portableEvidence = [ordered]@{
    schema_version = 1
    architecture = $Architecture
    provenance_sha256 = Get-Sha256Hex -Path $provenanceFile
    angle = [ordered]@{
        source_commit = $provenance.angle.source_commit
        depot_tools_commit = $provenance.angle.depot_tools_commit
        source_manifest_sha256 = Get-Sha256Hex -Path $angleManifestPath
        portable_manifest_sha256 = Get-Sha256Hex -Path $portableAngleManifestPath
        angle_license_sha256 = $angleManifest.angle_license_sha256
        license_inventory_sha256 = $angleManifest.license_inventory_sha256
    }
    libmpv = [ordered]@{
        release = $provenance.libmpv.release
        archive_url = $artifact.url
        archive_sha256 = $artifactHash
        extraction_manifest_sha256 = Get-Sha256Hex -Path $libmpvExtraction.manifest
        builder_commit = $provenance.libmpv.builder_commit
        mpv_commit = $provenance.libmpv.mpv_commit
        redistribution_status = $provenance.libmpv.license_mode_evidence.redistribution_status
    }
    runtime_files = @(
        $runtimeFiles |
            ForEach-Object {
                [ordered]@{
                    role = $_.role
                    file_name = [System.IO.Path]::GetFileName([string] $_.path)
                    sha256 = $_.sha256
                    pe_machine = $_.pe_machine
                    expected_export = $_.expected_export
                }
            }
    )
    release_gate = [ordered]@{
        public_redistribution_allowed = $false
        blocker = "libmpv transitive source and license inventory is incomplete"
    }
}
$portableEvidenceJson = $portableEvidence | ConvertTo-Json -Depth 10
if ($portableEvidenceJson -match '(?i)(?<![a-z])[a-z]:[\\/]|\\\\\\\\[^\\]') {
    throw "Portable package evidence unexpectedly contains an absolute Windows path."
}
Write-AtomicUtf8NoBom `
    -Path $portableEvidencePath `
    -Content $portableEvidenceJson

$cmakeRuntimePaths = @(
    $runtimeFiles |
        ForEach-Object { ConvertTo-CmakePath -Path $_.path }
)
$cmakeLines = @(
    "# Generated by prepare_native_media.ps1. Do not edit.",
    "set(MEDIA_KIT_NATIVE_ARCH `"$Architecture`")",
    "set(MEDIA_KIT_LIBMPV_DLL `"$(ConvertTo-CmakePath -Path $libmpvDll)`")",
    "set(MEDIA_KIT_ANGLE_RUNTIME_LIBRARIES `"$($cmakeRuntimePaths[1..($cmakeRuntimePaths.Count - 1)] -join ';')`")",
    "set(MEDIA_KIT_NATIVE_MEDIA_RESOLUTION `"$((ConvertTo-CmakePath -Path $resolutionFile))`")",
    "set(MEDIA_KIT_NATIVE_MEDIA_PACKAGE_EVIDENCE `"$((ConvertTo-CmakePath -Path $portableEvidencePath))`")",
    "set(MEDIA_KIT_NATIVE_MEDIA_ANGLE_MANIFEST `"$((ConvertTo-CmakePath -Path $portableAngleManifestPath))`")",
    "set(MEDIA_KIT_NATIVE_MEDIA_LIBMPV_MANIFEST `"$((ConvertTo-CmakePath -Path $libmpvExtraction.manifest))`")"
)
Write-AtomicUtf8NoBom `
    -Path $generatedCmake `
    -Content (($cmakeLines -join [Environment]::NewLine) + [Environment]::NewLine)

$resolution | ConvertTo-Json -Depth 10
