[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResolutionPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "NativeMediaVerification.psm1") -Force

if (-not ("OpenBubbles.NativeLibrary" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace OpenBubbles {
    public static class NativeLibrary {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetDefaultDllDirectories(uint directoryFlags);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr AddDllDirectory(string newDirectory);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool RemoveDllDirectory(IntPtr cookie);

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

function Get-NativeHostArchitecture {
    $native = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITEW6432")
    if (-not $native) {
        $native = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
    }
    switch -Regex ($native) {
        "^(ARM64|arm64|aarch64)$" { return "arm64" }
        "^(AMD64|amd64|x86_64|X86_64)$" { return "x64" }
        default { throw "Unsupported native host architecture: $native" }
    }
}

$resolutionFile = (Resolve-Path -LiteralPath $ResolutionPath -ErrorAction Stop).Path
$resolution = Get-Content -LiteralPath $resolutionFile -Raw |
    ConvertFrom-Json -ErrorAction Stop
if ($resolution.schema_version -ne 1) {
    throw "Unsupported native media resolution schema."
}
if ($resolution.architecture -notin @("x64", "arm64")) {
    throw "Resolution has an unsupported architecture: $($resolution.architecture)"
}

$hostArchitecture = Get-NativeHostArchitecture
if ($hostArchitecture -ne $resolution.architecture) {
    throw "Runtime smoke requires a native $($resolution.architecture) runner; host is $hostArchitecture."
}

$expectedMachine = if ($hostArchitecture -eq "arm64") { "ARM64" } else { "X64" }
$processMachine = [System.Runtime.InteropServices.RuntimeInformation]::
    ProcessArchitecture.ToString().ToUpperInvariant()
if ($processMachine -ne $expectedMachine) {
    throw (
        "Runtime smoke requires a native $expectedMachine PowerShell process; " +
        "current process is $processMachine."
    )
}
$runtimeFiles = @($resolution.runtime_files)
if ($runtimeFiles.Count -ne 3) {
    throw "Expected exactly libmpv, libEGL, and libGLESv2; got $($runtimeFiles.Count) files."
}

foreach ($entry in $runtimeFiles) {
    $path = (Resolve-Path -LiteralPath $entry.path -ErrorAction Stop).Path
    if ((Get-Sha256Hex -Path $path) -ne ([string] $entry.sha256).ToLowerInvariant()) {
        throw "Runtime SHA-256 mismatch: $path"
    }
    $machine = Get-PEMachine -Path $path
    if ($machine -ne $expectedMachine -or
        [string] $entry.pe_machine -ne $expectedMachine) {
        throw "Runtime PE machine mismatch: $path"
    }
}

$loadLibrarySearchDllLoadDir = 0x00000100
$loadLibrarySearchDefaultDirs = 0x00001000
$loadFlags = $loadLibrarySearchDllLoadDir -bor $loadLibrarySearchDefaultDirs
if (-not [OpenBubbles.NativeLibrary]::SetDefaultDllDirectories(
    $loadLibrarySearchDefaultDirs
)) {
    throw "SetDefaultDllDirectories failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
}

$cookies = [System.Collections.Generic.List[IntPtr]]::new()
$handles = [System.Collections.Generic.List[IntPtr]]::new()
try {
    $directories = @(
        $runtimeFiles |
            ForEach-Object { Split-Path ([string] $_.path) -Parent } |
            Sort-Object -Unique
    )
    foreach ($directory in $directories) {
        $cookie = [OpenBubbles.NativeLibrary]::AddDllDirectory($directory)
        if ($cookie -eq [IntPtr]::Zero) {
            throw "AddDllDirectory failed for $directory with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
        }
        $cookies.Add($cookie)
    }

    $ordered = @(
        $runtimeFiles | Sort-Object {
            $name = Split-Path ([string] $_.path) -Leaf
            switch ($name.ToLowerInvariant()) {
                "libglesv2.dll" { 0 }
                "libegl.dll" { 1 }
                "libmpv-2.dll" { 2 }
                default { 99 }
            }
        }
    )
    foreach ($entry in $ordered) {
        $path = (Resolve-Path -LiteralPath $entry.path).Path
        $handle = [OpenBubbles.NativeLibrary]::LoadLibraryEx(
            $path,
            [IntPtr]::Zero,
            $loadFlags
        )
        if ($handle -eq [IntPtr]::Zero) {
            throw "LoadLibraryEx failed for $path with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
        }
        $handles.Add($handle)

        $export = [string] $entry.expected_export
        if ([string]::IsNullOrWhiteSpace($export)) {
            throw "Resolution omits the expected export for $path."
        }
        if ([OpenBubbles.NativeLibrary]::GetProcAddress($handle, $export) -eq
            [IntPtr]::Zero) {
            throw "Native runtime $path does not export $export."
        }
    }
}
finally {
    for ($index = $handles.Count - 1; $index -ge 0; $index--) {
        [OpenBubbles.NativeLibrary]::FreeLibrary($handles[$index]) | Out-Null
    }
    for ($index = $cookies.Count - 1; $index -ge 0; $index--) {
        [OpenBubbles.NativeLibrary]::RemoveDllDirectory($cookies[$index]) |
            Out-Null
    }
}

[pscustomobject]@{
    result = "passed"
    architecture = $hostArchitecture
    process_architecture = $processMachine
    resolution = $resolutionFile
    loaded_files = @($runtimeFiles | ForEach-Object { $_.path })
} | ConvertTo-Json -Depth 5
