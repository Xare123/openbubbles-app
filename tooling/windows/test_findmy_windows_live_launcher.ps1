# Synthetic paths/processes only. Does not invoke the live launcher.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/run_findmy_windows_live.ps1" -FunctionsOnlyForTest
function Assert-Check([bool] $Value) { if (-not $Value) { throw 'synthetic contract failed' } }
$scratch = Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot/../../build")) ('findmy-launcher-synthetic-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$mutex = $null
$child = $null
$owned = @{}
$sdkOwned = @{}
$unrelatedOwned = @{}
try {
    $selectionEnvironment = @{ OPENBUBBLES_FINDMY_SELECT_SOLE_PERSON = '1' }
    Set-FindMySelectionOption $selectionEnvironment $false
    Assert-Check (-not $selectionEnvironment.ContainsKey('OPENBUBBLES_FINDMY_SELECT_SOLE_PERSON'))
    Set-FindMySelectionOption $selectionEnvironment $true
    Assert-Check ($selectionEnvironment['OPENBUBBLES_FINDMY_SELECT_SOLE_PERSON'] -ceq '1')
    $rejected = $false
    try { & "$PSScriptRoot/run_findmy_windows_live.ps1" } catch {
        $rejected = $_.Exception.Message -eq 'findmy_testhost_explicit_live_enable_required'
    }
    Assert-Check $rejected
    Assert-FindMyPlainPath $scratch
    $mutex = Enter-ProfileScopedLauncherLock -ProfilePath $scratch
    $mutexName = 'Local\OpenBubblesCloudSyncV2Launcher-' + (Get-Sha256Hex ([IO.Path]::GetFullPath($scratch).TrimEnd('\').ToUpperInvariant()))
    # A separate PowerShell process must fail to acquire the same synthetic lock.
    $code = '$m=[Threading.Mutex]::new($false,"' + $mutexName + '"); if($m.WaitOne(0)){ $m.ReleaseMutex(); exit 7 }; $m.Dispose(); exit 0'
    & (Get-Process -Id $PID).Path -NoProfile -Command $code
    Assert-Check ($LASTEXITCODE -eq 0)
    $mutex.ReleaseMutex(); $mutex.Dispose(); $mutex = $null
    # Reacquisition confirms release without touching any real profile.
    $mutex = Enter-ProfileScopedLauncherLock -ProfilePath $scratch
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
        Add-FindMyOwnedChildren $owned @($exe)
        Start-Sleep -Milliseconds 100
    }
    Assert-Check ($owned.Count -eq 2 -and -not $owned.ContainsKey($PID))
    $rejected = $false
    try { Stop-ExactLaunchedHarness $child 'C:\synthetic-wrong-executable.exe' } catch { $rejected = $true }
    Assert-Check ($rejected -and -not $child.HasExited)
    Stop-FindMyOwnedProcesses $owned
    Assert-Check (@($owned.Values | Where-Object { -not $_.Process.HasExited }).Count -eq 0)
    # Real installed Dart dispatcher, entirely synthetic code. Four-process
    # chain: dart -> dartvm -> dart -> dartvm. Also start an unrelated sibling
    # with the same exact SDK path to prove basename/path alone cannot admit it.
    $sdkPaths = @(Get-FindMySdkExecutables $FlutterRoot)
    $dart = $sdkPaths | Where-Object { [IO.Path]::GetFileName($_) -eq 'dart.exe' }
    $tester = $sdkPaths | Where-Object { [IO.Path]::GetFileName($_) -eq 'flutter_tester.exe' }
    $fixture = [IO.Path]::GetFullPath("$PSScriptRoot/fixtures/findmy_process_fixture.dart")
    foreach ($scope in @('descendant', 'unrelated')) {
        $info = [Diagnostics.ProcessStartInfo]::new($dart)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        foreach ($key in @($info.Environment.Keys)) {
            if ($key -like 'OPENBUBBLES_*') { $null = $info.Environment.Remove($key) }
        }
        $info.ArgumentList.Add($fixture)
        if ($scope -eq 'descendant') {
            $info.ArgumentList.Add('spawn'); $info.ArgumentList.Add($dart)
        }
        $instance = [Diagnostics.Process]::Start($info)
        $null = $instance.Handle
        $entry = @{ Process = $instance; Path = $dart; Started = $instance.StartTime.ToUniversalTime() }
        if ($scope -eq 'descendant') { $sdkOwned[[int]$instance.Id] = $entry; $sdkRoot = $entry }
        else { $unrelatedOwned[[int]$instance.Id] = $entry }
    }
    $deadline = [datetime]::UtcNow.AddSeconds(8)
    while (($sdkOwned.Count -lt 4 -or $unrelatedOwned.Count -lt 2) -and [datetime]::UtcNow -lt $deadline) {
        Add-FindMyOwnedChildren $sdkOwned $sdkPaths
        Add-FindMyOwnedChildren $unrelatedOwned $sdkPaths
        Start-Sleep -Milliseconds 100
    }
    Assert-Check ($sdkOwned.Count -eq 4 -and $unrelatedOwned.Count -eq 2)
    $oldOwned = @{ ([int]$sdkRoot.Process.Id) = $sdkRoot }
    Add-FindMyOwnedChildren $oldOwned @($dart, $tester)
    Assert-Check ($oldOwned.Count -eq 1) # Reproduces the old root-only bug.
    $leaf = $sdkOwned.Values | Sort-Object Started -Descending | Select-Object -First 1
    $outside = $unrelatedOwned.Values | Sort-Object Started -Descending | Select-Object -First 1
    Assert-Check ([IO.Path]::GetFileName($leaf.Path) -eq 'dartvm.exe')
    $launch = '0123456789abcdef0123456789abcdef'
    $ready = @{ launch_id = $launch; process_id = $leaf.Process.Id }
    Assert-Check (Test-FindMyReadyProcess $ready $launch $sdkOwned $leaf.Path)
    Assert-Check (-not (Test-FindMyReadyProcess $ready $launch $sdkOwned $tester))
    Assert-Check (-not (Test-FindMyReadyProcess $ready ('b' * 32) $sdkOwned $leaf.Path))
    Assert-Check (-not (Test-FindMyReadyProcess @{ launch_id = $launch; process_id = $outside.Process.Id } $launch $sdkOwned $leaf.Path))
    foreach ($set in @($sdkOwned, $unrelatedOwned)) {
        Stop-FindMyOwnedProcesses $set
        Assert-Check (@($set.Values | Where-Object { -not $_.Process.HasExited }).Count -eq 0)
    }
    Write-Host 'Real SDK synthetic dart -> dartvm -> dart -> dartvm chain passed; old root-only bug reproduced; unrelated PID and wrong tester rejected; all fixture processes exited.'
    Write-Host 'FindMy synthetic enable, mutex, descendant ownership, wrong-process rejection and cleanup checks passed.'
} finally {
    foreach ($set in @($sdkOwned, $unrelatedOwned)) {
        if ($set.Count -gt 0) {
            Stop-FindMyOwnedProcesses $set
            foreach ($entry in $set.Values) { $entry.Process.Dispose() }
        }
    }
    if ($owned.Count -gt 0) {
        Stop-FindMyOwnedProcesses $owned
        foreach ($entry in $owned.Values) { if ($entry.Process.Id -ne $child.Id) { $entry.Process.Dispose() } }
    }
    if ($null -ne $child) {
        if (-not $child.HasExited) { Stop-ExactLaunchedHarness $child $child.MainModule.FileName }
        $child.Dispose()
    }
    if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
    # Empty exact synthetic directory only, never a profile or recursive delete.
    Remove-Item -LiteralPath $scratch
}
