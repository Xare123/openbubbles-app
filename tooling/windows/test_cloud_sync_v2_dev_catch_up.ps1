$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'run_cloud_sync_v2_dev_catch_up.ps1')

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $ExpectedMessage
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw (
                "Expected failure containing '$ExpectedMessage', received " +
                "'$($_.Exception.Message)'."
            )
        }
        return
    }
    throw "Expected failure containing '$ExpectedMessage'."
}

function New-TestReportPayload {
    return [ordered]@{
        schemaVersion = 4
        timestampUtc = '2026-08-31T12:00:00Z'
        platform = 'windows'
        architecture = 'arm64'
        buildCommit = '0123456789ab'
        mode = 'manual-semantic-read-only-cloudkit'
        automaticTriggersEnabled = $false
        remoteSavesEnabled = $false
        remoteDeletesEnabled = $false
        tombstoneSemanticDeletesEnabled = $false
        tombstoneReadOnlyAcknowledgementsEnabled = $true
        retainedUnprojectedEvidencePreserved = $true
        pageLimit = 4
        changeLimit = 50
        outboxCountBefore = 0
        outboxCountAfter = 0
        zones = @(
            [ordered]@{
                zone = 'chats'
                fetched = 10
                applied = 8
                retainedUnprojected = 2
            },
            [ordered]@{
                zone = 'messages'
                fetched = 20
                applied = 15
                retainedUnprojected = 5
            },
            [ordered]@{
                zone = 'attachments'
                fetched = 30
                applied = 25
                retainedUnprojected = 5
            }
        )
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'openbubbles-catch-up-test-' + [guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $reportPath = Join-Path $testRoot 'obcs2-semantic-1.json'
    $payload = New-TestReportPayload
    [System.IO.File]::WriteAllText(
        $reportPath,
        ($payload | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )
    $summary = Read-VerifiedCatchUpReport -Report (
        Get-Item -LiteralPath $reportPath
    )
    if ($summary.Fetched -ne 60 -or
        $summary.Applied -ne 48 -or
        $summary.Retained -ne 12 -or
        $summary.Zones.Count -ne 3) {
        throw 'Valid report counters were not summarized exactly.'
    }

    $payload.remoteSavesEnabled = $true
    [System.IO.File]::WriteAllText(
        $reportPath,
        ($payload | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws -ExpectedMessage 'remoteSavesEnabled' -Action {
        Read-VerifiedCatchUpReport -Report (Get-Item -LiteralPath $reportPath)
    }

    $payload = New-TestReportPayload
    $payload.outboxCountAfter = 1
    [System.IO.File]::WriteAllText(
        $reportPath,
        ($payload | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws -ExpectedMessage 'zero-outbox tripwire' -Action {
        Read-VerifiedCatchUpReport -Report (Get-Item -LiteralPath $reportPath)
    }

    $payload = New-TestReportPayload
    $payload.zones = @($payload.zones | Where-Object zone -ne 'attachments')
    [System.IO.File]::WriteAllText(
        $reportPath,
        ($payload | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws -ExpectedMessage 'exactly the three zones' -Action {
        Read-VerifiedCatchUpReport -Report (Get-Item -LiteralPath $reportPath)
    }

    Write-Host 'CloudKit Windows catch-up contract tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::GetTempPath()
        ).TrimEnd('\') + '\'
        if (-not $resolvedTestRoot.StartsWith(
                $resolvedTempRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            [System.IO.Path]::GetFileName($resolvedTestRoot) -notmatch
                '^openbubbles-catch-up-test-[0-9a-f]{32}$') {
            throw "Refusing to remove an unexpected test directory."
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
