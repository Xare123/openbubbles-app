<#
.SYNOPSIS
  ADB host driver for the removable Canary-debug control channel.
.DESCRIPTION
  Status, route and semantic actions never launch the app. They require an
  already-ready Canary engine, so they cannot wake normal app lifecycle or a
  configured writer. Only open-dev/open-sync explicitly launch MainActivity;
  those actions use a ping/result readiness handshake rather than a fixed
  sleep. Semantic start is accepted asynchronously; use semantic-status for
  progress and completion.
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('ping', 'status', 'route', 'open-dev', 'open-sync', 'semantic-status', 'semantic-start', 'logs')]
  [string]$Action,
  [switch]$Confirm,
  [string]$Package = 'com.bluebubbles.messaging.cloudkitcanary',
  [string]$Serial = '',
  [ValidateRange(5, 120)]
  [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'
$base = @()
if ($Serial -ne '') { $base += @('-s', $Serial) }
$receiver = "$Package/com.bluebubbles.messaging.CanaryAdbControlReceiver"
$prefsPath = 'shared_prefs/FlutterSharedPreferences.xml'

function Invoke-Adb {
  param([string[]]$AdbArgs)
  return (& adb @AdbArgs 2>&1 | Out-String)
}

function New-Sequence {
  $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  return [string]$stamp + '-' + (Get-Random -Maximum 99999)
}

function Send-Control {
  param(
    [string]$NativeAction,
    [string]$Sequence,
    [switch]$Confirmed,
    [string]$Challenge = ''
  )
  $args = $base + @(
    'shell', 'am', 'broadcast', '-n', $receiver,
    '-a', 'com.bluebubbles.messaging.CANARY_ADB',
    '--es', 'action', $NativeAction,
    '--es', 'seq', $Sequence
  )
  if ($Confirmed) { $args += @('--es', 'confirm', 'true') }
  if ($Challenge -ne '') { $args += @('--es', 'challenge', $Challenge) }
  return Invoke-Adb $args
}

function Read-Result {
  param([string]$Sequence)
  $xml = Invoke-Adb ($base + @('shell', "run-as $Package cat $prefsPath"))
  if ($xml -match 'run-as: |Permission denied|not debuggable') {
    throw 'run-as unavailable. Install the debuggable canaryDebug variant.'
  }
  if ($xml -notmatch '<string name="canary_adb_last_result">(.*?)</string>') {
    return $null
  }
  $raw = [System.Net.WebUtility]::HtmlDecode($Matches[1])
  try { $result = $raw | ConvertFrom-Json } catch { return $null }
  if ($result.seq -ne $Sequence) { return $null }
  return $result
}

function Wait-Result {
  param(
    [string]$Sequence,
    [string]$PreviousCode = '',
    [int]$Seconds = $TimeoutSec
  )
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $result = Read-Result $Sequence
    if ($null -ne $result -and
        ($PreviousCode -eq '' -or $result.code -ne $PreviousCode)) {
      return $result
    }
    Start-Sleep -Milliseconds 250
  }
  throw "Timed out waiting for result seq=$Sequence. The command was not assumed to run."
}

function Assert-Forwarded {
  param([string]$Ack)
  if ($Ack -match 'adb_app_not_ready') {
    throw 'Canary is not already running and ready. Open it manually; this action will not launch it.'
  }
  if ($Ack -notmatch 'adb_received') {
    throw "Receiver refused or did not forward the command: $Ack"
  }
}

function Wait-DartReady {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  while ([DateTime]::UtcNow -lt $deadline) {
    $readySeq = New-Sequence
    $ack = Send-Control -NativeAction 'ping' -Sequence $readySeq
    if ($ack -match 'adb_received') {
      try {
        $result = Wait-Result -Sequence $readySeq -Seconds 3
        if ($result.code -eq 'adb_pong' -and $result.ok -eq $true) { return }
      } catch {
        # Engine may still be crossing its ready boundary; retry until deadline.
      }
    } elseif ($ack -notmatch 'adb_app_not_ready') {
      throw "Readiness probe was refused: $ack"
    }
    Start-Sleep -Milliseconds 250
  }
  throw 'Canary launched but its Dart engine did not become ready.'
}

$deviceOut = Invoke-Adb ($base + @('shell', 'echo', 'adb_ok'))
if ($deviceOut -notmatch 'adb_ok') { throw "No ADB device reachable: $deviceOut" }

if ($Action -eq 'logs') {
  Write-Output (Invoke-Adb ($base + @('logcat', '-d', '-s', 'CanaryAdb')))
  exit 0
}

$nativeFor = @{
  'ping' = 'ping'
  'status' = 'status'
  'route' = 'query_route'
  'open-dev' = 'open_developer_settings'
  'open-sync' = 'open_cloud_sync_v2'
  'semantic-status' = 'semantic_pull_status'
  'semantic-start' = 'semantic_pull_start'
}
$native = $nativeFor[$Action]

if ($Action -eq 'open-dev' -or $Action -eq 'open-sync') {
  Write-Output 'Launching Canary for the requested navigation action...'
  $start = Invoke-Adb ($base + @(
    'shell', 'am', 'start', '-n',
    "$Package/com.bluebubbles.messaging.MainActivity"
  ))
  if ($start -match 'Error:|Exception') { throw "Canary launch failed: $start" }
  Wait-DartReady
}

$seq = New-Sequence
if ($Action -eq 'semantic-start') {
  $preflightAck = Send-Control -NativeAction $native -Sequence $seq
  Assert-Forwarded $preflightAck
  $preflight = Wait-Result -Sequence $seq
  if ($preflight.code -eq 'adb_semantic_unavailable') {
    Write-Output 'code=adb_semantic_unavailable ok=False'
    Write-Output ($preflight.data | ConvertTo-Json -Depth 3)
    exit 1
  }
  if ($preflight.code -ne 'adb_semantic_preflight') {
    throw "Unexpected semantic preflight result: $($preflight.code)"
  }
  if (-not $Confirm) {
    Write-Output 'code=adb_semantic_preflight ok=False'
    Write-Output ($preflight.data | ConvertTo-Json -Depth 3)
    Write-Output 'Re-run with -Confirm. That invocation performs a fresh protected preflight.'
    exit 2
  }
  $challenge = [string]$preflight.data.challenge
  $startAck = Send-Control -NativeAction $native -Sequence $seq -Confirmed -Challenge $challenge
  Assert-Forwarded $startAck
  $accepted = Wait-Result -Sequence $seq -PreviousCode 'adb_semantic_preflight'
  Write-Output ("code=" + $accepted.code + " ok=" + $accepted.ok)
  Write-Output ($accepted.data | ConvertTo-Json -Depth 3)
  if ($accepted.code -eq 'adb_semantic_accepted') {
    Write-Output 'Pull accepted asynchronously. Use -Action semantic-status for progress/completion.'
    exit 0
  }
  exit 1
}

$ack = Send-Control -NativeAction $native -Sequence $seq
Assert-Forwarded $ack
$result = Wait-Result -Sequence $seq
Write-Output ("code=" + $result.code + " ok=" + $result.ok)
Write-Output ($result.data | ConvertTo-Json -Depth 3)
if ($result.ok -eq $true) { exit 0 }
exit 1
