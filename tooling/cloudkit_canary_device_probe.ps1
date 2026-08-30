<#
.SYNOPSIS
    Runs one deterministic, read-only CloudKit V2 Canary semantic-pull probe.

.DESCRIPTION
    Installs an already-built Canary APK in place, preserving the existing app
    data, invokes the existing Dart VM semantic-pull trigger, exports the newly
    emitted report, and validates only its safety and count fields.

    The probe never clears logcat, uninstalls the package, clears app data,
    prints message content, prints identifiers or tokens, or performs any
    filesystem deletion. The only filesystem write is the caller-selected
    evidence directory, the exported report, and a fixed-label diagnostic
    summary within it.

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
    Canary package name. Defaults to com.bluebubbles.messaging.cloudkitcanary.

.PARAMETER DartExecutable
    Exact Dart executable to use. Defaults to dart.exe resolved by PATH.

.PARAMETER PackageConfig
    Exact Dart package_config.json used by the VM trigger.

.PARAMETER VmTriggerScript
    Exact path to vm_trigger_semantic.dart.

.PARAMETER EvidenceDirectory
    Directory in which to export the exact newly emitted report.

.PARAMETER ReportTimeoutSeconds
    Maximum report-poll duration. Defaults to 180 seconds.

.EXAMPLE
    .\cloudkit_canary_device_probe.ps1 `
      -ApkPath 'C:\artifacts\app-canary-debug.apk' `
      -ExpectedApkSha256 'ABC123...' `
      -ExpectedSourceCommit '4b3bfb9d900ee88dd5878ff5635e023267139ac6' `
      -AdbSerial '57170DLCH000W8' `
      -AdbExecutable 'C:\Android\platform-tools\adb.exe' `
      -PackageConfig 'C:\app\.dart_tool\package_config.json' `
      -VmTriggerScript 'C:\tooling\vm_trigger_semantic.dart' `
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
    [ValidateNotNullOrEmpty()]
    [string] $ExpectedSourceCommit,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $AdbSerial,

    [ValidateNotNullOrEmpty()]
    [string] $AdbExecutable = 'adb.exe',

    [ValidateNotNullOrEmpty()]
    [string] $PackageName = 'com.bluebubbles.messaging.cloudkitcanary',

    [ValidateNotNullOrEmpty()]
    [string] $DartExecutable = 'dart.exe',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $PackageConfig,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $VmTriggerScript,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $EvidenceDirectory,

    [ValidateRange(1, 3600)]
    [int] $ReportTimeoutSeconds = 180
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:ForwardCreated = $false
$script:ForwardLocalPort = $null
$script:AdbPath = $null

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

function Invoke-AdbText {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $result = @(& $script:AdbPath -s $AdbSerial @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Fail-Probe 'adb_command_failed'
    }
    return $result
}

function Invoke-DartTrigger {
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][string] $DartPath,
        [Parameter(Mandatory = $true)][string] $ConfigPath,
        [Parameter(Mandatory = $true)][string] $ScriptPath
    )
    $null = & $DartPath "--packages=$ConfigPath" $ScriptPath $Uri 2>$null
    if ($LASTEXITCODE -ne 0) {
        Fail-Probe 'vm_trigger_failed'
    }
}

function Assert-DartExecutable {
    if ([System.IO.Path]::IsPathRooted($DartExecutable)) {
        Assert-ExistingFile -Path $DartExecutable -Code 'dart_executable_missing'
        return
    }
    $command = Get-Command -Name $DartExecutable -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) { Fail-Probe 'dart_executable_unavailable' }
}

function Resolve-AdbExecutable {
    if ([System.IO.Path]::IsPathRooted($AdbExecutable)) {
        Assert-ExistingFile -Path $AdbExecutable -Code 'adb_executable_missing'
        return (Resolve-Path -LiteralPath $AdbExecutable).Path
    }
    $command = Get-Command -Name $AdbExecutable -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) { Fail-Probe 'adb_executable_unavailable' }
    return $command.Path
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

function Get-ReportNames {
    $lines = Invoke-AdbText @('shell', 'run-as', $PackageName, 'find', '.', '-type', 'f', '-name', 'obcs2-semantic-*.json')
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $name = ([string]$line).Trim()
        if ($name -match '^\./(?:[^/]+/)*obcs2-semantic-[^/]+\.json$' -and
            $name -notmatch '-service-summary\.json$') {
            $names.Add($name)
        }
    }
    return @($names | Sort-Object -Unique)
}

function Get-ProcessId {
    $pidLines = Invoke-AdbText @('shell', 'pidof', $PackageName)
    $pids = @(([string]($pidLines -join ' ')) -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    if ($pids.Count -lt 1) {
        Fail-Probe 'package_pid_unavailable'
    }
    return ($pids | Sort-Object -Descending | Select-Object -First 1)
}

function Get-VmUri {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [Parameter(Mandatory = $true)][long] $StartEpochSeconds
    )
    $lines = Invoke-AdbText @('logcat', '-v', 'epoch', "--pid=$ProcessId", '-d')
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text -notmatch '^\s*(\d+\.\d+)\s+') { continue }
        if ([double]$Matches[1] -lt $StartEpochSeconds) { continue }
        $uriMatch = [regex]::Match($text, '(?i)(https?://127\.0\.0\.1:(?<port>\d+)(?:/[^\s]*)?)')
        if ($uriMatch.Success) {
            return [pscustomobject]@{
                Uri  = $uriMatch.Groups[1].Value
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
    if (-not $process.Start()) { Fail-Probe 'report_export_start_failed' }
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $memoryStream = [System.IO.MemoryStream]::new()
    try {
        $process.StandardOutput.BaseStream.CopyTo($memoryStream)
        $process.WaitForExit()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { Fail-Probe 'report_export_failed' }
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

function Read-SemanticReport {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    catch {
        Fail-Probe 'report_json_invalid'
    }
}

function Get-RequiredReportValue {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $Name
    )
    $property = $Report.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        Fail-Probe "report_$Name_missing"
    }
    return $property.Value
}

function Get-DiagnosticCounts {
    param(
        [Parameter(Mandatory = $true)][long] $StartEpochSeconds,
        [Parameter(Mandatory = $true)][long] $EndEpochSeconds
    )
    $allowed = [ordered]@{
        too_many_fields = 0
        malformed_field_identifier = 0
        duplicate_field_identifier = 0
        field_not_present = 0
        nested_payload_too_large = 0
        malformed_nested_plist = 0
        nested_plist_not_dictionary = 0
        explicit_clear_without_presence = 0
        missing_required_field = 0
        unsupported_service = 0
        unsupported_chat_style = 0
        empty_required_identity = 0
        group_photo_missing_stable_guid = 0
        direct_chat_group_photo_asset = 0
        group_photo_present_without_value = 0
        group_photo_presence_mismatch = 0
        display_name_field = 0
        last_addressed_handle_field = 0
        group_version_field = 0
        last_seen_message_field = 0
        group_photo_guid_field = 0
        direct_chat_group_photo_guid = 0
        empty_legacy_group_identifier = 0
        logical_identity_hash = 0
        alias_hash = 0
        canonical_payload = 0
        canonical_build = 0
    }
    $lines = Invoke-AdbText @('shell', 'run-as', $PackageName, 'find', '.', '-type', 'f', '-name', 'rs_rCURRENT.log')
    foreach ($line in $lines) {
        $path = ([string]$line).Trim()
        if ($path -notmatch '^\./(?:[^/]+/)*rs_rCURRENT\.log$') { continue }
        $logLines = Invoke-AdbText @('shell', 'run-as', $PackageName, 'cat', $path)
        foreach ($logLine in $logLines) {
            $text = [string]$logLine
            if ($text -notmatch '^\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)') { continue }
            $timestamp = ([DateTimeOffset]::Parse($Matches[1])).ToUnixTimeSeconds()
            if ($timestamp -lt $StartEpochSeconds -or $timestamp -gt $EndEpochSeconds) { continue }
            $codeMatch = [regex]::Match($text, 'CloudKit V2 transient chat diagnostic.*?code=([a-z0-9_]+)')
            if ($codeMatch.Success -and $allowed.Contains($codeMatch.Groups[1].Value)) {
                $allowed[$codeMatch.Groups[1].Value]++
            }
        }
    }
    return [pscustomobject]$allowed
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) { Fail-Probe 'powershell_7_required' }
    Assert-ExistingFile -Path $ApkPath -Code 'apk_missing'
    Assert-ExistingFile -Path $PackageConfig -Code 'package_config_missing'
    Assert-ExistingFile -Path $VmTriggerScript -Code 'vm_trigger_missing'
    Assert-DartExecutable
    $script:AdbPath = Resolve-AdbExecutable
    if (-not [System.IO.Path]::IsPathRooted($EvidenceDirectory)) { Fail-Probe 'evidence_path_not_absolute' }
    if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($EvidenceDirectory)
    }
    Assert-ExistingDirectory -Path $EvidenceDirectory -Code 'evidence_directory_unavailable'

    $deviceState = ([string](Invoke-AdbText @('get-state'))).Trim()
    if ($deviceState -ne 'device') { Fail-Probe 'device_not_ready' }

    $beforeDump = Invoke-AdbText @('shell', 'dumpsys', 'package', $PackageName)
    $beforeInstallTime = Get-PackageField -Dump $beforeDump -Field 'firstInstallTime'
    $beforeUpdateTime = Get-PackageField -Dump $beforeDump -Field 'lastUpdateTime'
    $beforeReports = @(Get-ReportNames)

    $actualHash = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash
    if ($actualHash -ine $ExpectedApkSha256) { Fail-Probe 'apk_hash_mismatch' }

    $null = Invoke-AdbText @('install', '-r', $ApkPath)

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

    $null = Invoke-AdbText @('shell', 'monkey', '-p', $PackageName, '-c', 'android.intent.category.LAUNCHER', '1')
    $startEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $processId = Get-ProcessId
    $vm = $null
    for ($attempt = 0; $attempt -lt 30 -and $null -eq $vm; $attempt++) {
        Start-Sleep -Milliseconds 500
        $vm = Get-VmUri -ProcessId $processId -StartEpochSeconds ($startEpoch - 2)
    }
    if ($null -eq $vm) { Fail-Probe 'vm_service_url_not_found' }

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $script:ForwardLocalPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $null = Invoke-AdbText @('forward', "tcp:$script:ForwardLocalPort", "tcp:$($vm.Port)")
    $script:ForwardCreated = $true
    $uriBuilder = [System.UriBuilder]::new($vm.Uri)
    $uriBuilder.Scheme = if ($uriBuilder.Scheme -eq 'https') { 'wss' } else { 'ws' }
    $uriBuilder.Host = '127.0.0.1'
    $uriBuilder.Port = $script:ForwardLocalPort
    Invoke-DartTrigger -Uri $uriBuilder.Uri.AbsoluteUri -DartPath $DartExecutable -ConfigPath $PackageConfig -ScriptPath $VmTriggerScript

    $newReport = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($ReportTimeoutSeconds)
    while ($null -eq $newReport -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 1
        $currentReports = @(Get-ReportNames)
        $newReport = $currentReports | Where-Object { $beforeReports -notcontains $_ } | Select-Object -First 1
    }
    $endEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($null -eq $newReport) { Fail-Probe 'new_report_not_emitted' }

    $safeName = [System.IO.Path]::GetFileName($newReport)
    if ($safeName -ne $newReport -and $newReport -notmatch '^\./(?:[^/]+/)+[^/]+$') { Fail-Probe 'report_path_invalid' }
    $destination = Join-Path -Path $EvidenceDirectory -ChildPath $safeName
    if (Test-Path -LiteralPath $destination) { Fail-Probe 'evidence_destination_exists' }
    Export-ReportBytes -RemotePath $newReport -Destination $destination

    $report = Read-SemanticReport -Path $destination
    if ([string](Get-RequiredReportValue -Report $report -Name 'buildCommit') -cne $ExpectedSourceCommit) { Fail-Probe 'build_commit_mismatch' }
    if ([bool](Get-RequiredReportValue -Report $report -Name 'remoteSavesEnabled')) { Fail-Probe 'remote_saves_enabled' }
    if ([bool](Get-RequiredReportValue -Report $report -Name 'remoteDeletesEnabled')) { Fail-Probe 'remote_deletes_enabled' }
    if ([bool](Get-RequiredReportValue -Report $report -Name 'tombstoneSemanticDeletesEnabled')) { Fail-Probe 'tombstone_semantic_deletes_enabled' }
    if (-not [bool](Get-RequiredReportValue -Report $report -Name 'retainedUnprojectedEvidencePreserved')) { Fail-Probe 'retained_evidence_not_preserved' }
    $outboxBefore = [int](Get-RequiredReportValue -Report $report -Name 'outboxCountBefore')
    $outboxAfter = [int](Get-RequiredReportValue -Report $report -Name 'outboxCountAfter')
    if ($outboxBefore -ne 0 -or $outboxAfter -ne 0) { Fail-Probe 'outbox_not_zero_to_zero' }

    $diagnostics = Get-DiagnosticCounts -StartEpochSeconds ($startEpoch - 2) -EndEpochSeconds ($endEpoch + 1)
    $nonzeroDiagnostics = @($diagnostics.PSObject.Properties | Where-Object { $_.Value -gt 0 })
    $diagnosticPath = Join-Path -Path $EvidenceDirectory -ChildPath "$safeName.diagnostics.json"
    if (Test-Path -LiteralPath $diagnosticPath) { Fail-Probe 'diagnostic_destination_exists' }
    $diagnosticDocument = [ordered]@{
        schemaVersion = 1
        sourceReport = $safeName
        buildCommit = $ExpectedSourceCommit
        counters = $diagnostics
    } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText(
        $diagnosticPath,
        $diagnosticDocument,
        [System.Text.UTF8Encoding]::new($false)
    )
    $diagnosticSummary = if ($nonzeroDiagnostics.Count -eq 0) { 'none' } else { "$($nonzeroDiagnostics.Count) fixed-label counters" }
    Write-Output "PASS report_exported=true build_commit_verified=true safety_verified=true outbox=0->0 diagnostics=$diagnosticSummary"
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
        $null = & $script:AdbPath -s $AdbSerial forward --remove "tcp:$script:ForwardLocalPort" 2>$null
    }
}
