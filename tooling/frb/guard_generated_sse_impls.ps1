param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Deduplicate', 'Verify')]
    [string]$Mode = 'Verify',

    [Parameter(Mandatory = $false)]
    [string]$GeneratedRust,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [int]$ExpectedRemovalCount = 6
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($GeneratedRust)) {
    $GeneratedRust = Join-Path $PSScriptRoot '..\..\rust\src\frb_generated.rs'
}
$GeneratedRust = [System.IO.Path]::GetFullPath($GeneratedRust)

if (-not (Test-Path -LiteralPath $GeneratedRust -PathType Leaf)) {
    throw "Generated Rust file not found: $GeneratedRust"
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-SseImplementations {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    # flutter_rust_bridge can wrap a long impl target after rustfmt. Match
    # through its opening brace, then locate the matching closing brace.
    $headerPattern = [regex]::new(
        '(?ms)^[ \t]*impl[ \t]+(?<trait>SseDecode|SseEncode)[ \t]+for[ \t]+(?<type>.*?)[ \t]*\{'
    )

    foreach ($match in $headerPattern.Matches($Source)) {
        $openingBrace = $match.Index + $match.Value.LastIndexOf('{')
        $depth = 0
        $closingBrace = -1

        :braceScan for ($index = $openingBrace; $index -lt $Source.Length; $index++) {
            switch ($Source[$index]) {
                '{' { $depth += 1 }
                '}' {
                    $depth -= 1
                    if ($depth -eq 0) {
                        $closingBrace = $index
                        break braceScan
                    }
                }
            }
        }

        if ($closingBrace -lt 0) {
            throw "Unbalanced generated SSE impl beginning at offset $($match.Index)"
        }

        $type = [regex]::Replace($match.Groups['type'].Value.Trim(), '\s+', ' ')
        $body = $Source.Substring(
            $openingBrace + 1,
            $closingBrace - $openingBrace - 1
        ).Trim()
        $endExclusive = $closingBrace + 1

        if (
            $endExclusive + 1 -lt $Source.Length -and
            $Source[$endExclusive] -eq "`r" -and
            $Source[$endExclusive + 1] -eq "`n"
        ) {
            $endExclusive += 2
        } elseif (
            $endExclusive -lt $Source.Length -and
            $Source[$endExclusive] -eq "`n"
        ) {
            $endExclusive += 1
        }

        [pscustomobject]@{
            Key = "$($match.Groups['trait'].Value) for $type"
            Start = $match.Index
            EndExclusive = $endExclusive
            BodySha256 = Get-Sha256 -Value $body
        }
    }
}

$rawBytes = [System.IO.File]::ReadAllBytes($GeneratedRust)
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
$sourceSha256 = Get-Sha256 -Value $source

$duplicateGroups = @(
    Get-SseImplementations -Source $source |
        Group-Object Key |
        Where-Object Count -gt 1 |
        Sort-Object Name
)

$removals = [System.Collections.Generic.List[object]]::new()
foreach ($group in $duplicateGroups) {
    $ordered = @($group.Group | Sort-Object Start)
    $bodyHashes = @($ordered.BodySha256 | Select-Object -Unique)

    if ($bodyHashes.Count -ne 1) {
        throw "Refusing to alter non-identical duplicate bodies for '$($group.Name)'"
    }

    foreach ($duplicate in ($ordered | Select-Object -Skip 1)) {
        $removals.Add($duplicate)
    }
}

if ($Mode -eq 'Verify') {
    if ($removals.Count -ne 0) {
        $keys = $duplicateGroups.Name -join ', '
        throw "Found $($removals.Count) duplicate SSE impl(s): $keys"
    }

    [pscustomobject]@{
        GeneratedRust = $GeneratedRust
        DuplicateGroupCount = 0
        DuplicateImplCount = 0
        Sha256 = $sourceSha256
    } | ConvertTo-Json
    exit 0
}

if ($removals.Count -ne $ExpectedRemovalCount) {
    throw "Expected exactly $ExpectedRemovalCount identical duplicate impl removal(s), found $($removals.Count)"
}

$builder = [System.Text.StringBuilder]::new($source.Length)
$cursor = 0
foreach ($removal in ($removals | Sort-Object Start)) {
    if ($removal.Start -lt $cursor) {
        throw "Overlapping generated-code removal ranges detected"
    }

    [void]$builder.Append($source, $cursor, $removal.Start - $cursor)
    $cursor = $removal.EndExclusive
}
[void]$builder.Append($source, $cursor, $source.Length - $cursor)
$deduplicated = $builder.ToString()

if (
    @(Get-SseImplementations -Source $deduplicated |
        Group-Object Key |
        Where-Object Count -gt 1).Count -ne 0
) {
    throw 'Internal verification failed: duplicate SSE impl signatures remain'
}

# Refuse to overwrite a concurrent regeneration.
$current = [System.IO.File]::ReadAllText($GeneratedRust)
if ((Get-Sha256 -Value $current) -ne $sourceSha256) {
    throw 'Generated Rust changed during verification; refusing to overwrite it'
}

$directory = [System.IO.Path]::GetDirectoryName($GeneratedRust)
$temporary = [System.IO.Path]::Combine(
    $directory,
    ".frb-generated-dedup-$([guid]::NewGuid().ToString('N')).tmp"
)
$outputEncoding = [System.Text.UTF8Encoding]::new($hasUtf8Bom)

try {
    [System.IO.File]::WriteAllText($temporary, $deduplicated, $outputEncoding)
    [System.IO.File]::Move($temporary, $GeneratedRust, $true)
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
}

$written = [System.IO.File]::ReadAllText($GeneratedRust)
if (
    @(Get-SseImplementations -Source $written |
        Group-Object Key |
        Where-Object Count -gt 1).Count -ne 0
) {
    throw 'Post-write verification failed: duplicate SSE impl signatures remain'
}

[pscustomobject]@{
    GeneratedRust = $GeneratedRust
    RemovedImplCount = $removals.Count
    DuplicateGroupCount = $duplicateGroups.Count
    OriginalSha256 = $sourceSha256
    DeduplicatedSha256 = Get-Sha256 -Value $written
} | ConvertTo-Json
