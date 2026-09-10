[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceCommit,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $SidecarCommit,

    [Parameter(Mandatory)]
    [ValidateSet('local-write', 'read-only')]
    [string] $BuildVariant,

    [Parameter(Mandatory)]
    [string] $OutputRoot,

    [string] $FlutterRoot,

    [ValidateRange(10, 120)]
    [int] $SmokeTimeoutSeconds = 30,

    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath"
    }
}

function Get-PEMachine {
    param([Parameter(Mandatory)][string] $Path)

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        try {
            if ($reader.ReadUInt16() -ne 0x5A4D) { return 'NotPE' }
            $stream.Position = 0x3C
            $peOffset = $reader.ReadUInt32()
            if ($peOffset -gt ($stream.Length - 6)) { return 'NotPE' }
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) { return 'NotPE' }
            switch ($reader.ReadUInt16()) {
                0x8664 { return 'X64' }
                0xAA64 { return 'ARM64' }
                0x014C { return 'X86' }
                default { return 'Unknown' }
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-CommandText {
    param([Parameter(Mandatory)][string] $FilePath, [string[]] $Arguments)
    return ((& $FilePath @Arguments 2>&1 | Out-String).Trim())
}

$source = (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).Path
$sourceItem = Get-Item -LiteralPath $source -Force
if (-not $sourceItem.PSIsContainer -or
    ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'SourceRoot must be a physical directory.'
}

$actualCommit = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -cne $ExpectedSourceCommit) {
    throw "Checked-out source does not match ExpectedSourceCommit: $actualCommit"
}
$status = @(& git -C $source status --porcelain=v1)
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) {
    throw 'Reviewed source checkout must be clean before build preparation.'
}

$requiredFiles = @(
    'lib/cloud_sync_v2_windows_harness.dart',
    'windows/CMakeLists.txt',
    'windows/runner/cloud_sync_v2_plugin_registrant.cc',
    'tooling/windows/run_cloud_sync_v2_dev.ps1',
    'tooling/windows/run_cloud_sync_v2_auth_probe.ps1',
    'tooling/windows/test_run_cloud_sync_v2_dev.ps1',
    'tooling/windows/test_run_cloud_sync_v2_auth_probe.ps1',
    'test/services/cloud_sync/cloud_sync_v2_windows_harness_test.dart',
    'test/services/cloud_sync/cloud_sync_windows_dev_profile_test.dart',
    'test/services/cloud_sync/cloud_sync_windows_local_write_test.dart'
)
foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) {
        throw "Reviewed source is missing required fast-loop input: $relative"
    }
}

$cmakeSource = Get-Content -LiteralPath (Join-Path $source 'windows/CMakeLists.txt') -Raw
foreach ($requiredText in @(
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS',
    'set(FLUTTER_PLUGIN_LIST',
    'objectbox_flutter_libs',
    'set(FLUTTER_FFI_PLUGIN_LIST',
    'rust_lib_bluebubbles',
    'if(NOT OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS)'
)) {
    if (-not $cmakeSource.Contains($requiredText)) {
        throw "Windows harness CMake contract is missing: $requiredText"
    }
}
$harnessBranch = $cmakeSource.IndexOf(
    'if(OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS)',
    [System.StringComparison]::Ordinal
)
$normalPluginInclude = $cmakeSource.IndexOf(
    'include(flutter/generated_plugins.cmake)',
    [System.StringComparison]::Ordinal
)
if ($harnessBranch -lt 0 -or $normalPluginInclude -le $harnessBranch) {
    throw 'CloudKit harness no longer bypasses the full generated plugin graph.'
}

$harnessSource = Get-Content -LiteralPath (
    Join-Path $source 'lib/cloud_sync_v2_windows_harness.dart'
) -Raw
$launchParse = $harnessSource.IndexOf(
    'CloudSyncV2WindowsHarnessLaunch.parse(arguments)',
    [System.StringComparison]::Ordinal
)
$profileConfiguration = $harnessSource.IndexOf(
    'fs.configureCloudSyncV2WindowsDevProfile()',
    [System.StringComparison]::Ordinal
)
$nativeInit = $harnessSource.IndexOf('await RustLib.init()', [System.StringComparison]::Ordinal)
if ($launchParse -lt 0 -or $profileConfiguration -le $launchParse -or
    $nativeInit -le $profileConfiguration -or
    -not $harnessSource.Contains('cloud_sync_windows_dev_launch_id_invalid')) {
    throw 'Invalid-launch rejection no longer precedes profile and native initialization.'
}

$launcherSource = Get-Content -LiteralPath (
    Join-Path $source 'tooling/windows/run_cloud_sync_v2_dev.ps1'
) -Raw
$flagAssignment = $launcherSource.IndexOf(
    '$env:OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS = "1"',
    [System.StringComparison]::Ordinal
)
$flutterBuild = $launcherSource.IndexOf('& $flutter @arguments', [System.StringComparison]::Ordinal)
if ($flagAssignment -lt 0 -or $flutterBuild -le $flagAssignment) {
    throw 'The reviewed launcher no longer selects the dedicated harness before building.'
}
foreach ($writerContract in @(
    'return "$SourceIdentifier-local-write"',
    '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY=true',
    '--dart-define=OPENBUBBLES_CLOUDKIT_WRITER_OWNER=v2'
)) {
    if (-not $launcherSource.Contains($writerContract)) {
        throw "The reviewed launcher is missing its local-write build contract: $writerContract"
    }
}

foreach ($name in @(
    'OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY',
    'OPENBUBBLES_CLOUDKIT_WRITER_OWNER',
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_REPLAY_EXCLUDED_CHATS',
    'OPENBUBBLES_CLOUD_SYNC_V2_LOCAL_SEND_RUNTIME'
)) {
    if (-not [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable($name, 'Process')
    )) {
        throw "Writer-capable environment variable must be absent: $name"
    }
}

if ($ValidateOnly) {
    [pscustomobject]@{
        result = 'validated'
        source_commit = $actualCommit
        build_variant = $BuildVariant
        harness_media_graph_excluded = $true
        invalid_launch_precedes_profile_and_native_init = $true
        automatic_send_runtime_absent = $true
    } | ConvertTo-Json -Depth 4
    return
}

if (-not $IsWindows -or
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
        [System.Runtime.InteropServices.Architecture]::Arm64) {
    throw 'This build must run on native Windows ARM64.'
}

if ($FlutterRoot) {
    $flutter = Join-Path ([System.IO.Path]::GetFullPath($FlutterRoot)) 'bin/flutter.bat'
}
else {
    $flutterCommand = Get-Command flutter.bat -ErrorAction SilentlyContinue
    if (-not $flutterCommand) { $flutterCommand = Get-Command flutter -ErrorAction Stop }
    $flutter = $flutterCommand.Source
}
foreach ($tool in @('git', 'cmake', 'perl', 'rustc', 'cargo', 'protoc')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required Windows build tool is unavailable: $tool"
    }
}
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
    throw "Flutter executable is unavailable: $flutter"
}

$output = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\', '/')
$outputVolume = [System.IO.Path]::GetPathRoot($output).TrimEnd('\', '/')
if ($output -eq $outputVolume -or $output.Length -lt ($outputVolume.Length + 12)) {
    throw "OutputRoot is too broad: $output"
}
if (Test-Path -LiteralPath $output) {
    if (@(Get-ChildItem -LiteralPath $output -Force).Count -ne 0) {
        throw "OutputRoot must be absent or empty: $output"
    }
}
else {
    New-Item -ItemType Directory -Path $output | Out-Null
}

$fairPlaySource = Join-Path $source 'rustpush/certs/legacy-fairplay'
$fairPlayDestination = Join-Path $source 'rustpush/certs/fairplay'
foreach ($file in @('fairplay.pem', 'fairplay.crt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $fairPlaySource $file) -PathType Leaf)) {
        throw "Repository-provided compile fixture is unavailable: $file"
    }
}
New-Item -ItemType Directory -Path $fairPlayDestination -Force | Out-Null
$certificateNames = @(
    '4056631661436364584235346952193',
    '4056631661436364584235346952194',
    '4056631661436364584235346952195',
    '4056631661436364584235346952196',
    '4056631661436364584235346952197',
    '4056631661436364584235346952198',
    '4056631661436364584235346952199',
    '4056631661436364584235346952200',
    '4056631661436364584235346952201',
    '4056631661436364584235346952208'
)
foreach ($name in $certificateNames) {
    Copy-Item -LiteralPath (Join-Path $fairPlaySource 'fairplay.pem') `
        -Destination (Join-Path $fairPlayDestination "$name.pem")
    Copy-Item -LiteralPath (Join-Path $fairPlaySource 'fairplay.crt') `
        -Destination (Join-Path $fairPlayDestination "$name.crt")
}

$previousEnvironment = @{}
$buildEnvironment = @{
    OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS = '1'
    CARGO_BUILD_JOBS = '4'
    CARGO_PROFILE_DEV_DEBUG = '0'
    CARGO_PROFILE_DEV_INCREMENTAL = 'false'
    CARGOKIT_TARGET_TEMP_DIR_OVERRIDE = (Join-Path $env:RUNNER_TEMP 'cloudkit-cargokit-arm64')
}
foreach ($name in $buildEnvironment.Keys) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$buildLog = Join-Path $output 'flutter-build.log'
$testLog = Join-Path $output 'contract-tests.log'
$dartTestLog = Join-Path $output 'dart-windows-tests.log'
$nativeCodecTestLog = Join-Path $output 'native-codec-tests.log'
Push-Location $source
try {
    foreach ($name in $buildEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $buildEnvironment[$name], 'Process')
    }

    Invoke-Checked -FilePath $flutter -ArgumentList @('config', '--enable-windows-desktop')
    Invoke-Checked -FilePath $flutter -ArgumentList @('pub', 'get')
    Invoke-Checked -FilePath 'git' -ArgumentList @('diff', '--exit-code', '--', 'pubspec.lock', 'rust/Cargo.lock')

    $contractScripts = @(
        'tooling/windows/test_run_cloud_sync_v2_dev.ps1',
        'tooling/windows/test_run_cloud_sync_v2_auth_probe.ps1'
    )
    foreach ($script in $contractScripts) {
        & pwsh -NoLogo -NoProfile -File $script 2>&1 |
            Tee-Object -FilePath $testLog -Append
        if ($LASTEXITCODE -ne 0) { throw "Contract test failed: $script" }
    }

    $dartTests = @(
        'test/services/cloud_sync/cloud_sync_v2_windows_harness_test.dart',
        'test/services/cloud_sync/cloud_sync_windows_dev_profile_test.dart',
        'test/services/cloud_sync/cloud_sync_windows_local_write_test.dart'
    )
    & $flutter test --no-pub @dartTests 2>&1 |
        Tee-Object -FilePath $dartTestLog
    if ($LASTEXITCODE -ne 0) { throw 'Focused Windows CloudKit Dart tests failed.' }

    $buildIdentifier = if ($BuildVariant -eq 'local-write') {
        "$actualCommit-local-write"
    }
    else {
        $actualCommit
    }
    $buildArguments = @(
        'build', 'windows', '--debug', '--no-pub',
        '--target', 'lib/cloud_sync_v2_windows_harness.dart',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE=true',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true',
        "--dart-define=OPENBUBBLES_BUILD_COMMIT=$buildIdentifier"
    )
    if ($BuildVariant -eq 'local-write') {
        $buildArguments += '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY=true'
        $buildArguments += '--dart-define=OPENBUBBLES_CLOUDKIT_WRITER_OWNER=v2'
    }
    & $flutter @buildArguments 2>&1 | Tee-Object -FilePath $buildLog
    if ($LASTEXITCODE -ne 0) { throw 'Windows CloudKit harness build failed.' }
    Invoke-Checked -FilePath 'git' -ArgumentList @('diff', '--exit-code', '--', 'pubspec.lock', 'rust/Cargo.lock')
}
finally {
    Pop-Location
    foreach ($name in $previousEnvironment.Keys) {
        if ($null -eq $previousEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
}

$builtBundle = Join-Path $source 'build/windows/arm64/runner/Debug'
$runner = Join-Path $builtBundle 'bluebubbles_app.exe'
$rustLibrary = Join-Path $builtBundle 'rust_lib_bluebubbles.dll'
foreach ($required in @($runner, $rustLibrary)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Build did not produce required executable content: $required"
    }
}

$bundle = Join-Path $output 'bundle'
New-Item -ItemType Directory -Path $bundle | Out-Null
Copy-Item -Path (Join-Path $builtBundle '*') -Destination $bundle -Recurse
$runner = Join-Path $bundle 'bluebubbles_app.exe'
$rustLibrary = Join-Path $bundle 'rust_lib_bluebubbles.dll'

$peFiles = @(Get-ChildItem -LiteralPath $bundle -File -Recurse |
    Where-Object { $_.Extension.ToLowerInvariant() -in @('.exe', '.dll') })
if ($peFiles.Count -lt 4) { throw 'Packaged harness contains too few PE runtime files.' }
foreach ($file in $peFiles) {
    $machine = Get-PEMachine -Path $file.FullName
    if ($machine -ne 'ARM64') {
        throw "Packaged harness has a non-ARM64 PE file: $($file.Name) ($machine)"
    }
}

$nativeHandle = [System.Runtime.InteropServices.NativeLibrary]::Load($rustLibrary)
try {
    if ($nativeHandle -eq [IntPtr]::Zero) { throw 'Rust bridge returned a null native handle.' }
}
finally {
    if ($nativeHandle -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.NativeLibrary]::Free($nativeHandle)
    }
}

$priorNativeTestLibrary = $env:OPENBUBBLES_TEST_NATIVE_LIBRARY
$priorNativeTestPath = $env:Path
try {
    $env:OPENBUBBLES_TEST_NATIVE_LIBRARY = $rustLibrary
    $env:Path = "$bundle;$priorNativeTestPath"
    Push-Location $source
    try {
        & $flutter test --no-pub `
            'test/services/cloud_sync/cloud_sync_local_send_encoder_test.dart' `
            --reporter json `
            2>&1 | Tee-Object -FilePath $nativeCodecTestLog
        if ($LASTEXITCODE -ne 0) {
            throw 'Native local-write encoder suite failed.'
        }
        $nativeTestEvents = @(Get-Content -LiteralPath $nativeCodecTestLog |
            ForEach-Object {
                try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
            })
        $nativeTestDone = @($nativeTestEvents | Where-Object {
            if ($null -eq $_ -or $null -eq $_.PSObject.Properties['type'] -or $_.type -ne 'testDone') { return $false }
            $hiddenProperty = $_.PSObject.Properties['hidden']
            return $null -eq $hiddenProperty -or -not [bool]$hiddenProperty.Value
        })
        if ($nativeTestDone.Count -ne 48) {
            throw "Expected 48 native codec tests, observed $($nativeTestDone.Count)."
        }
        if (@($nativeTestDone | Where-Object { $_.result -ne 'success' -or $_.skipped }).Count -ne 0) {
            throw 'Native codec results include a skipped or unsuccessful test.'
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    $env:Path = $priorNativeTestPath
    if ($null -eq $priorNativeTestLibrary) {
        Remove-Item -LiteralPath 'Env:OPENBUBBLES_TEST_NATIVE_LIBRARY' `
            -ErrorAction SilentlyContinue
    }
    else {
        $env:OPENBUBBLES_TEST_NATIVE_LIBRARY = $priorNativeTestLibrary
    }
}

$smokeRoot = Join-Path $env:RUNNER_TEMP (
    'cloudkit-executable-smoke-' + [guid]::NewGuid().ToString('N')
)
$smokeAppData = Join-Path $smokeRoot 'AppData/Roaming'
$smokeLocalAppData = Join-Path $smokeRoot 'AppData/Local'
New-Item -ItemType Directory -Path $smokeAppData -Force | Out-Null
New-Item -ItemType Directory -Path $smokeLocalAppData -Force | Out-Null
$priorAppData = $env:APPDATA
$priorLocalAppData = $env:LOCALAPPDATA
$smokeStdout = Join-Path $smokeRoot 'stdout.txt'
$smokeStderr = Join-Path $smokeRoot 'stderr.txt'
$expectedSmokeMarker = 'cloud_sync_windows_dev_launch_id_invalid'
$smokeMarkerSeen = $false
$process = $null
try {
    $env:APPDATA = $smokeAppData
    $env:LOCALAPPDATA = $smokeLocalAppData
    $process = Start-Process -FilePath $runner -WorkingDirectory $bundle `
        -ArgumentList @('--launch-id=invalid') `
        -RedirectStandardOutput $smokeStdout `
        -RedirectStandardError $smokeStderr `
        -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($SmokeTimeoutSeconds)
    do {
        $captured = @($smokeStdout, $smokeStderr | ForEach-Object {
            if (Test-Path -LiteralPath $_ -PathType Leaf) {
                Get-Content -LiteralPath $_ -Raw -ErrorAction SilentlyContinue
            }
        }) -join "`n"
        $smokeMarkerSeen = $captured.Contains($expectedSmokeMarker)
        if ($smokeMarkerSeen -or $process.HasExited) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
    $captured = @($smokeStdout, $smokeStderr | ForEach-Object {
        if (Test-Path -LiteralPath $_ -PathType Leaf) {
            Get-Content -LiteralPath $_ -Raw -ErrorAction SilentlyContinue
        }
    }) -join "`n"
    $smokeMarkerSeen = $captured.Contains($expectedSmokeMarker)
}
finally {
    $env:APPDATA = $priorAppData
    $env:LOCALAPPDATA = $priorLocalAppData
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
}
$smokeFiles = @(Get-ChildItem -LiteralPath $smokeRoot -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notin @($smokeStdout, $smokeStderr) })
if ($smokeFiles.Count -ne 0) {
    throw 'Invalid-launch smoke wrote application or profile state.'
}

$forbiddenBundleFiles = @(Get-ChildItem -LiteralPath $bundle -File -Recurse |
    Where-Object {
        $_.Extension.ToLowerInvariant() -in @('.pfx', '.p12', '.pem', '.crt', '.key', '.plist', '.db')
    })
if ($forbiddenBundleFiles.Count -ne 0) {
    throw 'Engineering bundle contains a credential, certificate, profile, or database file.'
}

$bundlePrefixLength = $bundle.TrimEnd('\', '/').Length + 1
$fileInventory = @(Get-ChildItem -LiteralPath $bundle -File -Recurse |
    Sort-Object FullName |
    ForEach-Object {
        [ordered]@{
            relative_path = $_.FullName.Substring($bundlePrefixLength).Replace('\', '/')
            size_bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            pe_machine = if ($_.Extension.ToLowerInvariant() -in @('.exe', '.dll')) {
                Get-PEMachine -Path $_.FullName
            } else { $null }
        }
    })

$manifestPath = Join-Path $output 'provenance.json'
$provenance = [ordered]@{
    schema_version = 1
    purpose = 'windows-cloudkit-fast-loop-engineering-bundle'
    source_commit = $actualCommit
    sidecar_commit = $SidecarCommit
    created_utc = [DateTime]::UtcNow.ToString('o')
    runner = [ordered]@{
        image_os = $env:ImageOS
        image_version = $env:ImageVersion
        os_architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    toolchain = [ordered]@{
        flutter = Get-CommandText -FilePath $flutter -Arguments @('--version')
        rustc = Get-CommandText -FilePath 'rustc' -Arguments @('--version')
        protoc = Get-CommandText -FilePath 'protoc' -Arguments @('--version')
        cmake = Get-CommandText -FilePath 'cmake' -Arguments @('--version')
    }
    build = [ordered]@{
        target = 'lib/cloud_sync_v2_windows_harness.dart'
        configuration = 'debug'
        architecture = 'arm64'
        variant = $BuildVariant
        build_identifier = $buildIdentifier
        native_media_graph_excluded = $true
        signing_applied = $false
        writer_defines_present = ($BuildVariant -eq 'local-write')
        automatic_send_runtime_present = $false
    }
    verification = [ordered]@{
        powershell_contract_tests = 'passed'
        focused_dart_tests = 'passed'
        all_pe_files_arm64 = $true
        rust_bridge_load_unload = 'passed'
        native_local_write_encoder_tests = [ordered]@{
            result = 'passed'
            native_library = 'bundle/rust_lib_bluebubbles.dll'
            test_file = 'test/services/cloud_sync/cloud_sync_local_send_encoder_test.dart'
            expected_test_count = 48
            full_file_run = $true
        }
        invalid_launch_diagnostic = [ordered]@{
            operation = 'invalid-launch-id'
            network_or_auth_requested = $false
            expected_dart_marker = $expectedSmokeMarker
            expected_dart_marker_seen = $smokeMarkerSeen
            process_terminated_if_still_running = $true
            profile_state_written = $false
            proof_status = if ($smokeMarkerSeen) { 'observed' } else { 'not-captured' }
        }
        account_profile_or_database_in_bundle = $false
    }
    files = $fileInventory
}
[System.IO.File]::WriteAllText(
    $manifestPath,
    ($provenance | ConvertTo-Json -Depth 10),
    [System.Text.UTF8Encoding]::new($false)
)

$archive = Join-Path $output "windows-cloudkit-fast-loop-arm64-$BuildVariant-$actualCommit.zip"
Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
$hashPath = "$archive.sha256"
[System.IO.File]::WriteAllText(
    $hashPath,
    "$archiveHash  $([System.IO.Path]::GetFileName($archive))`n",
    [System.Text.Encoding]::ASCII
)

[pscustomobject]@{
    result = 'passed'
    source_commit = $actualCommit
    build_variant = $BuildVariant
    build_identifier = $buildIdentifier
    bundle = $archive
    bundle_sha256 = $archiveHash
    provenance = $manifestPath
    pe_files = $peFiles.Count
    native_codec_smoke = '48_tests_passed_against_packaged_rust_dll'
    invalid_launch_marker_seen = $smokeMarkerSeen
    live_cloudkit_tested = $false
} | ConvertTo-Json -Depth 5
