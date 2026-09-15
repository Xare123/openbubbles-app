# Offline behavioral tests for the host-only lifecycle guard. No ADB calls.
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'canary_adb_control.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  $path, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Host script does not parse' }
$functions = @($ast.FindAll({param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Assert-CanaryIdleStatus'
}, $true))
if ($functions.Count -ne 1) { throw 'Expected exactly one idle guard' }
. ([scriptblock]::Create($functions[0].Extent.Text))
function New-IdleFixture {
  [pscustomobject]@{code='adb_status'; ok=$true; data=[pscustomobject]@{
    legacy_sync_active=$false; logout_active=$false
    semantic_pull_active=$false; semantic_pull_quiescing=$false
    coordinator_active=$false; outbox_state='settled'
  }}
}
$passed = 0
foreach ($outbox in @('empty', 'settled')) {
  $fixture = New-IdleFixture
  $fixture.data.outbox_state = $outbox
  Assert-CanaryIdleStatus $fixture
  $passed++
}
foreach ($field in @('legacy_sync_active', 'logout_active',
    'semantic_pull_active', 'semantic_pull_quiescing', 'coordinator_active')) {
  foreach ($value in @($true, $null, 'false')) {
    $fixture = New-IdleFixture
    $fixture.data.$field = $value
    $rejected = $false
    try { Assert-CanaryIdleStatus $fixture } catch { $rejected = $true }
    if (-not $rejected) { throw "Guard admitted invalid $field" }
    $passed++
  }
}
foreach ($outbox in @('blocked', 'unavailable', '', $null)) {
  $fixture = New-IdleFixture
  $fixture.data.outbox_state = $outbox
  $rejected = $false
  try { Assert-CanaryIdleStatus $fixture } catch { $rejected = $true }
  if (-not $rejected) { throw 'Guard admitted unfinished/unknown outbox' }
  $passed++
}
foreach ($fixture in @($null,
    [pscustomobject]@{code='adb_status'; ok=$false; data=$null},
    [pscustomobject]@{code='adb_route'; ok=$true; data=$null})) {
  $rejected = $false
  try { Assert-CanaryIdleStatus $fixture } catch { $rejected = $true }
  if (-not $rejected) { throw 'Guard admitted unavailable status' }
  $passed++
}
Write-Output "PASS canary-idle-guard cases=$passed remoteCalls=0"
