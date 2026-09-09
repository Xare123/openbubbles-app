# Copyright 2026 BlueBubbles contributors. Pixel CloudKit write gate.
<#
.SYNOPSIS
  Runs one phase of the explicit CloudKit V2 journaled-send qualification.
.DESCRIPTION
  PREPARE establishes V2 writer ownership without contacting CloudKit, then
  selects the newest exact journal origin. RUN reselects the same GUID hash
  after a fresh Canary process and executes the existing one-intent production
  path. VERIFY performs an optional post-restart idempotence pass and requires
  zero admissions.

  The recipient is read only from OPENBUBBLES_CANARY_RECIPIENT and must match
  the separately supplied SHA-256. It is never written to output or evidence.
  The gate requires a manual-writer build with the automatic worker compiled
  out. It never installs, uninstalls, clears data, deletes rows, enables legacy
  sync, or touches Alpha. A timeout is unresolved and is never retried.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('prepare', 'run', 'verify')][string] $Mode,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string] $ExpectedRecipientSha256,
    [ValidatePattern('^$|^[0-9a-f]{16}$')][string] $ExpectedGuidHash = '',
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedSourceCommit,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $AdbSerial,
    [ValidateNotNullOrEmpty()][string] $AdbExecutable = 'adb.exe',
    [ValidateNotNullOrEmpty()][string] $DartExecutable = 'dart.exe',
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $PackageConfig,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $VmWriteScript,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string] $ExpectedVmWriteSha256,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $VmReadUploadModeScript,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string] $ExpectedVmReadUploadModeSha256,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $EvidenceDirectory,
    [ValidateSet('com.bluebubbles.messaging.cloudkitcanary')][string] $CanaryPackage = 'com.bluebubbles.messaging.cloudkitcanary',
    [ValidateRange(10, 600)][int] $ProcessTimeoutSeconds = 360
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:AdbPath = ''
$script:DartPath = ''
$script:Forwards = @()

function Fail-Gate {
    param([Parameter(Mandatory = $true)][string] $Code)
    throw [System.InvalidOperationException]::new('gate_' + $Code)
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

function Invoke-BoundedText {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][ValidateRange(1, 600)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $FailureCode
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { Fail-Gate 'child_start_failed' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            Fail-Gate 'child_timeout_unresolved'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $discardedError = $stderrTask.GetAwaiter().GetResult()
        if ($stdout.Length -gt 1048576) { Fail-Gate 'child_output_too_large' }
        if ($process.ExitCode -ne 0) { Fail-Gate $FailureCode }
        return @($stdout -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    } finally {
        $process.Dispose()
    }
}

function Invoke-AdbLines {
    param([Parameter(Mandatory = $true)][string[]] $Arguments, [ValidateRange(1, 600)][int] $TimeoutSeconds = 30)
    Invoke-BoundedText -FilePath $script:AdbPath -Arguments (@('-s', $AdbSerial) + $Arguments) -TimeoutSeconds $TimeoutSeconds -FailureCode 'adb_command_failed'
}

function Get-CanaryPids {
    $lines = Invoke-AdbLines @('shell', 'ps', '-A', '-o', 'PID,NAME')
    $pids = @()
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*(?<pid>\d+)\s+(?<name>\S+)\s*$')
        if (-not $match.Success) { continue }
        $name = $match.Groups['name'].Value
        if ($name -ceq $CanaryPackage -or $name.StartsWith($CanaryPackage + ':', [System.StringComparison]::Ordinal)) {
            $pids += [int]$match.Groups['pid'].Value
        }
    }
    return @($pids | Sort-Object -Unique)
}

function Wait-CanaryStopped {
    for ($i = 0; $i -lt 20; $i++) {
        if (@(Get-CanaryPids).Count -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    Fail-Gate 'package_not_stopped'
}

function Get-VmUriForPid {
    param([Parameter(Mandatory = $true)][int] $ProcessId, [Parameter(Mandatory = $true)][double] $StartEpochSeconds)
    $lines = Invoke-AdbLines @('logcat', '-v', 'epoch', ('--pid=' + $ProcessId), '-d', '--regex=The Dart VM service is listening on http://127.0.0.1:') -TimeoutSeconds 5
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*(\d+\.\d+)\s+') { continue }
        if ([double]$Matches[1] -lt $StartEpochSeconds) { continue }
        $match = [regex]::Match($line, 'The Dart VM service is listening on (?<uri>http://127\.0\.0\.1:(?<port>\d+)/[^\s]+)')
        if ($match.Success) {
            return [pscustomobject]@{ Uri = $match.Groups['uri'].Value; Port = [int]$match.Groups['port'].Value }
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

function Open-VmChannel {
    $startEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $null = Invoke-AdbLines @('shell', 'am', 'force-stop', $CanaryPackage)
    Wait-CanaryStopped
    $null = Invoke-AdbLines @('shell', 'monkey', '-p', $CanaryPackage, '-c', 'android.intent.category.LAUNCHER', '1')
    $pidNow = 0
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $pids = @(Get-CanaryPids)
        if ($pids.Count -eq 1) { $pidNow = $pids[0]; break }
        if ($pids.Count -gt 1) { Fail-Gate 'package_pid_ambiguous' }
    }
    if ($pidNow -eq 0) { Fail-Gate 'package_pid_unavailable' }
    $vm = $null
    for ($i = 0; $i -lt 40 -and $null -eq $vm; $i++) {
        Start-Sleep -Milliseconds 500
        $vm = Get-VmUriForPid -ProcessId $pidNow -StartEpochSeconds $startEpoch
    }
    if ($null -eq $vm) { Fail-Gate 'vm_service_url_not_found' }
    $localPort = New-VmForward -DevicePort $vm.Port
    $builder = [System.UriBuilder]::new($vm.Uri)
    $builder.Scheme = if ($builder.Scheme -eq 'https') { 'wss' } else { 'ws' }
    $builder.Host = '127.0.0.1'
    $builder.Port = $localPort
    $builder.Path = $builder.Path.TrimEnd('/') + '/ws'
    return [pscustomobject]@{ WsUri = $builder.Uri.AbsoluteUri; LocalPort = $localPort }
}

function Remove-VmForward {
    param([Parameter(Mandatory = $true)][int] $LocalPort)
    $null = Invoke-AdbLines @('forward', '--remove', ('tcp:' + $LocalPort))
    $script:Forwards = @($script:Forwards | Where-Object { $_ -ne $LocalPort })
}

function Get-NormalizedRecipientHash {
    param([Parameter(Mandatory = $true)][string] $Recipient)
    $normalized = $Recipient.Trim()
    if ($normalized.StartsWith('mailto:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(7)
    } elseif ($normalized.StartsWith('tel:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(4)
    }
    $normalized = $normalized.Trim().ToLowerInvariant()
    if ($normalized.Length -lt 1 -or $normalized.Length -gt 320) { Fail-Gate 'recipient_invalid' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) { Fail-Gate 'powershell_7_required' }
    if ($Mode -eq 'prepare' -and $ExpectedGuidHash -ne '') { Fail-Gate 'unexpected_guid_hash' }
    if ($Mode -ne 'prepare' -and $ExpectedGuidHash -eq '') { Fail-Gate 'expected_guid_hash_required' }
    foreach ($path in @($PackageConfig, $VmWriteScript, $VmReadUploadModeScript)) {
        if (-not [System.IO.Path]::IsPathRooted($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Fail-Gate 'file_missing'
        }
    }
    if ((Get-FileHash -LiteralPath $VmWriteScript -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedVmWriteSha256) {
        Fail-Gate 'write_tool_hash_mismatch'
    }
    if ((Get-FileHash -LiteralPath $VmReadUploadModeScript -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedVmReadUploadModeSha256) {
        Fail-Gate 'upload_mode_tool_hash_mismatch'
    }
    if (-not [System.IO.Path]::IsPathRooted($EvidenceDirectory)) { Fail-Gate 'evidence_path_not_absolute' }
    if (Test-Path -LiteralPath $EvidenceDirectory) {
        if (@(Get-ChildItem -LiteralPath $EvidenceDirectory -Force).Count -ne 0) { Fail-Gate 'evidence_directory_not_empty' }
    } else {
        $null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force
    }
    $recipient = [System.Environment]::GetEnvironmentVariable('OPENBUBBLES_CANARY_RECIPIENT', 'Process')
    if ([string]::IsNullOrWhiteSpace($recipient)) { Fail-Gate 'recipient_environment_missing' }
    if ((Get-NormalizedRecipientHash -Recipient $recipient) -cne $ExpectedRecipientSha256) {
        Fail-Gate 'recipient_hash_mismatch'
    }
    $script:AdbPath = Resolve-GateExecutable -Executable $AdbExecutable -Code 'adb_executable_unavailable'
    $script:DartPath = Resolve-GateExecutable -Executable $DartExecutable -Code 'dart_executable_unavailable'
    $deviceState = Invoke-AdbLines @('get-state')
    if ($deviceState.Count -ne 1 -or $deviceState[0] -cne 'device') { Fail-Gate 'device_unavailable' }

    $channel = Open-VmChannel
    try {
        $modeArgs = @('--packages=' + $PackageConfig, $VmReadUploadModeScript, $channel.WsUri, '--expect-manual-writer')
        $modeLines = Invoke-BoundedText -FilePath $script:DartPath -Arguments $modeArgs -TimeoutSeconds 60 -FailureCode 'manual_writer_mode_failed'
        $modeDoc = ($modeLines -join "`n") | ConvertFrom-Json
        if ($modeDoc.mode -cne 'manual-writer') { Fail-Gate 'manual_writer_mode_failed' }
        $committed = @($modeDoc.isolates | Where-Object { $_.buildCommit })
        if ($committed.Count -ne 1 -or $committed[0].buildCommit -cne $ExpectedSourceCommit) {
            Fail-Gate 'source_commit_mismatch'
        }

        $writeArgs = @('--packages=' + $PackageConfig, $VmWriteScript, $channel.WsUri, ('--' + $Mode), '--expect-recipient-sha256', $ExpectedRecipientSha256)
        if ($Mode -ne 'prepare') { $writeArgs += $ExpectedGuidHash }
        $writeLines = Invoke-BoundedText -FilePath $script:DartPath -Arguments $writeArgs -TimeoutSeconds $ProcessTimeoutSeconds -FailureCode 'write_phase_failed'
        $writeDoc = ($writeLines -join "`n") | ConvertFrom-Json
        if ($writeDoc.mode -cne $Mode -or $writeDoc.recipientSha256 -cne $ExpectedRecipientSha256) {
            Fail-Gate 'write_evidence_invalid'
        }
        if ($Mode -eq 'prepare') {
            if ($writeDoc.candidateFound -ne $true -or $writeDoc.guidHash -cnotmatch '^[0-9a-f]{16}$') {
                Fail-Gate 'candidate_unavailable'
            }
        } else {
            if ($writeDoc.guidHash -cne $ExpectedGuidHash -or
                [int]$writeDoc.admitted -lt 0 -or [int]$writeDoc.admitted -gt 1 -or
                [int]$writeDoc.deferred -ne 0 -or $writeDoc.outboxBlocked -ne $false -or
                $writeDoc.chatReadbackPending -ne $false) {
                Fail-Gate 'write_not_settled'
            }
            if ($Mode -eq 'verify' -and [int]$writeDoc.admitted -ne 0) { Fail-Gate 'duplicate_admission' }
        }

        $evidence = [ordered]@{
            schemaVersion = 1
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            mode = $Mode
            sourceCommit = $ExpectedSourceCommit
            recipientSha256 = $ExpectedRecipientSha256
            vmWriteSha256 = $ExpectedVmWriteSha256
            vmReadUploadModeSha256 = $ExpectedVmReadUploadModeSha256
            result = $writeDoc
            automaticUploads = $false
            alphaTargeted = $false
        }
        $evidencePath = Join-Path $EvidenceDirectory ('pixel-cloudkit-write-' + $Mode + '.json')
        [System.IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 6))
        Write-Output ('PASS cloudkit_write_phase=' + $Mode + ' automatic_uploads=false alpha_targeted=false')
        if ($Mode -eq 'prepare') { Write-Output ('guid_hash=' + [string]$writeDoc.guidHash) }
    } finally {
        Remove-VmForward -LocalPort $channel.LocalPort
    }
} catch {
    $safeCode = 'gate_unexpected_failure'
    if ($_.Exception.Message -match '^gate_[a-z0-9_]+$') { $safeCode = $_.Exception.Message }
    $safeType = $_.Exception.GetType().FullName -replace '[^A-Za-z0-9_.]', '_'
    $safeLine = [int]$_.InvocationInfo.ScriptLineNumber
    Write-Error ('FAIL pixel_cloudkit_write_gate code=' + $safeCode + ' type=' + $safeType + ' line=' + $safeLine)
    exit 1
} finally {
    foreach ($port in @($script:Forwards)) {
        try { $null = Invoke-AdbLines @('forward', '--remove', ('tcp:' + $port)) } catch { }
    }
}
