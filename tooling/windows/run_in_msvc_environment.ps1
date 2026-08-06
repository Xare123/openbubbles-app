# Runs a command inside a Visual Studio 2022 developer environment.
#
#   .\msvc-run.ps1 -Arch arm64 -- cargo check --locked
#
# -Arch accepts the vcvarsall target name (arm64, x64). The host architecture is
# chosen automatically. GNU compiler overrides that would divert the `cc` crate
# away from cl.exe are removed, and Strawberry's gcc/binutils directories are
# dropped from PATH so an MSVC target cannot silently pick them up.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet("arm64", "x64")][string]$Arch,
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$Command
)

$ErrorActionPreference = "Stop"

$originalEnvironment = @{}
foreach ($entry in Get-ChildItem Env:) {
    $originalEnvironment[$entry.Name] = $entry.Value
}

$vcvarsall = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path -LiteralPath $vcvarsall)) {
    throw "vcvarsall.bat was not found at $vcvarsall"
}

# vcvarsall only mutates the environment of its own cmd.exe, so capture the
# resulting variables and import them here.
$marker = "___VCVARS_ENV___"
$captured = & cmd.exe /s /c "`"$vcvarsall`" $Arch >nul 2>&1 && echo $marker && set"
if ($LASTEXITCODE -ne 0) {
    throw "vcvarsall.bat $Arch failed with exit code $LASTEXITCODE"
}
$seenMarker = $false
foreach ($line in $captured) {
    if (-not $seenMarker) {
        # cmd echoes the marker with the trailing space that preceded `&&`.
        if ($line.Trim() -eq $marker) { $seenMarker = $true }
        continue
    }
    $split = $line.IndexOf('=')
    if ($split -lt 1) { continue }
    Set-Item -Path "Env:$($line.Substring(0, $split))" -Value $line.Substring($split + 1)
}
if (-not $seenMarker) {
    throw "Could not capture the developer environment for $Arch"
}

# `cc` honours these before it looks for cl.exe. A stale GNU value silently
# produces the wrong machine type or fails compiler detection outright.
foreach ($gnuOverride in @("CC", "CXX", "AR", "LD", "RANLIB", "CFLAGS", "CXXFLAGS")) {
    Remove-Item -Path "Env:$gnuOverride" -ErrorAction SilentlyContinue
}
$env:PATH = (($env:PATH -split ';') | Where-Object {
    $_ -and $_ -notmatch '(?i)\\Strawberry\\(c|perl)\\'
}) -join ';'

# Perl is required by the OpenSSL build, but it must not drag in gcc/ninja from
# the same distribution, so re-add only its interpreter directory at the end.
$strawberryPerl = "C:\Strawberry\perl\bin"
if (Test-Path -LiteralPath $strawberryPerl) {
    $env:PATH = "$env:PATH;$strawberryPerl"
}

# `ring` assembles GNU-syntax .S sources that cl.exe cannot consume, so clang
# must be reachable for the aarch64-pc-windows-msvc target. Appended after the
# MSVC directories so cl/link/lib still resolve to Visual Studio.
$llvmBin = "C:\Codex\Toolchains\LLVM-22.1.8-woa64-portable\bin"
if (Test-Path -LiteralPath $llvmBin) {
    $env:PATH = "$env:PATH;$llvmBin"
}

foreach ($tool in @("cl", "link", "lib", "nmake", "perl", "clang")) {
    $resolved = Get-Command $tool -ErrorAction SilentlyContinue
    if (-not $resolved) { throw "Required native build tool is missing from PATH: $tool" }
    Write-Host ("  {0,-6} {1}" -f $tool, $resolved.Source)
}

try {
    & $Command[0] @($Command[1..($Command.Length - 1)])
    $commandExitCode = $LASTEXITCODE
}
finally {
    # `$env:` writes are process-wide, so repeated invocations inside one
    # session would otherwise stack vcvars directories until PATH overflows.
    foreach ($name in $originalEnvironment.Keys) {
        Set-Item -Path "Env:$name" -Value $originalEnvironment[$name]
    }
    foreach ($name in @(Get-ChildItem Env: | Select-Object -ExpandProperty Name)) {
        if (-not $originalEnvironment.ContainsKey($name)) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
    }
}
exit $commandExitCode
