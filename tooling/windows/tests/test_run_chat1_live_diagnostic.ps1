# Synthetic paths/processes only. Does not invoke the live launcher.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../run_chat1_live_diagnostic.ps1" -FunctionsOnlyForTest
function Assert-Check([bool] $Value) { if (-not $Value) { throw 'synthetic contract failed' } }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$scratch = Join-Path $tempRoot ('chat1-live-synthetic-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$mutex = $null
$child = $null
$owned = @{}
try {
    $rejected = $false
    try { & "$PSScriptRoot/../run_chat1_live_diagnostic.ps1" } catch {
        $rejected = $_.Exception.Message -eq 'chat1_live_explicit_live_enable_required'
    }
    Assert-Check $rejected
    Assert-Chat1PlainPath $scratch
    $mutex = Enter-ProfileScopedLauncherLock -ProfilePath $scratch
    $mutex.ReleaseMutex(); $mutex.Dispose(); $mutex = $null
    $mutex = Enter-ProfileScopedLauncherLock -ProfilePath $scratch
    $launch = New-CryptographicLaunchId
    Assert-Check ($launch -match '^[a-f0-9]{32}$')
    $targetFile = Join-Path $scratch 'targets.txt'
    (1..8 | ForEach-Object { ('a' * 42) + $_.ToString() }) -join ',' | Set-Content -LiteralPath $targetFile -Encoding utf8
    Assert-Check ((Assert-Chat1TargetHashes $targetFile).Split(',').Count -eq 8)
    $caseTargetFile = Join-Path $scratch 'case-targets.txt'
    $casePair = ('b' * 42) + 'A'
    $casePairLower = ('b' * 42) + 'a'
    @(
        $casePair,
        $casePairLower,
        (1..6 | ForEach-Object { ('c' * 42) + $_.ToString() })
    ) | ForEach-Object { $_ } | Join-String -Separator ',' |
        Set-Content -LiteralPath $caseTargetFile -Encoding utf8
    Assert-Check ((Assert-Chat1TargetHashes $caseTargetFile).Split(',').Count -eq 8)
    $badFile = Join-Path $scratch 'bad-targets.txt'
    'short,values' | Set-Content -LiteralPath $badFile -Encoding utf8
    $rejected = $false
    try { Assert-Chat1TargetHashes $badFile } catch {
        $rejected = $_.Exception.Message -eq 'chat1_live_target_hash_file_rejected'
    }
    Assert-Check $rejected
    $blocked = $false
    try {
        $env:OPENBUBBLES_CLOUDKIT_WRITER_OWNER = 'v2'
        Assert-Chat1NoWriterEnv
    } catch {
        $blocked = $_.Exception.Message -eq 'chat1_live_writer_env_blocked'
    } finally {
        Remove-Item Env:OPENBUBBLES_CLOUDKIT_WRITER_OWNER -ErrorAction SilentlyContinue
    }
    Assert-Check $blocked
    $report = [pscustomobject]@{
        account_bound = $true; scope = 'chat1ManateeZone'
        network_read_performed = $true; content_exposed = $false
        durable_state_unchanged = $true; completed = $true
        message_sources = 8; chat1_sources = 50; verified_chat1_records = 50
        route_field_failure_matrix_schema = 1
        route_field_failure_matrix = @(0) * 88
        paged_route_field_failure_matrix = @(0) * 88
        route_field_decode_failures = 0; paged_route_field_decode_failures = 0
        paged_pages_scanned = 4; paged_changes_scanned = 167
        paged_chat_records = 165; paged_tombstones = 2
        paged_record_decode_failures = 0
        paged_terminal_reached = $true; paged_budget_exhausted = $false
        failure_code = $null
    }
    Assert-Chat1Aggregate $report 'correlation'
    Assert-Chat1AggregateLaunch $report '0123456789abcdef0123456789abcdef'
    $report | Add-Member -NotePropertyName launch_id `
        -NotePropertyValue '0123456789abcdef0123456789abcdef'
    Assert-Chat1AggregateLaunch $report '0123456789abcdef0123456789abcdef'
    $launchRejected = $false
    try {
        Assert-Chat1AggregateLaunch $report 'fedcba9876543210fedcba9876543210'
    } catch {
        $launchRejected = $_.Exception.Message -eq
            'chat1_live_aggregate_binding_rejected'
    }
    Assert-Check $launchRejected
    $discovery = [pscustomobject]@{
        account_bound = $true; scope = 'chat1ManateeZone'
        zero_mutation_counters = $true; canonical_counts_unchanged = $true
        outbox_count_unchanged = $true; durable_state_unchanged = $false
        content_exposed = $false
    }
    $rejected = $false
    try { Assert-Chat1Aggregate $discovery 'discovery' } catch {
        $rejected = $_.Exception.Message -eq 'chat1_live_write_tripwire_rejected'
    }
    Assert-Check $rejected
    $discovery.durable_state_unchanged = $true
    Assert-Chat1Aggregate $discovery 'discovery'
    $aggregate = Copy-Chat1Aggregate $report
    Assert-Check ($aggregate['scope'] -ceq 'chat1ManateeZone' -and $aggregate['message_sources'] -eq 8)
    Assert-Check ($aggregate['route_field_failure_matrix'].Count -eq 88 -and
        $aggregate['paged_route_field_failure_matrix'].Count -eq 88)
    $identityStart = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    Add-Chat1TestHostIdentity -Start $identityStart -BuildIdentifier '0123456789ab'
    Assert-Check ($identityStart.Environment['OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST'] -ceq '1')
    Assert-Check (@($identityStart.ArgumentList) -contains
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE=true')
    Assert-Check (@($identityStart.ArgumentList) -contains
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true')
    Assert-Check (@($identityStart.ArgumentList) -contains
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true')
    Assert-Check (@($identityStart.ArgumentList) -contains
        '--dart-define=OPENBUBBLES_BUILD_COMMIT=0123456789ab')
    $badIdentityRejected = $false
    try {
        Add-Chat1TestHostIdentity -Start $identityStart -BuildIdentifier 'dirty-build'
    } catch {
        $badIdentityRejected = $_.Exception.Message -eq
            'chat1_live_build_identifier_rejected'
    }
    Assert-Check $badIdentityRejected
    $exe = (Get-Process -Id $PID).Path
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $childCommand = "& '$exe' -NoProfile -Command 'Start-Sleep -Seconds 30'"
    foreach ($argument in @('-NoProfile', '-Command', $childCommand)) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($start)
    $null = $child.Handle
    $owned = @{ ([int]$child.Id) = @{ Process = $child; Path = $exe; Started = $child.StartTime.ToUniversalTime() } }
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while ($owned.Count -lt 2 -and [datetime]::UtcNow -lt $deadline) {
        Add-Chat1OwnedChildren $owned @($exe)
        Start-Sleep -Milliseconds 100
    }
    Assert-Check ($owned.Count -eq 2 -and -not $owned.ContainsKey($PID))
    Stop-Chat1OwnedProcesses $owned
    Assert-Check (@($owned.Values | Where-Object { -not $_.Process.HasExited }).Count -eq 0)
    Write-Host 'Chat1 synthetic enable, writer blocklist, target-hash, aggregate, mutex, descendant ownership and cleanup checks passed.'
} finally {
    if ($owned.Count -gt 0) {
        Stop-Chat1OwnedProcesses $owned
        foreach ($entry in $owned.Values) { $entry.Process.Dispose() }
    }
    if ($null -ne $child) {
        if (-not $child.HasExited) { Stop-ExactLaunchedHarness $child $exe }
        $child.Dispose()
    }
    if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
    Remove-Item -LiteralPath (Join-Path $scratch 'targets.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $scratch 'bad-targets.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $scratch 'case-targets.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch
}
