[CmdletBinding(DefaultParameterSetName = "Bundle")]
param(
    [Parameter(Mandatory, ParameterSetName = "Bundle")]
    [string] $BundleRoot,

    [Parameter(Mandatory, ParameterSetName = "Bundle")]
    [string] $ManifestPath,

    [Parameter(Mandatory, ParameterSetName = "Bundle")]
    [string] $ProvenancePath,

    [Parameter(Mandatory, ParameterSetName = "Files")]
    [string[]] $File,

    [Parameter(Mandatory)]
    [ValidateSet("x64", "arm64")]
    [string] $Architecture
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "NativeMediaVerification.psm1") -Force

if ($PSCmdlet.ParameterSetName -eq "Files") {
    $expectedMachine = if ($Architecture -eq "arm64") { "ARM64" } else { "X64" }
    $files = foreach ($item in $File) {
        $resolved = (Resolve-Path -LiteralPath $item -ErrorAction Stop).Path
        $machine = Get-PEMachine -Path $resolved
        if ($machine -ne $expectedMachine) {
            throw "PE machine mismatch for ${resolved}: got $machine, expected $expectedMachine"
        }
        [pscustomobject]@{
            path = $resolved
            pe_machine = $machine
            sha256 = Get-Sha256Hex -Path $resolved
        }
    }

    [pscustomobject]@{
        architecture = $Architecture
        files = @($files)
    } | ConvertTo-Json -Depth 5 -Compress
    exit 0
}

$provenance = Get-Content -LiteralPath $ProvenancePath -Raw |
    ConvertFrom-Json -ErrorAction Stop
if ($provenance.schema_version -ne 1) {
    throw "Unsupported native dependency provenance schema."
}
if ($provenance.angle.source_url -ne
    "https://chromium.googlesource.com/angle/angle.git" -or
    $provenance.angle.depot_tools_url -ne
    "https://chromium.googlesource.com/chromium/tools/depot_tools.git") {
    throw "Standalone verification refuses non-official ANGLE build sources."
}
foreach ($pin in @(
    [string] $provenance.angle.source_commit,
    [string] $provenance.angle.depot_tools_commit
)) {
    if ($pin -notmatch '^[0-9a-f]{40}$') {
        throw "Official source pins must be full lowercase Git commit hashes."
    }
}
$required = @($provenance.angle.runtime_files.$Architecture)

$result = Test-NativeMediaBundle `
    -BundleRoot $BundleRoot `
    -ManifestPath $ManifestPath `
    -Architecture $Architecture `
    -ExpectedAngleSourceUrl $provenance.angle.source_url `
    -ExpectedAngleCommit $provenance.angle.source_commit `
    -ExpectedDepotToolsUrl $provenance.angle.depot_tools_url `
    -ExpectedDepotToolsCommit $provenance.angle.depot_tools_commit `
    -RequiredRuntimeFiles $required

$result | ConvertTo-Json -Depth 7 -Compress
