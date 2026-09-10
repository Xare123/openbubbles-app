[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Evaluate only the argument-array assignments, never either device script.
# Paths with spaces catch accidental concatenation of the entire argument list.
$PackageConfig = 'C:\synthetic project\package_config.json'
$VmReadUploadModeScript = 'C:\synthetic project\mode.dart'
$VmReadChatScript = 'C:\synthetic project\chat.dart'
$VmWriteScript = 'C:\synthetic project\write.dart'
$WsUri = 'ws://127.0.0.1:1234/synthetic/ws'
$channel = [pscustomobject]@{WsUri = $WsUri}
$ChatId = 42
$Scope = 'profile'
$Mode = 'run'
$ExpectedRecipientSha256 = 'a' * 64
$cases = @(
    @{File='pixel_cloudkit_write_gate.ps1'; Name='modeArgs'; Expected=@("--packages=$PackageConfig", $VmReadUploadModeScript, $WsUri, '--expect-manual-writer')},
    @{File='pixel_cloudkit_write_gate.ps1'; Name='writeArgs'; Expected=@("--packages=$PackageConfig", $VmWriteScript, $WsUri, '--run', '--expect-recipient-sha256', $ExpectedRecipientSha256)},
    @{File='pixel_batch_gate.ps1'; Name='modeArgs'; Expected=@("--packages=$PackageConfig", $VmReadUploadModeScript, $WsUri, '--expect-uploads-off')},
    @{File='pixel_batch_gate.ps1'; Name='chatArgs'; Expected=@("--packages=$PackageConfig", $VmReadChatScript, $WsUri, '42', '--scope', 'profile')}
)
foreach ($case in $cases) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $case.File), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Gate parsing failed' }
    $nodes=@($ast.FindAll({param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Operator -eq [Management.Automation.Language.TokenKind]::Equals -and
        $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -ceq $case.Name
    }, $true))
    if ($nodes.Count -ne 1) { throw 'Expected one argument-array assignment' }
    $actual=@(& ([scriptblock]::Create($nodes[0].Right.Extent.Text)))
    if ($actual.Count -ne $case.Expected.Count) { throw 'Collapsed argument array' }
    for($i=0; $i -lt $actual.Count; $i++) {
        if ($actual[$i] -cne $case.Expected[$i]) { throw 'Unexpected argument boundary' }
    }
}
Write-Output 'PASS 4 real host argument arrays preserve paths, URI and flags. No device operations.'
