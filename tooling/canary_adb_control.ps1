<#
.SYNOPSIS
  ADB host driver for the removable Canary-debug OpenBubbles control channel.
.DESCRIPTION
  Sends an allowlisted command to the canaryDebug-only CanaryAdbControlReceiver
  via an explicit on-device broadcast (ADB/shell only; third-party apps are
  refused: the receiver requires android.permission.DUMP, which only the shell
  UID holds), then polls the content-free result the Dart dispatcher publishes
  to private prefs (primary) or logcat (fallback).
  The script launches the Canary activity explicitly first: background activity
  starts from a receiver are blocked on modern Android, so navigation commands
  must not rely on the receiver-side launch.
  Never prints message content or identifiers: results carry only route names,
  aggregate counts, booleans, and safe codes.
.EXAMPLE
  ./tooling/canary_adb_control.ps1 -Action status
.EXAMPLE
  ./tooling/canary_adb_control.ps1 -Action open-sync
.EXAMPLE
  ./tooling/canary_adb_control.ps1 -Action semantic-start
  ./tooling/canary_adb_control.ps1 -Action semantic-start -Confirm
  (Two-step: first call reports preconditions with code adb_confirmation_required;
  the -Confirm call runs the bounded read-only catch-up. No uploads or deletes.)
.NOTES
  Requires a canaryDebug build with
  --dart-define=OPENBUBBLES_CANARY_ADB_CONTROL=true and the app installed under
  com.bluebubbles.messaging.cloudkitcanary. Result polling via run-as needs a
  debuggable (debug-variant) install.
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('ping', 'status', 'route', 'open-dev', 'open-sync', 'semantic-status', 'semantic-start', 'logs')]
  [string]$Action,
  [switch]$Confirm,
  [string]$Package = 'com.bluebubbles.messaging.cloudkitcanary',
  [string]$Serial = '',
  [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
function Invoke-Adb {
  param([string[]]$AdbArgs)
  $out = & adb @AdbArgs 2>&1 | Out-String
  return $out
}
$base = @()
if ($Serial -ne '') { $base += @('-s', $Serial) }
$deviceOut = Invoke-Adb ($base + @('shell', 'echo', 'adb_ok'))
if ($deviceOut -notmatch 'adb_ok') { Write-Error "No ADB device reachable. Output: $deviceOut" }
$nativeFor = @{
  'ping' = 'ping'; 'status' = 'status'; 'route' = 'query_route'
  'open-dev' = 'open_developer_settings'; 'open-sync' = 'open_cloud_sync_v2'
  'semantic-status' = 'semantic_pull_status'; 'semantic-start' = 'semantic_pull_start'
}
if ($Action -eq 'logs') {
  Write-Output (Invoke-Adb ($base + @('logcat', '-d', '-s', 'CanaryAdb')))
  exit 0
}
$native = $nativeFor[$Action]
$seq = [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) + '-' + (Get-Random -Maximum 99999)
$Receiver = "$Package/com.bluebubbles.messaging.CanaryAdbControlReceiver"
Write-Output "Launching $Package (explicit foreground; receiver launch is best-effort only) ..."
$startOut = Invoke-Adb ($base + @('shell', 'am', 'start', '-n', "$Package/com.bluebubbles.messaging.MainActivity"))
Write-Output $startOut
Start-Sleep -Seconds 2
$cmd = $base + @('shell', 'am', 'broadcast', '-n', $Receiver, '-a', 'com.bluebubbles.messaging.CANARY_ADB', '--es', 'action', $native, '--es', 'seq', $seq)
if ($native -eq 'semantic_pull_start' -and $Confirm) { $cmd += @('--es', 'confirm', 'true') }
Write-Output "Sending action=$native seq=$seq ..."
$ack = Invoke-Adb $cmd
Write-Output $ack
if ($ack -notmatch 'adb_received') { Write-Error "Receiver did not acknowledge. Is a canaryDebug build installed and running?" }
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
$prefsPath = "shared_prefs/FlutterSharedPreferences.xml"
$runAsFailed = $false
while ([DateTime]::UtcNow -lt $deadline) {
  if (-not $runAsFailed) {
    $xml = Invoke-Adb ($base + @('shell', "run-as $Package cat $prefsPath"))
    if ($xml -match 'run-as: |error|Permission denied|not debuggable') {
      $runAsFailed = $true
    } elseif ($xml -match '<string name="canary_adb_last_result">(.*?)</string>') {
      $raw = [System.Net.WebUtility]::HtmlDecode($Matches[1])
      try {
        $result = $raw | ConvertFrom-Json
      } catch {
        Start-Sleep -Milliseconds 500
        continue
      }
      if ($result.seq -eq $seq) {
        Write-Output ("code=" + $result.code + " ok=" + $result.ok)
        Write-Output ($result.data | ConvertTo-Json -Depth 4)
        if ($result.code -eq 'adb_confirmation_required') {
          Write-Output "Preconditions reported. Re-run with -Confirm to execute the bounded read-only pull."
          exit 2
        }
        if ($result.ok -eq $true) { exit 0 } else { exit 1 }
      }
    }
  }
  Start-Sleep -Milliseconds 1000
}
if ($runAsFailed) {
  Write-Output "run-as unavailable (build may not be debuggable). Falling back to logcat ack only:"
  Write-Output (Invoke-Adb ($base + @('logcat', '-d', '-s', 'CanaryAdb')))
  exit 3
}
Write-Error "Timed out after $TimeoutSec s waiting for result seq=$seq. Check device logs."
