[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Load function definitions only. Never execute the host gate's top-level
# device, restart, upload or evidence-writing workflow in this test.
$probe = Join-Path $PSScriptRoot 'pixel_cloudkit_write_gate.ps1'
$parseErrors = $null
$parseTokens = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile(
    $probe, [ref]$parseTokens, [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) { throw 'Write gate parsing failed.' }
foreach ($name in @('Fail-Gate', 'Assert-CanaryIdleBeforeRestart', 'Open-VmChannel')) {
    $definition = $tree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $name
    }, $false)
    if ($null -eq $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$AdbSerial = 'synthetic-pixel:12345'
$CanaryPackage = 'com.bluebubbles.messaging.cloudkitcanary'
$script:AdbPath = 'synthetic-adb'
$script:CanaryControlPath = Join-Path $PSScriptRoot 'canary_adb_control.ps1'
$script:GuardFailure = $null
$script:ObservedArguments = @()
$script:DeviceCalls = @()

function Resolve-GateExecutable {
    param([string]$Executable, [string]$Code)
    return $Executable
}

function Invoke-BoundedText {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$FailureCode)
    $script:ObservedArguments = $Arguments
    if ($TimeoutSeconds -ne 20 -or $FailureCode -cne 'canary_not_idle') {
        throw 'Idle check is not bounded or does not preserve its failure code.'
    }
    if ($script:GuardFailure) { Fail-Gate $script:GuardFailure }
    return 'code=adb_status ok=True'
}

function Invoke-AdbLines {
    param([string[]]$Arguments)
    $script:DeviceCalls += ,$Arguments
    # Test sentinel: stop before any real lifecycle call or subsequent wait.
    throw 'synthetic_restart_boundary'
}

foreach ($failure in @('canary_not_idle', 'child_timeout_unresolved')) {
    $script:GuardFailure = $failure
    $script:DeviceCalls = @()
    $caught = $null
    try { $null = Open-VmChannel } catch { $caught = $_.Exception.Message }
    if ($caught -cne ('gate_' + $failure) -or $script:DeviceCalls.Count -ne 0) {
        throw "Idle preflight assertion: failure=$caught deviceCalls=$($script:DeviceCalls.Count)"
    }
}

$script:GuardFailure = $null
$script:DeviceCalls = @()
$caught = $null
try { $null = Open-VmChannel } catch { $caught = $_.Exception.Message }
if ($caught -cne 'synthetic_restart_boundary' -or $script:DeviceCalls.Count -ne 1) {
    throw 'Successful idle check did not reach exactly one mocked restart boundary.'
}
if (($script:DeviceCalls[0] -join '|') -cne
    "shell|am|force-stop|$CanaryPackage") {
    throw 'Restart targeted an unexpected package or command.'
}
foreach ($pair in @(
    @('-Action', 'assert-idle'), @('-Serial', $AdbSerial),
    @('-Package', $CanaryPackage), @('-AdbExecutable', $script:AdbPath),
    @('-TimeoutSec', '10')
)) {
    $position = [array]::IndexOf($script:ObservedArguments, $pair[0])
    if ($position -lt 0 -or $script:ObservedArguments[$position + 1] -cne $pair[1]) {
        throw 'Idle preflight argument binding changed.'
    }
}

Write-Output '3 host idle-preflight cases passed. No process, device or upload operations.'
