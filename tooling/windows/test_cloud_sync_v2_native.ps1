[CmdletBinding()]
param(
    [ValidatePattern('^(cloud_sync_[A-Za-z0-9_:]*|cloud_message[A-Za-z0-9_:]*|desktop_native_logging::tests)$')]
    [string] $TestFilter = 'cloud_sync_',
    [ValidateSet('rust_lib_bluebubbles', 'rustpush')]
    [string] $TestPackage = 'rust_lib_bluebubbles',
    [string] $CargoHome = 'C:\Codex\Toolchains\cargo',
    [string] $RustupHome = 'C:\Codex\Toolchains\rustup',
    [string] $CacheRoot = 'C:\Codex\OpenBubblesReview\build-cache\ck2-win-arm64',
    [string] $EvidenceRoot = 'C:\Codex\OpenBubblesReview\evidence\windows-native-tests',
    [string] $SignTool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\arm64\signtool.exe',
    [string] $SigningThumbprint = '8240557965890665F3B49E5FEC83D511CA4F2C9D',
    [switch] $RegenerateBindings,
    [string] $BridgeCodegen = 'C:\Codex\Toolchains\frb-codegen-2.3.0-x64\bin\flutter_rust_bridge_codegen.exe'
)

# Offline native tests, sharing the exact Windows harness build context.
# This does not open an application profile, connect an account, or send data.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$nativeCache = Join-Path $CacheRoot 'rust_lib_bluebubbles'
$harnessProject = Join-Path $repository 'build\windows\arm64\plugins\rust_lib_bluebubbles\rust_lib_bluebubbles_cargokit.vcxproj'
$wrapper = Join-Path $CacheRoot 'proc_macro_signing_wrapper_delayed.exe'
$cargo = Join-Path $CargoHome 'bin\cargo.exe'
foreach ($required in @($cargo, $wrapper, $SignTool, $harnessProject)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing Windows harness prerequisite: $required"
    }
}
$protoc = (Get-Command protoc -ErrorAction Stop).Source
$vsDevCmd = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $vsDevCmd -PathType Leaf)) {
    throw 'The matching Visual Studio build environment is unavailable.'
}
# Capture only SDK search paths, never print or persist the full environment.
# MSBuild gives cc-rs a compiler already on PATH. Registry fallback observes
# a different set of fingerprint inputs and churns the shared native cache.
$sdkOutput = & $env:ComSpec /d /s /c "`"$vsDevCmd`" -arch=arm64 -host_arch=arm64 -no_logo >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the ARM64 Visual Studio environment.' }
$sdkPaths = @{}
foreach ($line in $sdkOutput) {
    if ($line -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$') {
        $sdkPaths[$Matches[1]] = $Matches[2]
    }
}
$sdkOutput = $null
foreach ($name in @('PATH', 'INCLUDE', 'LIB')) {
    if ([string]::IsNullOrWhiteSpace($sdkPaths[$name])) { throw "SDK $name is missing." }
}
$cmakeCompilers = @(Get-ChildItem -LiteralPath (Join-Path $repository 'build\windows\arm64\CMakeFiles') -Directory | ForEach-Object {
    $configuration = Join-Path $_.FullName 'CMakeCXXCompiler.cmake'
    if (Test-Path -LiteralPath $configuration -PathType Leaf) {
        foreach ($line in [IO.File]::ReadLines($configuration)) {
            if ($line -match '^set\(CMAKE_CXX_COMPILER "([^"]+)"\)') {
                [IO.Path]::GetFullPath($Matches[1])
            }
        }
    }
} | Sort-Object -Unique)
$sdkCompiler = @($sdkPaths['PATH'] -split ';' | Where-Object { $_ } | ForEach-Object {
    $candidate = Join-Path $_ 'cl.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { [IO.Path]::GetFullPath($candidate) }
}) | Select-Object -First 1
if ($cmakeCompilers.Count -ne 1 -or $sdkCompiler -ne $cmakeCompilers[0]) {
    throw 'Visual Studio compiler differs from the cached Flutter compiler; rebuild the harness first.'
}
$safePath = (($sdkPaths['PATH'] -split ';') | Where-Object {
    $_ -and $_ -notmatch '(?i)\\Strawberry\\(c|perl)\\'
}) -join ';'
$buildEnvironment = @{
    CARGO_HOME = $CargoHome
    RUSTUP_HOME = $RustupHome
    RUSTC_WRAPPER = $wrapper
    OPENBUBBLES_PROC_MACRO_SIGNTOOL = $SignTool
    OPENBUBBLES_PROC_MACRO_SIGNING_THUMBPRINT = $SigningThumbprint
    CARGO_BUILD_JOBS = '4'
    CARGO_TARGET_DIR = $nativeCache
    CARGO_BUILD_TARGET = 'aarch64-pc-windows-msvc'
    CARGO_PROFILE_DEV_DEBUG = '0'
    CARGO_PROFILE_DEV_INCREMENTAL = 'false'
    # A space explicitly overrides rust/.cargo/config.toml with zero flags.
    RUSTFLAGS = ' '
    CARGO_ENCODED_RUSTFLAGS = $null
    # cc-rs tracks this MSBuild value. Omitting it rebuilds OpenSSL on every
    # switch between the Flutter runner and standalone Cargo tests.
    VSTEL_MSBuildProjectFullPath = $harnessProject
    VCINSTALLDIR = $null
    VSCMD_ARG_TGT_ARCH = $null
    VCToolsVersion = $null
    VSCMD_ARG_VCVARS_SPECTRE = $null
    WindowsSdkDir = $null
    WindowsSDKVersion = $null
    INCLUDE = $sdkPaths['INCLUDE']
    LIB = $sdkPaths['LIB']
    LIBPATH = $sdkPaths['LIBPATH']
    PROTOC = $protoc
    LANG = 'C'
    LC_ALL = 'C'
    # FRB 2.3 accepts only info/debug, not a host's inherited warn filter.
    RUST_LOG = 'info'
    Path = "C:\Codex\Toolchains\nuget;$(Join-Path $CargoHome 'bin');$safePath;C:\Strawberry\perl\bin;C:\Codex\Toolchains\LLVM-22.1.8-woa64-portable\bin"
    CC = $null; CXX = $null; AR = $null; LD = $null
    RANLIB = $null; CFLAGS = $null; CXXFLAGS = $null
}
$priorEnvironment = @{}
foreach ($name in $buildEnvironment.Keys) {
    $priorEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$runTag = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$runDirectory = Join-Path $EvidenceRoot $runTag
$null = New-Item -ItemType Directory -Path $runDirectory
$buildJson = Join-Path $runDirectory 'build.jsonl'
$buildLog = Join-Path $runDirectory 'build.log'
$testLog = Join-Path $runDirectory 'tests.log'
Push-Location $repository
try {
    foreach ($name in $buildEnvironment.Keys) {
        if ($null -eq $buildEnvironment[$name]) {
            # PowerShell can coerce $null to an empty string for the .NET
            # overload. cc-rs distinguishes an unset CC from CC="".
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $buildEnvironment[$name], 'Process')
        }
    }
    if ($RegenerateBindings) {
        if (-not (Test-Path -LiteralPath $BridgeCodegen -PathType Leaf)) {
            throw 'The pinned Flutter Rust Bridge generator is unavailable.'
        }
        $env:Path = 'C:\Codex\Toolchains\flutter-3.44.8-arm64\bin;' + $env:Path
        $codegenLog = Join-Path $runDirectory 'codegen.log'
        & $BridgeCodegen generate --config-file flutter_rust_bridge.yaml *> $codegenLog
        if ($LASTEXITCODE -ne 0) {
            Get-Content -LiteralPath $codegenLog -Tail 12
            throw "Bridge generation failed. See $codegenLog"
        }
        # Match the established CI post-generation contract, not raw FRB output.
        & .\tooling\frb\guard_generated_sse_impls.ps1 -Mode Deduplicate -ExpectedRemovalCount 6
        & .\tooling\frb\guard_generated_sse_impls.ps1 -Mode Verify
        & .\tooling\frb\normalize_generated_diagnostics.ps1 -Mode Normalize
        & .\tooling\frb\normalize_generated_diagnostics.ps1 -Mode Verify
    }
    $buildWatch = [Diagnostics.Stopwatch]::StartNew()
    # Test the native dependency itself without creating another Cargo cache
    # or changing the Windows application's feature/build environment.
    $packageArguments = @('--package', $TestPackage)
    & $cargo test --manifest-path rust/Cargo.toml --locked `
        @packageArguments `
        --target aarch64-pc-windows-msvc --target-dir $nativeCache `
        --lib --no-run --message-format=json 1> $buildJson 2> $buildLog
    $buildSeconds = [Math]::Round($buildWatch.Elapsed.TotalSeconds, 2)
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $buildLog -Tail 10
        throw "Native test compilation failed. See $runDirectory"
    }
    $artifacts = @(foreach ($line in [IO.File]::ReadLines($buildJson)) {
        $message = $line | ConvertFrom-Json
        if ($message.reason -eq 'compiler-artifact' -and
            $message.target.name -eq $TestPackage -and
            $message.profile.test -and $message.executable) {
            $message.executable
        }
    })
    if ($artifacts.Count -ne 1) { throw 'Expected exactly one native library test executable.' }
    $binary = Get-Item -LiteralPath $artifacts[0]
    $expectedParent = [IO.Path]::GetFullPath((Join-Path $nativeCache 'aarch64-pc-windows-msvc\debug\deps'))
    if ($binary.DirectoryName -ne $expectedParent -or
        $binary.Name -notmatch ('^' + [regex]::Escape($TestPackage) + '-[0-9a-f]+\.exe$') -or
        ($binary.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unexpected native test artifact; refusing to sign or execute it.'
    }
    if ((Get-AuthenticodeSignature -LiteralPath $binary.FullName).Status -ne 'Valid') {
        & $SignTool sign /fd SHA256 /sha1 $SigningThumbprint $binary.FullName
        if ($LASTEXITCODE -ne 0) { throw 'Native test signing failed.' }
    }
    if ((Get-AuthenticodeSignature -LiteralPath $binary.FullName).Status -ne 'Valid') {
        throw 'Native test signature did not verify.'
    }
    $testWatch = [Diagnostics.Stopwatch]::StartNew()
    & $binary.FullName $TestFilter --test-threads=4 *> $testLog
    $testExit = $LASTEXITCODE
    $testSeconds = [Math]::Round($testWatch.Elapsed.TotalSeconds, 2)
    $testSummary = Get-Content -LiteralPath $testLog -Tail 4
    $testSummary
    if ($testExit -ne 0 -or -not (($testSummary -join ' ') -match 'test result: ok\. [1-9][0-9]* passed; 0 failed;')) {
        throw "Native test selection failed or ran no tests. See $testLog"
    }
    [pscustomobject]@{
        Package = $TestPackage
        Filter = $TestFilter
        BuildSeconds = $buildSeconds
        TestSeconds = $testSeconds
        EvidenceDirectory = $runDirectory
    }
}
finally {
    Pop-Location
    foreach ($name in $priorEnvironment.Keys) {
        if ($null -eq $priorEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $priorEnvironment[$name], 'Process')
        }
    }
}
