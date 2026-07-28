param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "arm64")]
    [string]$Architecture,

    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = "Stop"

$expectedMachine = switch ($Architecture) {
    "x64" { 0x8664 }
    "arm64" { 0xAA64 }
}

$resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
$dlls = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Filter "*.dll")
if ($dlls.Count -eq 0) {
    throw "No DLLs were found under $resolvedRoot"
}

$mismatches = @()
foreach ($dll in $dlls) {
    $stream = [System.IO.File]::OpenRead($dll.FullName)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        if ([System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(2)) -ne "MZ") {
            throw "$($dll.FullName) is not a PE file"
        }

        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "$($dll.FullName) has an invalid PE signature"
        }

        $actualMachine = $reader.ReadUInt16()
        if ($actualMachine -ne $expectedMachine) {
            $mismatches += "$($dll.Name)=0x$($actualMachine.ToString('X4'))"
        }
    }
    finally {
        $stream.Dispose()
    }
}

if ($mismatches.Count -gt 0) {
    throw "Expected $Architecture DLLs (0x$($expectedMachine.ToString('X4'))) under $resolvedRoot, found: $($mismatches -join ', ')"
}

Write-Host "Verified $($dlls.Count) $Architecture PE DLL(s) under $resolvedRoot."
