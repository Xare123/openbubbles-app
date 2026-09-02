[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$launcher = Join-Path $PSScriptRoot 'run_cloud_sync_v2_dev.ps1'
. $launcher -FunctionsOnlyForTest

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Start-TestHarnessProcess {
    param([Parameter(Mandatory)][string] $Executable)

    return Start-Process `
        -FilePath $Executable `
        -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') `
        -WindowStyle Hidden `
        -PassThru
}

function Write-TestHarnessStatus {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $LaunchId,
        [Parameter(Mandatory)][int] $ProcessId,
        [Parameter(Mandatory)][string] $State,
        [Parameter(Mandatory)][string] $Stage
    )

    [ordered]@{
        version = 'cloud-sync-v2-windows-harness-status-v2'
        launch_id = $LaunchId
        process_id = $ProcessId
        state = $State
        stage = $Stage
        updated_utc = [datetime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock] $Action)

    try {
        & $Action
    }
    catch {
        return $_.Exception.Message
    }
    throw 'Expected the operation to fail.'
}

$hostProcess = Get-CimInstance Win32_Process -Filter (
    "ProcessId = {0}" -f $PID
) | Select-Object -First 1
if ($null -eq $hostProcess -or
    [string]::IsNullOrWhiteSpace($hostProcess.ExecutablePath)) {
    throw 'Could not resolve the PowerShell test host executable.'
}
$testExecutable = [System.IO.Path]::GetFullPath($hostProcess.ExecutablePath)
$tempRoot = (
    [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
)
$testDirectory = Join-Path $tempRoot (
    'openbubbles-cloud-sync-launcher-test-' + [guid]::NewGuid().ToString('N')
)
$testDirectory = [System.IO.Path]::GetFullPath($testDirectory)
if (-not $testDirectory.StartsWith(
    "$tempRoot\",
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The launcher test directory escaped the system temporary root.'
}
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$children = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

try {
    $firstLaunchId = New-CryptographicLaunchId
    $secondLaunchId = New-CryptographicLaunchId
    Assert-True `
        -Condition ($firstLaunchId -match '^[a-f0-9]{32}$') `
        -Message 'The launch ID did not match the 128-bit hexadecimal contract.'
    Assert-True `
        -Condition ($firstLaunchId -ne $secondLaunchId) `
        -Message 'Two cryptographic launch IDs unexpectedly matched.'

    $receiptRunner = Join-Path $testDirectory 'runner.bin'
    $receiptLibrary = Join-Path $testDirectory 'library.bin'
    $receiptPath = Join-Path $testDirectory 'build-receipt.json'
    Set-Content -LiteralPath $receiptRunner -Value 'runner-v1' -Encoding UTF8
    Set-Content -LiteralPath $receiptLibrary -Value 'library-v1' -Encoding UTF8
    Write-HarnessBuildReceipt `
        -ReceiptPath $receiptPath `
        -BuildIdentifier 'test-build-v1' `
        -Runner $receiptRunner `
        -RustLibrary $receiptLibrary
    Write-HarnessBuildReceipt `
        -ReceiptPath $receiptPath `
        -BuildIdentifier 'test-build-v1' `
        -Runner $receiptRunner `
        -RustLibrary $receiptLibrary
    Assert-True `
        -Condition (Test-HarnessBuildReceipt `
            -ReceiptPath $receiptPath `
            -BuildIdentifier 'test-build-v1' `
            -Runner $receiptRunner `
            -RustLibrary $receiptLibrary
        ) `
        -Message 'A matching build receipt was rejected.'
    Assert-True `
        -Condition (-not (Test-HarnessBuildReceipt `
            -ReceiptPath $receiptPath `
            -BuildIdentifier 'test-build-v2' `
            -Runner $receiptRunner `
            -RustLibrary $receiptLibrary
        )) `
        -Message 'A receipt for a different source build was accepted.'
    Set-Content -LiteralPath $receiptRunner -Value 'runner-v2' -Encoding UTF8
    Assert-True `
        -Condition (-not (Test-HarnessBuildReceipt `
            -ReceiptPath $receiptPath `
            -BuildIdentifier 'test-build-v1' `
            -Runner $receiptRunner `
            -RustLibrary $receiptLibrary
        )) `
        -Message 'A receipt accepted a modified executable.'

    $reportDirectory = Join-Path $testDirectory 'reports'
    New-Item -ItemType Directory -Path $reportDirectory | Out-Null
    $readOnlyReportPath = Join-Path `
        $reportDirectory `
        'obcs2-semantic-100.json'
    $projectionReportPath = Join-Path `
        $reportDirectory `
        'obcs2-semantic-200.json'
    [ordered]@{
        mode = 'manual-semantic-read-only-cloudkit'
        buildCommit = 'test-build-v1'
    } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath $readOnlyReportPath -Encoding UTF8
    [ordered]@{
        mode = 'manual-semantic-local-projection-sweep'
        buildCommit = 'test-build-v1'
    } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath $projectionReportPath -Encoding UTF8
    $readOnlyWriteUtc = [datetime]::UtcNow.AddMinutes(-2)
    (Get-Item -LiteralPath $readOnlyReportPath).LastWriteTimeUtc =
        $readOnlyWriteUtc
    (Get-Item -LiteralPath $projectionReportPath).LastWriteTimeUtc =
        $readOnlyWriteUtc.AddMinutes(1)
    $selectedReport = Find-LatestReadOnlyHarnessReport `
        -ReportDirectory $reportDirectory `
        -NotOlderThanUtc $readOnlyWriteUtc.AddSeconds(-1)
    Assert-True `
        -Condition ($null -ne $selectedReport -and
            $selectedReport.File.FullName -eq $readOnlyReportPath) `
        -Message (
            'A newer projection report hid the matching read-only report.'
        )
    $staleReport = Find-LatestReadOnlyHarnessReport `
        -ReportDirectory $reportDirectory `
        -NotOlderThanUtc $readOnlyWriteUtc.AddSeconds(1)
    Assert-True `
        -Condition ($null -eq $staleReport) `
        -Message 'A stale read-only report was accepted.'

    $launcherSource = Get-Content -LiteralPath $launcher -Raw
    $processChecks = [regex]::Matches(
        $launcherSource,
        '(?m)^\s{4}Stop-StoreOpenBubbles -StoreExecutable \$storeExecutable\s*$'
    )
    $buildInvocation = $launcherSource.IndexOf(
        '& $flutter @arguments',
        [System.StringComparison]::Ordinal
    )
    Assert-True `
        -Condition ($processChecks.Count -eq 2 -and
            $processChecks[0].Index -lt $buildInvocation -and
            $buildInvocation -lt $processChecks[1].Index) `
        -Message (
            'The launcher must reject a retained harness before rebuilding ' +
            'and recheck immediately before launch.'
        )

    $lockProfile = Join-Path $testDirectory 'profile'
    $profileLock = Enter-ProfileScopedLauncherLock -ProfilePath $lockProfile
    try {
        $escapedLauncher = $launcher.Replace("'", "''")
        $escapedProfile = $lockProfile.Replace("'", "''")
        $contenderCommand = (
            ". '$escapedLauncher' -FunctionsOnlyForTest; " +
            "try { `$lock = Enter-ProfileScopedLauncherLock " +
            "-ProfilePath '$escapedProfile'; exit 0 } catch { exit 23 }"
        )
        $encodedCommand = [System.Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes($contenderCommand)
        )
        $contender = Start-Process `
            -FilePath $testExecutable `
            -ArgumentList @('-NoProfile', '-EncodedCommand', $encodedCommand) `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        Assert-True `
            -Condition ($contender.ExitCode -eq 23) `
            -Message 'A simultaneous launcher acquired the same profile lock.'
        $contender.Dispose()
    }
    finally {
        $profileLock.ReleaseMutex()
        $profileLock.Dispose()
    }
    $releasedLock = Enter-ProfileScopedLauncherLock -ProfilePath $lockProfile
    $releasedLock.ReleaseMutex()
    $releasedLock.Dispose()

    $timeoutProcess = Start-TestHarnessProcess -Executable $testExecutable
    $children.Add($timeoutProcess)
    $timeoutMessage = Invoke-ExpectedFailure {
        Wait-HarnessOperation `
            -Process $timeoutProcess `
            -ExpectedExecutable $testExecutable `
            -StatusPath (Join-Path $testDirectory 'missing-status.json') `
            -LaunchStartedUtc ([datetime]::UtcNow) `
            -BaselineWriteUtc ([datetime]::MinValue) `
            -ExpectedLaunchId $firstLaunchId `
            -ExpectedOperation drain `
            -TimeoutSeconds 1
    }
    Assert-True `
        -Condition ($timeoutMessage -eq (
            'Timed out waiting for the Windows harness terminal status; ' +
            'the harness remains running.'
        )) `
        -Message 'The timeout did not return the fixed content-free failure.'
    $timeoutProcess.Refresh()
    Assert-True `
        -Condition (-not $timeoutProcess.HasExited) `
        -Message 'A timeout stopped the active harness process.'

    $mismatchProcess = Start-TestHarnessProcess -Executable $testExecutable
    $children.Add($mismatchProcess)
    $mismatchPath = Join-Path $testDirectory 'mismatch-status.json'
    Write-TestHarnessStatus `
        -Path $mismatchPath `
        -LaunchId $secondLaunchId `
        -ProcessId $mismatchProcess.Id `
        -State finished `
        -Stage semantic-drain-complete
    $mismatchMessage = Invoke-ExpectedFailure {
        Wait-HarnessOperation `
            -Process $mismatchProcess `
            -ExpectedExecutable $testExecutable `
            -StatusPath $mismatchPath `
            -LaunchStartedUtc ([datetime]::UtcNow.AddSeconds(-1)) `
            -BaselineWriteUtc ([datetime]::MinValue) `
            -ExpectedLaunchId $firstLaunchId `
            -ExpectedOperation drain `
            -TimeoutSeconds 1
    }
    Assert-True `
        -Condition ($mismatchMessage -like 'Timed out waiting*') `
        -Message 'A mismatched launch ID was accepted.'
    $mismatchProcess.Refresh()
    Assert-True `
        -Condition (-not $mismatchProcess.HasExited) `
        -Message 'A mismatched status stopped the active harness process.'

    $pidMismatchProcess = Start-TestHarnessProcess -Executable $testExecutable
    $children.Add($pidMismatchProcess)
    $pidMismatchPath = Join-Path $testDirectory 'pid-mismatch-status.json'
    Write-TestHarnessStatus `
        -Path $pidMismatchPath `
        -LaunchId $firstLaunchId `
        -ProcessId ($pidMismatchProcess.Id + 1) `
        -State finished `
        -Stage semantic-drain-complete
    $pidMismatchMessage = Invoke-ExpectedFailure {
        Wait-HarnessOperation `
            -Process $pidMismatchProcess `
            -ExpectedExecutable $testExecutable `
            -StatusPath $pidMismatchPath `
            -LaunchStartedUtc ([datetime]::UtcNow.AddSeconds(-1)) `
            -BaselineWriteUtc ([datetime]::MinValue) `
            -ExpectedLaunchId $firstLaunchId `
            -ExpectedOperation drain `
            -TimeoutSeconds 1
    }
    Assert-True `
        -Condition ($pidMismatchMessage -like 'Timed out waiting*') `
        -Message 'A mismatched process ID was accepted.'
    $pidMismatchProcess.Refresh()
    Assert-True `
        -Condition (-not $pidMismatchProcess.HasExited) `
        -Message 'A PID-mismatched status stopped the active harness process.'

    $waitingProcess = Start-TestHarnessProcess -Executable $testExecutable
    $children.Add($waitingProcess)
    $waitingPath = Join-Path $testDirectory 'waiting-status.json'
    Write-TestHarnessStatus `
        -Path $waitingPath `
        -LaunchId $firstLaunchId `
        -ProcessId $waitingProcess.Id `
        -State waiting-user `
        -Stage sms-2fa
    Wait-HarnessOperation `
        -Process $waitingProcess `
        -ExpectedExecutable $testExecutable `
        -StatusPath $waitingPath `
        -LaunchStartedUtc ([datetime]::UtcNow.AddSeconds(-1)) `
        -BaselineWriteUtc ([datetime]::MinValue) `
        -ExpectedLaunchId $firstLaunchId `
        -ExpectedOperation drain `
        -TimeoutSeconds 5
    $waitingProcess.Refresh()
    Assert-True `
        -Condition (-not $waitingProcess.HasExited) `
        -Message 'A waiting-user status stopped the harness process.'

    $resumableProcess = Start-TestHarnessProcess -Executable $testExecutable
    $children.Add($resumableProcess)
    $resumablePath = Join-Path $testDirectory 'resumable-status.json'
    Write-TestHarnessStatus `
        -Path $resumablePath `
        -LaunchId $firstLaunchId `
        -ProcessId $resumableProcess.Id `
        -State resumable `
        -Stage semantic-drain-pass-limit
    $resumableMessage = Invoke-ExpectedFailure {
        Wait-HarnessOperation `
            -Process $resumableProcess `
            -ExpectedExecutable $testExecutable `
            -StatusPath $resumablePath `
            -LaunchStartedUtc ([datetime]::UtcNow.AddSeconds(-1)) `
            -BaselineWriteUtc ([datetime]::MinValue) `
            -ExpectedLaunchId $firstLaunchId `
            -ExpectedOperation drain `
            -TimeoutSeconds 5
    }
    Assert-True `
        -Condition ($resumableMessage -eq (
            'Cloud Sync V2 Windows drain reached its safe pass limit ' +
            'and remains resumable.'
        )) `
        -Message 'Pass-limit did not produce the fixed resumable failure.'
    $resumableProcess.Refresh()
    Assert-True `
        -Condition $resumableProcess.HasExited `
        -Message 'The terminal resumable harness was not closed.'

    $invalidFinishedProcess = Start-TestHarnessProcess -Executable $testExecutable
    $children.Add($invalidFinishedProcess)
    $invalidFinishedPath = Join-Path $testDirectory 'invalid-finished.json'
    Write-TestHarnessStatus `
        -Path $invalidFinishedPath `
        -LaunchId $firstLaunchId `
        -ProcessId $invalidFinishedProcess.Id `
        -State finished `
        -Stage semantic-drain-pass-limit
    $invalidFinishedMessage = Invoke-ExpectedFailure {
        Wait-HarnessOperation `
            -Process $invalidFinishedProcess `
            -ExpectedExecutable $testExecutable `
            -StatusPath $invalidFinishedPath `
            -LaunchStartedUtc ([datetime]::UtcNow.AddSeconds(-1)) `
            -BaselineWriteUtc ([datetime]::MinValue) `
            -ExpectedLaunchId $firstLaunchId `
            -ExpectedOperation drain `
            -TimeoutSeconds 5
    }
    Assert-True `
        -Condition ($invalidFinishedMessage -eq (
            'Cloud Sync V2 Windows harness reported an invalid terminal stage.'
        )) `
        -Message 'A generic finished pass-limit status was accepted.'

    $finishedProcess = Start-TestHarnessProcess -Executable $testExecutable
    $children.Add($finishedProcess)
    $finishedPath = Join-Path $testDirectory 'finished-status.json'
    Write-TestHarnessStatus `
        -Path $finishedPath `
        -LaunchId $firstLaunchId `
        -ProcessId $finishedProcess.Id `
        -State finished `
        -Stage semantic-drain-complete
    Wait-HarnessOperation `
        -Process $finishedProcess `
        -ExpectedExecutable $testExecutable `
        -StatusPath $finishedPath `
        -LaunchStartedUtc ([datetime]::UtcNow.AddSeconds(-1)) `
        -BaselineWriteUtc ([datetime]::MinValue) `
        -ExpectedLaunchId $firstLaunchId `
        -ExpectedOperation drain `
        -TimeoutSeconds 5
    $finishedProcess.Refresh()
    Assert-True `
        -Condition $finishedProcess.HasExited `
        -Message 'The verified terminal harness was not closed.'

    $runOnceProcess = Start-TestHarnessProcess -Executable $testExecutable
    $children.Add($runOnceProcess)
    $runOncePath = Join-Path $testDirectory 'run-once-finished-status.json'
    Write-TestHarnessStatus `
        -Path $runOncePath `
        -LaunchId $firstLaunchId `
        -ProcessId $runOnceProcess.Id `
        -State finished `
        -Stage semantic-pull
    Wait-HarnessOperation `
        -Process $runOnceProcess `
        -ExpectedExecutable $testExecutable `
        -StatusPath $runOncePath `
        -LaunchStartedUtc ([datetime]::UtcNow.AddSeconds(-1)) `
        -BaselineWriteUtc ([datetime]::MinValue) `
        -ExpectedLaunchId $firstLaunchId `
        -ExpectedOperation run-once `
        -TimeoutSeconds 5
    $runOnceProcess.Refresh()
    Assert-True `
        -Condition $runOnceProcess.HasExited `
        -Message 'The verified run-once harness was not closed.'

    $attachmentProcess = Start-TestHarnessProcess -Executable $testExecutable
    $children.Add($attachmentProcess)
    $attachmentPath = Join-Path `
        $testDirectory `
        'attachment-probe-finished-status.json'
    Write-TestHarnessStatus `
        -Path $attachmentPath `
        -LaunchId $firstLaunchId `
        -ProcessId $attachmentProcess.Id `
        -State finished `
        -Stage attachment-probe-complete
    Wait-HarnessOperation `
        -Process $attachmentProcess `
        -ExpectedExecutable $testExecutable `
        -StatusPath $attachmentPath `
        -LaunchStartedUtc ([datetime]::UtcNow.AddSeconds(-1)) `
        -BaselineWriteUtc ([datetime]::MinValue) `
        -ExpectedLaunchId $firstLaunchId `
        -ExpectedOperation attachment-probe `
        -TimeoutSeconds 5
    $attachmentProcess.Refresh()
    Assert-True `
        -Condition $attachmentProcess.HasExited `
        -Message 'The verified attachment probe harness was not closed.'

    Write-Host 'Cloud Sync V2 Windows launcher behavioral tests passed.'
}
finally {
    foreach ($child in $children) {
        $child.Refresh()
        if (-not $child.HasExited) {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $child.Id -Timeout 5 -ErrorAction SilentlyContinue
        }
        $child.Dispose()
    }
    if (Test-Path -LiteralPath $testDirectory -PathType Container) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}
