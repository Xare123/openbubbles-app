[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("x64", "arm64")]
    [string] $Architecture,

    [Parameter(Mandatory)]
    [string] $ArchivePath,

    [Parameter(Mandatory)]
    [string] $OutputRoot,

    [string] $ProvenancePath = (
        Join-Path $PSScriptRoot "..\provenance\native-dependencies.json"
    )
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "NativeMediaVerification.psm1") -Force

function Get-NativeHostArchitecture {
    $native = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ($native.ToString()) {
        "Arm64" { return "arm64" }
        "X64" { return "x64" }
        default { throw "Unsupported native host architecture: $native" }
    }
}

function Assert-SafeArchiveEntry {
    param([Parameter(Mandatory)][string] $Entry)
    $normalized = $Entry.Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return
    }
    if ($normalized.StartsWith("/") -or
        $normalized -match '^[A-Za-z]:' -or
        $normalized.Split('/') -contains '..') {
        throw "libmpv archive contains an unsafe path: $Entry"
    }
}

if ((Get-NativeHostArchitecture) -ne $Architecture) {
    throw "A native $Architecture host is required for the libmpv load test."
}

$archive = (Resolve-Path -LiteralPath $ArchivePath -ErrorAction Stop).Path
$provenanceFile = (
    Resolve-Path -LiteralPath $ProvenancePath -ErrorAction Stop
).Path
$provenance = Get-Content -LiteralPath $provenanceFile -Raw |
    ConvertFrom-Json -ErrorAction Stop
$artifact = $provenance.libmpv.artifacts.$Architecture
if (-not $artifact) {
    throw "No reviewed libmpv artifact exists for $Architecture."
}
$actualArchiveHash = Get-Sha256Hex -Path $archive
if ($actualArchiveHash -ne ([string] $artifact.sha256).ToLowerInvariant()) {
    throw "libmpv archive SHA-256 mismatch."
}

$output = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\', '/')
$root = [System.IO.Path]::GetPathRoot($output).TrimEnd('\', '/')
if ($output -eq $root -or $output.Length -lt ($root.Length + 8)) {
    throw "OutputRoot is too broad for a native smoke-test extraction: $output"
}
if (Test-Path -LiteralPath $output) {
    throw "Refusing to overwrite an existing smoke-test directory: $output"
}
New-Item -ItemType Directory -Path $output | Out-Null

$cmake = (Get-Command cmake -ErrorAction Stop).Source
$entries = @(& $cmake -E tar tf $archive)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list the libmpv archive."
}
foreach ($entry in $entries) {
    Assert-SafeArchiveEntry -Entry ([string] $entry)
}
& $cmake -E chdir $output $cmake -E tar xvf $archive | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to extract the libmpv archive."
}

$dll = Join-Path $output ([string] $artifact.dll_relative_path)
if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
    throw "Extracted archive is missing libmpv."
}
$expectedMachine = if ($Architecture -eq "arm64") { "ARM64" } else { "X64" }
if ((Get-PEMachine -Path $dll) -ne $expectedMachine) {
    throw "Extracted libmpv has the wrong PE machine."
}

if (-not ("OpenBubbles.LibmpvArchiveSmoke" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace OpenBubbles {
    public static class LibmpvArchiveSmoke {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr LoadLibraryEx(
            string fileName,
            IntPtr reserved,
            uint flags
        );

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
        public static extern IntPtr GetProcAddress(IntPtr module, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool FreeLibrary(IntPtr module);
    }
}
'@
}

$loadLibrarySearchDllLoadDir = 0x00000100
$loadLibrarySearchDefaultDirs = 0x00001000
$handle = [OpenBubbles.LibmpvArchiveSmoke]::LoadLibraryEx(
    $dll,
    [IntPtr]::Zero,
    ($loadLibrarySearchDllLoadDir -bor $loadLibrarySearchDefaultDirs)
)
if ($handle -eq [IntPtr]::Zero) {
    throw "LoadLibraryEx failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
}
try {
    $export = "mpv_client_api_version"
    if ([OpenBubbles.LibmpvArchiveSmoke]::GetProcAddress(
        $handle,
        $export
    ) -eq [IntPtr]::Zero) {
        throw "libmpv does not export $export."
    }
}
finally {
    [OpenBubbles.LibmpvArchiveSmoke]::FreeLibrary($handle) | Out-Null
}

[pscustomobject]@{
    result = "passed"
    architecture = $Architecture
    archive_sha256 = $actualArchiveHash
    dll_sha256 = Get-Sha256Hex -Path $dll
    dll_pe_machine = $expectedMachine
    verified_export = "mpv_client_api_version"
    extraction_root = $output
} | ConvertTo-Json -Depth 4
