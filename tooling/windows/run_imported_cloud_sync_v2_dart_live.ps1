[CmdletBinding()]
param(
    [switch] $EnableLive,
    [string] $ExpectedSourceSha = '',
    [string] $ExpectedNativeSourceSha = '',
    [string] $ExpectedPilotSha = '',
    [string] $ExpectedArchiveSha256 = '',
    [string] $ExpectedProvenanceSha256 = '',
    [string] $SigningThumbprint = '8240557965890665F3B49E5FEC83D511CA4F2C9D',
    [string] $Repository = '',
    [string] $FlutterRoot = 'C:\Codex\Toolchains\flutter-3.44.8-arm64',
    [ValidateRange(2, 6)][int] $MaximumPasses = 4,
    [ValidateRange(60, 900)][int] $TimeoutSeconds = 600,
    [switch] $FunctionsOnlyForTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Reuse the exact isolated-profile, signed native-host, ObjectBox pin, mutex,
# and process-stop checks from the standalone native qualification launcher.
$dartApplierInvocation = [ordered]@{
    EnableLive = [bool]$EnableLive
    ExpectedSourceSha = $ExpectedSourceSha
    ExpectedNativeSourceSha = $ExpectedNativeSourceSha
    ExpectedPilotSha = $ExpectedPilotSha
    ExpectedArchiveSha256 = $ExpectedArchiveSha256
    ExpectedProvenanceSha256 = $ExpectedProvenanceSha256
    SigningThumbprint = $SigningThumbprint
    Repository = $Repository
    FlutterRoot = $FlutterRoot
    MaximumPasses = $MaximumPasses
    TimeoutSeconds = $TimeoutSeconds
    FunctionsOnlyForTest = [bool]$FunctionsOnlyForTest
}
. "$PSScriptRoot/run_imported_chat1_native_live.ps1" -FunctionsOnlyForTest
$EnableLive = $dartApplierInvocation.EnableLive
$ExpectedSourceSha = $dartApplierInvocation.ExpectedSourceSha
$ExpectedNativeSourceSha = $dartApplierInvocation.ExpectedNativeSourceSha
$ExpectedPilotSha = $dartApplierInvocation.ExpectedPilotSha
$ExpectedArchiveSha256 = $dartApplierInvocation.ExpectedArchiveSha256
$ExpectedProvenanceSha256 = $dartApplierInvocation.ExpectedProvenanceSha256
$SigningThumbprint = $dartApplierInvocation.SigningThumbprint
$Repository = $dartApplierInvocation.Repository
$FlutterRoot = $dartApplierInvocation.FlutterRoot
$MaximumPasses = $dartApplierInvocation.MaximumPasses
$TimeoutSeconds = $dartApplierInvocation.TimeoutSeconds
$FunctionsOnlyForTest = $dartApplierInvocation.FunctionsOnlyForTest

# Runs the ordinary Dart/ObjectBox semantic applier against the exact imported
# native library without rebuilding Windows or Android. Each pass is a fresh
# Flutter test process. It retains content-free report summaries only and
# deletes raw stdout/stderr on success and failure.

$script:DartApplierConsent = 'OPENBUBBLES_RUN_IMPORTED_DART_APPLIER_LIVE'
$script:DartApplierNativeBoundaryPaths = @(
    'rust',
    'rustpush',
    'rust_builder',
    'lib/src/rust',
    'lib/objectbox.g.dart',
    'lib/objectbox-model.json',
    'flutter_rust_bridge.yaml',
    'pubspec.yaml',
    'pubspec.lock'
)
$script:DartApplierTestName =
    'isolated Windows profile executes one explicit harness operation'
$script:DartApplierReportModes = @(
    'manual-semantic-read-only-cloudkit'
)
$script:DartApplierRequiredRootFields = @(
    'schemaVersion', 'timestampUtc', 'platform', 'architecture',
    'buildCommit', 'mode', 'automaticTriggersEnabled',
    'remoteSavesEnabled', 'remoteDeletesEnabled',
    'tombstoneSemanticDeletesEnabled',
    'tombstoneReadOnlyAcknowledgementsEnabled',
    'retainedUnprojectedEvidencePreserved', 'pageLimit', 'changeLimit',
    'outboxCountBefore', 'outboxCountAfter', 'settledOutboxUnchanged', 'zones'
)
$script:DartApplierRequiredZoneFields = @(
    'zone', 'status', 'fetched', 'applied', 'deferred', 'quarantined',
    'preflightQuarantined', 'preflightReasons', 'quarantinePhases',
    'tombstoneQuarantined', 'tombstoneReadOnlyAcknowledged',
    'retainedUnprojected', 'semanticUnsupportedServiceQuarantined',
    'semanticStageQuarantined', 'retried', 'elapsedMilliseconds',
    'observedEmptyTerminalRead', 'projectionExamined',
    'projectionRetained', 'projectionBatches', 'semanticDiagnostics',
    'failureCategory', 'failureSafeCode', 'skipReason'
)
$script:DartApplierBlockedEnvironment = @(
    $script:StandaloneWriterEnvironment + @(
        'OPENBUBBLES_RUN_CHAT1_STANDALONE_LIVE',
        'OPENBUBBLES_INSPECT_CHAT1_CORRELATION',
        'OPENBUBBLES_INSPECT_CHAT1_SEMANTIC_CORRELATION',
        'OPENBUBBLES_INSPECT_CHAT1_PAGED_CORRELATION',
        'OPENBUBBLES_INSPECT_CHAT1_PSEUDONYMOUS_GRAPH'
    )
)

function Fail-DartApplierLive {
    param([Parameter(Mandatory)][string] $Code)
    throw $Code
}

function Get-DartApplierProperty {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $FailureCode
    )
    if ($Value -isnot [pscustomobject]) { Fail-DartApplierLive $FailureCode }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { Fail-DartApplierLive $FailureCode }
    return $property.Value
}

function Test-DartApplierExactRequiredProperties {
    param($Value, [Parameter(Mandatory)][string[]] $Required)
    if ($Value -isnot [pscustomobject]) { return $false }
    foreach ($name in $Required) {
        if ($null -eq $Value.PSObject.Properties[$name]) { return $false }
    }
    return $true
}

function Test-DartApplierNonNegativeInteger {
    param($Value)
    if ($Value -is [bool] -or $null -eq $Value) { return $false }
    try {
        $number = [decimal]$Value
        return $number -ge 0 -and [decimal]::Truncate($number) -eq $number
    }
    catch { return $false }
}

function Assert-DartApplierNoBlockedEnvironment {
    foreach ($name in $script:DartApplierBlockedEnvironment) {
        if ($null -ne [Environment]::GetEnvironmentVariable($name, 'Process')) {
            Fail-DartApplierLive 'dart_applier_writer_or_probe_environment_rejected'
        }
    }
}

function Assert-DartApplierRepository {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedSource
    )
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    Assert-StandalonePlainPath -Path $resolved -Label 'repository'
    $head = (& git -C $resolved rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne $ExpectedSource) {
        Fail-DartApplierLive 'dart_applier_source_head_rejected'
    }
    $productPaths = @(
        'lib', 'test', 'pubspec.yaml', 'pubspec.lock', 'objectbox-model.json'
    )
    $diffArguments = @(
        'diff', '--name-only', '--ignore-submodules=dirty', '--'
    ) + $productPaths
    $changed = @(& git -C $resolved @diffArguments)
    if ($LASTEXITCODE -ne 0 -or $changed.Count -ne 0) {
        Fail-DartApplierLive 'dart_applier_product_source_dirty'
    }
    $untrackedArguments = @(
        'ls-files', '--others', '--exclude-standard', '--'
    ) + $productPaths
    $untracked = @(& git -C $resolved @untrackedArguments)
    if ($LASTEXITCODE -ne 0 -or $untracked.Count -ne 0) {
        Fail-DartApplierLive 'dart_applier_product_source_untracked'
    }
    return $resolved
}

function Assert-DartApplierNativeCompatibility {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $DartSource,
        [Parameter(Mandatory)][string] $NativeSource
    )
    if ($DartSource -cnotmatch '^[0-9a-f]{40}$' -or
        $NativeSource -cnotmatch '^[0-9a-f]{40}$') {
        Fail-DartApplierLive 'dart_applier_source_identity_rejected'
    }
    if ($DartSource -ceq $NativeSource) { return }

    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    & git -C $resolved merge-base --is-ancestor $NativeSource $DartSource
    if ($LASTEXITCODE -ne 0) {
        Fail-DartApplierLive 'dart_applier_native_source_not_ancestor'
    }
    $changed = @(& git -C $resolved diff --name-only --no-renames `
        $NativeSource $DartSource -- $script:DartApplierNativeBoundaryPaths)
    if ($LASTEXITCODE -ne 0 -or $changed.Count -ne 0) {
        Fail-DartApplierLive 'dart_applier_native_boundary_changed'
    }
}

function Assert-DartApplierReport {
    param(
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)][string] $ExpectedBuildIdentifier,
        [Parameter(Mandatory)][datetime] $NotBeforeUtc
    )
    $rootShapeValid = Test-DartApplierExactRequiredProperties `
        -Value $Report -Required $script:DartApplierRequiredRootFields
    if (-not $rootShapeValid) {
        Fail-DartApplierLive 'dart_applier_report_header_rejected'
    }
    if (-not (Test-DartApplierNonNegativeInteger $Report.schemaVersion) -or
        [int]$Report.schemaVersion -ne 7 -or
        [string]$Report.platform -cne 'windows' -or
        [string]$Report.architecture -notmatch '(?i)arm64' -or
        [string]$Report.buildCommit -cne $ExpectedBuildIdentifier -or
        $script:DartApplierReportModes -cnotcontains [string]$Report.mode -or
        $Report.automaticTriggersEnabled -ne $false -or
        $Report.remoteSavesEnabled -ne $false -or
        $Report.remoteDeletesEnabled -ne $false -or
        $Report.tombstoneSemanticDeletesEnabled -ne $false -or
        $Report.tombstoneReadOnlyAcknowledgementsEnabled -ne $true -or
        $Report.retainedUnprojectedEvidencePreserved -ne $true -or
        -not (Test-DartApplierNonNegativeInteger $Report.pageLimit) -or
        [decimal]$Report.pageLimit -le 0 -or
        -not (Test-DartApplierNonNegativeInteger $Report.changeLimit) -or
        [decimal]$Report.changeLimit -le 0 -or
        -not (Test-DartApplierNonNegativeInteger $Report.outboxCountBefore) -or
        -not (Test-DartApplierNonNegativeInteger $Report.outboxCountAfter)) {
        Fail-DartApplierLive 'dart_applier_report_header_rejected'
    }
    try {
        $timestamp = [DateTimeOffset]::Parse(
            [string]$Report.timestampUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor
                [Globalization.DateTimeStyles]::AdjustToUniversal
        ).UtcDateTime
    }
    catch { Fail-DartApplierLive 'dart_applier_report_timestamp_rejected' }
    if ($timestamp -lt $NotBeforeUtc.AddSeconds(-2)) {
        Fail-DartApplierLive 'dart_applier_report_timestamp_rejected'
    }
    $outboxBefore = [long]$Report.outboxCountBefore
    $outboxAfter = [long]$Report.outboxCountAfter
    if ($outboxBefore -ne $outboxAfter -or
        ($outboxBefore -gt 0 -and $Report.settledOutboxUnchanged -ne $true)) {
        Fail-DartApplierLive 'dart_applier_outbox_tripwire_rejected'
    }

    $zones = @($Report.zones)
    $expectedZones = @('attachments', 'chats', 'messages')
    $labels = @($zones | ForEach-Object { [string]$_.zone } |
        Sort-Object -Unique -CaseSensitive)
    if ($zones.Count -ne 3 -or $labels.Count -ne 3 -or
        @($expectedZones | Where-Object { $labels -cnotcontains $_ }).Count -ne 0) {
        Fail-DartApplierLive 'dart_applier_zone_shape_rejected'
    }

    $fetched = [long]0
    $applied = [long]0
    $retained = [ordered]@{}
    $allEmptyTerminal = $true
    foreach ($zone in $zones) {
        $zoneShapeValid = Test-DartApplierExactRequiredProperties `
            -Value $zone -Required $script:DartApplierRequiredZoneFields
        if (-not $zoneShapeValid) {
            Fail-DartApplierLive 'dart_applier_zone_shape_rejected'
        }
        foreach ($name in @(
            'fetched', 'applied', 'deferred', 'quarantined',
            'preflightQuarantined', 'tombstoneQuarantined',
            'tombstoneReadOnlyAcknowledged', 'retainedUnprojected',
            'semanticUnsupportedServiceQuarantined',
            'semanticStageQuarantined', 'retried', 'elapsedMilliseconds',
            'projectionExamined', 'projectionRetained', 'projectionBatches'
        )) {
            if (-not (Test-DartApplierNonNegativeInteger $zone.$name)) {
                Fail-DartApplierLive 'dart_applier_zone_counter_rejected'
            }
        }
        $acceptedStatus =
            ([string]$zone.status -ceq 'completed' -and
                $null -eq $zone.failureCategory -and
                $null -eq $zone.failureSafeCode) -or
            ([string]$zone.status -ceq 'degraded' -and
                [string]$zone.failureCategory -ceq 'dependency' -and
                [string]$zone.failureSafeCode -ceq
                    'retained_projection_incomplete')
        if (-not $acceptedStatus -or $null -ne $zone.skipReason) {
            Fail-DartApplierLive 'dart_applier_zone_status_rejected'
        }
        foreach ($name in @(
            'deferred', 'quarantined', 'preflightQuarantined',
            'tombstoneQuarantined', 'semanticUnsupportedServiceQuarantined',
            'semanticStageQuarantined', 'retried'
        )) {
            if ([long]$zone.$name -ne 0) {
                Fail-DartApplierLive 'dart_applier_zone_tripwire_rejected'
            }
        }
        foreach ($name in @(
            'unsupportedRecordType', 'malformedMetadata', 'oversizedRecord',
            'invalidChangeShape', 'unknown'
        )) {
            $preflightValue = Get-DartApplierProperty `
                -Value $zone.preflightReasons -Name $name `
                -FailureCode 'dart_applier_preflight_shape_rejected'
            if ([long]$preflightValue -ne 0) {
                Fail-DartApplierLive 'dart_applier_zone_tripwire_rejected'
            }
        }
        foreach ($name in @('startup', 'postFetch')) {
            $phaseValue = Get-DartApplierProperty `
                -Value $zone.quarantinePhases -Name $name `
                -FailureCode 'dart_applier_quarantine_shape_rejected'
            if ([long]$phaseValue -ne 0) {
                Fail-DartApplierLive 'dart_applier_zone_tripwire_rejected'
            }
        }
        $summaryReady = Get-DartApplierProperty `
            -Value $zone.semanticDiagnostics `
            -Name 'retained_backlog_summary_ready' `
            -FailureCode 'dart_applier_diagnostics_rejected'
        if ([long]$summaryReady -ne 1) {
            Fail-DartApplierLive 'dart_applier_diagnostics_rejected'
        }
        foreach ($bad in @(
            'cloud_sync_unknown_failure', 'diagnostic_code_invalid',
            'retained_backlog_summary_unavailable',
            'retained_backlog_summary_mismatch'
        )) {
            if ($null -ne $zone.semanticDiagnostics.PSObject.Properties[$bad]) {
                Fail-DartApplierLive 'dart_applier_diagnostics_rejected'
            }
        }
        $fetched += [long]$zone.fetched
        $applied += [long]$zone.applied
        $retained[[string]$zone.zone] = [long]$zone.retainedUnprojected
        if ($zone.observedEmptyTerminalRead -ne $true) {
            $allEmptyTerminal = $false
        }
    }
    return [pscustomobject][ordered]@{
        fetched = $fetched
        applied = $applied
        retained = [pscustomobject]$retained
        retained_total = [long](($retained.Values | Measure-Object -Sum).Sum)
        all_zones_empty_terminal = $allEmptyTerminal
        outbox_before = $outboxBefore
        outbox_after = $outboxAfter
    }
}

function New-DartApplierStartInfo {
    param(
        [Parameter(Mandatory)][string] $Dart,
        [Parameter(Mandatory)][string] $FlutterToolsSnapshot,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $NativeLibrary,
        [Parameter(Mandatory)][string] $RuntimeDirectory,
        [Parameter(Mandatory)][string] $LaunchId,
        [Parameter(Mandatory)][string] $BuildIdentifier
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
    $start.Environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] = 'run-once'
    $start.Environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'] = $LaunchId
    $start.Environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'] = $NativeLibrary
    $start.Environment['PATH'] = "$RuntimeDirectory;$($start.Environment['PATH'])"
    foreach ($argument in @(
        $FlutterToolsSnapshot, 'test', '--no-pub', '--concurrency=1',
        '--reporter=expanded',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE=true',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true',
        "--dart-define=OPENBUBBLES_BUILD_COMMIT=$BuildIdentifier",
        'test/live/cloud_sync_v2_windows_live_harness_test.dart'
    )) { $start.ArgumentList.Add($argument) }
    return $start
}

function Add-DartApplierOwnedChildren {
    param(
        [Parameter(Mandatory)][hashtable] $Owned,
        [Parameter(Mandatory)][string[]] $AllowedExecutables
    )
    do {
        $added = $false
        foreach ($parent in @($Owned.Values)) {
            $parent.Process.Refresh()
            if ($parent.Process.HasExited) { continue }
            $childFilter = "ParentProcessId = $($parent.Process.Id)"
            foreach ($child in @(Get-CimInstance Win32_Process -Filter $childFilter)) {
                if ($Owned.ContainsKey([int]$child.ProcessId) -or
                    [string]::IsNullOrWhiteSpace($child.ExecutablePath)) {
                    continue
                }
                $childPath = [IO.Path]::GetFullPath($child.ExecutablePath)
                if ($AllowedExecutables -inotcontains $childPath) { continue }
                $process = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
                if ($null -eq $process) { continue }
                $null = $process.Handle
                $started = $process.StartTime.ToUniversalTime()
                if ($started -lt $parent.Started) {
                    $process.Dispose()
                    continue
                }
                $Owned[[int]$process.Id] = @{
                    Process = $process
                    Path = $childPath
                    Started = $started
                }
                $added = $true
            }
        }
    } while ($added)
}

function Stop-DartApplierOwnedProcesses {
    param([Parameter(Mandatory)][hashtable] $Owned)
    $confirmed = $true
    foreach ($entry in @($Owned.Values | Sort-Object Started -Descending)) {
        $stopped = Stop-StandaloneOwnedProcess `
            -Process $entry.Process -ExpectedExecutable $entry.Path
        if (-not $stopped) {
            $confirmed = $false
        }
    }
    foreach ($entry in $Owned.Values) {
        try {
            $entry.Process.Refresh()
            if (-not $entry.Process.HasExited) { $confirmed = $false }
        }
        catch { $confirmed = $false }
    }
    return $confirmed
}

function Get-DartApplierReportNameFromStatus {
    param([Parameter(Mandatory)] $Status)
    if ([string]$Status.detail -notmatch
        '(?:^|\s)report=(obcs2-semantic-[0-9]+\.json)(?:\s|$)') {
        Fail-DartApplierLive 'dart_applier_status_report_binding_rejected'
    }
    return $Matches[1]
}

function Invoke-DartApplierPass {
    param(
        [Parameter(Mandatory)][int] $Pass,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Profile,
        [Parameter(Mandatory)] $HostInfo,
        [Parameter(Mandatory)][string] $Dart,
        [Parameter(Mandatory)][string] $Tester,
        [Parameter(Mandatory)][string] $FlutterToolsSnapshot,
        [Parameter(Mandatory)][string[]] $AllowedExecutables,
        [Parameter(Mandatory)][string] $BuildIdentifier,
        [Parameter(Mandatory)][string] $EvidenceDirectory,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )
    $launchId = [Convert]::ToHexString(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    ).ToLowerInvariant()
    $rawOut = Join-Path $EvidenceDirectory ("pass-$Pass-stdout.tmp")
    $rawErr = Join-Path $EvidenceDirectory ("pass-$Pass-stderr.tmp")
    $statusPath = Join-Path $Profile 'cloud-sync-v2\windows-harness-status.json'
    $launchStartedUtc = [datetime]::UtcNow
    $startArguments = @{
        Dart = $Dart
        FlutterToolsSnapshot = $FlutterToolsSnapshot
        Repository = $Repository
        NativeLibrary = Join-Path $HostInfo.Directory 'rust_lib_bluebubbles.dll'
        RuntimeDirectory = $HostInfo.Directory
        LaunchId = $launchId
        BuildIdentifier = $BuildIdentifier
    }
    $start = New-DartApplierStartInfo @startArguments
    $process = $null
    $owned = @{}
    $cleanupConfirmed = $false
    $stdoutHash = $null
    $stderrHash = $null
    $stdoutBytes = [long]0
    $stderrBytes = [long]0
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
                    Fail-DartApplierLive 'dart_applier_output_overflow'
                }
                Start-Sleep -Milliseconds 100
                $process.Refresh()
            }
            if (-not $process.HasExited) {
                Fail-DartApplierLive 'dart_applier_process_deadline'
            }
            if (-not $outCopy.Wait(10000) -or -not $errCopy.Wait(10000)) {
                Fail-DartApplierLive 'dart_applier_output_drain_timeout'
            }
        }
        finally {
            $outStream.Dispose()
            $errStream.Dispose()
        }
        Add-DartApplierOwnedChildren `
            -Owned $owned -AllowedExecutables $AllowedExecutables
        $stdoutBytes = (Get-Item -LiteralPath $rawOut).Length
        $stderrBytes = (Get-Item -LiteralPath $rawErr).Length
        $stdoutHash = (Get-FileHash -LiteralPath $rawOut -Algorithm SHA256).Hash.ToLowerInvariant()
        $stderrHash = (Get-FileHash -LiteralPath $rawErr -Algorithm SHA256).Hash.ToLowerInvariant()
        $stdout = Get-Content -LiteralPath $rawOut -Raw
        if ($process.ExitCode -ne 0 -or
            -not $stdout.Contains($script:DartApplierTestName,
                [StringComparison]::Ordinal) -or
            -not $stdout.Contains('All tests passed!',
                [StringComparison]::Ordinal)) {
            $safeCode = 'dart_applier_flutter_test_failed'
            try {
                $failedStatus = Get-Content -LiteralPath $statusPath -Raw |
                    ConvertFrom-Json
                if ($failedStatus.launch_id -ceq $launchId -and
                    $failedStatus.PSObject.Properties['safe_code']) {
                    $safeCode = [string]$failedStatus.safe_code
                }
            }
            catch {}
            Fail-DartApplierLive $safeCode
        }
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        $testerIds = @($owned.Values | Where-Object {
            $_.Path.Equals($Tester, [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { [int]$_.Process.Id })
        if ($status.version -cne 'cloud-sync-v2-windows-harness-status-v2' -or
            $status.launch_id -cne $launchId -or
            $status.build_identifier -cne $BuildIdentifier -or
            $status.state -cne 'finished' -or
            $status.stage -cne 'semantic-pull' -or
            $testerIds -notcontains [int]$status.process_id) {
            Fail-DartApplierLive 'dart_applier_status_binding_rejected'
        }
        $reportName = Get-DartApplierReportNameFromStatus -Status $status
        $reportPath = Join-Path (Join-Path $Profile 'cloud-sync-v2\reports') $reportName
        Assert-StandalonePlainPath -Path $reportPath -Label 'dart_applier_report'
        if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
            Fail-DartApplierLive 'dart_applier_report_missing'
        }
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $summary = Assert-DartApplierReport `
            -Report $report `
            -ExpectedBuildIdentifier $BuildIdentifier `
            -NotBeforeUtc $launchStartedUtc
        $chatOrder = [long]0
        if ([string]$status.detail -match
            '(?:^|\s)chat_order_cache_repaired=([0-9]+)(?:\s|$)') {
            $chatOrder = [long]$Matches[1]
        }
        else {
            Fail-DartApplierLive 'dart_applier_status_detail_rejected'
        }
        return [pscustomobject][ordered]@{
            pass = $Pass
            launch_id = $launchId
            report = $reportName
            report_sha256 = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
            fetched = $summary.fetched
            applied = $summary.applied
            retained = $summary.retained
            retained_total = $summary.retained_total
            all_zones_empty_terminal = $summary.all_zones_empty_terminal
            outbox_before = $summary.outbox_before
            outbox_after = $summary.outbox_after
            chat_order_cache_repaired = $chatOrder
            stdout_bytes = $stdoutBytes
            stdout_sha256 = $stdoutHash
            stderr_bytes = $stderrBytes
            stderr_sha256 = $stderrHash
            process_count = $owned.Count
        }
    }
    finally {
        $cleanupConfirmed = Stop-DartApplierOwnedProcesses -Owned $owned
        foreach ($path in @($rawOut, $rawErr)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        foreach ($entry in $owned.Values) { $entry.Process.Dispose() }
        if (-not $cleanupConfirmed -and $null -ne $process) {
            Fail-DartApplierLive 'dart_applier_process_cleanup_unconfirmed'
        }
    }
}

function Test-DartApplierStablePair {
    param(
        [Parameter(Mandatory)] $Previous,
        [Parameter(Mandatory)] $Current
    )
    if ($Previous.fetched -ne 0 -or $Previous.applied -ne 0 -or
        $Current.fetched -ne 0 -or $Current.applied -ne 0 -or
        $Previous.all_zones_empty_terminal -ne $true -or
        $Current.all_zones_empty_terminal -ne $true -or
        $Current.chat_order_cache_repaired -ne 0 -or
        $Previous.outbox_after -ne $Current.outbox_before) {
        return $false
    }
    foreach ($zone in @('attachments', 'chats', 'messages')) {
        if ([long]$Previous.retained.$zone -ne [long]$Current.retained.$zone) {
            return $false
        }
    }
    return $true
}

if ($FunctionsOnlyForTest) { return }

if ([string]::IsNullOrWhiteSpace($ExpectedNativeSourceSha)) {
    $ExpectedNativeSourceSha = $ExpectedSourceSha
}

if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $EnableLive -or
    [Environment]::GetEnvironmentVariable($script:DartApplierConsent,
        'Process') -cne '1' -or
    $env:OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA -cne '1') {
    Fail-DartApplierLive 'dart_applier_explicit_live_enable_required'
}
Assert-DartApplierNoBlockedEnvironment
if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = Join-Path $PSScriptRoot '../..'
}
$repository = Assert-DartApplierRepository `
    -Path $Repository -ExpectedSource $ExpectedSourceSha
Assert-DartApplierNativeCompatibility `
    -Path $repository `
    -DartSource $ExpectedSourceSha `
    -NativeSource $ExpectedNativeSourceSha
$profile = Resolve-StandaloneProfile
$hostInfo = Assert-StandaloneTestHost `
    -Profile $profile `
    -ExpectedSource $ExpectedNativeSourceSha `
    -ExpectedPilot $ExpectedPilotSha `
    -ExpectedArchive $ExpectedArchiveSha256 `
    -ExpectedProvenance $ExpectedProvenanceSha256 `
    -ExpectedSigner $SigningThumbprint
$dart = [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\dart-sdk\bin\dart.exe'))
$tester = [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\artifacts\engine\windows-arm64\flutter_tester.exe'))
$snapshot = [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\flutter_tools.snapshot'))
$harnessTest = Join-Path -Path $repository -ChildPath 'test\live\cloud_sync_v2_windows_live_harness_test.dart'
foreach ($path in @($dart, $tester, $snapshot, $harnessTest)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail-DartApplierLive 'dart_applier_toolchain_file_missing'
    }
    Assert-StandalonePlainPath -Path $path -Label 'dart_applier_toolchain'
}
Assert-StandaloneNoProfileOwner
$mutex = Enter-StandaloneProfileLock -Profile $profile
$evidenceDirectory = $null
try {
    Assert-StandaloneNoProfileOwner
    $sessionId = [Convert]::ToHexString(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    ).ToLowerInvariant()
    $evidenceDirectory = Join-Path -Path $profile -ChildPath "cloud-sync-v2\diagnostics\dart-applier-live\$sessionId"
    $null = New-Item -ItemType Directory -Path $evidenceDirectory -Force
    Assert-StandalonePlainPath -Path $evidenceDirectory -Label 'dart_applier_evidence'
    $buildIdentifier = $ExpectedSourceSha.Substring(0, 12)
    [ordered]@{
        version = 1
        session_id = $sessionId
        source_commit = $ExpectedSourceSha
        native_source_commit = $ExpectedNativeSourceSha
        pilot_commit = $ExpectedPilotSha
        archive_sha256 = $ExpectedArchiveSha256
        provenance_sha256 = $ExpectedProvenanceSha256
        native_library_sha256 = $hostInfo.Hashes['rust_lib_bluebubbles.dll']
        objectbox_sha256 = $hostInfo.Hashes['objectbox.dll']
        harness_test_sha256 = (Get-FileHash -LiteralPath $harnessTest -Algorithm SHA256).Hash.ToLowerInvariant()
        launcher_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        operation = 'ordinary-dart-objectbox-run-once'
        remote_writes_enabled = $false
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'qualification.json') -Encoding UTF8

    $allowed = @(
        $dart,
        [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\dart-sdk\bin\dartvm.exe')),
        [IO.Path]::GetFullPath((Join-Path -Path $FlutterRoot -ChildPath 'bin\cache\dart-sdk\bin\dartaotruntime.exe')),
        $tester
    )
    $passes = [Collections.Generic.List[object]]::new()
    $stable = $false
    for ($pass = 1; $pass -le $MaximumPasses; $pass++) {
        $passArguments = @{
            Pass = $pass
            Repository = $repository
            Profile = $profile
            HostInfo = $hostInfo
            Dart = $dart
            Tester = $tester
            FlutterToolsSnapshot = $snapshot
            AllowedExecutables = $allowed
            BuildIdentifier = $buildIdentifier
            EvidenceDirectory = $evidenceDirectory
            TimeoutSeconds = $TimeoutSeconds
        }
        $result = Invoke-DartApplierPass @passArguments
        $passes.Add($result)
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $evidenceDirectory "pass-$pass.json") -Encoding UTF8
        if ($passes.Count -ge 2 -and
            (Test-DartApplierStablePair `
                -Previous $passes[$passes.Count - 2] `
                -Current $passes[$passes.Count - 1])) {
            $stable = $true
            break
        }
    }
    [ordered]@{
        version = 1
        session_id = $sessionId
        completed = $stable
        passes = $passes.Count
        stable_repeat = $stable
        content_exposed = $false
        remote_writes_enabled = $false
        results = @($passes)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'result.json') -Encoding UTF8
    if (-not $stable) {
        Fail-DartApplierLive 'dart_applier_stable_repeat_unproven'
    }
    Write-Output ([ordered]@{
        completed = $true
        session_id = $sessionId
        passes = $passes.Count
        stable_repeat = $true
        retained_total = $passes[$passes.Count - 1].retained_total
        outbox_count = $passes[$passes.Count - 1].outbox_after
        content_exposed = $false
        remote_writes_enabled = $false
    } | ConvertTo-Json -Compress)
}
finally {
    try {
        if ($null -ne $evidenceDirectory) {
            [ordered]@{
                process_cleanup_confirmed = $true
                raw_output_retained = $false
                completed_utc = [datetime]::UtcNow.ToString('o')
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'cleanup.json') -Encoding UTF8
        }
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
