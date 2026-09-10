# Copyright 2026 BlueBubbles contributors. Read-only Pixel preflight.
<#
.SYNOPSIS
  Read-only Pixel preflight for the Canary batch gate.
.DESCRIPTION
  Pins the Canary APK (SHA-256, application ID, v2 signer certificate
  SHA-256) and the VM reader/trigger scripts (SHA-256 each), records the
  expected source commit, and snapshots Canary plus Alpha package state
  with dumpsys. Writes one content-free JSON snapshot and prints a fixed
  PASS line. Performs no install, uninstall, clear, stop, launch,
  deletion, or remote mutation. Alpha-untouched proof is completed by the
  batch orchestrator, which runs this preflight before and after the batch
  and requires the Alpha install/update times and version to be identical.

  Phone numbers, message content, GUIDs, tokens, and record values never
  cross this boundary. Only hashes, version codes, install times, package
  names, system package paths, and isolation booleans are emitted. The
  expected source commit is labeled caller-attested here; only the probe
  report check against the running APK verifies it on-device.
.NOTES
  Requires PowerShell 7, adb, aapt2, and apksigner. Never touches user
  data and never mutates the device.
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
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedApkSignerSha256,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $AdbSerial,
    [ValidateNotNullOrEmpty()]
    [string] $AdbExecutable = 'adb.exe',
    [ValidateNotNullOrEmpty()]
    [string] $Aapt2Executable = 'aapt2.exe',
    [ValidateNotNullOrEmpty()]
    [string] $ApksignerExecutable = 'apksigner.bat',
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
    [string] $VmReadChatScript,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedVmReadChatSha256,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $VmReadUploadModeScript,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedVmReadUploadModeSha256,
    [ValidateSet('com.bluebubbles.messaging.cloudkitcanary')]
    [string] $CanaryPackage = 'com.bluebubbles.messaging.cloudkitcanary',
    [ValidateSet('com.bluebubbles.messaging.alpha')]
    [string] $AlphaPackage = 'com.bluebubbles.messaging.alpha',
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $EvidenceDirectory,
    [ValidateRange(1, 900)]
    [int] $ProcessTimeoutSeconds = 60
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Fail-Preflight {
    param([Parameter(Mandatory = $true)][string] $Code)
    throw [System.InvalidOperationException]::new('preflight_' + $Code)
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
        if (-not $process.Start()) { Fail-Preflight 'child_start_failed' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            Fail-Preflight 'child_timeout'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $discard = $stderrTask.GetAwaiter().GetResult()
        if ($stdout.Length -gt 4194304) { Fail-Preflight 'child_output_too_large' }
        if ($process.ExitCode -ne 0) { Fail-Preflight $FailureCode }
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
        if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { Fail-Preflight $MissingCode }
        return (Resolve-Path -LiteralPath $Executable).Path
    }
    $command = Get-Command -Name $Executable -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) { Fail-Preflight $UnavailableCode }
    return $command.Path
}

function Get-PackageSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $AdbPath,
        [Parameter(Mandatory = $true)][string] $Serial,
        [Parameter(Mandatory = $true)][string] $Pkg,
        [Parameter(Mandatory = $true)][string] $MissingCode
    )
    $lines = Invoke-BoundedText -FilePath $AdbPath -Arguments @('-s', $Serial, 'shell', 'dumpsys', 'package', $Pkg) -TimeoutSeconds $ProcessTimeoutSeconds -FailureCode 'adb_dumpsys_failed'
    $joined = $lines -join "`n"
    if ($joined -match '(?i)unable to find package') { Fail-Preflight $MissingCode }
    $versionMatch = [regex]::Match(
        $joined,
        '(?m)^\s*versionCode=(\d+)(?:\s+.*)?$'
    )
    if (-not $versionMatch.Success) { Fail-Preflight 'package_version_unavailable' }
    $firstInstall = Get-PackageTimeField -Dump $joined -Field 'firstInstallTime'
    $lastUpdate = Get-PackageTimeField -Dump $joined -Field 'lastUpdateTime'
    $dirMatch = [regex]::Match($joined, '(?m)^\s*dataDir=(\S+)\s*$')
    if (-not $dirMatch.Success) { Fail-Preflight 'package_datadir_unavailable' }
    $codeMatch = [regex]::Match($joined, '(?m)^\s*codePath=(\S+)\s*$')
    if (-not $codeMatch.Success) { Fail-Preflight 'package_codepath_unavailable' }
    $uidMatch = [regex]::Match($joined, '(?:userId|appId)=(\d+)')
    if (-not $uidMatch.Success) { Fail-Preflight 'package_uid_unavailable' }
    return [pscustomobject]@{
        versionCode = $versionMatch.Groups[1].Value
        firstInstallTime = $firstInstall
        lastUpdateTime = $lastUpdate
        userId = $uidMatch.Groups[1].Value
        dataDir = $dirMatch.Groups[1].Value
        codePath = $codeMatch.Groups[1].Value
    }
}

function Get-PackageTimeField {
    param([Parameter(Mandatory = $true)][string] $Dump, [Parameter(Mandatory = $true)][string] $Field)
    $m = [regex]::Match($Dump, '(?m)^\s*' + [regex]::Escape($Field) + '=(.+?)\s*$')
    if (-not $m.Success) { Fail-Preflight ('package_field_missing_' + $Field) }
    return $m.Groups[1].Value.Trim()
}

function Invoke-ApksignerPrintCerts {
    param([Parameter(Mandatory = $true)][string] $SignerPath, [Parameter(Mandatory = $true)][string] $TargetApk)
    if ($SignerPath -match '(?i)\.(bat|cmd)$') {
        $cmdLine = '""{0}" verify --verbose --print-certs "{1}""' -f $SignerPath, $TargetApk
        return Invoke-BoundedText -FilePath 'cmd.exe' -Arguments @('/d', '/c', $cmdLine) -TimeoutSeconds $ProcessTimeoutSeconds -FailureCode 'apk_signature_verify_failed'
    }
    return Invoke-BoundedText -FilePath $SignerPath -Arguments @('verify', '--verbose', '--print-certs', $TargetApk) -TimeoutSeconds $ProcessTimeoutSeconds -FailureCode 'apk_signature_verify_failed'
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) { Fail-Preflight 'powershell_7_required' }
    foreach ($f in @($ApkPath, $PackageConfig, $VmTriggerScript, $VmReadChatScript, $VmReadUploadModeScript)) {
        if (-not [System.IO.Path]::IsPathRooted($f)) { Fail-Preflight 'path_not_absolute' }
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Fail-Preflight 'file_missing' }
    }
    $actualApk = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash
    if ($actualApk -ine $ExpectedApkSha256) { Fail-Preflight 'apk_hash_mismatch' }
    $actualTrigger = (Get-FileHash -LiteralPath $VmTriggerScript -Algorithm SHA256).Hash
    if ($actualTrigger -ine $ExpectedVmTriggerSha256) { Fail-Preflight 'vm_trigger_hash_mismatch' }
    $actualChat = (Get-FileHash -LiteralPath $VmReadChatScript -Algorithm SHA256).Hash
    if ($actualChat -ine $ExpectedVmReadChatSha256) { Fail-Preflight 'vm_chat_reader_hash_mismatch' }
    $actualUpload = (Get-FileHash -LiteralPath $VmReadUploadModeScript -Algorithm SHA256).Hash
    if ($actualUpload -ine $ExpectedVmReadUploadModeSha256) { Fail-Preflight 'vm_upload_reader_hash_mismatch' }
    $adbPath = Resolve-Executable -Executable $AdbExecutable -MissingCode 'adb_executable_missing' -UnavailableCode 'adb_executable_unavailable'
    $aapt2Path = Resolve-Executable -Executable $Aapt2Executable -MissingCode 'aapt2_executable_missing' -UnavailableCode 'aapt2_executable_unavailable'
    $apksignerPath = Resolve-Executable -Executable $ApksignerExecutable -MissingCode 'apksigner_missing' -UnavailableCode 'apksigner_unavailable'
    $badging = Invoke-BoundedText -FilePath $aapt2Path -Arguments @('dump', 'badging', $ApkPath) -TimeoutSeconds $ProcessTimeoutSeconds -FailureCode 'apk_manifest_read_failed'
    $appIds = @()
    foreach ($line in $badging) {
        if ($line -match "^package: name='([^']+)'") { $appIds += $Matches[1] }
    }
    if ($appIds.Count -ne 1) { Fail-Preflight 'apk_application_id_unavailable' }
    if ($appIds[0] -cne $CanaryPackage) { Fail-Preflight 'apk_application_id_not_canary' }
    $certLines = Invoke-ApksignerPrintCerts -SignerPath $apksignerPath -TargetApk $ApkPath
    $digests = @()
    $signerHeaders = 0
    $v2Verified = $false
    foreach ($certLine in $certLines) {
        if ($certLine -match 'Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F:]+)') { $digests += $Matches[1].Replace(':', '').ToLowerInvariant() }
        if ($certLine -match 'Signer #\d+ certificate DN:') { $signerHeaders += 1 }
        if ($certLine -match '^Verified using v2 scheme(?: \([^)]*\))?:\s+true\s*$') { $v2Verified = $true }
    }
    if ($signerHeaders -ne 1 -or $digests.Count -ne 1) { Fail-Preflight 'apk_signer_count_invalid' }
    if (-not $v2Verified) { Fail-Preflight 'apk_signature_v2_missing' }
    if ($digests[0] -cne $ExpectedApkSignerSha256.ToLowerInvariant()) { Fail-Preflight 'apk_signer_mismatch' }
    $deviceState = ((Invoke-BoundedText -FilePath $adbPath -Arguments @('-s', $AdbSerial, 'get-state') -TimeoutSeconds 10 -FailureCode 'adb_state_failed') -join '').Trim()
    if ($deviceState -ne 'device') { Fail-Preflight 'device_not_ready' }
    $canary = Get-PackageSnapshot -AdbPath $adbPath -Serial $AdbSerial -Pkg $CanaryPackage -MissingCode 'canary_package_missing'
    $alpha = Get-PackageSnapshot -AdbPath $adbPath -Serial $AdbSerial -Pkg $AlphaPackage -MissingCode 'alpha_package_missing'
    if ($canary.dataDir -ceq $alpha.dataDir) { Fail-Preflight 'data_dir_not_isolated' }
    if ($canary.userId -ceq $alpha.userId) { Fail-Preflight 'uid_not_isolated' }
    if (-not [System.IO.Path]::IsPathRooted($EvidenceDirectory)) { Fail-Preflight 'evidence_path_not_absolute' }
    if (Test-Path -LiteralPath $EvidenceDirectory) {
        $existingChildren = @(Get-ChildItem -LiteralPath $EvidenceDirectory -Force)
        if ($existingChildren.Count -ne 0) { Fail-Preflight 'evidence_directory_not_empty' }
    } else {
        $null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force
    }
    $destination = Join-Path -Path $EvidenceDirectory -ChildPath 'pixel-preflight.json'
    if (Test-Path -LiteralPath $destination) { Fail-Preflight 'evidence_destination_exists' }
    $snapshot = [ordered]@{
        schemaVersion = 1
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        pins = [ordered]@{
            apkSha256 = $actualApk.ToLowerInvariant()
            apkSignerSha256 = $digests[0]
            apkSignatureV2Verified = $true
            apkSignerCount = 1
            sourceCommitCallerAttested = $ExpectedSourceCommit
            sourceCommitDeviceVerified = $false
            vmTriggerSha256 = $actualTrigger.ToLowerInvariant()
            vmReadChatSha256 = $actualChat.ToLowerInvariant()
            vmReadUploadModeSha256 = $actualUpload.ToLowerInvariant()
            apkApplicationId = $appIds[0]
            canaryPackage = $CanaryPackage
            alphaPackage = $AlphaPackage
        }
        canary = [ordered]@{
            versionCode = $canary.versionCode
            firstInstallTime = $canary.firstInstallTime
            lastUpdateTime = $canary.lastUpdateTime
            userId = $canary.userId
            codePath = $canary.codePath
            dataDir = $canary.dataDir
        }
        alpha = [ordered]@{
            versionCode = $alpha.versionCode
            firstInstallTime = $alpha.firstInstallTime
            lastUpdateTime = $alpha.lastUpdateTime
            userId = $alpha.userId
            codePath = $alpha.codePath
            dataDir = $alpha.dataDir
        }
        isolation = [ordered]@{
            dataDirDifferent = $true
            uidDifferent = $true
        }
    }
    [System.IO.File]::WriteAllText($destination, ($snapshot | ConvertTo-Json -Depth 5))
    Write-Output 'PASS preflight_ok=true signer_verified=true alpha_baseline_captured=true'
} catch {
    $safeFailure = 'preflight_unexpected_failure'
    if ($_.Exception.Message -match '^preflight_[a-z0-9_]+$') { $safeFailure = $_.Exception.Message }
    $safeType = $_.Exception.GetType().FullName -replace '[^A-Za-z0-9_.]', '_'
    $safeLine = [int]$_.InvocationInfo.ScriptLineNumber
    Write-Error ('FAIL pixel_preflight_violation code=' + $safeFailure + ' type=' + $safeType + ' line=' + $safeLine)
    exit 1
}
