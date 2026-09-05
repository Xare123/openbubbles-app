<#
.SYNOPSIS
    Runs one deterministic, read-only CloudKit V2 Canary semantic-pull probe.

.DESCRIPTION
    Installs an already-built Canary APK in place, preserving the package's
    existing app-data directory, invokes an integrity-pinned Dart VM
    semantic-pull trigger, exports the uniquely emitted report, and validates
    its complete content-free schema plus safety and count fields.

    The probe never clears logcat, uninstalls the package, clears app data,
    prints message content, prints identifiers or tokens, or performs any
    filesystem deletion. The only filesystem write is the caller-selected
    evidence directory and the exported content-free report within it. Local
    Canary projection state is expected to change during a semantic pull; this
    probe does not claim byte-for-byte app-data immutability.

    The Dart package configuration is supplied to the Dart executable with its
    --packages option. The trigger script itself continues to receive exactly
    the VM service URI expected by vm_trigger_semantic.dart.

.PARAMETER ApkPath
    Exact path to the APK to install.

.PARAMETER ExpectedApkSha256
    Expected SHA-256 digest of the APK, case-insensitive.

.PARAMETER ExpectedSourceCommit
    Exact source commit expected in the emitted semantic report.

.PARAMETER AdbSerial
    Required adb device serial.

.PARAMETER AdbExecutable
    Exact adb executable to use. Defaults to adb.exe resolved by PATH.

.PARAMETER PackageName
    Canary package name. The validation set permits only the dedicated Canary.

.PARAMETER Aapt2Executable
    Exact aapt2 executable used to verify the APK application ID before install.

.PARAMETER DartExecutable
    Exact Dart executable to use. Defaults to dart.exe resolved by PATH.

.PARAMETER PackageConfig
    Exact Dart package_config.json used by the VM trigger.

.PARAMETER VmTriggerScript
    Exact path to vm_trigger_semantic.dart.

.PARAMETER ExpectedVmTriggerSha256
    Expected SHA-256 digest of vm_trigger_semantic.dart, case-insensitive.

.PARAMETER EvidenceDirectory
    Directory in which to export the exact newly emitted report.

.PARAMETER ReportTimeoutSeconds
    Maximum report-poll duration. Defaults to 180 seconds.

.PARAMETER ProcessTimeoutSeconds
    Maximum duration for one non-install child process. Defaults to 60 seconds.

.EXAMPLE
    .\cloudkit_canary_device_probe.ps1 `
      -ApkPath 'C:\artifacts\app-canary-debug.apk' `
      -ExpectedApkSha256 'ABC123...' `
      -ExpectedSourceCommit '4b3bfb9d900ee88dd5878ff5635e023267139ac6' `
      -AdbSerial '57170DLCH000W8' `
      -AdbExecutable 'C:\Android\platform-tools\adb.exe' `
      -Aapt2Executable 'C:\Android\build-tools\36.0.0\aapt2.exe' `
      -PackageConfig 'C:\app\.dart_tool\package_config.json' `
      -VmTriggerScript 'C:\app\tooling\vm_trigger_semantic.dart' `
      -ExpectedVmTriggerSha256 'DEF456...' `
      -EvidenceDirectory 'C:\evidence\run-01'

.NOTES
    Requires PowerShell 7, adb, and the supplied Dart executable.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ApkPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedApkSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceCommit,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $AdbSerial,

    [ValidateNotNullOrEmpty()]
    [string] $AdbExecutable = 'adb.exe',

    [ValidateSet('com.bluebubbles.messaging.cloudkitcanary')]
    [string] $PackageName = 'com.bluebubbles.messaging.cloudkitcanary',

    [ValidateNotNullOrEmpty()]
    [string] $Aapt2Executable = 'aapt2.exe',

    [ValidateNotNullOrEmpty()]
    [string] $DartExecutable = 'dart.exe',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $PackageConfig,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $VmTriggerScript,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedVmTriggerSha256,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $EvidenceDirectory,

    [ValidateRange(1, 3600)]
    [int] $ReportTimeoutSeconds = 180,

    [ValidateRange(1, 900)]
    [int] $ProcessTimeoutSeconds = 60
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:ForwardCreated = $false
$script:ForwardLocalPort = $null
$script:AdbPath = $null
$script:Aapt2Path = $null
$script:CanaryPackageName = 'com.bluebubbles.messaging.cloudkitcanary'

function Fail-Probe {
    param([Parameter(Mandatory = $true)][string] $Code)
    throw [System.InvalidOperationException]::new("probe_$Code")
}

function Assert-ExistingFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Code
    )
    if (-not [System.IO.Path]::IsPathRooted($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-Probe $Code
    }
}

function Assert-ExistingDirectory {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Code
    )
    if (-not [System.IO.Path]::IsPathRooted($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail-Probe $Code
    }
}

function Invoke-BoundedProcessText {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][ValidateRange(1, 900)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $FailureCode,
        [Parameter(Mandatory = $true)][string] $TimeoutCode
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$psi.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { Fail-Probe $FailureCode }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            if (-not $process.WaitForExit(5000)) {
                Fail-Probe 'child_process_termination_unconfirmed'
            }
            [void]$stdoutTask.Wait(5000)
            [void]$stderrTask.Wait(5000)
            Fail-Probe $TimeoutCode
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($stdout.Length -gt 4194304 -or $stderr.Length -gt 262144) {
            Fail-Probe 'child_process_output_too_large'
        }
        if ($process.ExitCode -ne 0) { Fail-Probe $FailureCode }
        return @($stdout -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    }
    finally {
        $process.Dispose()
    }
}

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)][string] $Executable,
        [Parameter(Mandatory = $true)][string] $MissingCode,
        [Parameter(Mandatory = $true)][string] $UnavailableCode
    )
    if ([System.IO.Path]::IsPathRooted($Executable)) {
        Assert-ExistingFile -Path $Executable -Code $MissingCode
        return (Resolve-Path -LiteralPath $Executable).Path
    }
    $command = Get-Command -Name $Executable -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) { Fail-Probe $UnavailableCode }
    return $command.Path
}

function Resolve-AdbExecutable {
    return Resolve-Executable -Executable $AdbExecutable `
        -MissingCode 'adb_executable_missing' `
        -UnavailableCode 'adb_executable_unavailable'
}

function Invoke-AdbText {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [ValidateRange(1, 900)][int] $TimeoutSeconds = $ProcessTimeoutSeconds
    )
    return Invoke-BoundedProcessText `
        -FilePath $script:AdbPath `
        -Arguments (@('-s', $AdbSerial) + $Arguments) `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureCode 'adb_command_failed' `
        -TimeoutCode 'adb_command_timeout'
}

function Invoke-DartTrigger {
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][string] $DartPath,
        [Parameter(Mandatory = $true)][string] $ConfigPath,
        [Parameter(Mandatory = $true)][string] $ScriptPath
    )
    $null = Invoke-BoundedProcessText `
        -FilePath $DartPath `
        -Arguments @("--packages=$ConfigPath", $ScriptPath, $Uri) `
        -TimeoutSeconds $ProcessTimeoutSeconds `
        -FailureCode 'vm_trigger_failed' `
        -TimeoutCode 'vm_trigger_timeout'
}

function Get-PackageField {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]] $Dump,
        [Parameter(Mandatory = $true)][string] $Field
    )
    $match = ($Dump -join "`n") | Select-String -Pattern "(?m)^\s*$([regex]::Escape($Field))=(.+?)\s*$"
    if ($null -eq $match -or $match.Matches.Count -ne 1) {
        Fail-Probe "package_$Field_unavailable"
    }
    return $match.Matches[0].Groups[1].Value.Trim()
}

function Get-ApkApplicationId {
    $lines = Invoke-BoundedProcessText `
        -FilePath $script:Aapt2Path `
        -Arguments @('dump', 'badging', $ApkPath) `
        -TimeoutSeconds $ProcessTimeoutSeconds `
        -FailureCode 'apk_manifest_read_failed' `
        -TimeoutCode 'apk_manifest_read_timeout'
    $applicationIds = @()
    foreach ($line in $lines) {
        if ([string]$line -match "^package: name='([^']+)'") {
            $applicationIds += $Matches[1]
        }
    }
    if ($applicationIds.Count -ne 1) { Fail-Probe 'apk_application_id_unavailable' }
    return [string]$applicationIds[0]
}

function Get-ReportNames {
    $lines = Invoke-AdbText @('shell', 'run-as', $PackageName, 'find', '.', '-type', 'f', '-name', 'obcs2-semantic-*.json')
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $name = ([string]$line).Trim()
        if ($name -match '^\./(?:[^/]+/)*obcs2-semantic-[0-9]{1,24}\.json$') {
            $names.Add($name)
        }
    }
    return @($names | Sort-Object -Unique)
}

function Get-PackageProcessIds {
    $lines = Invoke-AdbText @('shell', 'ps', '-A', '-o', 'PID,NAME')
    $pids = [System.Collections.Generic.List[int]]::new()
    foreach ($line in $lines) {
        $match = [regex]::Match([string]$line, '^\s*(?<pid>\d+)\s+(?<name>\S+)\s*$')
        if (-not $match.Success) { continue }
        $name = $match.Groups['name'].Value
        if ($name -ceq $PackageName -or $name.StartsWith("${PackageName}:", [System.StringComparison]::Ordinal)) {
            $pids.Add([int]$match.Groups['pid'].Value)
        }
    }
    return @($pids | Sort-Object -Unique)
}

function Get-ProcessId {
    $pids = @(Get-PackageProcessIds)
    if ($pids.Count -eq 0) { Fail-Probe 'package_pid_unavailable' }
    if ($pids.Count -ne 1) { Fail-Probe 'package_pid_ambiguous' }
    return $pids[0]
}

function Get-VmUri {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [Parameter(Mandatory = $true)][double] $StartEpochSeconds
    )
    $lines = Invoke-AdbText `
        -Arguments @(
            'logcat',
            '-v',
            'epoch',
            "--pid=$ProcessId",
            '-d',
            '--regex=The Dart VM service is listening on http://127\.0\.0\.1:'
        ) `
        -TimeoutSeconds 5
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text -notmatch '^\s*(\d+\.\d+)\s+') { continue }
        if ([double]$Matches[1] -lt $StartEpochSeconds) { continue }
        $uriMatch = [regex]::Match(
            $text,
            'The Dart VM service is listening on (?<uri>http://127\.0\.0\.1:(?<port>\d+)/[^\s]+)'
        )
        if ($uriMatch.Success) {
            return [pscustomobject]@{
                Uri  = $uriMatch.Groups['uri'].Value
                Port = [int]$uriMatch.Groups['port'].Value
            }
        }
    }
    return $null
}

function Export-ReportBytes {
    param(
        [Parameter(Mandatory = $true)][string] $RemotePath,
        [Parameter(Mandatory = $true)][string] $Destination
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:AdbPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @('-s', $AdbSerial, 'exec-out', 'run-as', $PackageName, 'cat', $RemotePath)) {
        [void]$psi.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $memoryStream = [System.IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) { Fail-Probe 'report_export_start_failed' }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memoryStream)
        if (-not $process.WaitForExit($ProcessTimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            if (-not $process.WaitForExit(5000)) {
                Fail-Probe 'child_process_termination_unconfirmed'
            }
            [void]$copyTask.Wait(5000)
            [void]$stderrTask.Wait(5000)
            Fail-Probe 'report_export_timeout'
        }
        $copyTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { Fail-Probe 'report_export_failed' }
        if ($memoryStream.Length -le 0 -or $memoryStream.Length -gt 262144) {
            Fail-Probe 'report_size_invalid'
        }
        $fileStream = [System.IO.FileStream]::new($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $memoryStream.Position = 0
            $memoryStream.CopyTo($fileStream)
            $fileStream.Flush()
        }
        finally {
            $fileStream.Dispose()
        }
    }
    finally {
        $memoryStream.Dispose()
        $process.Dispose()
    }
}

function Assert-RemoteReportSize {
    param([Parameter(Mandatory = $true)][string] $RemotePath)
    $lines = @(Invoke-AdbText @('shell', 'run-as', $PackageName, 'stat', '-c', '%s', $RemotePath))
    if ($lines.Count -ne 1 -or [string]$lines[0] -cnotmatch '^\d{1,7}$') {
        Fail-Probe 'report_size_unavailable'
    }
    $size = [long]$lines[0]
    if ($size -le 0 -or $size -gt 262144) { Fail-Probe 'report_size_invalid' }
}

function Read-SemanticReport {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    catch {
        Fail-Probe 'report_json_invalid'
    }
}

function Assert-ExactPropertyNames {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Code
    )
    if ($null -eq $Value) { Fail-Probe $Code }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if ($actual.Count -ne $wanted.Count -or
        @(Compare-Object -ReferenceObject $wanted -DifferenceObject $actual).Count -ne 0) {
        Fail-Probe $Code
    }
}

function Assert-ReportIntegerRange {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][long] $Minimum,
        [Parameter(Mandatory = $true)][long] $Maximum,
        [Parameter(Mandatory = $true)][string] $Code
    )
    if (($Value -isnot [int]) -and ($Value -isnot [long])) { Fail-Probe $Code }
    $number = [long]$Value
    if ($number -lt $Minimum -or $number -gt $Maximum) { Fail-Probe $Code }
}

function Assert-NullableEnumValue {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)][string[]] $Allowed,
        [Parameter(Mandatory = $true)][string] $Code
    )
    if ($null -eq $Value) { return }
    if ($Value -isnot [string] -or $Allowed -cnotcontains $Value) {
        Fail-Probe $Code
    }
}

function Assert-SemanticReportContract {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][double] $StartedAtEpochSeconds,
        [Parameter(Mandatory = $true)][double] $FinishedAtEpochSeconds
    )
    $topLevelProperties = @(
        'schemaVersion',
        'timestampUtc',
        'platform',
        'architecture',
        'buildCommit',
        'mode',
        'automaticTriggersEnabled',
        'remoteSavesEnabled',
        'remoteDeletesEnabled',
        'tombstoneSemanticDeletesEnabled',
        'tombstoneReadOnlyAcknowledgementsEnabled',
        'retainedUnprojectedEvidencePreserved',
        'pageLimit',
        'changeLimit',
        'outboxCountBefore',
        'outboxCountAfter',
        'zones'
    )
    Assert-ReportIntegerRange -Value $Report.schemaVersion -Minimum 6 -Maximum 7 -Code 'report_schema_version_invalid'
    if ($Report.schemaVersion -eq 7) {
        $topLevelProperties += 'settledOutboxUnchanged'
    }
    Assert-ExactPropertyNames -Value $Report -Expected $topLevelProperties -Code 'report_schema_properties_invalid'
    if ($Report.platform -isnot [string] -or
        $Report.architecture -isnot [string] -or
        $Report.platform -cne 'android' -or
        $Report.architecture -cne 'android_arm64') {
        Fail-Probe 'report_platform_invalid'
    }
    if ($Report.mode -isnot [string] -or
        $Report.mode -cne 'manual-semantic-read-only-cloudkit') {
        Fail-Probe 'report_mode_invalid'
    }
    if ($Report.buildCommit -isnot [string] -or $Report.buildCommit -cne $ExpectedSourceCommit) {
        Fail-Probe 'build_commit_mismatch'
    }
    foreach ($property in @(
        'automaticTriggersEnabled',
        'remoteSavesEnabled',
        'remoteDeletesEnabled',
        'tombstoneSemanticDeletesEnabled',
        'tombstoneReadOnlyAcknowledgementsEnabled',
        'retainedUnprojectedEvidencePreserved'
    )) {
        if ($Report.$property -isnot [bool]) { Fail-Probe 'report_boolean_type_invalid' }
    }
    if ($Report.automaticTriggersEnabled -or
        $Report.remoteSavesEnabled -or
        $Report.remoteDeletesEnabled -or
        $Report.tombstoneSemanticDeletesEnabled) {
        Fail-Probe 'remote_write_tripwire_invalid'
    }
    if (-not $Report.tombstoneReadOnlyAcknowledgementsEnabled -or
        -not $Report.retainedUnprojectedEvidencePreserved) {
        Fail-Probe 'retained_evidence_not_preserved'
    }
    Assert-ReportIntegerRange -Value $Report.pageLimit -Minimum 4 -Maximum 4 -Code 'report_page_limit_invalid'
    Assert-ReportIntegerRange -Value $Report.changeLimit -Minimum 50 -Maximum 50 -Code 'report_change_limit_invalid'
    Assert-SemanticOutboxContract -Report $Report

    $timestamp = [DateTimeOffset]::MinValue
    if ($Report.timestampUtc -is [DateTime]) {
        $dateTime = [DateTime]$Report.timestampUtc
        if ($dateTime.Kind -ne [DateTimeKind]::Utc) { Fail-Probe 'report_timestamp_invalid' }
        $timestamp = [DateTimeOffset]$dateTime
    }
    elseif ($Report.timestampUtc -is [string] -and
        $Report.timestampUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        if (-not [DateTimeOffset]::TryParse(
            $Report.timestampUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            $styles,
            [ref]$timestamp
        )) {
            Fail-Probe 'report_timestamp_invalid'
        }
    }
    else {
        Fail-Probe 'report_timestamp_invalid'
    }
    $timestampEpoch = $timestamp.ToUnixTimeMilliseconds() / 1000.0
    if ($timestampEpoch -lt $StartedAtEpochSeconds -or
        $timestampEpoch -gt ($FinishedAtEpochSeconds + 5.0)) {
        Fail-Probe 'report_timestamp_outside_probe'
    }

    $zoneProperties = @(
        'zone',
        'status',
        'fetched',
        'applied',
        'deferred',
        'quarantined',
        'preflightQuarantined',
        'preflightReasons',
        'quarantinePhases',
        'tombstoneQuarantined',
        'tombstoneReadOnlyAcknowledged',
        'retainedUnprojected',
        'semanticUnsupportedServiceQuarantined',
        'semanticStageQuarantined',
        'retried',
        'elapsedMilliseconds',
        'observedEmptyTerminalRead',
        'projectionExamined',
        'projectionRetained',
        'projectionBatches',
        'semanticDiagnostics',
        'failureCategory',
        'failureSafeCode',
        'skipReason'
    )
    $expectedZones = @('attachments', 'chats', 'messages')
    $zones = @($Report.zones)
    if ($zones.Count -ne 3) { Fail-Probe 'report_zone_count_invalid' }
    $actualZones = [System.Collections.Generic.List[string]]::new()
    foreach ($zone in $zones) {
        Assert-ExactPropertyNames -Value $zone -Expected $zoneProperties -Code 'report_zone_properties_invalid'
        if ($zone.zone -isnot [string] -or $expectedZones -cnotcontains $zone.zone) {
            Fail-Probe 'report_zone_label_invalid'
        }
        $actualZones.Add($zone.zone)
        if ($null -eq $zone.status) { Fail-Probe 'report_zone_status_invalid' }
        Assert-NullableEnumValue -Value $zone.status -Allowed @('completed', 'degraded', 'skipped', 'cancelled', 'failed') -Code 'report_zone_status_invalid'
        Assert-NullableEnumValue -Value $zone.failureCategory -Allowed @('network', 'throttled', 'server', 'authorization', 'pcsUnavailable', 'malformedRecord', 'conflict', 'dependency', 'localStorage', 'cancelled', 'unknown', 'unsupportedService', 'outOfScopeService') -Code 'report_failure_category_invalid'
        Assert-NullableEnumValue -Value $zone.skipReason -Allowed @('localRunActive', 'coordinatorLeaseUnavailable', 'pullBackoffActive', 'featureDisabled') -Code 'report_skip_reason_invalid'
        if ($null -eq $zone.failureSafeCode) {
            if ($null -ne $zone.failureCategory) { Fail-Probe 'report_failure_code_invalid' }
        }
        elseif ($zone.failureSafeCode -isnot [string] -or
            $zone.failureSafeCode -cnotmatch '^[a-z0-9][a-z0-9_-]{0,95}$' -or
            $null -eq $zone.failureCategory) {
            Fail-Probe 'report_failure_code_invalid'
        }
        foreach ($counter in @('fetched', 'applied', 'deferred', 'quarantined', 'preflightQuarantined', 'tombstoneQuarantined', 'tombstoneReadOnlyAcknowledged', 'semanticUnsupportedServiceQuarantined', 'semanticStageQuarantined', 'retried')) {
            Assert-ReportIntegerRange -Value $zone.$counter -Minimum 0 -Maximum 200 -Code 'report_zone_counter_invalid'
        }
        Assert-ReportIntegerRange -Value $zone.retainedUnprojected -Minimum 0 -Maximum 65535 -Code 'report_zone_counter_invalid'
        Assert-ReportIntegerRange -Value $zone.elapsedMilliseconds -Minimum 0 -Maximum 600000 -Code 'report_zone_elapsed_invalid'
        if ($zone.observedEmptyTerminalRead -isnot [bool]) { Fail-Probe 'report_terminal_read_invalid' }
        Assert-ReportIntegerRange -Value $zone.projectionExamined -Minimum 0 -Maximum 0 -Code 'report_projection_counter_invalid'
        Assert-ReportIntegerRange -Value $zone.projectionRetained -Minimum 0 -Maximum 0 -Code 'report_projection_counter_invalid'
        Assert-ReportIntegerRange -Value $zone.projectionBatches -Minimum 0 -Maximum 0 -Code 'report_projection_counter_invalid'

        Assert-ExactPropertyNames -Value $zone.preflightReasons -Expected @('unsupportedRecordType', 'malformedMetadata', 'oversizedRecord', 'invalidChangeShape', 'unknown') -Code 'report_preflight_properties_invalid'
        foreach ($property in $zone.preflightReasons.PSObject.Properties) {
            Assert-ReportIntegerRange -Value $property.Value -Minimum 0 -Maximum 200 -Code 'report_preflight_counter_invalid'
        }
        Assert-ExactPropertyNames -Value $zone.quarantinePhases -Expected @('startup', 'postFetch') -Code 'report_quarantine_properties_invalid'
        foreach ($property in $zone.quarantinePhases.PSObject.Properties) {
            Assert-ReportIntegerRange -Value $property.Value -Minimum 0 -Maximum 200 -Code 'report_quarantine_counter_invalid'
        }
        if ($null -eq $zone.semanticDiagnostics) { Fail-Probe 'report_diagnostics_invalid' }
        foreach ($property in $zone.semanticDiagnostics.PSObject.Properties) {
            if ($property.Name -cnotmatch '^[a-z0-9][a-z0-9_-]{0,95}$') {
                Fail-Probe 'report_diagnostic_code_invalid'
            }
            Assert-ReportIntegerRange -Value $property.Value -Minimum 1 -Maximum 65535 -Code 'report_diagnostic_count_invalid'
        }
    }
    $actualZones = @($actualZones | Sort-Object -Unique)
    if ($actualZones.Count -ne 3 -or
        @(Compare-Object -ReferenceObject $expectedZones -DifferenceObject $actualZones).Count -ne 0) {
        Fail-Probe 'report_zone_set_invalid'
    }
}

function Assert-SemanticOutboxContract {
    param([Parameter(Mandatory = $true)] $Report)
    # Schema 6 has no complete-snapshot proof and must keep its zero-row gate.
    # Schema 7 permits retained, fully settled rows only with the sampler's
    # before/after equality proof. Counts continue to mean all durable rows.
    Assert-ReportIntegerRange -Value $Report.schemaVersion -Minimum 6 -Maximum 7 -Code 'report_schema_version_invalid'
    $maximum = if ($Report.schemaVersion -eq 6) { 0 } else { 65535 }
    Assert-ReportIntegerRange -Value $Report.outboxCountBefore -Minimum 0 -Maximum $maximum -Code 'outbox_snapshot_invalid'
    Assert-ReportIntegerRange -Value $Report.outboxCountAfter -Minimum 0 -Maximum $maximum -Code 'outbox_snapshot_invalid'
    if ($Report.schemaVersion -eq 7 -and $Report.settledOutboxUnchanged -isnot [bool]) {
        Fail-Probe 'outbox_snapshot_invalid'
    }
    if ($Report.outboxCountBefore -ne $Report.outboxCountAfter -or
        ($Report.outboxCountBefore -gt 0 -and -not $Report.settledOutboxUnchanged)) {
        Fail-Probe 'outbox_snapshot_changed'
    }
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) { Fail-Probe 'powershell_7_required' }
    if ($PackageName -cne $script:CanaryPackageName) { Fail-Probe 'package_not_canary' }
    Assert-ExistingFile -Path $ApkPath -Code 'apk_missing'
    Assert-ExistingFile -Path $PackageConfig -Code 'package_config_missing'
    Assert-ExistingFile -Path $VmTriggerScript -Code 'vm_trigger_missing'
    $script:AdbPath = Resolve-AdbExecutable
    $script:Aapt2Path = Resolve-Executable -Executable $Aapt2Executable `
        -MissingCode 'aapt2_executable_missing' `
        -UnavailableCode 'aapt2_executable_unavailable'
    $dartPath = Resolve-Executable -Executable $DartExecutable `
        -MissingCode 'dart_executable_missing' `
        -UnavailableCode 'dart_executable_unavailable'
    if (-not [System.IO.Path]::IsPathRooted($EvidenceDirectory)) { Fail-Probe 'evidence_path_not_absolute' }
    if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($EvidenceDirectory)
    }
    Assert-ExistingDirectory -Path $EvidenceDirectory -Code 'evidence_directory_unavailable'

    $deviceState = ([string](Invoke-AdbText @('get-state'))).Trim()
    if ($deviceState -ne 'device') { Fail-Probe 'device_not_ready' }

    $actualHash = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash
    if ($actualHash -ine $ExpectedApkSha256) { Fail-Probe 'apk_hash_mismatch' }
    $actualTriggerHash = (Get-FileHash -LiteralPath $VmTriggerScript -Algorithm SHA256).Hash
    if ($actualTriggerHash -ine $ExpectedVmTriggerSha256) { Fail-Probe 'vm_trigger_hash_mismatch' }
    $apkApplicationId = Get-ApkApplicationId
    if ($apkApplicationId -cne $script:CanaryPackageName) { Fail-Probe 'apk_application_id_not_canary' }

    $beforeDump = Invoke-AdbText @('shell', 'dumpsys', 'package', $PackageName)
    $beforeInstallTime = Get-PackageField -Dump $beforeDump -Field 'firstInstallTime'
    $beforeUpdateTime = Get-PackageField -Dump $beforeDump -Field 'lastUpdateTime'
    $beforeReports = @(Get-ReportNames)

    $null = Invoke-AdbText -Arguments @('install', '-r', $ApkPath) -TimeoutSeconds 300

    $afterDump = Invoke-AdbText @('shell', 'dumpsys', 'package', $PackageName)
    $afterInstallTime = Get-PackageField -Dump $afterDump -Field 'firstInstallTime'
    $afterUpdateTime = Get-PackageField -Dump $afterDump -Field 'lastUpdateTime'
    $afterReports = @(Get-ReportNames)
    if ($beforeInstallTime -ne $afterInstallTime) { Fail-Probe 'first_install_time_changed' }
    $installReportSetDiff = @(Compare-Object -ReferenceObject $beforeReports -DifferenceObject $afterReports)
    if ($installReportSetDiff.Count -ne 0) {
        Fail-Probe 'report_set_changed_during_install'
    }
    if ($beforeUpdateTime -eq $afterUpdateTime) { Fail-Probe 'package_update_time_unchanged' }

    $null = Invoke-AdbText @('shell', 'am', 'force-stop', $PackageName)
    Start-Sleep -Milliseconds 250
    if (@(Get-PackageProcessIds).Count -ne 0) { Fail-Probe 'package_not_stopped_before_launch' }
    $startEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $null = Invoke-AdbText @('shell', 'monkey', '-p', $PackageName, '-c', 'android.intent.category.LAUNCHER', '1')
    $processId = Get-ProcessId
    $vm = $null
    for ($attempt = 0; $attempt -lt 30 -and $null -eq $vm; $attempt++) {
        Start-Sleep -Milliseconds 500
        $vm = Get-VmUri -ProcessId $processId -StartEpochSeconds $startEpoch
    }
    if ($null -eq $vm) { Fail-Probe 'vm_service_url_not_found' }

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $script:ForwardLocalPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $null = Invoke-AdbText @('forward', '--no-rebind', "tcp:$script:ForwardLocalPort", "tcp:$($vm.Port)")
    $script:ForwardCreated = $true
    $uriBuilder = [System.UriBuilder]::new($vm.Uri)
    $uriBuilder.Scheme = if ($uriBuilder.Scheme -eq 'https') { 'wss' } else { 'ws' }
    $uriBuilder.Host = '127.0.0.1'
    $uriBuilder.Port = $script:ForwardLocalPort
    $uriBuilder.Path = "$($uriBuilder.Path.TrimEnd('/'))/ws"
    Invoke-DartTrigger -Uri $uriBuilder.Uri.AbsoluteUri -DartPath $dartPath -ConfigPath $PackageConfig -ScriptPath $VmTriggerScript

    $newReport = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($ReportTimeoutSeconds)
    while ($null -eq $newReport -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 1
        $currentReports = @(Get-ReportNames)
        $newReports = @($currentReports | Where-Object { $afterReports -notcontains $_ })
        if ($newReports.Count -gt 1) { Fail-Probe 'new_report_ambiguous' }
        if ($newReports.Count -eq 1) { $newReport = $newReports[0] }
    }
    $endEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    if ($null -eq $newReport) { Fail-Probe 'new_report_not_emitted' }
    # VM-service invoke does not return until the awaited semantic pull has
    # atomically written its one report. This second snapshot catches a manual
    # overlapping run without waiting out the full report timeout.
    Start-Sleep -Seconds 2
    $settledReports = @((Get-ReportNames) | Where-Object { $afterReports -notcontains $_ })
    if ($settledReports.Count -ne 1 -or $settledReports[0] -cne $newReport) {
        Fail-Probe 'new_report_set_unstable'
    }

    $safeName = [System.IO.Path]::GetFileName($newReport)
    if ($safeName -cnotmatch '^obcs2-semantic-[0-9]{1,24}\.json$' -or
        $newReport -cnotmatch '^\./(?:[^/]+/)*obcs2-semantic-[0-9]{1,24}\.json$') {
        Fail-Probe 'report_path_invalid'
    }
    $destination = Join-Path -Path $EvidenceDirectory -ChildPath $safeName
    if (Test-Path -LiteralPath $destination) { Fail-Probe 'evidence_destination_exists' }
    Assert-RemoteReportSize -RemotePath $newReport
    Export-ReportBytes -RemotePath $newReport -Destination $destination

    $report = Read-SemanticReport -Path $destination
    Assert-SemanticReportContract -Report $report -StartedAtEpochSeconds $startEpoch -FinishedAtEpochSeconds $endEpoch
    $diagnosticCodeCount = @($report.zones | ForEach-Object { $_.semanticDiagnostics.PSObject.Properties }).Count
    $null = Invoke-AdbText @('forward', '--remove', "tcp:$script:ForwardLocalPort")
    $remainingForwards = @(Invoke-AdbText @('forward', '--list'))
    if (($remainingForwards -join "`n") -match [regex]::Escape("tcp:$script:ForwardLocalPort")) {
        Fail-Probe 'forward_cleanup_unverified'
    }
    $script:ForwardCreated = $false
    Write-Output "PASS report_exported=true build_commit_verified=true safety_verified=true outbox=0->0 report_diagnostic_codes=$diagnosticCodeCount"
}
catch {
    $safeFailure = if ($_.Exception.Message -match '^probe_[a-z0-9_]+$') {
        $_.Exception.Message
    }
    else {
        'probe_unexpected_failure'
    }
    $safeType = $_.Exception.GetType().FullName -replace '[^A-Za-z0-9_.]', '_'
    $safeLine = [int]$_.InvocationInfo.ScriptLineNumber
    Write-Error "FAIL cloudkit_canary_device_probe_violation code=$safeFailure type=$safeType line=$safeLine"
    exit 1
}
finally {
    if ($script:ForwardCreated -and $null -ne $script:ForwardLocalPort) {
        try {
            $null = Invoke-AdbText @('forward', '--remove', "tcp:$script:ForwardLocalPort")
            $remainingForwards = @(Invoke-AdbText @('forward', '--list'))
            if (($remainingForwards -join "`n") -match [regex]::Escape("tcp:$script:ForwardLocalPort")) {
                Fail-Probe 'forward_cleanup_unverified'
            }
        }
        catch {
            [Console]::Error.WriteLine('FAIL cloudkit_canary_device_probe_cleanup code=probe_forward_cleanup_failed')
            exit 2
        }
    }
}
