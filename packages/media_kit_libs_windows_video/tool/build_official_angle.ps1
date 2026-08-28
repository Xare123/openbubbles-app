[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("x64", "arm64")]
    [string] $Architecture,

    [Parameter(Mandatory)]
    [string] $WorkRoot,

    [Parameter(Mandatory)]
    [string] $OutputRoot,

    [string] $ProvenancePath = (
        Join-Path $PSScriptRoot "..\provenance\native-dependencies.json"
    ),

    [switch] $Force,

    [switch] $ValidateOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "NativeMediaVerification.psm1") -Force

function Get-SafeFullPath {
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
        throw "$Label is too broad for build output: $full"
    }
    return $full
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-CommandText {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [string[]] $ArgumentList = @(),

        [string] $WorkingDirectory
    )

    if ($WorkingDirectory) {
        Push-Location $WorkingDirectory
    }
    try {
        $value = & $FilePath @ArgumentList 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to query command output: $FilePath $($ArgumentList -join ' ')"
        }
        return (($value | Out-String).Trim())
    }
    finally {
        if ($WorkingDirectory) {
            Pop-Location
        }
    }
}

function Ensure-PinnedCheckout {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $RemoteUrl,

        [Parameter(Mandatory)]
        [string] $Commit,

        [Parameter(Mandatory)]
        [string] $Git
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Invoke-Checked -FilePath $Git -ArgumentList @("init") -WorkingDirectory $Path
        Invoke-Checked -FilePath $Git -ArgumentList @(
            "remote", "add", "origin", $RemoteUrl
        ) -WorkingDirectory $Path
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path $Path ".git"))) {
        throw "Existing checkout path is not a Git repository: $Path"
    }

    $actualRemote = (& $Git -C $Path remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualRemote -ne $RemoteUrl) {
        throw "Checkout origin mismatch at $Path. Got '$actualRemote', expected '$RemoteUrl'."
    }

    Invoke-Checked -FilePath $Git -ArgumentList @(
        "fetch", "--depth", "1", "origin", $Commit
    ) -WorkingDirectory $Path
    Invoke-Checked -FilePath $Git -ArgumentList @(
        "checkout", "--detach", "--force", $Commit
    ) -WorkingDirectory $Path

    $actualCommit = (& $Git -C $Path rev-parse HEAD).Trim()
    if ($actualCommit -ne $Commit) {
        throw "Checkout commit mismatch at $Path. Got $actualCommit, expected $Commit."
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Ensure-DepotToolsGitShim {
    param(
        [Parameter(Mandatory)]
        [string] $DepotToolsPath,

        [Parameter(Mandatory)]
        [string] $GitPath
    )

    # The pinned depot_tools revision invokes `git.bat` from Python, but a
    # fresh pinned checkout does not contain that bootstrap-generated shim.
    # DEPOT_TOOLS_UPDATE stays disabled so the reviewed source pin cannot
    # move; provide the same minimal forwarding shim to the runner's Git.
    $shim = Join-Path $DepotToolsPath "git.bat"
    if (Test-Path -LiteralPath $shim -PathType Leaf) {
        return
    }
    $escapedGitPath = $GitPath.Replace("%", "%%")
    Write-Utf8NoBom `
        -Path $shim `
        -Content ("@echo off`r`n`"$escapedGitPath`" %*`r`n")
}

$work = Get-SafeFullPath -Path $WorkRoot -Label "WorkRoot"
$output = Get-SafeFullPath -Path $OutputRoot -Label "OutputRoot"
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
    [string] $provenance.angle.depot_tools_commit
)) {
    if ($pin -notmatch '^[0-9a-f]{40}$') {
        throw "Official source pins must be full lowercase Git commit hashes."
    }
}

$requiredRuntimeFiles = @($provenance.angle.runtime_files.$Architecture)
$expectedMachine = if ($Architecture -eq "arm64") { "ARM64" } else { "X64" }

if (Test-Path -LiteralPath $output -PathType Container) {
    $existingManifest = Join-Path $output "native-manifest.json"
    if (-not $Force) {
        $result = Test-NativeMediaBundle `
            -BundleRoot $output `
            -ManifestPath $existingManifest `
            -Architecture $Architecture `
            -ExpectedAngleSourceUrl $provenance.angle.source_url `
            -ExpectedAngleCommit $provenance.angle.source_commit `
            -ExpectedDepotToolsUrl $provenance.angle.depot_tools_url `
            -ExpectedDepotToolsCommit $provenance.angle.depot_tools_commit `
            -RequiredRuntimeFiles $requiredRuntimeFiles
        $result | ConvertTo-Json -Depth 7
        exit 0
    }
}

$plan = [pscustomobject]@{
    architecture = $Architecture
    work_root = $work
    output_root = $output
    angle_source = $provenance.angle.source_url
    angle_commit = $provenance.angle.source_commit
    depot_tools_source = $provenance.angle.depot_tools_url
    depot_tools_commit = $provenance.angle.depot_tools_commit
    required_runtime_files = $requiredRuntimeFiles
}

if ($ValidateOnly) {
    $plan | ConvertTo-Json -Depth 6
    exit 0
}

New-Item -ItemType Directory -Path $work -Force | Out-Null

$git = (Get-Command git -ErrorAction Stop).Source
$python = (Get-Command python -ErrorAction Stop).Source
$depotTools = Join-Path $work "depot_tools"
$angleSource = Join-Path $work "angle"

Ensure-PinnedCheckout `
    -Path $depotTools `
    -RemoteUrl $provenance.angle.depot_tools_url `
    -Commit $provenance.angle.depot_tools_commit `
    -Git $git

Ensure-DepotToolsGitShim -DepotToolsPath $depotTools -GitPath $git

$env:PATH = "$depotTools;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
$env:DEPOT_TOOLS_UPDATE = "0"

Ensure-PinnedCheckout `
    -Path $angleSource `
    -RemoteUrl $provenance.angle.source_url `
    -Commit $provenance.angle.source_commit `
    -Git $git

Invoke-Checked `
    -FilePath $python `
    -ArgumentList @("scripts/bootstrap.py") `
    -WorkingDirectory $angleSource
Invoke-Checked `
    -FilePath (Join-Path $depotTools "gclient.bat") `
    -ArgumentList @("sync", "--force", "--reset", "--no-history") `
    -WorkingDirectory $angleSource

$actualAngleCommit = (& $git -C $angleSource rev-parse HEAD).Trim()
if ($actualAngleCommit -ne $provenance.angle.source_commit) {
    throw "gclient changed the pinned ANGLE checkout to $actualAngleCommit."
}
$actualDepotToolsCommit = (& $git -C $depotTools rev-parse HEAD).Trim()
if ($actualDepotToolsCommit -ne $provenance.angle.depot_tools_commit) {
    throw "depot_tools moved away from its reviewed pin to $actualDepotToolsCommit."
}

$gn = (Get-Command gn -ErrorAction Stop).Source
$autoninja = (Get-Command autoninja -ErrorAction Stop).Source
$targetCpu = if ($Architecture -eq "arm64") { "arm64" } else { "x64" }
$gnArgs = @($provenance.angle.gn_args_common) + @("target_cpu=`"$targetCpu`"")
$gnArgsText = $gnArgs -join " "
$buildRoot = Join-Path $angleSource "out\openbubbles-$Architecture-release"

Invoke-Checked `
    -FilePath $gn `
    -ArgumentList @("gen", $buildRoot, "--args=$gnArgsText") `
    -WorkingDirectory $angleSource
Invoke-Checked `
    -FilePath $autoninja `
    -ArgumentList @("-C", $buildRoot, "libEGL", "libGLESv2") `
    -WorkingDirectory $angleSource

$stage = "$output.stage-$([guid]::NewGuid().ToString('N'))"
$bin = Join-Path $stage "bin"
$licenses = Join-Path $stage "licenses"
$sourceLicenses = Join-Path $licenses "source-tree"
$evidence = Join-Path $stage "provenance"
New-Item -ItemType Directory -Path $bin -Force | Out-Null
New-Item -ItemType Directory -Path $sourceLicenses -Force | Out-Null
New-Item -ItemType Directory -Path $evidence -Force | Out-Null

foreach ($relative in $requiredRuntimeFiles) {
    $name = Split-Path $relative -Leaf
    $source = Join-Path $buildRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Official ANGLE build did not produce required runtime: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $bin $name)
}

$angleLicense = Join-Path $angleSource "LICENSE"
if (-not (Test-Path -LiteralPath $angleLicense -PathType Leaf)) {
    throw "Pinned ANGLE checkout is missing its top-level LICENSE."
}
Copy-Item -LiteralPath $angleLicense -Destination (
    Join-Path $licenses "ANGLE-LICENSE.txt"
)

$licenseNames = @(
    "LICENSE",
    "COPYING",
    "NOTICE",
    "README.chromium"
)
$licenseFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $angleSource "third_party") -File -Recurse |
        Where-Object {
            $base = $_.BaseName
            $_.Name -eq "README.chromium" -or
            $licenseNames -contains $base -or
            $_.Name -like "LICENSE.*" -or
            $_.Name -like "COPYING.*" -or
            $_.Name -like "NOTICE.*"
        } |
        Sort-Object FullName
)
if ($licenseFiles.Count -eq 0) {
    throw "No third-party license evidence was found in the pinned ANGLE checkout."
}

$sourcePrefixLength = $angleSource.TrimEnd('\', '/').Length + 1
$licenseInventory = [System.Collections.Generic.List[object]]::new()
foreach ($item in $licenseFiles) {
    if ($item.FullName.StartsWith(
        $buildRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        continue
    }
    $sourceRelative = $item.FullName.Substring($sourcePrefixLength).Replace('\', '/')
    $bundleRelative = "source-tree/$sourceRelative"
    $destination = Join-Path $licenses $bundleRelative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force |
        Out-Null
    Copy-Item -LiteralPath $item.FullName -Destination $destination
    $licenseInventory.Add([pscustomobject]@{
        source_relative_path = $sourceRelative
        bundle_relative_path = "licenses/$bundleRelative"
        sha256 = Get-Sha256Hex -Path $destination
    })
}

$licenseInventoryPath = Join-Path $licenses "license-inventory.json"
Write-Utf8NoBom `
    -Path $licenseInventoryPath `
    -Content (@($licenseInventory) | ConvertTo-Json -Depth 6)

$gclient = Join-Path $depotTools "gclient.bat"
$gclientRevisionsPath = Join-Path $evidence "gclient-revisions.txt"
$gclientRevisions = Get-CommandText `
    -FilePath $gclient `
    -ArgumentList @("revinfo", "-a") `
    -WorkingDirectory $angleSource
Write-Utf8NoBom `
    -Path $gclientRevisionsPath `
    -Content ($gclientRevisions + [Environment]::NewLine)

$gnArgsPath = Join-Path $evidence "gn-args.txt"
Write-Utf8NoBom `
    -Path $gnArgsPath `
    -Content (($gnArgs -join [Environment]::NewLine) + [Environment]::NewLine)

$runtimeEntries = [System.Collections.Generic.List[object]]::new()
foreach ($relative in $requiredRuntimeFiles) {
    $file = Join-Path $stage $relative
    $machine = Get-PEMachine -Path $file
    if ($machine -ne $expectedMachine) {
        throw "Official ANGLE output has PE machine $machine, expected $expectedMachine`: $file"
    }
    $runtimeEntries.Add([pscustomobject]@{
        relative_path = $relative
        sha256 = Get-Sha256Hex -Path $file
        pe_machine = $machine
        origin = "official ANGLE source build"
    })
}

$manifest = [ordered]@{
    schema_version = 1
    architecture = $Architecture
    source = [ordered]@{
        angle_url = $provenance.angle.source_url
        angle_commit = $provenance.angle.source_commit
        depot_tools_url = $provenance.angle.depot_tools_url
        depot_tools_commit = $provenance.angle.depot_tools_commit
    }
    build = [ordered]@{
        built_at_utc = [DateTime]::UtcNow.ToString("o")
        gn_args = $gnArgs
        git_version = Get-CommandText -FilePath $git -ArgumentList @("--version")
        python_version = Get-CommandText -FilePath $python -ArgumentList @("--version")
        gn_version = Get-CommandText -FilePath $gn -ArgumentList @("--version")
        ninja_version = Get-CommandText -FilePath $autoninja -ArgumentList @("--version")
        os_version = [System.Environment]::OSVersion.VersionString
        process_architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    }
    files = @($runtimeEntries)
    angle_license_sha256 = Get-Sha256Hex -Path (
        Join-Path $licenses "ANGLE-LICENSE.txt"
    )
    license_inventory_sha256 = Get-Sha256Hex -Path $licenseInventoryPath
    evidence = [ordered]@{
        gclient_revisions_path = "provenance/gclient-revisions.txt"
        gclient_revisions_sha256 = Get-Sha256Hex -Path $gclientRevisionsPath
        gn_args_path = "provenance/gn-args.txt"
        gn_args_sha256 = Get-Sha256Hex -Path $gnArgsPath
    }
}

$manifestPath = Join-Path $stage "native-manifest.json"
Write-Utf8NoBom `
    -Path $manifestPath `
    -Content ($manifest | ConvertTo-Json -Depth 10)

Test-NativeMediaBundle `
    -BundleRoot $stage `
    -ManifestPath $manifestPath `
    -Architecture $Architecture `
    -ExpectedAngleSourceUrl $provenance.angle.source_url `
    -ExpectedAngleCommit $provenance.angle.source_commit `
    -ExpectedDepotToolsUrl $provenance.angle.depot_tools_url `
    -ExpectedDepotToolsCommit $provenance.angle.depot_tools_commit `
    -RequiredRuntimeFiles $requiredRuntimeFiles |
    Out-Null

if (Test-Path -LiteralPath $output) {
    $backup = "$output.previous-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    if (Test-Path -LiteralPath $backup) {
        throw "Refusing to overwrite existing native bundle backup: $backup"
    }
    Move-Item -LiteralPath $output -Destination $backup
}
Move-Item -LiteralPath $stage -Destination $output

$result = Test-NativeMediaBundle `
    -BundleRoot $output `
    -ManifestPath (Join-Path $output "native-manifest.json") `
    -Architecture $Architecture `
    -ExpectedAngleSourceUrl $provenance.angle.source_url `
    -ExpectedAngleCommit $provenance.angle.source_commit `
    -ExpectedDepotToolsUrl $provenance.angle.depot_tools_url `
    -ExpectedDepotToolsCommit $provenance.angle.depot_tools_commit `
    -RequiredRuntimeFiles $requiredRuntimeFiles

$result | ConvertTo-Json -Depth 7
