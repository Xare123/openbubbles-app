[CmdletBinding()]
param(
    [switch] $EnableLive,
    [string] $RunnerDirectory = '',
    [string] $ReceiptPath = '',
    [string] $ExpectedSourceSha = '',
    [string] $ExpectedNativeSourceSha = '',
    [string] $ExpectedPilotSha = '',
    [string] $ExpectedArchiveSha256 = '',
    [string] $ExpectedProvenanceSha256 = '',
    [string] $SigningThumbprint = '8240557965890665F3B49E5FEC83D511CA4F2C9D',
    [string] $Repository = '',
    [string] $FlutterRoot = 'C:\Codex\Toolchains\flutter-3.44.8-arm64',
    [string] $ProfileRoot = '',
    [ValidateRange(60, 900)][int] $TimeoutSeconds = 600,
    [switch] $FunctionsOnlyForTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Dart-only historical import against a verified local-write harness bundle:
# Dart executes from source (no Windows/APK rebuild per Dart change) while the
# native library comes from the imported, provenance-checked artifact. Without
# -EnableLive this script is inert: it prints requirements and touches nothing.
# With -EnableLive it performs exactly one historical-import pass inside the
# fixed isolated dev profile using the profile's existing
# windows-historical-import-request.json. It never sends IDS messages, enables
# automatic uploads, replays auth, drains unrelated queues, mutates the source
# database, or deletes queue/evidence directories on timeout.

$script:HistoricalLiveConsent = 'OPENBUBBLES_RUN_IMPORTED_HISTORICAL_LIVE'
$script:HistoricalLiveAcknowledge = 'OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA'
$script:HistoricalLiveTestName =
    'isolated profile executes one historical import pass'
$script:HistoricalLiveOperation = 'historical-import'
$script:HistoricalLiveTerminalStage = 'historical-import-pass-complete'
$script:HistoricalLiveRequestFileName = 'windows-historical-import-request.json'

# Reused verification, profile, and process helpers. The base
# scripts honor -FunctionsOnlyForTest, so test dot-sourcing defines functions
# without executing anything.

# Dot-sourced scripts carry top-level param blocks that overwrite same-named
# caller variables (including FunctionsOnlyForTest). Preserve the complete
# invocation state first and restore it immediately after, mirroring the
# import_verified_windows_cloud_harness.ps1 pattern. Without this, the
# FunctionsOnlyForTest restore alone would silently flip this run inert.
$script:HistoricalLiveInvocation = [ordered]@{
    EnableLive = [bool]$EnableLive
    RunnerDirectory = $RunnerDirectory
    ReceiptPath = $ReceiptPath
    ExpectedSourceSha = $ExpectedSourceSha
    ExpectedNativeSourceSha = $ExpectedNativeSourceSha
    ExpectedPilotSha = $ExpectedPilotSha
    ExpectedArchiveSha256 = $ExpectedArchiveSha256
    ExpectedProvenanceSha256 = $ExpectedProvenanceSha256
    SigningThumbprint = $SigningThumbprint
    Repository = $Repository
    FlutterRoot = $FlutterRoot
    ProfileRoot = $ProfileRoot
    TimeoutSeconds = $TimeoutSeconds
    FunctionsOnlyForTest = [bool]$FunctionsOnlyForTest
}
. (Join-Path $PSScriptRoot 'run_imported_chat1_native_live.ps1') -FunctionsOnlyForTest
. (Join-Path $PSScriptRoot 'run_imported_cloud_sync_v2_dart_live.ps1') -FunctionsOnlyForTest
. (Join-Path $PSScriptRoot 'import_verified_windows_cloud_harness.ps1') -FunctionsOnlyForTest
$EnableLive = $script:HistoricalLiveInvocation.EnableLive
$RunnerDirectory = $script:HistoricalLiveInvocation.RunnerDirectory
$ReceiptPath = $script:HistoricalLiveInvocation.ReceiptPath
$ExpectedSourceSha = $script:HistoricalLiveInvocation.ExpectedSourceSha
$ExpectedNativeSourceSha = $script:HistoricalLiveInvocation.ExpectedNativeSourceSha
$ExpectedPilotSha = $script:HistoricalLiveInvocation.ExpectedPilotSha
$ExpectedArchiveSha256 = $script:HistoricalLiveInvocation.ExpectedArchiveSha256
$ExpectedProvenanceSha256 = $script:HistoricalLiveInvocation.ExpectedProvenanceSha256
$SigningThumbprint = $script:HistoricalLiveInvocation.SigningThumbprint
$Repository = $script:HistoricalLiveInvocation.Repository
$FlutterRoot = $script:HistoricalLiveInvocation.FlutterRoot
$ProfileRoot = $script:HistoricalLiveInvocation.ProfileRoot
$TimeoutSeconds = $script:HistoricalLiveInvocation.TimeoutSeconds
$FunctionsOnlyForTest = $script:HistoricalLiveInvocation.FunctionsOnlyForTest

function Fail-HistoricalLive {
    param([Parameter(Mandatory)][string] $Code)
    if ($Code -cnotmatch '^[a-z][a-z0-9_]{1,120}$') {
        $Code = 'historical_live_unclassified_failure'
    }
    throw "HISTORICAL-LIVE-FAIL: $Code"
}

function Test-HistoricalLiveHex {
    param([string] $Value = '', [Parameter(Mandatory)][int] $Length)
    if ($Value.Length -ne $Length -or $Length -le 0) { return $false }
    return $Value -cnotmatch '[^0-9a-f]'
}

function Assert-HistoricalLiveRequestFile {
    param([Parameter(Mandatory)][string] $Profile)
    $requestPath = Join-Path -Path $Profile $script:HistoricalLiveRequestFileName
    if (-not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
        Fail-HistoricalLive 'historical_live_request_missing'
    }
    Assert-StandalonePlainPath -Path $requestPath -Label 'historical_live_request'
    $requestLength = (Get-Item -LiteralPath $requestPath).Length
    if ($requestLength -lt 1 -or $requestLength -gt 16384) {
        Fail-HistoricalLive 'historical_live_request_size_rejected'
    }
    try {
        $parsed = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -AsHashtable
    }
    catch { Fail-HistoricalLive 'historical_live_request_unparseable' }
    if ($parsed -isnot [Collections.IDictionary]) {
        Fail-HistoricalLive 'historical_live_request_bounds_rejected'
    }
    foreach ($field in @('version', 'action', 'maximumAssessed', 'maximumCreates')) {
        if (-not $parsed.Contains($field)) { Fail-HistoricalLive 'historical_live_request_bounds_rejected' }
    }
    if ($parsed.version -cne 1 -or
        $parsed.action -cnotin @('preview', 'archive') -or
        ($parsed.maximumAssessed -isnot [long] -and $parsed.maximumAssessed -isnot [int]) -or
        ($parsed.maximumCreates -isnot [long] -and $parsed.maximumCreates -isnot [int]) -or
        $parsed.maximumAssessed -lt 1 -or $parsed.maximumAssessed -gt 200 -or
        $parsed.maximumCreates -lt 1 -or $parsed.maximumCreates -gt 20) {
        Fail-HistoricalLive 'historical_live_request_bounds_rejected'
    }
    return $parsed
}

function Assert-HistoricalLocalWriteRuntime {
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][string] $NativeSource,
        [Parameter(Mandatory)][string] $Pilot,
        [Parameter(Mandatory)][string] $Archive,
        [Parameter(Mandatory)][string] $Provenance,
        [Parameter(Mandatory)][string] $Signer
    )
    foreach ($sha in @($NativeSource, $Pilot)) {
        if (-not (Test-HistoricalLiveHex $sha 40)) {
            Fail-HistoricalLive 'historical_live_source_identity_rejected'
        }
    }
    foreach ($sha in @($Archive, $Provenance)) {
        if (-not (Test-HistoricalLiveHex $sha 64)) {
            Fail-HistoricalLive 'historical_live_origin_hash_rejected'
        }
    }
    $directoryFull = [IO.Path]::GetFullPath($Directory)
    $runner = Join-Path $directoryFull 'bluebubbles_app.exe'
    $native = Join-Path $directoryFull 'rust_lib_bluebubbles.dll'
    $vendor = Join-Path $directoryFull 'objectbox.dll'
    foreach ($file in @($ReceiptPath, $runner, $native, $vendor)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Fail-HistoricalLive 'historical_live_runtime_file_missing'
        }
        Assert-StandalonePlainPath -Path $file -Label 'historical_live_runtime'
    }
    try { $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json }
    catch { Fail-HistoricalLive 'historical_live_receipt_rejected' }
    $build = $NativeSource.Substring(0, 12) + '-local-write'
    try {
        $bound = $receipt.origin.source_commit -ceq $NativeSource -and
            $receipt.origin.pilot_commit -ceq $Pilot -and
            $receipt.origin.archive_sha256 -ceq $Archive -and
            $receipt.origin.provenance_sha256 -ceq $Provenance -and
            $receipt.origin.artifact_mode -ceq 'harness' -and
            $receipt.origin.variant -ceq 'local-write' -and
            $receipt.origin.runner_post_sign_sha256 -ceq $receipt.runner_sha256 -and
            $receipt.origin.rust_library_post_sign_sha256 -ceq $receipt.rust_library_sha256
    } catch { $bound = $false }
    if (-not $bound -or -not (Test-HarnessBuildReceipt -ReceiptPath $ReceiptPath `
            -BuildIdentifier $build -Runner $runner -RustLibrary $native)) {
        Fail-HistoricalLive 'historical_live_receipt_rejected'
    }
    foreach ($file in @($runner, $native, $vendor)) {
        if ((Get-StandalonePeMachine $file) -ne 0xAA64) {
            Fail-HistoricalLive 'historical_live_runtime_architecture_rejected'
        }
    }
    if ((Get-FileHash -LiteralPath $vendor -Algorithm SHA256).Hash.ToLowerInvariant() -cne
        (Get-StandaloneObjectBoxPin)) {
        Fail-HistoricalLive 'historical_live_objectbox_pin_rejected'
    }
    foreach ($file in @($runner, $native)) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file
        if ([string]$signature.Status -cne 'Valid' -or
            $null -eq $signature.SignerCertificate -or
            [string]$signature.SignerCertificate.Thumbprint -ine $Signer) {
            Fail-HistoricalLive 'historical_live_runtime_signature_rejected'
        }
    }
    return [pscustomobject]@{
        Directory = $directoryFull
        NativeLibrary = $native
        NativeSha256 = $receipt.rust_library_sha256
        ObjectBoxSha256 = (Get-StandaloneObjectBoxPin)
        ReceiptSha256 = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function New-HistoricalLiveStartInfo {
    param(
        [Parameter(Mandatory)][string] $Dart,
        [Parameter(Mandatory)][string] $FlutterToolsSnapshot,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $NativeLibrary,
        [Parameter(Mandatory)][string] $RuntimeDirectory,
        [Parameter(Mandatory)][string] $LaunchId,
        [Parameter(Mandatory)][string] $BuildIdentifier,
        [Parameter(Mandatory)][string] $RequestSha256,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )
    $start = [Diagnostics.ProcessStartInfo]::new($Dart)
    $start.WorkingDirectory = $Repository
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -like 'OPENBUBBLES_*' -or $key -ceq 'RUST_LOG') {
            $null = $start.Environment.Remove($key)
        }
    }
    $start.Environment['OPENBUBBLES_RUN_LIVE_WINDOWS_HARNESS'] = '1'
    $start.Environment['OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST'] = '1'
    $start.Environment['OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS'] = '1'
    $start.Environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] = 'historical-import'
    $start.Environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'] = $LaunchId
    $start.Environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'] = $NativeLibrary
    $start.Environment['OPENBUBBLES_HISTORICAL_IMPORT_TIMEOUT_SECONDS'] = "$TimeoutSeconds"
    $start.Environment['OPENBUBBLES_HISTORICAL_IMPORT_REQUEST_SHA256'] = $RequestSha256
    $start.Environment['PATH'] = "$RuntimeDirectory;$($start.Environment['PATH'])"
    foreach ($argument in @(
        $FlutterToolsSnapshot, 'test', '--no-pub', '--concurrency=1',
        '--reporter=expanded',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE=true',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY=true',
        '--dart-define=OPENBUBBLES_CLOUDKIT_WRITER_OWNER=v2',
        "--dart-define=OPENBUBBLES_BUILD_COMMIT=$BuildIdentifier",
        'test\live\cloud_sync_v2_windows_historical_live_test.dart'
    )) { $start.ArgumentList.Add($argument) }
    return $start
}

function Invoke-HistoricalLivePass {
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Profile,
        [Parameter(Mandatory)][string] $Dart,
        [Parameter(Mandatory)][string] $Tester,
        [Parameter(Mandatory)][string] $FlutterToolsSnapshot,
        [Parameter(Mandatory)][string] $NativeLibrary,
        [Parameter(Mandatory)][string] $RuntimeDirectory,
        [Parameter(Mandatory)][string] $LaunchId,
        [Parameter(Mandatory)][string] $BuildIdentifier,
        [Parameter(Mandatory)][string] $RequestSha256,
        [Parameter(Mandatory)][string] $ExpectedAction,
        [Parameter(Mandatory)][string] $EvidenceDirectory,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string[]] $AllowedExecutables
    )
    $rawOut = Join-Path $EvidenceDirectory 'historical-stdout.tmp'
    $rawErr = Join-Path $EvidenceDirectory 'historical-stderr.tmp'
    $statusPath = Join-Path $Profile 'cloud-sync-v2\windows-harness-status.json'
    $startArguments = @{
        Dart = $Dart
        FlutterToolsSnapshot = $FlutterToolsSnapshot
        Repository = $Repository
        NativeLibrary = $NativeLibrary
        RuntimeDirectory = $RuntimeDirectory
        LaunchId = $LaunchId
        BuildIdentifier = $BuildIdentifier
        RequestSha256 = $RequestSha256
        TimeoutSeconds = $TimeoutSeconds
    }
    $start = New-HistoricalLiveStartInfo @startArguments
    $process = $null
    $owned = @{}
    try {
        $process = [Diagnostics.Process]::Start($start)
        $null = $process.Handle
        $owned[[int]$process.Id] = @{
            Process = $process
            Path = $Dart
            Started = $process.StartTime.ToUniversalTime()
        }
        $outStream = [IO.File]::Open($rawOut, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $errStream = [IO.File]::Open($rawErr, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $outCopy = $process.StandardOutput.BaseStream.CopyToAsync($outStream)
            $errCopy = $process.StandardError.BaseStream.CopyToAsync($errStream)
            $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
            while (-not $process.HasExited -and [datetime]::UtcNow -lt $deadline) {
                Add-DartApplierOwnedChildren `
                    -Owned $owned -AllowedExecutables $AllowedExecutables
                if ((Get-Item -LiteralPath $rawOut).Length -gt 32MB -or
                    (Get-Item -LiteralPath $rawErr).Length -gt 8MB) {
                    Fail-HistoricalLive 'historical_live_output_overflow'
                }
                Start-Sleep -Milliseconds 100
                $process.Refresh()
            }
            if (-not $process.HasExited) {
                Fail-HistoricalLive 'historical_live_process_deadline'
            }
            if (-not $outCopy.Wait(10000) -or -not $errCopy.Wait(10000)) {
                Fail-HistoricalLive 'historical_live_output_drain_timeout'
            }
        }
        finally {
            $outStream.Dispose()
            $errStream.Dispose()
        }
        Add-DartApplierOwnedChildren `
            -Owned $owned -AllowedExecutables $AllowedExecutables
        $stdout = Get-Content -LiteralPath $rawOut -Raw
        if ($process.ExitCode -ne 0 -or
            -not $stdout.Contains($script:HistoricalLiveTestName,
                [StringComparison]::Ordinal) -or
            -not $stdout.Contains('All tests passed!',
                [StringComparison]::Ordinal)) {
            $safeCode = 'historical_live_flutter_test_failed'
            try {
                $failedStatus = Get-Content -LiteralPath $statusPath -Raw |
                    ConvertFrom-Json
                if ($failedStatus.launch_id -ceq $LaunchId -and
                    $failedStatus.PSObject.Properties['safe_code']) {
                    $safeCode = [string]$failedStatus.safe_code
                }
            }
            catch {}
            Fail-HistoricalLive $safeCode
        }
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        if ($status.launch_id -cne $LaunchId -or $status.state -cne 'finished' -or
            $status.stage -cne $script:HistoricalLiveTerminalStage) {
            Fail-HistoricalLive 'historical_live_terminal_stage_rejected'
        }
        $report = $status.detail | ConvertFrom-Json
        if ($report.action -cne $ExpectedAction) {
            Fail-HistoricalLive 'historical_live_report_action_rejected'
        }
        return $status
    }
    finally {
        # A deadline expiry stops owned processes only. Queue, profile, report,
        # and evidence directories are never deleted here.
        $stopped = Stop-DartApplierOwnedProcesses -Owned $owned
        if (-not $stopped) { Fail-HistoricalLive 'historical_live_stop_unconfirmed' }
        $transcriptEvidence = [ordered]@{ owned_processes_stopped = $true; transcripts = @() }
        foreach ($transcript in @($rawOut, $rawErr)) {
            if (Test-Path -LiteralPath $transcript -PathType Leaf) {
                $transcriptEvidence.transcripts += [ordered]@{
                    name = [IO.Path]::GetFileName($transcript)
                    bytes = (Get-Item -LiteralPath $transcript).Length
                    sha256 = (Get-FileHash -LiteralPath $transcript -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        }
        $transcriptEvidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (
            Join-Path $EvidenceDirectory 'execution.json') -Encoding UTF8
        foreach ($transcript in @($rawOut, $rawErr)) {
            if (Test-Path -LiteralPath $transcript) {
                Remove-Item -LiteralPath $transcript -Force
            }
        }
        foreach ($entry in $owned.Values) { $entry.Process.Dispose() }
    }
}

function Invoke-HistoricalLiveWorkflow {
param([Parameter(Mandatory)][Collections.IDictionary] $Invocation)
foreach ($key in $script:HistoricalLiveInvocation.Keys) {
    Set-Variable -Name $key -Value $Invocation[$key] -Scope Local
}
if (-not $EnableLive) {
    Write-Host 'HISTORICAL-LIVE-INERT: pass -EnableLive with verified local-write artifact SHAs,'
    Write-Host 'HISTORICAL-LIVE-INERT: an isolated dev profile holding windows-historical-import-request.json,'
    Write-Host 'HISTORICAL-LIVE-INERT: and the live consent environment. Nothing was touched.'
    return
}

if ([string]::IsNullOrWhiteSpace($ExpectedNativeSourceSha)) {
    $ExpectedNativeSourceSha = $ExpectedSourceSha
}

if ($PSVersionTable.PSVersion.Major -lt 7 -or
    [Environment]::GetEnvironmentVariable($script:HistoricalLiveConsent, 'Process') -cne '1' -or
    $env:OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA -cne '1') {
    Fail-HistoricalLive 'historical_live_explicit_enable_required'
}


if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = Join-Path $PSScriptRoot '../..'
}

$repository = Assert-DartApplierRepository `
    -Path $Repository -ExpectedSource $ExpectedSourceSha
Assert-DartApplierNativeCompatibility `
    -Path $repository `
    -DartSource $ExpectedSourceSha `
    -NativeSource $ExpectedNativeSourceSha
$profile = Resolve-StandaloneProfile -Candidate $ProfileRoot
$mutex = Enter-StandaloneProfileLock -Profile $profile
$evidenceDirectory = $null
$requestLock = $null
try {
    Assert-StandaloneNoProfileOwner
    # Import/sign once using import_verified_windows_cloud_harness.ps1. This
    # loop only verifies the installed receipt; it never replaces a live DLL or
    # requires the Dart checkout to have the native artifact's older HEAD.
    $runtime = Assert-HistoricalLocalWriteRuntime -Directory $RunnerDirectory `
        -ReceiptPath $ReceiptPath -NativeSource $ExpectedNativeSourceSha `
        -Pilot $ExpectedPilotSha -Archive $ExpectedArchiveSha256 `
        -Provenance $ExpectedProvenanceSha256 -Signer $SigningThumbprint
    $requestPath = Join-Path $profile $script:HistoricalLiveRequestFileName
    Assert-StandalonePlainPath -Path $requestPath -Label 'historical_live_request'
    # Deny replacement or editing from preflight until the owned test process
    # exits. The Dart entry also checks this exact digest before loading native.
    $requestLock = [IO.File]::Open($requestPath, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $request = Assert-HistoricalLiveRequestFile -Profile $profile
    $requestSha = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sessionId = [Convert]::ToHexString(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    ).ToLowerInvariant()
    $evidenceDirectory = Join-Path -Path $profile -ChildPath "cloud-sync-v2\diagnostics\historical-live\$sessionId"
    $null = New-Item -ItemType Directory -Path $evidenceDirectory -Force
    Assert-StandalonePlainPath -Path $evidenceDirectory -Label 'historical_live_evidence'
    $buildIdentifier = $ExpectedSourceSha.Substring(0, 12)
    [ordered]@{
        version = 1
        session_id = $sessionId
        source_commit = $ExpectedSourceSha
        native_source_commit = $ExpectedNativeSourceSha
        pilot_commit = $ExpectedPilotSha
        archive_sha256 = $ExpectedArchiveSha256
        provenance_sha256 = $ExpectedProvenanceSha256
        native_library_sha256 = $runtime.NativeSha256
        objectbox_sha256 = $runtime.ObjectBoxSha256
        runtime_receipt_sha256 = $runtime.ReceiptSha256
        request_sha256 = $requestSha
        request_action = $request.action
        operation = 'historical-import'
        remote_writes_enabled = $request.action -ceq 'archive'
        automatic_uploads_enabled = $false
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'qualification.json') -Encoding UTF8
    $dart = [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\dart-sdk\bin\dart.exe'))
    $tester = [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\artifacts\engine\windows-arm64\flutter_tester.exe'))
    $snapshot = [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\flutter_tools.snapshot'))
    foreach ($tool in @($dart, $tester, $snapshot)) {
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
            Fail-HistoricalLive 'historical_live_toolchain_file_missing'
        }
        Assert-StandalonePlainPath -Path $tool -Label 'historical_live_toolchain'
    }
    $allowed = @(
        $dart,
        [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\dart-sdk\bin\dartvm.exe')),
        [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\dart-sdk\bin\dartaotruntime.exe')),
        $tester
    )
    $launchId = [Convert]::ToHexString(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    ).ToLowerInvariant()
    $status = Invoke-HistoricalLivePass `
        -Repository $repository `
        -Profile $profile `
        -Dart $dart `
        -Tester $tester `
        -FlutterToolsSnapshot $snapshot `
        -NativeLibrary $runtime.NativeLibrary `
        -RuntimeDirectory $runtime.Directory `
        -LaunchId $launchId `
        -BuildIdentifier $buildIdentifier `
        -RequestSha256 $requestSha `
        -ExpectedAction $request.action `
        -EvidenceDirectory $evidenceDirectory `
        -TimeoutSeconds $TimeoutSeconds `
        -AllowedExecutables $allowed
    $status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'historical-pass.json') -Encoding UTF8
    Write-Host "HISTORICAL-LIVE-PASS: stage=$($status.stage) launch=$launchId"
}
finally {
    if ($null -ne $requestLock) { $requestLock.Dispose() }
    if ($null -ne $mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
}

if ($FunctionsOnlyForTest) { return }
Invoke-HistoricalLiveWorkflow -Invocation $script:HistoricalLiveInvocation
