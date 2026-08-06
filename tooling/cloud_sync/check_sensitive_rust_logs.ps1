param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
)

$ErrorActionPreference = "Stop"

$searchRoots = @(
    (Join-Path $RepositoryRoot "rust\src"),
    (Join-Path $RepositoryRoot "rustpush\src"),
    (Join-Path $RepositoryRoot "rustpush\apple-private-apis\icloud-auth\src")
)

$forbiddenPatterns = @(
    '\b(?:trace|debug|info|warn|error|println)!\s*\([^\r\n]*(?:Got spd|spd \{?:\?|IDSUser|login_state|adsid.*\{|PET:|Got code \{|idms message \{data:\?|auth response \{|gsa auth extras \{|wrapped asn|Decoding with \{|response hex|ati:)',
    '\b(?:trace|debug|info|warn|error|println)!\s*\([^\r\n]*(?:response|body|request|token)[^\r\n]*\{[^}]*:\?[^}]*\}'
)

$violations = @()
foreach ($root in $searchRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }

    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.rs") {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $file.FullName) {
            $lineNumber++
            if ($line.TrimStart().StartsWith("//")) {
                continue
            }
            foreach ($pattern in $forbiddenPatterns) {
                if ($line -match $pattern) {
                    $relative = [System.IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName)
                    $violations += "${relative}:${lineNumber}: $($line.Trim())"
                    break
                }
            }
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Error ("Sensitive Rust logging patterns detected:`n" + ($violations -join "`n"))
    exit 1
}

Write-Host "Sensitive Rust logging scan passed."
exit 0
