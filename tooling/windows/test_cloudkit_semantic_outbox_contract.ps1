[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Load only the pure contract functions. Never execute the device probe's
# top-level install, ADB, or report-export workflow during a host test.
$probe = Join-Path $PSScriptRoot '..\cloudkit_canary_device_probe.ps1'
$parseErrors = $null
$parseTokens = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile(
    $probe, [ref]$parseTokens, [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) { throw 'Probe parsing failed.' }
foreach ($name in @('Fail-Probe', 'Assert-ReportIntegerRange', 'Assert-SemanticOutboxContract')) {
    $definition = $tree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
    }, $false)
    if ($null -eq $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$cases = @(
    @{ Version = 6; Before = 0; After = 0; Proof = $null; Pass = $true },
    @{ Version = 6; Before = 1; After = 1; Proof = $true; Pass = $false },
    @{ Version = 7; Before = 0; After = 0; Proof = $false; Pass = $true },
    @{ Version = 7; Before = 1; After = 1; Proof = $true; Pass = $true },
    @{ Version = 7; Before = 1; After = 1; Proof = $false; Pass = $false },
    @{ Version = 7; Before = 1; After = 2; Proof = $true; Pass = $false },
    @{ Version = 7; Before = 1; After = 0; Proof = $true; Pass = $false },
    @{ Version = 7; Before = -1; After = -1; Proof = $true; Pass = $false },
    @{ Version = 7; Before = 65536; After = 65536; Proof = $true; Pass = $false },
    @{ Version = 7; Before = 1; After = 1; Proof = 'true'; Pass = $false },
    @{ Version = 7; Before = '1'; After = '1'; Proof = $true; Pass = $false },
    @{ Version = 7; Before = 0; After = 0; Proof = $null; Pass = $false },
    @{ Version = 8; Before = 0; After = 0; Proof = $true; Pass = $false }
)
foreach ($case in $cases) {
    $report = [pscustomobject]@{
        schemaVersion = $case.Version
        outboxCountBefore = $case.Before
        outboxCountAfter = $case.After
        settledOutboxUnchanged = $case.Proof
    }
    $passed = $true
    try { Assert-SemanticOutboxContract -Report $report }
    catch { $passed = $false }
    if ($passed -ne $case.Pass) { throw 'Semantic outbox contract case failed.' }
}
Write-Output "$($cases.Count) semantic outbox contract cases passed. No device operations."
