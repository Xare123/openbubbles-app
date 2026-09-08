# Copyright 2026 BlueBubbles contributors. Pixel Canary batch gate.
<#
.SYNOPSIS
  Pixel Canary batch qualification gate (content-free).
.DESCRIPTION
  Batches existing tooling into one qualification run: preflight pin plus
  Alpha baseline, legacy/off upload gates, a direct-chat semantic pull with
  restart-persistence plus readback plus no-duplicate repull, then a
  restored-group pull with restart plus readback. Emits content-free JSON
  evidence only and never deletes chats or remote data.

  Allowed device operations: get-state, dumpsys package (preflight),
  canary_adb_control status/route/semantic-status (never open-dev,
  open-sync, or semantic-start), install -r of the pinned APK (inside the
  existing probe only, preserving app data), force-stop plus launcher
  restart for persistence coverage, logcat reads, port forwards, and
  run-as cat/find/stat (inside the existing probe and readers). No
  uninstall, pm clear, run-as rm, chat delete, or CloudKit mutation exists
  anywhere in this path; the semantic reports themselves tripwire remote
  writes, tombstone deletes, and outbox changes.

  Direct recipient scope is enforced by hash: the operator precomputes
  SHA-256 of the direct canonical routing string off-device and passes
  only the hash. Group scope is enforced by shape plus a mandatory
  out-of-band expected hash that must match on both readbacks, with hash
  stability required across restart. Self-pinning is forbidden. Phone
  numbers and GUIDs never appear in arguments, logs, or evidence.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $ApkPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedApkSha256,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedSourceCommit,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedApkSignerSha256,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $AdbSerial,
    [ValidateNotNullOrEmpty()][string] $AdbExecutable = 'adb.exe',
    [ValidateNotNullOrEmpty()][string] $Aapt2Executable = 'aapt2.exe',
    [ValidateNotNullOrEmpty()][string] $ApksignerExecutable = 'apksigner.bat',
    [ValidateNotNullOrEmpty()][string] $DartExecutable = 'dart.exe',
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $PackageConfig,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $VmTriggerScript,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedVmTriggerSha256,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $VmReadChatScript,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedVmReadChatSha256,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $VmReadUploadModeScript,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedVmReadUploadModeSha256,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $CanaryAdbControlScript,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $CloudkitProbeScript,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $PreflightScript,
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int] $DirectChatId,
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int] $GroupChatId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $DirectRecipientHash,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $GroupRoutingHash,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $EvidenceDirectory,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $GroupRestoreSignalFile,
    [ValidateSet('com.bluebubbles.messaging.cloudkitcanary')][string] $CanaryPackage = 'com.bluebubbles.messaging.cloudkitcanary',
    [ValidateRange(60, 7200)][int] $GroupRestoreTimeoutSec = 1800,
    [ValidateRange(1, 900)][int] $ProcessTimeoutSeconds = 60,
    [ValidateRange(1, 3600)][int] $ReportTimeoutSeconds = 180,
    [ValidateRange(240, 900)][int] $VmTriggerTimeoutSeconds = 240
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:AdbPath = ''
$script:Forwards = @()

function Fail-Gate {
    param([Parameter(Mandatory = $true)][string] $Code)
    throw [System.InvalidOperationException]::new('gate_' + $Code)
}

function Invoke-BoundedText {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][ValidateRange(1, 900)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $FailureCode
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
        if (-not $process.Start()) { Fail-Gate 'child_start_failed' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            Fail-Gate 'child_timeout'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $discardErr = $stderrTask.GetAwaiter().GetResult()
        if ($stdout.Length -gt 4194304) { Fail-Gate 'child_output_too_large' }
        if ($process.ExitCode -ne 0) { Fail-Gate $FailureCode }
        return @($stdout -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    }
    finally {
        $process.Dispose()
    }
}

function Resolve-GateExecutable {
    param([Parameter(Mandatory = $true)][string] $Executable, [Parameter(Mandatory = $true)][string] $Code)
    if ([System.IO.Path]::IsPathRooted($Executable)) {
        if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { Fail-Gate $Code }
        return (Resolve-Path -LiteralPath $Executable).Path
    }
    $command = Get-Command -Name $Executable -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) { Fail-Gate $Code }
    return $command.Path
}

function Invoke-AdbLines {
    param([Parameter(Mandatory = $true)][string[]] $Arguments, [ValidateRange(1, 900)][int] $TimeoutSeconds = $ProcessTimeoutSeconds)
    return Invoke-BoundedText -FilePath $script:AdbPath -Arguments (@('-s', $AdbSerial) + $Arguments) -TimeoutSeconds $TimeoutSeconds -FailureCode 'adb_command_failed'
}

function Get-CanaryPids {
    $lines = Invoke-AdbLines @('shell', 'ps', '-A', '-o', 'PID,NAME')
    $pids = @()
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^\s*(?<pid>\d+)\s+(?<name>\S+)\s*$')
        if (-not $m.Success) { continue }
        $name = $m.Groups['name'].Value
        if ($name -ceq $CanaryPackage -or $name.StartsWith($CanaryPackage + ':', [System.StringComparison]::Ordinal)) {
            $pids += [int]$m.Groups['pid'].Value
        }
    }
    return @($pids | Sort-Object -Unique)
}

function Get-VmUriForPid {
    param([Parameter(Mandatory = $true)][int] $ProcessId, [Parameter(Mandatory = $true)][double] $StartEpochSeconds)
    $lines = Invoke-AdbLines @('logcat', '-v', 'epoch', ('--pid=' + $ProcessId), '-d', '--regex=The Dart VM service is listening on http://127.0.0.1:') -TimeoutSeconds 5
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*(\d+\.\d+)\s+') { continue }
        if ([double]$Matches[1] -lt $StartEpochSeconds) { continue }
        $uriMatch = [regex]::Match($line, 'The Dart VM service is listening on (?<uri>http://127\.0\.0\.1:(?<port>\d+)/[^\s]+)')
        if ($uriMatch.Success) {
            return [pscustomobject]@{ Uri = $uriMatch.Groups['uri'].Value; Port = [int]$uriMatch.Groups['port'].Value }
        }
    }
    return $null
}

function New-VmForward {
    param([Parameter(Mandatory = $true)][int] $DevicePort)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $localPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $null = Invoke-AdbLines @('forward', '--no-rebind', ('tcp:' + $localPort), ('tcp:' + $DevicePort))
    $script:Forwards += $localPort
    return $localPort
}

function Remove-VmForward {
    param([Parameter(Mandatory = $true)][int] $LocalPort)
    $null = Invoke-AdbLines @('forward', '--remove', ('tcp:' + $LocalPort))
    $script:Forwards = @($script:Forwards | Where-Object { $_ -ne $LocalPort })
}

function Ensure-CanaryRunning {
    $pids = @(Get-CanaryPids)
    if ($pids.Count -eq 1) { return $pids[0] }
    if ($pids.Count -gt 1) { Fail-Gate 'package_pid_ambiguous' }
    $null = Invoke-AdbLines @('shell', 'monkey', '-p', $CanaryPackage, '-c', 'android.intent.category.LAUNCHER', '1')
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $pids = @(Get-CanaryPids)
        if ($pids.Count -eq 1) { return $pids[0] }
    }
    Fail-Gate 'package_pid_unavailable'
}

function Open-VmChannel {
    $startEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $null = Invoke-AdbLines @('shell', 'am', 'force-stop', $CanaryPackage)
    Wait-CanaryStopped
    $null = Invoke-AdbLines @('shell', 'monkey', '-p', $CanaryPackage, '-c', 'android.intent.category.LAUNCHER', '1')
    $pidNow = 0
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $pids = @(Get-CanaryPids)
        if ($pids.Count -eq 1) { $pidNow = $pids[0]; break }
    }
    if ($pidNow -eq 0) { Fail-Gate 'package_pid_unavailable' }
    $vm = $null
    for ($i = 0; $i -lt 30 -and $null -eq $vm; $i++) {
        Start-Sleep -Milliseconds 500
        $vm = Get-VmUriForPid -ProcessId $pidNow -StartEpochSeconds $startEpoch
    }
    if ($null -eq $vm) { Fail-Gate 'vm_service_url_not_found' }
    $localPort = New-VmForward -DevicePort $vm.Port
    $builder = [System.UriBuilder]::new($vm.Uri)
    if ($builder.Scheme -eq 'https') { $builder.Scheme = 'wss' } else { $builder.Scheme = 'ws' }
    $builder.Host = '127.0.0.1'
    $builder.Port = $localPort
    $builder.Path = $builder.Path.TrimEnd('/') + '/ws'
    return [pscustomobject]@{ WsUri = $builder.Uri.AbsoluteUri; LocalPort = $localPort; Pid = $pidNow }
}

function Wait-CanaryStopped {
    for ($i = 0; $i -lt 20; $i++) {
        if (@(Get-CanaryPids).Count -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    Fail-Gate 'package_not_stopped'
}

function Invoke-ChatRead {
    param([Parameter(Mandatory = $true)][string] $WsUri, [Parameter(Mandatory = $true)][int] $ChatId, [Parameter(Mandatory = $true)][string] $Scope, [string] $ExpectHash = '')
    $chatArgs = @('--packages=' + $PackageConfig, $VmReadChatScript, $WsUri, [string]$ChatId, '--scope', $Scope)
    if ($ExpectHash -ne '') { $chatArgs += @('--expect-hash', $ExpectHash) }
    $lines = Invoke-BoundedText -FilePath $script:DartPath -Arguments $chatArgs -TimeoutSeconds $ProcessTimeoutSeconds -FailureCode 'chat_read_failed'
    $doc = ($lines -join "`n") | ConvertFrom-Json
    if (-not $doc.found) { Fail-Gate 'chat_not_found' }
    return $doc
}

function Invoke-UploadModeRead {
    param([Parameter(Mandatory = $true)][string] $WsUri)
    $modeArgs = @('--packages=' + $PackageConfig, $VmReadUploadModeScript, $WsUri, '--expect-uploads-off')
    $lines = Invoke-BoundedText -FilePath $script:DartPath -Arguments $modeArgs -TimeoutSeconds $ProcessTimeoutSeconds -FailureCode 'upload_mode_check_failed'
    $doc = ($lines -join "`n") | ConvertFrom-Json
    if ($doc.mode -cne 'uploads-off') { Fail-Gate 'uploads_not_off' }
    return $doc
}

function Invoke-ControlStatus {
    param([Parameter(Mandatory = $true)][string] $Action)
    $out = & $CanaryAdbControlScript -Action $Action -Package $CanaryPackage -Serial $AdbSerial -TimeoutSec $ProcessTimeoutSeconds 2>&1 | ForEach-Object { [string]$_ }
    if ($LASTEXITCODE -ne 0) { Fail-Gate ('control_' + $Action + '_failed') }
    return @($out | Where-Object { $_.Length -gt 0 })
}

function Invoke-ProbeRun {
    param([Parameter(Mandatory = $true)][string] $RunDirectory)
    & $CloudkitProbeScript -ApkPath $ApkPath -ExpectedApkSha256 $ExpectedApkSha256 -ExpectedSourceCommit $ExpectedSourceCommit -AdbSerial $AdbSerial -AdbExecutable $script:AdbPath -Aapt2Executable $script:Aapt2Path -DartExecutable $script:DartPath -PackageConfig $PackageConfig -VmTriggerScript $VmTriggerScript -ExpectedVmTriggerSha256 $ExpectedVmTriggerSha256 -EvidenceDirectory $RunDirectory -ReportTimeoutSeconds $ReportTimeoutSeconds -ProcessTimeoutSeconds $ProcessTimeoutSeconds -VmTriggerTimeoutSeconds $VmTriggerTimeoutSeconds
    if ($LASTEXITCODE -ne 0) { Fail-Gate 'probe_run_failed' }
    $reports = @(Get-ChildItem -LiteralPath $RunDirectory -Filter 'obcs2-semantic-*.json' | Sort-Object Name)
    if ($reports.Count -ne 1) { Fail-Gate 'probe_evidence_not_single' }
    $hash = (Get-FileHash -LiteralPath $reports[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $doc = Get-Content -LiteralPath $reports[0].FullName -Raw | ConvertFrom-Json
    if ($doc.buildCommit -cne $ExpectedSourceCommit) { Fail-Gate 'build_commit_mismatch' }
    if ($doc.outboxCountBefore -ne $doc.outboxCountAfter) { Fail-Gate 'outbox_snapshot_changed' }
    $appliedSum = 0
    foreach ($zone in $doc.zones) { $appliedSum += [long]$zone.applied }
    return [pscustomobject]@{ FileName = $reports[0].Name; Sha256 = $hash; OutboxBefore = [long]$doc.outboxCountBefore; OutboxAfter = [long]$doc.outboxCountAfter; AppliedSum = $appliedSum }
}

$script:DartPath = ''
$script:Aapt2Path = ''
try {
    if ($PSVersionTable.PSVersion.Major -lt 7) { Fail-Gate 'powershell_7_required' }
    foreach ($f in @($ApkPath, $PackageConfig, $VmTriggerScript, $VmReadChatScript, $VmReadUploadModeScript, $CanaryAdbControlScript, $CloudkitProbeScript, $PreflightScript)) {
        if (-not [System.IO.Path]::IsPathRooted($f)) { Fail-Gate 'path_not_absolute' }
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Fail-Gate 'file_missing' }
    }
    if (-not [System.IO.Path]::IsPathRooted($EvidenceDirectory)) { Fail-Gate 'evidence_path_not_absolute' }
    if (Test-Path -LiteralPath $EvidenceDirectory) {
        $existingChildren = @(Get-ChildItem -LiteralPath $EvidenceDirectory -Force)
        if ($existingChildren.Count -ne 0) { Fail-Gate 'evidence_directory_not_empty' }
    } else {
        $null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force
    }
    $script:AdbPath = Resolve-GateExecutable -Executable $AdbExecutable -Code 'adb_executable_unavailable'
    $script:Aapt2Path = Resolve-GateExecutable -Executable $Aapt2Executable -Code 'aapt2_executable_unavailable'
    $script:DartPath = Resolve-GateExecutable -Executable $DartExecutable -Code 'dart_executable_unavailable'
    $preDir = Join-Path $EvidenceDirectory 'pre'
    & $PreflightScript -ApkPath $ApkPath -ExpectedApkSha256 $ExpectedApkSha256 -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedApkSignerSha256 $ExpectedApkSignerSha256 -AdbSerial $AdbSerial -AdbExecutable $script:AdbPath -Aapt2Executable $script:Aapt2Path -ApksignerExecutable $ApksignerExecutable -PackageConfig $PackageConfig -VmTriggerScript $VmTriggerScript -ExpectedVmTriggerSha256 $ExpectedVmTriggerSha256 -VmReadChatScript $VmReadChatScript -ExpectedVmReadChatSha256 $ExpectedVmReadChatSha256 -VmReadUploadModeScript $VmReadUploadModeScript -ExpectedVmReadUploadModeSha256 $ExpectedVmReadUploadModeSha256 -EvidenceDirectory $preDir -ProcessTimeoutSeconds $ProcessTimeoutSeconds
    if ($LASTEXITCODE -ne 0) { Fail-Gate 'preflight_pre_failed' }
    $preDoc = Get-Content -LiteralPath (Join-Path $preDir 'pixel-preflight.json') -Raw | ConvertFrom-Json
    $statusLines = Invoke-ControlStatus -Action 'status'
    if ($statusLines[0] -cnotmatch '^code=\S+ ok=True$') { Fail-Gate 'canary_status_not_ok' }
    $statusDoc = ($statusLines | Select-Object -Skip 1 | Out-String) | ConvertFrom-Json
    if ($statusDoc.legacy_sync_enabled -ne $false -or $statusDoc.legacy_sync_active -ne $false) { Fail-Gate 'legacy_sync_active' }
    $routeLines = Invoke-ControlStatus -Action 'route'
    $routeHead = [string]$routeLines[0]
    if ($routeHead -cnotmatch '^code=\S+ ok=True$') { Fail-Gate 'canary_route_not_ok' }
    try {
        $routeDoc = ($routeLines | Select-Object -Skip 1 | Out-String) | ConvertFrom-Json
    } catch {
        Fail-Gate 'canary_route_json_invalid'
    }
    if ($routeDoc.route -cne 'other' -or $routeDoc.foreground -ne $true) {
        Fail-Gate 'canary_route_not_safe'
    }
    $channel = Open-VmChannel
    try {
        $null = Invoke-UploadModeRead -WsUri $channel.WsUri
    } finally {
        Remove-VmForward -LocalPort $channel.LocalPort
    }
    $direct1Dir = Join-Path $EvidenceDirectory 'run-direct-1'
    $direct1 = Invoke-ProbeRun -RunDirectory $direct1Dir
    $channel = Open-VmChannel
    try {
        $readD1 = Invoke-ChatRead -WsUri $channel.WsUri -ChatId $DirectChatId -Scope 'direct' -ExpectHash $DirectRecipientHash
        if (-not $readD1.scopeMatch -or -not $readD1.recipientHashMatch) { Fail-Gate 'direct_scope_not_matched' }
        $directHash1 = [string]$readD1.routingHash
        $oldDirectPid = $channel.Pid
        $null = Invoke-AdbLines @('shell', 'am', 'force-stop', $CanaryPackage)
        Wait-CanaryStopped
        Remove-VmForward -LocalPort $channel.LocalPort
        $channel = Open-VmChannel
        if ($channel.Pid -eq $oldDirectPid) { Fail-Gate 'pid_not_renewed' }
        $readD2 = Invoke-ChatRead -WsUri $channel.WsUri -ChatId $DirectChatId -Scope 'direct' -ExpectHash $DirectRecipientHash
        if ([string]$readD2.routingHash -cne $directHash1) { Fail-Gate 'direct_hash_unstable' }
    } finally {
        Remove-VmForward -LocalPort $channel.LocalPort
    }
    $direct2Dir = Join-Path $EvidenceDirectory 'run-direct-2'
    $direct2 = Invoke-ProbeRun -RunDirectory $direct2Dir
    if ($direct2.AppliedSum -ne 0) { Fail-Gate 'duplicate_projection_on_repull' }
    Write-Output 'AWAITING_GROUP_RESTORE group chat must be restored in the Pixel UI, then create the signal file.'
    $restoreDeadline = [DateTime]::UtcNow.AddSeconds($GroupRestoreTimeoutSec)
    while (-not (Test-Path -LiteralPath $GroupRestoreSignalFile -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $restoreDeadline) { Fail-Gate 'group_restore_timeout' }
        Start-Sleep -Seconds 5
    }
    $group1Dir = Join-Path $EvidenceDirectory 'run-group-1'
    $group1 = Invoke-ProbeRun -RunDirectory $group1Dir
    $channel = Open-VmChannel
    try {
        $readG1 = Invoke-ChatRead -WsUri $channel.WsUri -ChatId $GroupChatId -Scope 'group' -ExpectHash $GroupRoutingHash
        if (-not $readG1.scopeMatch -or -not $readG1.recipientHashMatch) { Fail-Gate 'group_scope_not_matched' }
        $groupHash1 = [string]$readG1.routingHash
        $oldGroupPid = $channel.Pid
        $null = Invoke-AdbLines @('shell', 'am', 'force-stop', $CanaryPackage)
        Wait-CanaryStopped
        Remove-VmForward -LocalPort $channel.LocalPort
        $channel = Open-VmChannel
        if ($channel.Pid -eq $oldGroupPid) { Fail-Gate 'pid_not_renewed' }
        $readG2 = Invoke-ChatRead -WsUri $channel.WsUri -ChatId $GroupChatId -Scope 'group' -ExpectHash $GroupRoutingHash
        if (-not $readG2.recipientHashMatch) { Fail-Gate 'group_hash_mismatch' }
        if ([string]$readG2.routingHash -cne $groupHash1) { Fail-Gate 'group_hash_unstable' }
    } finally {
        Remove-VmForward -LocalPort $channel.LocalPort
    }
    $postDir = Join-Path $EvidenceDirectory 'post'
    & $PreflightScript -ApkPath $ApkPath -ExpectedApkSha256 $ExpectedApkSha256 -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedApkSignerSha256 $ExpectedApkSignerSha256 -AdbSerial $AdbSerial -AdbExecutable $script:AdbPath -Aapt2Executable $script:Aapt2Path -ApksignerExecutable $ApksignerExecutable -PackageConfig $PackageConfig -VmTriggerScript $VmTriggerScript -ExpectedVmTriggerSha256 $ExpectedVmTriggerSha256 -VmReadChatScript $VmReadChatScript -ExpectedVmReadChatSha256 $ExpectedVmReadChatSha256 -VmReadUploadModeScript $VmReadUploadModeScript -ExpectedVmReadUploadModeSha256 $ExpectedVmReadUploadModeSha256 -EvidenceDirectory $postDir -ProcessTimeoutSeconds $ProcessTimeoutSeconds
    if ($LASTEXITCODE -ne 0) { Fail-Gate 'preflight_post_failed' }
    $postDoc = Get-Content -LiteralPath (Join-Path $postDir 'pixel-preflight.json') -Raw | ConvertFrom-Json
    $alphaStable = ($preDoc.alpha.versionCode -ceq $postDoc.alpha.versionCode) -and ($preDoc.alpha.firstInstallTime -ceq $postDoc.alpha.firstInstallTime) -and ($preDoc.alpha.lastUpdateTime -ceq $postDoc.alpha.lastUpdateTime) -and ($preDoc.alpha.userId -ceq $postDoc.alpha.userId) -and ($preDoc.alpha.codePath -ceq $postDoc.alpha.codePath) -and ($preDoc.alpha.dataDir -ceq $postDoc.alpha.dataDir)
    if (-not $alphaStable) { Fail-Gate 'alpha_touched' }
    if ($preDoc.canary.firstInstallTime -cne $postDoc.canary.firstInstallTime) { Fail-Gate 'canary_reinstalled' }
    if ($preDoc.canary.dataDir -cne $postDoc.canary.dataDir) { Fail-Gate 'canary_reinstalled' }
    $summary = [ordered]@{
        schemaVersion = 1
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        pins = $preDoc.pins
        legacyOff = $true
        uploadsOff = $true
        routeHead = $routeHead
        direct = [ordered]@{
            run1 = [ordered]@{ file = $direct1.FileName; sha256 = $direct1.Sha256; outbox = ('{0}->{1}' -f $direct1.OutboxBefore, $direct1.OutboxAfter) }
            routingHash = $directHash1
            hashStableAcrossRestart = $true
            run2 = [ordered]@{ file = $direct2.FileName; sha256 = $direct2.Sha256; outbox = ('{0}->{1}' -f $direct2.OutboxBefore, $direct2.OutboxAfter); appliedSum = $direct2.AppliedSum }
            noDuplicateOnRepull = $true
        }
        group = [ordered]@{
            run1 = [ordered]@{ file = $group1.FileName; sha256 = $group1.Sha256; outbox = ('{0}->{1}' -f $group1.OutboxBefore, $group1.OutboxAfter) }
            routingHash = $groupHash1
            hashStableAcrossRestart = $true
        }
        alphaUntouched = $true
        canaryFirstInstallStable = $true
    }
    $summaryPath = Join-Path $EvidenceDirectory 'pixel-batch-summary.json'
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 6))
    Write-Output 'PASS batch_complete=true alpha_untouched=true uploads_off=true direct_restart_stable=true group_restart_stable=true no_duplicate=true'
} catch {
    $safeFailure = 'gate_unexpected_failure'
    if ($_.Exception.Message -match '^gate_[a-z0-9_]+$') { $safeFailure = $_.Exception.Message }
    if ($_.Exception.Message -match '^preflight_[a-z0-9_]+$') { $safeFailure = $_.Exception.Message }
    if ($_.Exception.Message -match '^probe_[a-z0-9_]+$') { $safeFailure = $_.Exception.Message }
    $safeType = $_.Exception.GetType().FullName -replace '[^A-Za-z0-9_.]', '_'
    $safeLine = [int]$_.InvocationInfo.ScriptLineNumber
    Write-Error ('FAIL pixel_batch_gate_violation code=' + $safeFailure + ' type=' + $safeType + ' line=' + $safeLine)
    exit 1
} finally {
    foreach ($port in @($script:Forwards)) {
        try { $null = Invoke-AdbLines @('forward', '--remove', ('tcp:' + $port)) } catch { }
    }
}
