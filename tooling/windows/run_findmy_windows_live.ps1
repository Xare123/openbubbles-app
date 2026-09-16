# Parent-invoked only. No build, receipt relabel, app launch, or policy change.
# PowerShell 7 is required for ArgumentList and asynchronous pipe draining.
[CmdletBinding()]
param(
    [switch] $EnableLive,
    [switch] $SelectSolePerson,
    [switch] $FunctionsOnlyForTest,
    [string] $FlutterRoot = 'C:\Codex\Toolchains\flutter-3.44.8-arm64',
    [string] $PythonExecutable = 'C:\Users\ramia\AppData\Local\Python\pythoncore-3.14-64\python.exe',
    [string] $NativeRuntime = (Join-Path $env:APPDATA 'OpenBubbles\cloudkit-v2-dev\cloud-sync-v2\native-test-host'),
    [ValidateRange(30, 180)][int] $TimeoutSeconds = 150
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$functionsOnly = $FunctionsOnlyForTest
# Reuse the exact mutex naming and exact-process stop checks. This mode returns
# before the parent launcher's profile, build, receipt, or operation code.
. "$PSScriptRoot/run_cloud_sync_v2_dev.ps1" -FunctionsOnlyForTest -FlutterRoot $FlutterRoot

function Set-FindMySelectionOption($Environment, [bool] $Enabled) {
    $null = $Environment.Remove('OPENBUBBLES_FINDMY_SELECT_SOLE_PERSON')
    if ($Enabled) { $Environment['OPENBUBBLES_FINDMY_SELECT_SOLE_PERSON'] = '1' }
}

function Assert-FindMyPlainPath([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'findmy_testhost_reparse_path_rejected'
        }
        $parent = [IO.Path]::GetDirectoryName($item.FullName.TrimEnd('\'))
        if (-not $parent -or $parent -eq $item.FullName) { break }
        $item = Get-Item -LiteralPath $parent -Force
    }
}

function Assert-FindMyArtifact([string] $Library) {
    Assert-FindMyPlainPath $Library
    $hash = (Get-FileHash -LiteralPath $Library -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne '4bd6bf205090625c980cf68666f6e39deb1b475d89e757d87b03d99346832d9a') {
        throw 'findmy_testhost_native_hash_rejected'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Library
    if ($signature.Status -ne 'Valid') { throw 'findmy_testhost_signature_rejected' }
    return @{ sha256 = $hash; signature_status = 'Valid'; signer = $signature.SignerCertificate.Thumbprint }
}

function Get-FindMySdkExecutables([string] $SdkRoot) {
    # dart.exe is a dispatcher in this SDK. Track only these exact installed
    # runtime paths through real ParentProcessId edges, never by basename.
    foreach ($relative in @('bin/cache/dart-sdk/bin/dart.exe',
        'bin/cache/dart-sdk/bin/dartvm.exe',
        'bin/cache/dart-sdk/bin/dartaotruntime.exe',
        'bin/cache/artifacts/engine/windows-arm64/flutter_tester.exe')) {
        $executable = [IO.Path]::GetFullPath((Join-Path $SdkRoot $relative))
        Assert-FindMyPlainPath $executable
        $executable
    }
}

function Test-FindMyReadyProcess($Ready, [string] $Launch, $Owned, [string] $TesterPath) {
    try {
        if ($null -eq $Ready -or $Ready.launch_id -cne $Launch -or
            -not $Owned.ContainsKey([int]$Ready.process_id)) { return $false }
        $entry = $Owned[[int]$Ready.process_id]
        $entry.Process.Refresh()
        return $entry.Path -ieq $TesterPath -and -not $entry.Process.HasExited
    } catch { return $false }
}

function Add-FindMyOwnedChildren($Owned, [string[]] $AllowedExecutables) {
    # Only direct descendants of recorded process instances are admitted.
    # A separate ready/go handshake prevents an unrecorded test from using FFI.
    foreach ($parent in @($Owned.Values)) {
        $parent.Process.Refresh()
        if ($parent.Process.HasExited) { continue }
        foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($parent.Process.Id)")) {
            if ($Owned.ContainsKey([int]$child.ProcessId)) { continue }
            if ([string]::IsNullOrWhiteSpace($child.ExecutablePath)) { continue }
            $childPath = [IO.Path]::GetFullPath($child.ExecutablePath)
            if ($childPath -notin $AllowedExecutables) { continue }
            $process = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
            if ($null -eq $process) { continue }
            # Retain the process handle/start time, not just a reusable PID.
            $null = $process.Handle
            if ($process.StartTime.ToUniversalTime() -lt $parent.Started) { $process.Dispose(); continue }
            # Bind the OS ancestry observation to this retained process instance.
            if ([math]::Abs(($process.StartTime.ToUniversalTime() - $child.CreationDate.ToUniversalTime()).TotalMilliseconds) -gt 1) {
                $process.Dispose(); continue
            }
            $Owned[[int]$process.Id] = @{
                Process = $process; Path = $childPath
                Started = $process.StartTime.ToUniversalTime()
            }
        }
    }
}

function Stop-FindMyOwnedProcesses($Owned) {
    foreach ($entry in @($Owned.Values | Sort-Object Started -Descending)) {
        Stop-ExactLaunchedHarness -Process $entry.Process -ExpectedExecutable $entry.Path
        if (-not $entry.Process.WaitForExit(5000)) { throw 'findmy_testhost_cleanup_unconfirmed' }
    }
}

if ($functionsOnly) { return }
if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $EnableLive -or
    $env:OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE -cne '1') {
    throw 'findmy_testhost_explicit_live_enable_required'
}
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$profile = Join-Path $env:APPDATA 'OpenBubbles/cloudkit-v2-dev'
$library = Join-Path $NativeRuntime 'rust_lib_bluebubbles.dll'
$dart = Join-Path $FlutterRoot 'bin/cache/dart-sdk/bin/dart.exe'
$tester = Join-Path $FlutterRoot 'bin/cache/artifacts/engine/windows-arm64/flutter_tester.exe'
$snapshot = Join-Path $FlutterRoot 'bin/cache/flutter_tools.snapshot'
$sdkExecutables = @(Get-FindMySdkExecutables $FlutterRoot)
$helper = Join-Path $PSScriptRoot 'findmy_windows_preflight.py'
foreach ($item in @($profile, $dart, $tester, $snapshot, $PythonExecutable)) { Assert-FindMyPlainPath $item }
$artifact = Assert-FindMyArtifact $library
$policy = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState).VerifiedAndReputablePolicyState
if ($policy -ne 1) { throw 'findmy_testhost_enforced_policy_required' }
$launch = [guid]::NewGuid().ToString('N')
$owned = @{}
$mutex = Enter-ProfileScopedLauncherLock -ProfilePath $profile
$cleaned = $false
$prepared = $false
$verified = $false
$directory = $null
try {
    # Only diagnostic directories are created; the profile is never bootstrapped.
    $directory = $profile
    foreach ($part in @('cloud-sync-v2', 'findmy-testhost', $launch)) {
        $directory = Join-Path $directory $part
        if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory }
        Assert-FindMyPlainPath $directory
    }
    $preflight = @($helper, 'prepare', '--profile', $profile, '--launch', $launch,
        '--repository', $repository, '--library', $library)
    $safeOutput = & $PythonExecutable -B @preflight 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'findmy_testhost_retained_preflight_rejected' }
    $prepared = $true
    $head = (& git -C $repository rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[0-9a-f]{40}$') { throw 'findmy_testhost_source_unavailable' }
    $qualification = @{
        version = 1; launch_id = $launch; native_library = $library
        native = $artifact; native_source_reference = '5ecd7abe849c22a2de3c024e471b6afc47af4b77'; dart_head = $head
        bridge_version = '2.3.0'; expected_bridge_content_hash = -849563835
        policy_state = $policy; full_app_receipt_reused = $false
        host_sha256 = (Get-FileHash "$repository/test/live/findmy_windows_live_test.dart").Hash
        bridge_sha256 = (Get-FileHash "$repository/lib/src/rust/frb_generated.dart").Hash
        probe_sha256 = (Get-FileHash "$repository/lib/cloud_sync_v2_windows_findmy_probe.dart").Hash
        preflight_sha256 = (Get-FileHash $helper).Hash
        launcher_sha256 = (Get-FileHash $PSCommandPath).Hash
        sdk_executables = $sdkExecutables
        select_sole_person = [bool]$SelectSolePerson
    }
    $qualification | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$directory/qualification.json" -Encoding utf8
    $start = [Diagnostics.ProcessStartInfo]::new($dart)
    $start.WorkingDirectory = $repository
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -like 'OPENBUBBLES_*' -or $key -eq 'RUST_LOG') { $null = $start.Environment.Remove($key) }
    }
    $start.Environment['OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE'] = '1'
    $start.Environment['OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE'] = '1'
    $start.Environment['OPENBUBBLES_FINDMY_LAUNCH_ID'] = $launch
    $start.Environment['OPENBUBBLES_FINDMY_SOURCE_HEAD'] = $head
    $start.Environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'] = $library
    Set-FindMySelectionOption $start.Environment ([bool]$SelectSolePerson)
    $start.Environment['PATH'] = "$NativeRuntime;$($start.Environment['PATH'])"
    foreach ($arg in @($snapshot, 'test', '--no-pub', '--concurrency=1', '--reporter=expanded',
        'test/live/findmy_windows_live_test.dart')) { $start.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    $owned[[int]$process.Id] = @{ Process = $process; Path = $dart; Started = $process.StartTime.ToUniversalTime() }
    # Drain to Null, not terminal or a raw account log. The host writes aggregates.
    $stdout = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
    $stderr = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $admitted = $false
    $ready = $null
    $readyPath = Join-Path $directory 'ready.json'
    while (-not $process.HasExited -and [datetime]::UtcNow -lt $deadline) {
        Add-FindMyOwnedChildren $owned $sdkExecutables
        if (-not $admitted -and (Test-Path -LiteralPath $readyPath)) {
            try { $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json } catch { $ready = $null }
            if (Test-FindMyReadyProcess $ready $launch $owned $tester) {
                @{ launch_id = $launch; process_id = [int]$ready.process_id } | ConvertTo-Json |
                    Set-Content -LiteralPath "$directory/go.json" -Encoding utf8
                $admitted = $true
            }
        }
        Start-Sleep -Milliseconds 200
        $process.Refresh()
    }
    # Bounded structural diagnostics only. Do not retain compiler/native text.
    @{ launch_id = $launch; root_process_id = $process.Id
        root_exit_code = $(if ($process.HasExited) { $process.ExitCode } else { $null })
        ready_present = (Test-Path -LiteralPath $readyPath)
        ready_parsed = ($null -ne $ready); admitted = $admitted
        owned_process_count = $owned.Count
        expected_tester_seen = @($owned.Values | Where-Object { $_.Path -ieq $tester }).Count -gt 0
    } | ConvertTo-Json | Set-Content -LiteralPath "$directory/admission-status.json" -Encoding utf8
    if (-not $process.HasExited) { throw 'findmy_testhost_process_deadline' }
    if (-not $admitted) { throw 'findmy_testhost_process_not_admitted' }
    Stop-FindMyOwnedProcesses $owned
    $cleaned = $true
    $verify = @($helper, 'verify', '--profile', $profile, '--launch', $launch,
        '--repository', $repository, '--library', $library)
    $safeOutput = & $PythonExecutable -B @verify 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'findmy_testhost_retained_state_changed_or_unreadable' }
    $verified = $true
    $report = Get-Content -LiteralPath "$directory/report.json" -Raw | ConvertFrom-Json
    if ($report.launch_id -cne $launch -or $report.native_sha256 -cne $artifact.sha256 -or
        $report.process_id -ne $ready.process_id) { throw 'findmy_testhost_report_binding_rejected' }
    $report | Add-Member -NotePropertyName retained_state_invariants_verified -NotePropertyValue $true
    # Report content is produced only by the hash-bound host's aggregate helper.
    $report | ConvertTo-Json -Depth 12
    if ($process.ExitCode -ne 0 -or $report.state -ne 'finished') { throw 'findmy_testhost_read_failed' }
} finally {
    if (-not $cleaned) { Stop-FindMyOwnedProcesses $owned; $cleaned = $true }
    # Never release this acquisition until every admitted child has exited.
    # If cleanup throws, leave ownership to the parent shell for manual review.
    if ($cleaned) {
        try {
            if ($prepared -and -not $verified) {
                $verify = @($helper, 'verify', '--profile', $profile, '--launch', $launch,
                    '--repository', $repository, '--library', $library)
                $safeOutput = & $PythonExecutable -B @verify 2>&1
                $verified = $LASTEXITCODE -eq 0
            }
            if ($null -ne $directory) {
                @{ confirmed = $true; retained_state_invariants_verified = $verified
                    processes = @($owned.Values | ForEach-Object {
                        @{ process_id = $_.Process.Id; started_utc = $_.Started.ToString('o'); executable = $_.Path }
                    })
                } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$directory/cleanup.json" -Encoding utf8
            }
        } finally {
            foreach ($entry in $owned.Values) { $entry.Process.Dispose() }
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
        if ($prepared -and -not $verified) { throw 'findmy_testhost_retained_state_changed_or_unreadable' }
    }
}
