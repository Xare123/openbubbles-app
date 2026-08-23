Set-StrictMode -Version Latest

function Get-Sha256Hex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PEMachine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $stream = [System.IO.File]::Open(
        $resolved,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )

    try {
        if ($stream.Length -lt 64) {
            throw "PE file is too short: $resolved"
        }

        $reader = [System.IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "Missing DOS MZ header: $resolved"
        }

        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or ($peOffset + 6) -gt $stream.Length) {
            throw "Invalid PE header offset in $resolved"
        }

        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Missing PE signature: $resolved"
        }

        $machine = $reader.ReadUInt16()
        switch ($machine) {
            0x014C { return "X86" }
            0x8664 { return "X64" }
            0xAA64 { return "ARM64" }
            0xA641 { return "ARM64EC" }
            default { return ("UNKNOWN_0x{0:X4}" -f $machine) }
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-SafeRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "Manifest contains an empty relative path."
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Manifest path must be relative: $RelativePath"
    }

    $segments = $RelativePath.Replace('\', '/').Split('/')
    if ($segments -contains '..') {
        throw "Manifest path escapes its bundle root: $RelativePath"
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath(
        (Join-Path $rootFull $RelativePath)
    )
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Manifest path escapes its bundle root: $RelativePath"
    }

    return $candidate
}

function Test-HexDigest {
    param([string] $Value)
    return $Value -match '^[0-9a-fA-F]{64}$'
}

function Test-NativeMediaBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $BundleRoot,

        [Parameter(Mandatory)]
        [string] $ManifestPath,

        [Parameter(Mandatory)]
        [ValidateSet("x64", "arm64")]
        [string] $Architecture,

        [Parameter(Mandatory)]
        [string] $ExpectedAngleSourceUrl,

        [Parameter(Mandatory)]
        [string] $ExpectedAngleCommit,

        [Parameter(Mandatory)]
        [string] $ExpectedDepotToolsUrl,

        [Parameter(Mandatory)]
        [string] $ExpectedDepotToolsCommit,

        [Parameter(Mandatory)]
        [string[]] $RequiredRuntimeFiles
    )

    $bundle = (Resolve-Path -LiteralPath $BundleRoot -ErrorAction Stop).Path
    $manifestFile = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path
    $manifest = Get-Content -LiteralPath $manifestFile -Raw |
        ConvertFrom-Json -ErrorAction Stop

    if ($manifest.schema_version -ne 1) {
        throw "Unsupported ANGLE bundle manifest schema: $($manifest.schema_version)"
    }
    if ($manifest.architecture -ne $Architecture) {
        throw "ANGLE bundle architecture is '$($manifest.architecture)', expected '$Architecture'."
    }
    if ($manifest.source.angle_url -ne $ExpectedAngleSourceUrl) {
        throw "ANGLE source URL does not match the reviewed official source."
    }
    if ($manifest.source.angle_commit -ne $ExpectedAngleCommit) {
        throw "ANGLE source commit does not match the reviewed pin."
    }
    if ($manifest.source.depot_tools_url -ne $ExpectedDepotToolsUrl) {
        throw "depot_tools URL does not match the reviewed official source."
    }
    if ($manifest.source.depot_tools_commit -ne $ExpectedDepotToolsCommit) {
        throw "depot_tools commit does not match the reviewed pin."
    }

    $expectedMachine = if ($Architecture -eq "arm64") { "ARM64" } else { "X64" }
    $manifestFiles = @($manifest.files)
    if ($manifestFiles.Count -eq 0) {
        throw "ANGLE bundle manifest has no runtime files."
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $required = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($requiredRuntime in $RequiredRuntimeFiles) {
        $requiredRelative = ([string] $requiredRuntime).Replace('\', '/')
        Assert-SafeRelativePath `
            -Root $bundle `
            -RelativePath $requiredRelative |
            Out-Null
        if (-not $required.Add($requiredRelative)) {
            throw "Required ANGLE runtime list contains duplicate path: $requiredRelative"
        }
    }
    $validatedFiles = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $manifestFiles) {
        $relative = ([string] $entry.relative_path).Replace('\', '/')
        if (-not $seen.Add($relative)) {
            throw "ANGLE bundle manifest contains duplicate path: $relative"
        }
        if (-not $required.Contains($relative)) {
            throw "ANGLE bundle manifest contains an unexpected runtime file: $relative"
        }
        if (-not (Test-HexDigest ([string] $entry.sha256))) {
            throw "ANGLE bundle manifest has an invalid SHA-256 for $relative"
        }

        $file = Assert-SafeRelativePath -Root $bundle -RelativePath $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "ANGLE bundle is missing required manifest file: $relative"
        }

        $actualHash = Get-Sha256Hex -Path $file
        if ($actualHash -ne ([string] $entry.sha256).ToLowerInvariant()) {
            throw "ANGLE bundle SHA-256 mismatch for $relative"
        }

        $actualMachine = Get-PEMachine -Path $file
        if ($actualMachine -ne $expectedMachine) {
            throw "ANGLE bundle PE machine mismatch for ${relative}: got $actualMachine, expected $expectedMachine"
        }
        if ([string] $entry.pe_machine -ne $expectedMachine) {
            throw "ANGLE manifest PE machine mismatch for ${relative}: got $($entry.pe_machine), expected $expectedMachine"
        }

        $validatedFiles.Add([pscustomobject]@{
            relative_path = $relative.Replace('\', '/')
            path = $file
            sha256 = $actualHash
            pe_machine = $actualMachine
        })
    }

    foreach ($relative in $required) {
        if (-not $seen.Contains($relative)) {
            throw "ANGLE manifest omits required runtime file: $relative"
        }
    }
    if ($seen.Count -ne $required.Count) {
        throw "ANGLE manifest runtime set does not exactly match the reviewed set."
    }

    $binRoot = Join-Path $bundle "bin"
    if (-not (Test-Path -LiteralPath $binRoot -PathType Container)) {
        throw "ANGLE bundle has no bin directory."
    }

    $actualPeFiles = @(
        Get-ChildItem -LiteralPath $bundle -File -Recurse |
            Where-Object { $_.Extension -in @(".dll", ".exe") }
    )
    $bundlePrefixLength = $bundle.TrimEnd('\', '/').Length + 1
    foreach ($actual in $actualPeFiles) {
        $relative = $actual.FullName.Substring($bundlePrefixLength).Replace('\', '/')
        if (-not $seen.Contains($relative)) {
            throw "ANGLE bundle contains an unlisted PE runtime: $relative"
        }
    }

    $licensePath = Join-Path $bundle "licenses\ANGLE-LICENSE.txt"
    $licenseInventoryPath = Join-Path $bundle "licenses\license-inventory.json"
    foreach ($requiredLicenseFile in @($licensePath, $licenseInventoryPath)) {
        if (-not (Test-Path -LiteralPath $requiredLicenseFile -PathType Leaf)) {
            throw "ANGLE bundle is missing provenance file: $requiredLicenseFile"
        }
    }
    if (-not (Test-HexDigest ([string] $manifest.angle_license_sha256))) {
        throw "ANGLE manifest has an invalid top-level license SHA-256."
    }
    if ((Get-Sha256Hex -Path $licensePath) -ne
        ([string] $manifest.angle_license_sha256).ToLowerInvariant()) {
        throw "ANGLE top-level license hash does not match the manifest."
    }
    if (-not (Test-HexDigest ([string] $manifest.license_inventory_sha256))) {
        throw "ANGLE manifest has an invalid license inventory SHA-256."
    }
    if ((Get-Sha256Hex -Path $licenseInventoryPath) -ne
        ([string] $manifest.license_inventory_sha256).ToLowerInvariant()) {
        throw "ANGLE license inventory hash does not match the manifest."
    }

    $licenseInventory = @(
        Get-Content -LiteralPath $licenseInventoryPath -Raw |
            ConvertFrom-Json -ErrorAction Stop
    )
    if ($licenseInventory.Count -eq 0) {
        throw "ANGLE third-party license inventory is empty."
    }
    $seenLicenses = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($licenseEntry in $licenseInventory) {
        $relative = [string] $licenseEntry.bundle_relative_path
        if (-not $relative.StartsWith(
            "licenses/source-tree/",
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "ANGLE license inventory path is outside its source-tree boundary: $relative"
        }
        if (-not $seenLicenses.Add($relative)) {
            throw "ANGLE license inventory contains a duplicate path: $relative"
        }
        if (-not (Test-HexDigest ([string] $licenseEntry.sha256))) {
            throw "ANGLE license inventory has an invalid SHA-256 for $relative"
        }
        $licenseFile = Assert-SafeRelativePath `
            -Root $bundle `
            -RelativePath $relative
        if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
            throw "ANGLE license inventory references a missing file: $relative"
        }
        if ((Get-Sha256Hex -Path $licenseFile) -ne
            ([string] $licenseEntry.sha256).ToLowerInvariant()) {
            throw "ANGLE third-party license hash mismatch: $relative"
        }
    }

    $sourceTree = Join-Path $bundle "licenses\source-tree"
    if (-not (Test-Path -LiteralPath $sourceTree -PathType Container)) {
        throw "ANGLE bundle is missing its third-party license source tree."
    }
    $sourceTreeFiles = @(Get-ChildItem -LiteralPath $sourceTree -File -Recurse)
    $bundleLicensePrefix = $bundle.TrimEnd('\', '/').Length + 1
    foreach ($sourceTreeFile in $sourceTreeFiles) {
        $relative = $sourceTreeFile.FullName.Substring(
            $bundleLicensePrefix
        ).Replace('\', '/')
        if (-not $seenLicenses.Contains($relative)) {
            throw "ANGLE license source tree contains an unlisted file: $relative"
        }
    }
    if ($sourceTreeFiles.Count -ne $seenLicenses.Count) {
        throw "ANGLE license source tree file count does not match its inventory."
    }

    $evidenceFiles = @(
        [pscustomobject]@{
            path = [string] $manifest.evidence.gclient_revisions_path
            sha256 = [string] $manifest.evidence.gclient_revisions_sha256
        },
        [pscustomobject]@{
            path = [string] $manifest.evidence.gn_args_path
            sha256 = [string] $manifest.evidence.gn_args_sha256
        }
    )
    foreach ($evidenceEntry in $evidenceFiles) {
        if (-not (Test-HexDigest $evidenceEntry.sha256)) {
            throw "ANGLE manifest has an invalid evidence SHA-256 for $($evidenceEntry.path)."
        }
        $evidencePath = Assert-SafeRelativePath `
            -Root $bundle `
            -RelativePath $evidenceEntry.path
        if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
            throw "ANGLE bundle is missing provenance evidence: $($evidenceEntry.path)"
        }
        if ((Get-Sha256Hex -Path $evidencePath) -ne
            $evidenceEntry.sha256.ToLowerInvariant()) {
            throw "ANGLE provenance evidence hash mismatch for $($evidenceEntry.path)."
        }
    }

    return [pscustomobject]@{
        architecture = $Architecture
        angle_commit = $ExpectedAngleCommit
        depot_tools_commit = $ExpectedDepotToolsCommit
        files = @($validatedFiles)
        manifest_path = $manifestFile
        bundle_root = $bundle
    }
}

Export-ModuleMember -Function @(
    "Get-Sha256Hex",
    "Get-PEMachine",
    "Assert-SafeRelativePath",
    "Test-NativeMediaBundle"
)
