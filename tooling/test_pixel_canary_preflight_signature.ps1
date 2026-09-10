[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptPath = Join-Path $PSScriptRoot 'pixel_canary_preflight.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Preflight PowerShell parsing failed.' }
$checks = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Imatch -and
        $node.Right -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Right.Value.Contains('Verified using v2 scheme')
}, $true))
if ($checks.Count -ne 1) { throw 'Expected one v2 verification parser.' }
$pattern = $checks[0].Right.Value
$cases = @(
    @('Verified using v2 scheme (APK Signature Scheme v2): true', $true),
    @('Verified using v2 scheme: true', $true),
    @('Verified using v2 scheme (APK Signature Scheme v2): false', $false),
    @('Verified using v1 scheme (JAR signing): true', $false),
    @('Verified using v3 scheme (APK Signature Scheme v3): true', $false),
    @('Signer #1 certificate SHA-256 digest: synthetic', $false),
    @('not Verified using v2 scheme: true', $false),
    @('Verified using v2 scheme: true garbage', $false)
)
foreach ($case in $cases) {
    if (($case[0] -match $pattern) -ne $case[1]) {
        throw 'APK v2 verification output was misclassified.'
    }
}
$source = Get-Content -LiteralPath $scriptPath -Raw
if (-not $source.Contains('verify --verbose --print-certs') -or
    -not $source.Contains("@('verify', '--verbose', '--print-certs', `$TargetApk)")) {
    throw 'Both apksigner invocation paths must request verbose scheme output.'
}
Write-Output 'PASS 8 APK v2 output cases; both CLI paths request verbose verification. No device operations.'
