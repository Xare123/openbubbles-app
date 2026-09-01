param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Normalize', 'Verify')]
    [string]$Mode = 'Verify',

    [Parameter(Mandatory = $false)]
    [string]$GeneratedDart
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($GeneratedDart)) {
    $GeneratedDart = Join-Path $PSScriptRoot '..\..\lib\src\rust\api\api.dart'
}
$GeneratedDart = [System.IO.Path]::GetFullPath($GeneratedDart)

if (-not (Test-Path -LiteralPath $GeneratedDart -PathType Leaf)) {
    throw "Generated Dart file not found: $GeneratedDart"
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $hash = [System.Security.Cryptography.SHA256]::HashData($Bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Test-ByteArrayEqual {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Left,

        [Parameter(Mandatory = $true)]
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }

    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }

    return $true
}

$rawBytes = [System.IO.File]::ReadAllBytes($GeneratedDart)
$hasUtf8Bom = (
    $rawBytes.Length -ge 3 -and
    $rawBytes[0] -eq 0xef -and
    $rawBytes[1] -eq 0xbb -and
    $rawBytes[2] -eq 0xbf
)
$sourceOffset = if ($hasUtf8Bom) { 3 } else { 0 }
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$source = $utf8Strict.GetString(
    $rawBytes,
    $sourceOffset,
    $rawBytes.Length - $sourceOffset
)
$sourceSha256 = Get-Sha256 -Bytes $rawBytes

# These are the five known FRB informational diagnostic classes emitted in the
# generated Dart prologue. Four are invariant and the owner-type notice is
# Windows-only for this source. The payload is deliberately constrained to a
# comma-separated list of Rust identifiers rendered in backticks. No free-form
# suffix is accepted, so a changed diagnostic fails closed instead of removal.
$symbolListPattern = '(?<symbols>`[A-Za-z_][A-Za-z0-9_]*`(?:, `[A-Za-z_][A-Za-z0-9_]*`)*)'
$allowlistedDiagnostics = @(
    [pscustomobject]@{
        Name = 'not-public'
        Required = $true
        Pattern = [regex]::new(
            '^// These functions are ignored because they are not marked as `pub`: ' +
            $symbolListPattern + '$'
        )
    }
    [pscustomobject]@{
        Name = 'generic-arguments'
        Required = $true
        Pattern = [regex]::new(
            '^// These functions are ignored because they have generic arguments: ' +
            $symbolListPattern + '$'
        )
    }
    [pscustomobject]@{
        Name = 'unused-types'
        Required = $true
        Pattern = [regex]::new(
            '^// These types are ignored because they are not used by any `pub` functions: ' +
            $symbolListPattern + '$'
        )
    }
    [pscustomobject]@{
        Name = 'undefined-trait'
        Required = $true
        Pattern = [regex]::new(
            '^// These function are ignored because they are on traits that is not defined in current crate \(put an empty `\#\[frb\]` on it to unignore\): ' +
            $symbolListPattern + '$'
        )
    }
    [pscustomobject]@{
        Name = 'owner-type'
        # FRB emits this notice on Windows but omits it on Linux for the same
        # source. Zero or one is therefore the exact cross-platform contract.
        Required = $false
        Pattern = [regex]::new(
            '^// These functions are ignored \(category: IgnoreBecauseOwnerTyShouldIgnore\): ' +
            $symbolListPattern + '$'
        )
    }
)

$diagnosticCandidatePattern = [regex]::new(
    '^// These [^\r\n]*\bare\s+ignored\b',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Multiline
)
$linePattern = [regex]::new('(?<text>[^\r\n]*)(?<eol>\r\n|\n|\r|$)')
$lineRecords = [System.Collections.Generic.List[object]]::new()
foreach ($lineMatch in $linePattern.Matches($source)) {
    if ($lineMatch.Length -eq 0) {
        continue
    }

    $lineRecords.Add([pscustomobject]@{
            Text = $lineMatch.Groups['text'].Value
            Eol = $lineMatch.Groups['eol'].Value
        })
}

$partLineIndices = @(
    for ($index = 0; $index -lt $lineRecords.Count; $index++) {
        if ($lineRecords[$index].Text -eq "part 'api.freezed.dart';") {
            $index
        }
    }
)
if ($partLineIndices.Count -ne 1) {
    throw "Expected exactly one generated Dart prologue anchor, found $($partLineIndices.Count)"
}

function Get-AllowlistedMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    return @(
        $allowlistedDiagnostics | Where-Object {
            $_.Pattern.IsMatch($Line)
        }
    )
}

$prologueLineIndices = [System.Collections.Generic.HashSet[int]]::new()
$cursor = $partLineIndices[0] + 1
while ($cursor -lt $lineRecords.Count) {
    $line = $lineRecords[$cursor].Text
    if ($line.Length -eq 0) {
        $cursor++
        continue
    }

    $matchedSpecs = @(Get-AllowlistedMatches -Line $line)
    if ($matchedSpecs.Count -gt 1) {
        throw "Generated Dart diagnostic matches multiple allowlisted classes on line $($cursor + 1)"
    }
    if ($matchedSpecs.Count -eq 1) {
        [void]$prologueLineIndices.Add($cursor)
        $cursor++
        continue
    }

    if ($diagnosticCandidatePattern.IsMatch($line)) {
        throw "Unexpected FRB diagnostic variant in generated Dart prologue at line $($cursor + 1)"
    }
    break
}

if ($cursor -ge $lineRecords.Count) {
    throw 'Generated Dart prologue has no declaration after its anchor'
}
$anchorEol = $lineRecords[$partLineIndices[0]].Eol
if ([string]::IsNullOrEmpty($anchorEol)) {
    throw 'Generated Dart prologue anchor has no line ending'
}
$prologueRegionIndices = @(
    for (
        $index = $partLineIndices[0] + 1;
        $index -lt $cursor;
        $index++
    ) {
        $index
    }
)

$diagnosticLines = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $lineRecords.Count; $index++) {
    $line = $lineRecords[$index].Text
    $matchedSpecs = if ($line.Length -eq 0) {
        @()
    } else {
        @(Get-AllowlistedMatches -Line $line)
    }
    if ($matchedSpecs.Count -gt 1) {
        throw "Generated Dart diagnostic matches multiple allowlisted classes at line $($index + 1)"
    }

    $isCandidate = $diagnosticCandidatePattern.IsMatch($line)
    if ($isCandidate -and $matchedSpecs.Count -eq 0) {
        throw "Unexpected FRB diagnostic variant at line $($index + 1)"
    }
    if ($matchedSpecs.Count -eq 1) {
        if (-not $prologueLineIndices.Contains($index)) {
            throw "Allowlisted FRB diagnostic is outside the generated Dart prologue at line $($index + 1)"
        }

        $diagnosticLines.Add([pscustomobject]@{
                Index = $index
                Name = $matchedSpecs[0].Name
            })
    }
}

if ($Mode -eq 'Verify') {
    if ($diagnosticLines.Count -ne 0) {
        throw "Found $($diagnosticLines.Count) unnormalized allowlisted FRB diagnostic comment(s)"
    }
    if ($prologueRegionIndices.Count -ne 1 -or
        $lineRecords[$prologueRegionIndices[0]].Text.Length -ne 0) {
        throw 'Generated Dart prologue spacing is not canonical'
    }

    [pscustomobject]@{
        GeneratedDart = $GeneratedDart
        DiagnosticCommentCount = 0
        Sha256 = $sourceSha256
    } | ConvertTo-Json
    exit 0
}

foreach ($spec in $allowlistedDiagnostics) {
    $count = @($diagnosticLines | Where-Object { $_.Name -eq $spec.Name }).Count
    if ($count -gt 1 -or ($spec.Required -and $count -ne 1)) {
        $expectation = if ($spec.Required) { 'exactly one' } else { 'zero or one' }
        throw "Expected $expectation allowlisted FRB diagnostic '$($spec.Name)', found $count"
    }
}

$removeIndices = [System.Collections.Generic.HashSet[int]]::new()
foreach ($diagnosticLine in $diagnosticLines) {
    [void]$removeIndices.Add($diagnosticLine.Index)
}
foreach ($regionIndex in $prologueRegionIndices) {
    [void]$removeIndices.Add($regionIndex)
}

$builder = [System.Text.StringBuilder]::new()
for ($index = 0; $index -lt $lineRecords.Count; $index++) {
    if ($index -eq $partLineIndices[0]) {
        [void]$builder.Append($lineRecords[$index].Text)
        [void]$builder.Append($lineRecords[$index].Eol)
        [void]$builder.Append($anchorEol)
    } elseif (-not $removeIndices.Contains($index)) {
        [void]$builder.Append($lineRecords[$index].Text)
        [void]$builder.Append($lineRecords[$index].Eol)
    }
}
$normalized = $builder.ToString()
if ($diagnosticCandidatePattern.IsMatch($normalized)) {
    throw 'Internal verification failed: FRB diagnostic comments remain'
}

# Refuse to overwrite a source that changed while the normalized output was
# being prepared. The second read is intentionally after the temporary write,
# narrowing the guarded interval immediately before replacement.
$directory = [System.IO.Path]::GetDirectoryName($GeneratedDart)
$temporary = [System.IO.Path]::Combine(
    $directory,
    ".frb-generated-diagnostics-$([guid]::NewGuid().ToString('N')).tmp"
)
$outputEncoding = [System.Text.UTF8Encoding]::new($hasUtf8Bom)

try {
    [System.IO.File]::WriteAllText($temporary, $normalized, $outputEncoding)
    $expectedBytes = [System.IO.File]::ReadAllBytes($temporary)

    $currentBytes = [System.IO.File]::ReadAllBytes($GeneratedDart)
    if (-not (Test-ByteArrayEqual -Left $currentBytes -Right $rawBytes)) {
        throw 'Generated Dart changed during normalization; refusing to overwrite it'
    }

    [System.IO.File]::Move($temporary, $GeneratedDart, $true)
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
}

$writtenBytes = [System.IO.File]::ReadAllBytes($GeneratedDart)
if (-not (Test-ByteArrayEqual -Left $writtenBytes -Right $expectedBytes)) {
    throw 'Final normalized Dart bytes do not match the prepared output'
}

$writtenOffset = if (
    $writtenBytes.Length -ge 3 -and
    $writtenBytes[0] -eq 0xef -and
    $writtenBytes[1] -eq 0xbb -and
    $writtenBytes[2] -eq 0xbf
) { 3 } else { 0 }
$written = $utf8Strict.GetString(
    $writtenBytes,
    $writtenOffset,
    $writtenBytes.Length - $writtenOffset
)
if ($diagnosticCandidatePattern.IsMatch($written)) {
    throw 'Post-write verification failed: FRB diagnostic comments remain'
}

[pscustomobject]@{
    GeneratedDart = $GeneratedDart
    RemovedDiagnosticCommentCount = $diagnosticLines.Count
    OriginalSha256 = $sourceSha256
    NormalizedSha256 = Get-Sha256 -Bytes $writtenBytes
} | ConvertTo-Json
