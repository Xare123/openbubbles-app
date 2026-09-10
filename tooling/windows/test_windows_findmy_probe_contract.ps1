[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$launcher = Join-Path $PSScriptRoot 'run_cloud_sync_v2_dev.ps1'
. $launcher -FunctionsOnlyForTest

function Assert-FindMyContract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

foreach ($conflict in @('LocalWrite', 'RunOnce', 'ReplayExcludedChats', 'BuildOnly')) {
    $options = @{ FunctionsOnlyForTest = $true; FindMyProbe = $true }
    $options[$conflict] = $true
    $rejected = $false
    try { & $launcher @options } catch { $rejected = $true }
    Assert-FindMyContract $rejected "FindMy accepted conflicting option $conflict"
}
& $launcher -FunctionsOnlyForTest -FindMyProbe -SkipBuild
$values = (Get-Command Wait-HarnessOperation).Parameters['ExpectedOperation'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
Assert-FindMyContract ($values.ValidValues -contains 'findmy-probe') 'Missing validated operation'

# Synthetic status only. Never start an app, compiler, native library or network.
$testRoot = Join-Path $PSScriptRoot '../../build'
$scratch = New-Item -ItemType Directory -Path (
    Join-Path $testRoot ('findmy-contract-' + [guid]::NewGuid().ToString('N')))
try {
    $statusFile = Join-Path $scratch.FullName 'status.json'
    $launch = '0123456789abcdef0123456789abcdef'
    $build = '4388109691ce-dirty-0123456789ab'
    $payload = @{
        version = 'cloud-sync-v2-windows-harness-status-v2'
        launch_id = $launch; process_id = $PID; build_identifier = $build
        state = 'failed'; stage = 'findmy-probe-preflight'
        safe_code = 'findmy_probe_preflight_rejected'
        updated_utc = [datetime]::UtcNow.ToString('o')
    }
    $payload | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
    $read = @{
        StatusPath = $statusFile; LaunchStartedUtc = [datetime]::UtcNow.AddSeconds(-1)
        BaselineWriteUtc = [datetime]::MinValue; ExpectedLaunchId = $launch
        ExpectedProcessId = $PID; ExpectedBuildIdentifier = $build
    }
    Assert-FindMyContract ($null -ne (Read-FreshHarnessStatus @read)) 'Current status rejected'
    $read.ExpectedBuildIdentifier = 'cf8ae21b61ea-dirty-b3f4575d0e4c'
    Assert-FindMyContract ($null -eq (Read-FreshHarnessStatus @read)) 'Stale build accepted'
    $read.ExpectedBuildIdentifier = $build
    $read.ExpectedLaunchId = 'ffffffffffffffffffffffffffffffff'
    Assert-FindMyContract ($null -eq (Read-FreshHarnessStatus @read)) 'Other launch accepted'
    $read.ExpectedLaunchId = $launch
    $read.ExpectedProcessId = $PID + 1
    Assert-FindMyContract ($null -eq (Read-FreshHarnessStatus @read)) 'Other process accepted'
    $read.ExpectedProcessId = $PID
    $payload.Remove('build_identifier')
    $payload | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
    Assert-FindMyContract ($null -eq (Read-FreshHarnessStatus @read)) 'Unbound build accepted'
    $payload.build_identifier = $build
    $payload.state = 'finished'
    $payload.stage = 'findmy-probe-complete'
    $report = @{
        version = 'windows-findmy-probe-v1'; launch_id = $launch
        build_identifier = $build; live_reads_admitted = $true
        devices = @{ state = 'observed'; fresh_request_completed = $true }
        people = @{ state = 'observed'; fresh_request_completed = $true }
        selected = @{ requested = $false }
    }
    $payload.detail = $report | ConvertTo-Json -Depth 5 -Compress
    $payload | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
    Assert-FindMyContract ($null -ne (Read-FreshHarnessStatus @read)) 'Completed real-read evidence rejected'
    $report.devices.state = 'failed'
    $report.devices.fresh_request_completed = $false
    $payload.detail = $report | ConvertTo-Json -Depth 5 -Compress
    $payload | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
    Assert-FindMyContract ($null -eq (Read-FreshHarnessStatus @read)) 'Partial evidence called complete'
    $payload.stage = 'findmy-probe-partial'
    $payload | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
    Assert-FindMyContract ($null -ne (Read-FreshHarnessStatus @read)) 'Partial read evidence rejected'
    $report.people.fresh_request_completed = $false
    $payload.detail = $report | ConvertTo-Json -Depth 5 -Compress
    $payload | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
    Assert-FindMyContract ($null -eq (Read-FreshHarnessStatus @read)) 'Cache-only evidence called finished'
} finally {
    # Exact synthetic test artifacts only; no recursive profile cleanup.
    if (Test-Path -LiteralPath $statusFile) { Remove-Item -LiteralPath $statusFile }
    Remove-Item -LiteralPath $scratch.FullName
}
Write-Host 'FindMy launcher contract checks passed (no live execution).'
